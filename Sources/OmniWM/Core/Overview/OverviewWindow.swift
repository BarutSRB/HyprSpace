// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class OverviewWindow: NSPanel {
    private let overlayView: OverviewView
    private let monitor: Monitor

    var monitorId: Monitor.ID {
        monitor.id
    }

    var displayId: CGDirectDisplayID {
        monitor.displayId
    }

    var onWindowSelected: ((Monitor.ID, WindowHandle) -> Void)?
    var onWindowClosed: ((Monitor.ID, WindowHandle) -> Void)?
    var onDismiss: ((Monitor.ID) -> Void)?
    var onScroll: ((Monitor.ID, CGFloat) -> Void)?
    var onScrollWithModifiers: ((Monitor.ID, CGFloat, NSEvent.ModifierFlags, Bool) -> Void)?
    var onDragBegin: ((Monitor.ID, WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((Monitor.ID, CGPoint) -> Void)?
    var onDragEnd: ((Monitor.ID, CGPoint) -> Void)?
    var onDragCancel: (() -> Void)?

    init(monitor: Monitor, palette: OverviewRenderPalette = .default) {
        self.monitor = monitor
        overlayView = OverviewView(frame: .zero, displayId: monitor.displayId, palette: palette)

        super.init(
            contentRect: monitor.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true

        contentView = overlayView
        overlayView.frame = CGRect(origin: .zero, size: monitor.frame.size)

        overlayView.onWindowSelected = { [weak self] handle in
            guard let self else { return }
            self.onWindowSelected?(self.monitor.id, handle)
        }
        overlayView.onWindowClosed = { [weak self] handle in
            guard let self else { return }
            self.onWindowClosed?(self.monitor.id, handle)
        }
        overlayView.onDismiss = { [weak self] in
            guard let self else { return }
            self.onDismiss?(self.monitor.id)
        }
        overlayView.onScroll = { [weak self] delta in
            guard let self else { return }
            self.onScroll?(self.monitor.id, delta)
        }
        overlayView.onScrollWithModifiers = { [weak self] delta, modifiers, isPrecise in
            guard let self else { return }
            self.onScrollWithModifiers?(self.monitor.id, delta, modifiers, isPrecise)
        }
        overlayView.onDragBegin = { [weak self] handle, start in
            guard let self else { return }
            self.onDragBegin?(self.monitor.id, handle, start)
        }
        overlayView.onDragUpdate = { [weak self] point in
            guard let self else { return }
            self.onDragUpdate?(self.monitor.id, point)
        }
        overlayView.onDragEnd = { [weak self] point in
            guard let self else { return }
            self.onDragEnd?(self.monitor.id, point)
        }
        overlayView.onDragCancel = { [weak self] in
            self?.onDragCancel?()
        }
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    func show(asKeyWindow: Bool) {
        setFrame(monitor.frame, display: false)
        overlayView.frame = CGRect(origin: .zero, size: monitor.frame.size)
        if asKeyWindow {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(overlayView)
        } else {
            orderFrontRegardless()
        }
    }

    func hide() {
        orderOut(nil)
    }

    func cancelPendingDragIfNeeded(optionPressed: Bool) {
        overlayView.cancelPendingDragIfNeeded(optionPressed: optionPressed)
    }

    func updateLayout(
        _ layout: OverviewLayout,
        state: OverviewState,
        searchQuery: String,
        selectedWindowHandle: WindowHandle?,
        palette: OverviewRenderPalette? = nil,
        thumbnails: [Int: CGImage]? = nil
    ) {
        overlayView.updateLayout(
            layout,
            state: state,
            searchQuery: searchQuery,
            selectedWindowHandle: selectedWindowHandle,
            palette: palette,
            thumbnails: thumbnails
        )
    }

    func updateThumbnails(_ thumbnails: [Int: CGImage]) {
        overlayView.updateThumbnails(thumbnails)
    }

    func updateAnimationProgress(
        _ progress: Double,
        generation: UInt64,
        sequence: UInt64
    ) {
        overlayView.updateAnimationProgress(
            progress,
            generation: generation,
            sequence: sequence
        )
    }

    func updatePalette(_ palette: OverviewRenderPalette) {
        overlayView.updatePalette(palette)
    }
}

@MainActor
final class OverviewView: NSView {
    private(set) var layout: OverviewLayout = .init()
    private(set) var searchQuery: String = ""
    private(set) var thumbnails: [Int: CGImage] = [:]
    private(set) var palette: OverviewRenderPalette
    private(set) var selectedWindowHandle: WindowHandle?
    private(set) var presentationProgress: Double = 0

    private let displayId: CGDirectDisplayID

    var onWindowSelected: ((WindowHandle) -> Void)?
    var onWindowClosed: ((WindowHandle) -> Void)?
    var onDismiss: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onScrollWithModifiers: ((CGFloat, NSEvent.ModifierFlags, Bool) -> Void)?
    var onDragBegin: ((WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?
    var onDragCancel: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragCandidateHandle: WindowHandle?
    private var dragStartPoint: CGPoint = .zero
    private var isDragging: Bool = false
    private var hoveredWindowHandle: WindowHandle?
    private var closeButtonHovered = false
    private var textLineCache = OverviewTextLineCache()
    private var traceCaptureGeneration: UInt64 = 0
    private var traceGeneration: UInt64 = 0
    private var traceSequence: UInt64 = 0
    private var traceInvalidatedAt: CFTimeInterval = 0
    private(set) var tracePendingInvalidations = 0
    private let dragThreshold: CGFloat = 6.0
    private let scrollAxisEpsilon: CGFloat = 0.0001

    init(
        frame: NSRect,
        displayId: CGDirectDisplayID = CGMainDisplayID(),
        palette: OverviewRenderPalette = .default
    ) {
        self.displayId = displayId
        self.palette = palette
        selectedWindowHandle = nil
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLayout(
        _ layout: OverviewLayout,
        state: OverviewState,
        searchQuery: String,
        selectedWindowHandle: WindowHandle?,
        palette: OverviewRenderPalette? = nil,
        thumbnails: [Int: CGImage]? = nil
    ) {
        self.layout = layout
        self.searchQuery = searchQuery
        self.selectedWindowHandle = selectedWindowHandle
        if let hoveredWindowHandle,
           layout.window(for: hoveredWindowHandle)?.matchesSearch != true
        {
            self.hoveredWindowHandle = nil
            closeButtonHovered = false
        }
        switch state {
        case .closed:
            presentationProgress = 0
            textLineCache.removeAll()
        case .open:
            presentationProgress = 1
        case .opening,
             .closing:
            break
        }
        if let palette {
            self.palette = palette
        }
        if let thumbnails {
            self.thumbnails = thumbnails
        }
        needsDisplay = true
    }

    func updateAnimationProgress(
        _ progress: Double,
        generation: UInt64,
        sequence: UInt64
    ) {
        let activeTraceCaptureGeneration = OverviewFrameTrace.shared.captureGeneration
        let traceActive = activeTraceCaptureGeneration != 0
        let startTime = traceActive ? CACurrentMediaTime() : 0
        presentationProgress = progress.isFinite ? min(max(progress, 0), 1) : 0
        needsDisplay = true

        guard traceActive else {
            resetFrameTraceState()
            traceCaptureGeneration = 0
            return
        }
        if traceCaptureGeneration != activeTraceCaptureGeneration {
            resetFrameTraceState()
            traceCaptureGeneration = activeTraceCaptureGeneration
        }
        let endTime = CACurrentMediaTime()
        if tracePendingInvalidations == 0 {
            traceInvalidatedAt = endTime
        }
        traceGeneration = generation
        traceSequence = sequence
        tracePendingInvalidations += 1
        OverviewFrameTrace.shared.record(
            OverviewFrameTrace.Record(
                event: .invalidation,
                mediaTime: endTime,
                displayId: displayId,
                generation: generation,
                sequence: sequence,
                progress: presentationProgress,
                durationMs: (endTime - startTime) * 1000,
                waitMs: 0,
                targetLeadMs: 0,
                pendingInvalidations: tracePendingInvalidations,
                endpointScheduled: false,
                sessionCompleted: false
            )
        )
    }

    func updateThumbnails(_ thumbnails: [Int: CGImage]) {
        self.thumbnails = thumbnails
        needsDisplay = true
    }

    func updatePalette(_ palette: OverviewRenderPalette) {
        self.palette = palette
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoverState(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = layout.windowHit(at: point)

        if let hit, hit.isCloseButton {
            onWindowClosed?(hit.window.handle)
            return
        }

        if let window = hit?.window {
            if event.modifierFlags.contains(.option) {
                dragCandidateHandle = window.handle
                dragStartPoint = point
                isDragging = false
            } else {
                onWindowSelected?(window.handle)
            }
            return
        }

        onDismiss?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = dragCandidateHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y)

        if !isDragging {
            guard distance >= dragThreshold else { return }
            isDragging = true
            onDragBegin?(handle, dragStartPoint)
        }

        onDragUpdate?(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDragging {
            onDragEnd?(point)
            cancelDragState()
            return
        }

        guard dragCandidateHandle != nil else { return }
        cancelDragState()
        let hit = layout.windowHit(at: point)

        if let hit, hit.isCloseButton {
            onWindowClosed?(hit.window.handle)
            return
        }

        if let window = hit?.window {
            onWindowSelected?(window.handle)
            return
        }

        onDismiss?()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = normalizedScrollDelta(for: event)
        if let onScrollWithModifiers {
            onScrollWithModifiers(delta, event.modifierFlags, event.hasPreciseScrollingDeltas)
        } else {
            onScroll?(delta)
        }
    }

    private func normalizedScrollDelta(for event: NSEvent) -> CGFloat {
        let rawY = event.scrollingDeltaY
        let rawX = event.scrollingDeltaX
        let dominantRaw = abs(rawY) >= abs(rawX) ? rawY : rawX
        if abs(dominantRaw) <= scrollAxisEpsilon {
            return 0
        }
        return event.isDirectionInvertedFromDevice ? -dominantRaw : dominantRaw
    }

    private func cancelDrag() {
        if isDragging {
            onDragCancel?()
        }
        cancelDragState()
    }

    func cancelPendingDragIfNeeded(optionPressed: Bool) {
        if (isDragging || dragCandidateHandle != nil), !optionPressed {
            cancelDrag()
        }
    }

    private func cancelDragState() {
        dragCandidateHandle = nil
        isDragging = false
    }

    private func updateHoverState(at point: CGPoint) {
        let hit = layout.windowHit(at: point)
        let nextHoveredHandle = hit?.window.handle
        let nextCloseButtonHovered = hit?.isCloseButton ?? false
        guard nextHoveredHandle != hoveredWindowHandle
            || nextCloseButtonHovered != closeButtonHovered
        else { return }
        hoveredWindowHandle = nextHoveredHandle
        closeButtonHovered = nextCloseButtonHovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let activeTraceCaptureGeneration = OverviewFrameTrace.shared.captureGeneration
        let traceActive = activeTraceCaptureGeneration != 0
        if traceCaptureGeneration != activeTraceCaptureGeneration {
            resetFrameTraceState()
            traceCaptureGeneration = activeTraceCaptureGeneration
        }
        let startTime = traceActive ? CACurrentMediaTime() : 0
        let generation = traceGeneration
        let sequence = traceSequence
        let pendingInvalidations = tracePendingInvalidations
        let invalidatedAt = traceInvalidatedAt
        defer {
            if traceActive {
                let endTime = CACurrentMediaTime()
                OverviewFrameTrace.shared.record(
                    OverviewFrameTrace.Record(
                        event: .draw,
                        mediaTime: endTime,
                        displayId: displayId,
                        generation: generation,
                        sequence: sequence,
                        progress: presentationProgress,
                        durationMs: (endTime - startTime) * 1000,
                        waitMs: invalidatedAt > 0 ? (startTime - invalidatedAt) * 1000 : 0,
                        targetLeadMs: 0,
                        pendingInvalidations: pendingInvalidations,
                        endpointScheduled: false,
                        sessionCompleted: false
                    )
                )
                resetPendingFrameTraceState()
            }
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        OverviewRenderer.render(
            context: context,
            layout: layout,
            thumbnails: thumbnails,
            searchQuery: searchQuery,
            selectedWindowHandle: selectedWindowHandle,
            hoveredWindowHandle: hoveredWindowHandle,
            closeButtonHovered: closeButtonHovered,
            textLineCache: &textLineCache,
            progress: presentationProgress,
            bounds: bounds,
            palette: palette
        )
    }

    private func resetFrameTraceState() {
        traceGeneration = 0
        traceSequence = 0
        resetPendingFrameTraceState()
    }

    private func resetPendingFrameTraceState() {
        traceInvalidatedAt = 0
        tracePendingInvalidations = 0
    }
}
