// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreText

struct NativeFullscreenPlaceholderUpdate: Equatable {
    let originalToken: WindowToken
    let currentToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    var frame: CGRect
    var displayContext: NativeFullscreenCardDisplayContext?
    let selected: Bool
    let visible: Bool
}

struct NativeFullscreenCardDisplayContext: Equatable {
    let workingFrame: CGRect
    let scale: CGFloat
}

enum NativeFullscreenCardMode: Equatable {
    case regular
    case compact
}

struct NativeFullscreenCardLayout: Equatable {
    let mode: NativeFullscreenCardMode
    let frame: CGRect
}

enum NativeFullscreenCardGeometry {
    static let regularHeight: CGFloat = 64
    static let regularMinimumWidth: CGFloat = 176
    static let regularMaximumWidth: CGFloat = 288

    private static let regularInset: CGFloat = 12
    private static let regularExitHysteresis: CGFloat = 8
    private static let compactMinimumVisibleSide: CGFloat = 52
    private static let compactExitHysteresis: CGFloat = 8
    private static let compactMinimumSide: CGFloat = 44
    private static let compactMaximumSide: CGFloat = 64
    private static let compactVisiblePadding: CGFloat = 8

    static func resolve(
        slotFrame: CGRect,
        workingFrame: CGRect,
        scale: CGFloat,
        preferredRegularWidth: CGFloat,
        previousMode: NativeFullscreenCardMode?
    ) -> NativeFullscreenCardLayout? {
        guard isValid(slotFrame), isValid(workingFrame) else { return nil }
        let visibleFrame = slotFrame.intersection(workingFrame)
        guard !visibleFrame.isNull, !visibleFrame.isEmpty, isValid(visibleFrame) else { return nil }

        let regularArea = visibleFrame.insetBy(dx: regularInset, dy: regularInset)
        let regularWidthThreshold = previousMode == .regular
            ? regularMinimumWidth - regularExitHysteresis
            : regularMinimumWidth
        let regularHeightThreshold = previousMode == .regular
            ? regularHeight - regularExitHysteresis
            : regularHeight

        if regularArea.width >= regularWidthThreshold,
           regularArea.height >= regularHeightThreshold
        {
            let maximumAvailableWidth = max(regularArea.width, regularMinimumWidth)
            let width = min(
                max(preferredRegularWidth.isFinite ? preferredRegularWidth : regularMinimumWidth, regularMinimumWidth),
                min(regularMaximumWidth, maximumAvailableWidth)
            )
            return NativeFullscreenCardLayout(
                mode: .regular,
                frame: centeredFrame(
                    size: CGSize(width: width, height: regularHeight),
                    in: visibleFrame,
                    scale: scale
                )
            )
        }

        let compactThreshold = previousMode == nil
            ? compactMinimumVisibleSide
            : compactMinimumVisibleSide - compactExitHysteresis
        let visibleSide = min(visibleFrame.width, visibleFrame.height)
        guard visibleSide >= compactThreshold else { return nil }
        let cardSide = min(
            max(visibleSide - compactVisiblePadding, compactMinimumSide),
            compactMaximumSide
        )
        return NativeFullscreenCardLayout(
            mode: .compact,
            frame: centeredFrame(
                size: CGSize(width: cardSide, height: cardSide),
                in: visibleFrame,
                scale: scale
            )
        )
    }

