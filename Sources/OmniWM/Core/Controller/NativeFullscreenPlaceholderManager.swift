// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreText

struct NativeFullscreenPlaceholderUpdate: Equatable {
    let originalToken: WindowToken
    let currentToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    var frame: CGRect
    var displayContext: NativeFullscreenDisplayContext?
    let selected: Bool
    let visible: Bool
}

struct NativeFullscreenDisplayContext: Equatable {
    let workingFrame: CGRect
    let scale: CGFloat
}

enum NativeFullscreenPlaceholderGeometry {
    static func resolve(
        slotFrame: CGRect,
        workingFrame: CGRect
    ) -> CGRect? {
        guard isValid(slotFrame), isValid(workingFrame) else { return nil }
        let visibleIntersection = slotFrame.intersection(workingFrame)
        guard !visibleIntersection.isNull,
              !visibleIntersection.isEmpty,
              isValid(visibleIntersection)
        else { return nil }
        return slotFrame
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}

enum NativeFullscreenCaptureExclusionOutcome: String, Equatable {
    case failed
    case acceptedUnverified = "accepted_unverified"
    case verified

    static func resolve(writeAccepted: Bool, readback: Bool?) -> NativeFullscreenCaptureExclusionOutcome {
        guard writeAccepted else { return .failed }
        switch readback {
        case true:
            return .verified
        case nil:
            return .acceptedUnverified
        case false:
            return .failed
        }
    }
}

@MainActor
final class NativeFullscreenPlaceholderManager {
    var onActivate: ((WindowToken) -> Void)?
    var appInfoCache: AppInfoCache?

    private var windowsByOriginalToken: [WindowToken: NativeFullscreenPlaceholderWindow] = [:]

    func apply(_ placeholders: [NativeFullscreenPlaceholderUpdate], forceOrdering: Bool = false) {
        let desiredTokens = Set(placeholders.map(\.originalToken))
        let staleTokens = windowsByOriginalToken.keys.filter { !desiredTokens.contains($0) }
        for token in staleTokens {
            destroyPanel(originalToken: token)
        }

        for placeholder in placeholders {
            let window = windowsByOriginalToken[placeholder.originalToken] ?? makePanel(for: placeholder)
            window.update(placeholder, forceOrdering: forceOrdering)
        }
    }

    func moveForAnimation(_ placeholder: NativeFullscreenPlaceholderUpdate) {
        windowsByOriginalToken[placeholder.originalToken]?.moveForAnimation(
            slotFrame: placeholder.frame,
            displayContext: placeholder.displayContext
        )
    }

    func panelIdentity(for originalToken: WindowToken) -> ObjectIdentifier? {
        windowsByOriginalToken[originalToken].map(ObjectIdentifier.init)
    }

    func diagnosticsSnapshot() -> [NativeFullscreenPanelDiagnostics] {
        windowsByOriginalToken.values
            .map { $0.diagnosticsSnapshot() }
            .sorted {
                ($0.originalToken.pid, $0.originalToken.windowId)
                    < ($1.originalToken.pid, $1.originalToken.windowId)
            }
    }

    func removeAll() {
        for token in Array(windowsByOriginalToken.keys) {
            destroyPanel(originalToken: token)
        }
    }

    private func makePanel(for placeholder: NativeFullscreenPlaceholderUpdate) -> NativeFullscreenPlaceholderWindow {
        let appInfo = appInfoCache?.info(for: placeholder.currentToken.pid)
        let window = NativeFullscreenPlaceholderWindow(
            placeholder: placeholder,
            appName: appInfo?.name,
            icon: appInfo?.icon
        )
        window.onActivate = { [weak self] originalToken in
            self?.onActivate?(originalToken)
        }
        windowsByOriginalToken[placeholder.originalToken] = window
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .panelCreated,
                originalToken: placeholder.originalToken,
                currentToken: placeholder.currentToken,
                workspaceId: placeholder.workspaceId,
                slotFrame: placeholder.frame,
                visible: false,
                windowNumber: window.windowNumber
            )
        )
        window.prepareSurface()
        return window
    }

    private func destroyPanel(originalToken: WindowToken) {
        windowsByOriginalToken.removeValue(forKey: originalToken)?.destroy()
    }
}

@MainActor
private final class NativeFullscreenPlaceholderWindow: NSPanel {
    private static let captureExclusionRetryDelays: [Duration] = [
        .milliseconds(50),
        .milliseconds(150),
        .milliseconds(400)
    ]