    private static func centeredFrame(size: CGSize, in container: CGRect, scale: CGFloat) -> CGRect {
        let frame = CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let effectiveScale = scale.isFinite && scale > 0 ? scale : 1
        return frame.roundedToPhysicalPixels(scale: effectiveScale)
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
            originalToken: placeholder.originalToken,
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
    private var slotFrame = CGRect.zero
    private var displayContext: NativeFullscreenCardDisplayContext?
    private var cardMode: NativeFullscreenCardMode?
    private var appliedCardFrame: CGRect?
    private var descriptorVisible = false
    private var appliedVisible = false
    private var registeredWindowNumber: Int?
    private var excludedWindowNumber: Int?
    private var captureExclusionRetryIndex = 0
    private var captureExclusionRetryExhausted = false
    private var captureExclusionRetryTask: Task<Void, Never>?

    var onActivate: ((WindowToken) -> Void)?

    init(originalToken: WindowToken, appName: String?, icon: NSImage?) {
        self.originalToken = originalToken
        surfaceId = "native-fullscreen-placeholder-\(originalToken.pid)-\(originalToken.windowId)"
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
        contentView = placeholderView

        registerSurface()
        ensureCaptureExclusion(schedulesRetry: false)
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
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
        displayContext: NativeFullscreenCardDisplayContext?
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
                cardFrame: appliedCardFrame,
                visible: isVisible,
                mode: cardMode.map(NativeFullscreenPlaceholderTrace.Mode.init),
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
            cardFrame: appliedCardFrame,
            windowFrame: frame,
            cardMode: cardMode,
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
            captureRetryIndex: captureExclusionRetryIndex,
            captureRetryPending: captureExclusionRetryTask != nil,
            captureRetryExhausted: captureExclusionRetryExhausted
        )
    }