    private let placeholderView: NativeFullscreenPlaceholderView
    private let originalToken: WindowToken
    private let surfaceId: String
    private var currentToken: WindowToken?
    private var workspaceId: WorkspaceDescriptor.ID?
    private var slotFrame: CGRect
    private var displayContext: NativeFullscreenDisplayContext?
    private var appliedPanelFrame: CGRect?
    private var descriptorVisible: Bool
    private var appliedVisible = false
    private var registeredWindowNumber: Int?
    private var excludedWindowNumber: Int?
    private var captureExclusionOutcome: NativeFullscreenCaptureExclusionOutcome?
    private var captureExclusionRetryIndex = 0
    private var captureExclusionRetryExhausted = false
    private var captureExclusionRetryTask: Task<Void, Never>?

    var onActivate: ((WindowToken) -> Void)?

    init(placeholder: NativeFullscreenPlaceholderUpdate, appName: String?, icon: NSImage?) {
        originalToken = placeholder.originalToken
        surfaceId = "native-fullscreen-placeholder-\(placeholder.originalToken.pid)-\(placeholder.originalToken.windowId)"
        currentToken = placeholder.currentToken
        workspaceId = placeholder.workspaceId
        slotFrame = placeholder.frame
        displayContext = placeholder.displayContext
        descriptorVisible = placeholder.visible
        placeholderView = NativeFullscreenPlaceholderView(appName: appName, icon: icon)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = false
        isOpaque = false
        backgroundColor = .clear
        level = .normal
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        placeholderView.onActivate = { [weak self] in
            self?.activate()
        }
        placeholderView.setSelected(placeholder.selected)
        contentView = placeholderView
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func prepareSurface() {
        registerSurface()
        ensureCaptureExclusion(schedulesRetry: false)
    }

    func update(
        _ update: NativeFullscreenPlaceholderUpdate,
        forceOrdering: Bool
    ) {
        currentToken = update.currentToken
        workspaceId = update.workspaceId
        slotFrame = update.frame
        displayContext = update.displayContext
        descriptorVisible = update.visible
        placeholderView.setSelected(update.selected)
        reconcileGeometry(forceOrdering: forceOrdering)
    }

    func moveForAnimation(
        slotFrame: CGRect,
        displayContext: NativeFullscreenDisplayContext?
    ) {
        self.slotFrame = slotFrame
        self.displayContext = displayContext
        guard descriptorVisible else { return }
        reconcileGeometry(forceOrdering: false)
    }

    func destroy() {
        cancelCaptureExclusionRetry(resetsAttempts: true)
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .panelDestroyed,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                slotFrame: slotFrame,
                panelFrame: appliedPanelFrame,
                visible: isVisible,
                windowNumber: windowNumber
            )
        )
        SurfaceCoordinator.shared.unregister(id: surfaceId)
        orderOut(nil)
        close()
    }

    func diagnosticsSnapshot() -> NativeFullscreenPanelDiagnostics {
        let panelWindowNumber = windowNumber
        let registryCaptureEligible = panelWindowNumber > 0
            ? SurfaceCoordinator.shared.isCaptureEligible(windowNumber: panelWindowNumber)
            : nil
        let skyLightCaptureExcluded = UInt32(exactly: panelWindowNumber).flatMap {
            SkyLight.shared.isExcludedFromScreencaptureWindowSelection($0)
        }
        return NativeFullscreenPanelDiagnostics(
            originalToken: originalToken,
            currentToken: currentToken,
            workspaceId: workspaceId,
            slotFrame: slotFrame,
            displayContext: displayContext,
            panelFrame: appliedPanelFrame,
            windowFrame: frame,
            descriptorVisible: descriptorVisible,
            appliedVisible: appliedVisible,
            windowVisible: isVisible,
            windowNumber: panelWindowNumber,
            level: level.rawValue,
            orderedIndex: orderedIndex,
            onActiveSpace: isOnActiveSpace,
            collectionBehavior: collectionBehavior.rawValue,
            registeredWindowNumber: registeredWindowNumber,
            registryCaptureEligible: registryCaptureEligible,
            skyLightCaptureExcluded: skyLightCaptureExcluded,
            excludedWindowNumber: excludedWindowNumber,
            captureExclusionOutcome: captureExclusionOutcome,
            captureRetryIndex: captureExclusionRetryIndex,
            captureRetryPending: captureExclusionRetryTask != nil,
            captureRetryExhausted: captureExclusionRetryExhausted
        )
    }

    private func reconcileGeometry(forceOrdering: Bool) {
        guard descriptorVisible,
              let displayContext,
              let panelFrame = NativeFullscreenPlaceholderGeometry.resolve(
                  slotFrame: slotFrame,
                  workingFrame: displayContext.workingFrame
              )
        else {
            hidePanel()
            return
        }

        applyPanelFrame(panelFrame)

        if !isVisible || forceOrdering {
            let wasVisible = isVisible
            orderBack(nil)
            appliedVisible = true
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    wasVisible ? .panelOrdered : .panelShown,
                    originalToken: originalToken,
                    currentToken: currentToken,
                    workspaceId: workspaceId,
                    slotFrame: slotFrame,
                    panelFrame: appliedPanelFrame,
                    visible: isVisible,
                    windowNumber: windowNumber,
                    reason: isVisible ? .accepted : .orderingFailed
                )
            )
            ensureCaptureExclusion(schedulesRetry: true)
        } else {
            appliedVisible = true
        }
    }

    private func applyPanelFrame(_ nextFrame: CGRect) {
        guard appliedPanelFrame != nextFrame || frame != nextFrame else { return }
        let sizeChanged = frame.size != nextFrame.size
        if frame.size == nextFrame.size {
            setFrameOrigin(nextFrame.origin)
        } else {
            setFrame(nextFrame, display: false)
        }
        appliedPanelFrame = nextFrame
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                sizeChanged ? .panelResized : .panelMoved,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                slotFrame: slotFrame,
                panelFrame: nextFrame,
                visible: isVisible,
                windowNumber: windowNumber
            )
        )
        if sizeChanged {
            placeholderView.needsDisplay = true
        }
    }

    private func hidePanel() {
        cancelCaptureExclusionRetry(resetsAttempts: true)
        placeholderView.cancelInteraction()
        if appliedVisible || isVisible {
            orderOut(nil)
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .panelHidden,
                    originalToken: originalToken,
                    currentToken: currentToken,
                    workspaceId: workspaceId,
                    slotFrame: slotFrame,
                    panelFrame: appliedPanelFrame,
                    visible: false,
                    windowNumber: windowNumber,
                    reason: descriptorVisible ? .geometryRejected : .descriptorHidden
                )
            )
        }
        appliedVisible = false
    }

    private func activate() {
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .activationRequested,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                slotFrame: slotFrame,
                panelFrame: appliedPanelFrame,
                visible: isVisible,
                windowNumber: windowNumber
            )
        )
        onActivate?(originalToken)
    }

    private func registerSurface() {
        SurfaceCoordinator.shared.register(
            window: self,
            id: surfaceId,
            policy: SurfacePolicy(
                kind: .nativeFullscreenPlaceholder,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredWindowNumber = windowNumber > 0 ? windowNumber : nil
    }

    private func ensureCaptureExclusion(schedulesRetry: Bool) {
        let panelWindowNumber = windowNumber
        guard panelWindowNumber > 0 else {
            if schedulesRetry {
                scheduleCaptureExclusionRetry()
            }
            return
        }
        if registeredWindowNumber != panelWindowNumber {
            registerSurface()
        }
        guard excludedWindowNumber != panelWindowNumber else {
            cancelCaptureExclusionRetry(resetsAttempts: false)
            return
        }
        let windowId = UInt32(panelWindowNumber)
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .captureAttempt,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                visible: appliedVisible,
                windowNumber: panelWindowNumber,
                retryIndex: captureExclusionRetryIndex
            )
        )
        let writeAccepted = SkyLight.shared.excludeFromScreencaptureWindowSelection(windowId)
        let readback = writeAccepted
            ? SkyLight.shared.isExcludedFromScreencaptureWindowSelection(windowId)
            : nil
        captureExclusionOutcome = NativeFullscreenCaptureExclusionOutcome.resolve(
            writeAccepted: writeAccepted,
            readback: readback
        )
        if captureExclusionOutcome == .verified || captureExclusionOutcome == .acceptedUnverified {
            excludedWindowNumber = panelWindowNumber
            let reason: NativeFullscreenPlaceholderTrace.Reason = captureExclusionOutcome == .verified
                ? .captureVerified
                : .captureUnverified
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .captureExcluded,
                    originalToken: originalToken,
                    currentToken: currentToken,
                    workspaceId: workspaceId,
                    visible: appliedVisible,
                    windowNumber: panelWindowNumber,
                    reason: reason,
                    retryIndex: captureExclusionRetryIndex
                )
            )
            cancelCaptureExclusionRetry(resetsAttempts: false)
        } else if schedulesRetry {
            scheduleCaptureExclusionRetry()
        }
    }

    private func scheduleCaptureExclusionRetry() {
        guard captureExclusionRetryTask == nil else { return }
        guard Self.captureExclusionRetryDelays.indices.contains(captureExclusionRetryIndex) else {
            if !captureExclusionRetryExhausted {
                FallbackFiringRecorder.shared.note(.capture, "nativeFullscreenPlaceholderExclusionRetryExhausted")
                captureExclusionRetryExhausted = true
                NativeFullscreenPlaceholderTrace.record(
                    NativeFullscreenPlaceholderTrace.makeRecord(
                        .captureRetryExhausted,
                        originalToken: originalToken,
                        currentToken: currentToken,
                        workspaceId: workspaceId,
                        visible: appliedVisible,
                        windowNumber: windowNumber,
                        reason: .captureFailed,
                        retryIndex: captureExclusionRetryIndex
                    )
                )
            }
            return
        }

        let delay = Self.captureExclusionRetryDelays[captureExclusionRetryIndex]
        captureExclusionRetryIndex += 1
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .captureRetryScheduled,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                visible: appliedVisible,
                windowNumber: windowNumber,
                retryIndex: captureExclusionRetryIndex
            )
        )
        captureExclusionRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            captureExclusionRetryTask = nil
            guard appliedVisible else { return }
            ensureCaptureExclusion(schedulesRetry: true)
        }
    }

    private func cancelCaptureExclusionRetry(resetsAttempts: Bool) {
        if let captureExclusionRetryTask {
            captureExclusionRetryTask.cancel()
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .captureRetryCancelled,
                    originalToken: originalToken,
                    currentToken: currentToken,
                    workspaceId: workspaceId,
                    visible: appliedVisible,
                    windowNumber: windowNumber,
                    retryIndex: captureExclusionRetryIndex
                )
            )
        }
        captureExclusionRetryTask = nil
        if resetsAttempts {
            captureExclusionRetryIndex = 0
            captureExclusionRetryExhausted = false
        }
    }
}

private final class NativeFullscreenPlaceholderView: NSView {
    private static let title = "In macOS Full Screen"
    private static let subtitle = "Move or resize this slot; the window will return here."
    private static let activationModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
    private static let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold) as CTFont
    private static let subtitleFont = NSFont.systemFont(ofSize: 12) as CTFont

    private let appName: String
    private let icon: CGImage?
    private let titleLine: CTLine
    private let subtitleLine: CTLine
    private let titleLineWidth: CGFloat
    private let subtitleLineWidth: CGFloat
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var isTrackingPrimaryPress = false
    private var isSelected = false

    var onActivate: (() -> Void)?

    init(appName: String?, icon: NSImage?) {
        let resolvedAppName = appName ?? "Application"
        self.appName = resolvedAppName
        let sourceIcon = icon ?? NSImage(named: NSImage.applicationIconName)
        self.icon = sourceIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let titleAttributed = Self.attributedLine(
            Self.title,
            font: Self.titleFont,
            color: .white
        )
        let subtitleAttributed = Self.attributedLine(
            Self.subtitle,
            font: Self.subtitleFont,
            color: NSColor.white.withAlphaComponent(0.78)
        )
        let resolvedTitleLine = CTLineCreateWithAttributedString(titleAttributed)
        let resolvedSubtitleLine = CTLineCreateWithAttributedString(subtitleAttributed)
        titleLine = resolvedTitleLine
        subtitleLine = resolvedSubtitleLine
        titleLineWidth = CGFloat(CTLineGetTypographicBounds(resolvedTitleLine, nil, nil, nil))
        subtitleLineWidth = CGFloat(CTLineGetTypographicBounds(resolvedSubtitleLine, nil, nil, nil))
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolTip = "Press to switch Spaces. The tiling position remains reserved."
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let nextTracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTracking)
        tracking = nextTracking
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let panelBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(
            roundedRect: panelBounds,
            cornerWidth: 10,
            cornerHeight: 10,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(resolvedColor(.black, alpha: 0.98))
        context.fillPath()

        if isHovered || isPressed {
            context.addPath(path)
            let alpha: CGFloat = isPressed ? 0.16 : 0.07
            context.setFillColor(resolvedColor(.controlAccentColor, alpha: alpha))
            context.fillPath()
        }

        context.addPath(path)
        context.setLineWidth(isSelected ? 2 : 1)
        context.setStrokeColor(
            isSelected
                ? resolvedColor(.controlAccentColor, alpha: 1)
                : resolvedColor(.separatorColor, alpha: 0.9)
        )
        context.strokePath()

        drawContent(in: context)
    }

    override func mouseEntered(with _: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with _: NSEvent) {
        setHovered(false)
        if isTrackingPrimaryPress {
            setPressed(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0,
              event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        else { return }
        isTrackingPrimaryPress = true
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPrimaryPress else { return }
        let point = convert(event.locationInWindow, from: nil)
        setPressed(
            bounds.contains(point)
                && event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingPrimaryPress else { return }
        let point = convert(event.locationInWindow, from: nil)
        let shouldActivate = event.buttonNumber == 0
            && bounds.contains(point)
            && event.modifierFlags.isDisjoint(with: Self.activationModifiers)
        isTrackingPrimaryPress = false
        setPressed(false)
        if shouldActivate {
            onActivate?()
        }
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityLabel() -> String? {
        "\(appName), in macOS Full Screen"
    }

    override func accessibilityHelp() -> String? {
        "Press to switch to the app's macOS Full Screen Space. Its tiling position remains reserved."
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: isSelected)
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func cancelInteraction() {
        isTrackingPrimaryPress = false
        setPressed(false)
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    private func setPressed(_ pressed: Bool) {
        guard isPressed != pressed else { return }
        isPressed = pressed
        needsDisplay = true
    }

    private func drawContent(in context: CGContext) {
        let shortestSide = min(bounds.width, bounds.height)
        let maximumTextWidth = max(bounds.width - 48, 0)
        if bounds.width < 180
            || bounds.height < 140
            || titleLineWidth > maximumTextWidth
            || subtitleLineWidth > maximumTextWidth
        {
            let iconSide = min(64, max(min(shortestSide, 24), shortestSide - 24))
            drawIcon(
                in: CGRect(
                    x: (bounds.width - iconSide) / 2,
                    y: (bounds.height - iconSide) / 2,
                    width: iconSide,
                    height: iconSide
                ),
                context: context
            )
            return
        }
        let iconSide = min(96, max(48, shortestSide * 0.2))
        let titleHeight = CGFloat(CTFontGetAscent(Self.titleFont) + CTFontGetDescent(Self.titleFont))
        let subtitleHeight = CGFloat(CTFontGetAscent(Self.subtitleFont) + CTFontGetDescent(Self.subtitleFont))
        let contentHeight = iconSide + 16 + titleHeight + 6 + subtitleHeight
        let contentBottom = max((bounds.height - contentHeight) / 2, 16)
        let iconFrame = CGRect(
            x: (bounds.width - iconSide) / 2,
            y: contentBottom + titleHeight + subtitleHeight + 22,
            width: iconSide,
            height: iconSide
        )
        drawIcon(in: iconFrame, context: context)
        drawCentered(
            line: titleLine,
            lineWidth: titleLineWidth,
            baseline: contentBottom + subtitleHeight + 6,
            context: context
        )
        drawCentered(
            line: subtitleLine,
            lineWidth: subtitleLineWidth,
            baseline: contentBottom,
            context: context
        )
    }

    private func drawIcon(in frame: CGRect, context: CGContext) {
        guard let icon else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(icon, in: frame)
        context.restoreGState()
    }

    private func drawCentered(
        line: CTLine,
        lineWidth: CGFloat,
        baseline: CGFloat,
        context: CGContext
    ) {
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: (bounds.width - lineWidth) / 2, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func resolvedColor(_ color: NSColor, alpha: CGFloat) -> CGColor {
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.withAlphaComponent(alpha).cgColor
        }
        return resolved ?? color.withAlphaComponent(alpha).cgColor
    }

    private static func attributedLine(
        _ text: String,
        font: CTFont,
        color: NSColor
    ) -> NSAttributedString {
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color
            ]
        )
    }
}