    private func reconcileGeometry(forceOrdering: Bool) {
        guard descriptorVisible,
              let displayContext,
              let layout = NativeFullscreenCardGeometry.resolve(
                  slotFrame: slotFrame,
                  workingFrame: displayContext.workingFrame,
                  scale: displayContext.scale,
                  preferredRegularWidth: placeholderView.preferredRegularWidth,
                  previousMode: cardMode
              )
        else {
            hidePanel()
            return
        }

        if cardMode != layout.mode {
            cardMode = layout.mode
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .panelModeChanged,
                    originalToken: originalToken,
                    currentToken: currentToken,
                    workspaceId: workspaceId,
                    slotFrame: slotFrame,
                    cardFrame: layout.frame,
                    visible: isVisible,
                    mode: .init(layout.mode),
                    windowNumber: windowNumber
                )
            )
        }
        placeholderView.setMode(layout.mode)
        applyCardFrame(layout.frame)

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
                    cardFrame: appliedCardFrame,
                    visible: isVisible,
                    mode: cardMode.map(NativeFullscreenPlaceholderTrace.Mode.init),
                    windowNumber: windowNumber,
                    reason: isVisible ? .accepted : .orderingFailed
                )
            )
            ensureCaptureExclusion(schedulesRetry: true)
        } else {
            appliedVisible = true
        }
    }

    private func applyCardFrame(_ nextFrame: CGRect) {
        guard appliedCardFrame != nextFrame || frame != nextFrame else { return }
        let sizeChanged = frame.size != nextFrame.size
        if frame.size == nextFrame.size {
            setFrameOrigin(nextFrame.origin)
        } else {
            setFrame(nextFrame, display: false)
        }
        appliedCardFrame = nextFrame
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                sizeChanged ? .panelResized : .panelMoved,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                slotFrame: slotFrame,
                cardFrame: nextFrame,
                visible: isVisible,
                mode: cardMode.map(NativeFullscreenPlaceholderTrace.Mode.init),
                windowNumber: windowNumber
            )
        )
        if sizeChanged {
            placeholderView.needsDisplay = true
        }
    }

    private func hidePanel() {
        if descriptorVisible {
            cardMode = nil
        }
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
                    cardFrame: appliedCardFrame,
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
                cardFrame: appliedCardFrame,
                visible: isVisible,
                mode: cardMode.map(NativeFullscreenPlaceholderTrace.Mode.init),
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
        if SkyLight.shared.excludeFromScreencaptureWindowSelection(windowId),
           SkyLight.shared.isExcludedFromScreencaptureWindowSelection(windowId) != false
        {
            excludedWindowNumber = panelWindowNumber
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .captureExcluded,
                    originalToken: originalToken,
                    currentToken: currentToken,
                    workspaceId: workspaceId,
                    visible: appliedVisible,
                    windowNumber: panelWindowNumber,
                    reason: .accepted,
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
    private static let status = "In macOS Full Screen"
    private static let activationModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
    private static let appFont = CTFontCreateWithName("SF Pro Text" as CFString, 13, nil)
    private static let statusFont = CTFontCreateWithName("SF Pro Text" as CFString, 11, nil)

    private let appName: String
    private let icon: CGImage?
    private var appLine: CTLine
    private var statusLine: CTLine
    private var appTruncationToken: CTLine
    private var statusTruncationToken: CTLine
    private var mode = NativeFullscreenCardMode.regular
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var isTrackingPrimaryPress = false
    private var isSelected = false

    let preferredRegularWidth: CGFloat
    var onActivate: (() -> Void)?

    init(appName: String?, icon: NSImage?) {
        let resolvedAppName = appName ?? "Application"
        self.appName = resolvedAppName
        let sourceIcon = icon ?? NSImage(named: NSImage.applicationIconName)
        self.icon = sourceIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let appAttributed = Self.attributedLine(
            resolvedAppName,
            font: Self.appFont,
            color: .labelColor
        )
        let statusAttributed = Self.attributedLine(
            Self.status,
            font: Self.statusFont,
            color: .secondaryLabelColor
        )
        appLine = CTLineCreateWithAttributedString(appAttributed)
        statusLine = CTLineCreateWithAttributedString(statusAttributed)
        appTruncationToken = CTLineCreateWithAttributedString(
            Self.attributedLine("…", font: Self.appFont, color: .labelColor)
        )
        statusTruncationToken = CTLineCreateWithAttributedString(
            Self.attributedLine("…", font: Self.statusFont, color: .secondaryLabelColor)
        )
        let textWidth = max(
            CGFloat(CTLineGetTypographicBounds(appLine, nil, nil, nil)),
            CGFloat(CTLineGetTypographicBounds(statusLine, nil, nil, nil))
        )
        preferredRegularWidth = textWidth + 74
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
        rebuildTextLines()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let cardBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(
            roundedRect: cardBounds,
            cornerWidth: 10,
            cornerHeight: 10,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(resolvedColor(.windowBackgroundColor, alpha: 0.96))
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

        switch mode {
        case .regular:
            drawRegularContent(in: context)
        case .compact:
            drawCompactContent(in: context)
        }
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

    func setMode(_ mode: NativeFullscreenCardMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        needsDisplay = true
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

    private func drawRegularContent(in context: CGContext) {
        drawIcon(in: CGRect(x: 12, y: 12, width: 40, height: 40), context: context)
        let textX: CGFloat = 62
        let textWidth = max(bounds.width - textX - 12, 0)
        draw(
            line: appLine,
            truncationToken: appTruncationToken,
            x: textX,
            baseline: 36,
            maximumWidth: textWidth,
            context: context
        )
        draw(
            line: statusLine,
            truncationToken: statusTruncationToken,
            x: textX,
            baseline: 18,
            maximumWidth: textWidth,
            context: context
        )
    }

    private func drawCompactContent(in context: CGContext) {
        let iconSide = min(40, max(min(bounds.width, bounds.height) - 12, 24))
        drawIcon(
            in: CGRect(
                x: (bounds.width - iconSide) / 2,
                y: (bounds.height - iconSide) / 2,
                width: iconSide,
                height: iconSide
            ),
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

    private func draw(
        line: CTLine,
        truncationToken: CTLine,
        x: CGFloat,
        baseline: CGFloat,
        maximumWidth: CGFloat,
        context: CGContext
    ) {
        guard maximumWidth > 0 else { return }
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let renderedLine = lineWidth > maximumWidth
            ? CTLineCreateTruncatedLine(line, Double(maximumWidth), .end, truncationToken) ?? line
            : line
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(renderedLine, context)
        context.restoreGState()
    }

    private func rebuildTextLines() {
        appLine = CTLineCreateWithAttributedString(
            Self.attributedLine(appName, font: Self.appFont, color: .labelColor)
        )
        statusLine = CTLineCreateWithAttributedString(
            Self.attributedLine(
                Self.status,
                font: Self.statusFont,
                color: .secondaryLabelColor
            )
        )
        appTruncationToken = CTLineCreateWithAttributedString(
            Self.attributedLine("…", font: Self.appFont, color: .labelColor)
        )
        statusTruncationToken = CTLineCreateWithAttributedString(
            Self.attributedLine(
                "…",
                font: Self.statusFont,
                color: .secondaryLabelColor
            )
        )
    }

    private func resolvedColor(_ color: NSColor, alpha: CGFloat) -> CGColor {
        var resolved = color.withAlphaComponent(alpha).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.withAlphaComponent(alpha).cgColor
        }
        return resolved
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
