// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

private let niriTouchpadGestureRecognitionThreshold: CGFloat = 16.0
// AppKit gives normalized touch positions rather than libinput gesture deltas.
// This maps normalized movement into the delta space that AnimationDriver later
// normalizes with gestureWorkingAreaMovement.
private let macNormalizedTouchPositionToNiriGestureUnits: CGFloat = 500.0
private let mouseWheelAxisEpsilon: CGFloat = 0.001
private let niriWheelScrollTickAmount: CGFloat = 120.0
private let trackpadGestureScrollTailSuppressionDuration: TimeInterval = 0.25
private let mouseRelevantModifierFlags: CGEventFlags = [
    .maskAlternate,
    .maskShift,
    .maskControl,
    .maskCommand
]

@MainActor
final class MouseEventHandler {
    enum ViewportGestureTerminationDisposition {
        case settleLiveOffset
        case settleLiveOffsetWithoutRelayout
        case viewportAlreadySettled
    }

    struct PerformanceSnapshot: Equatable, Sendable {
        let cgEvents: UInt64
        let mouseMovedEvents: UInt64
        let mouseDraggedEvents: UInt64
        let scrollEvents: UInt64
        let buttonEvents: UInt64
        let droppedTrackpadScrollEvents: UInt64
        let mouseWarpSamples: UInt64
        let multitouch: MultitouchFrameMailbox.PerformanceSnapshot?
    }

    private struct PerformanceCounters {
        var cgEvents: UInt64 = 0
        var mouseMovedEvents: UInt64 = 0
        var mouseDraggedEvents: UInt64 = 0
        var scrollEvents: UInt64 = 0
        var buttonEvents: UInt64 = 0
        var droppedTrackpadScrollEvents: UInt64 = 0
        var mouseWarpSamples: UInt64 = 0
        var retiredMultitouch: MultitouchFrameMailbox.PerformanceSnapshot?

        func snapshot(multitouch: MultitouchFrameMailbox.PerformanceSnapshot?) -> PerformanceSnapshot {
            PerformanceSnapshot(
                cgEvents: cgEvents,
                mouseMovedEvents: mouseMovedEvents,
                mouseDraggedEvents: mouseDraggedEvents,
                scrollEvents: scrollEvents,
                buttonEvents: buttonEvents,
                droppedTrackpadScrollEvents: droppedTrackpadScrollEvents,
                mouseWarpSamples: mouseWarpSamples,
                multitouch: mergedMultitouch(with: multitouch)
            )
        }

        mutating func accumulateRetiredMultitouch(
            _ snapshot: MultitouchFrameMailbox.PerformanceSnapshot
        ) {
            retiredMultitouch = if let retiredMultitouch {
                Self.mergeMultitouch(retiredMultitouch, snapshot, pendingFrames: 0)
            } else {
                Self.mergeMultitouch(snapshot, nil, pendingFrames: 0)
            }
        }

        private func mergedMultitouch(
            with current: MultitouchFrameMailbox.PerformanceSnapshot?
        ) -> MultitouchFrameMailbox.PerformanceSnapshot? {
            guard let retiredMultitouch else { return current }
            return Self.mergeMultitouch(
                retiredMultitouch,
                current,
                pendingFrames: current?.pendingFrames ?? 0
            )
        }

        private static func mergeMultitouch(
            _ accumulated: MultitouchFrameMailbox.PerformanceSnapshot,
            _ current: MultitouchFrameMailbox.PerformanceSnapshot?,
            pendingFrames: Int
        ) -> MultitouchFrameMailbox.PerformanceSnapshot {
            guard let current else {
                return MultitouchFrameMailbox.PerformanceSnapshot(
                    rawCallbacks: accumulated.rawCallbacks,
                    staleCallbacks: accumulated.staleCallbacks,
                    drainBatches: accumulated.drainBatches,
                    overwrittenChanges: accumulated.overwrittenChanges,
                    transitionsQueued: accumulated.transitionsQueued,
                    cursorSamples: accumulated.cursorSamples,
                    pendingFrames: pendingFrames,
                    maximumPendingFrames: accumulated.maximumPendingFrames
                )
            }
            return MultitouchFrameMailbox.PerformanceSnapshot(
                rawCallbacks: accumulated.rawCallbacks &+ current.rawCallbacks,
                staleCallbacks: accumulated.staleCallbacks &+ current.staleCallbacks,
                drainBatches: accumulated.drainBatches &+ current.drainBatches,
                overwrittenChanges: accumulated.overwrittenChanges &+ current.overwrittenChanges,
                transitionsQueued: accumulated.transitionsQueued &+ current.transitionsQueued,
                cursorSamples: accumulated.cursorSamples &+ current.cursorSamples,
                pendingFrames: pendingFrames,
                maximumPendingFrames: max(
                    accumulated.maximumPendingFrames,
                    current.maximumPendingFrames
                )
            )
        }
    }

    enum MouseButton: Hashable {
        case left
        case right

        var pressedMask: Int {
            switch self {
            case .left: 1
            case .right: 2
            }
        }
    }

    enum MouseMoveMode: Equatable {
        case swap
        case insert
    }

    private enum MouseWheelColumnAxis {
        case horizontal
        case vertical
    }

    private struct MouseWheelColumnDelta {
        var axis: MouseWheelColumnAxis
        var value: CGFloat
    }

    private enum FocusFollowsMouseTarget {
        case niri(workspaceId: WorkspaceDescriptor.ID, window: NiriWindow)
        case dwindle(workspaceId: WorkspaceDescriptor.ID, token: WindowToken)
        case floating(token: WindowToken)
    }

    struct GestureTouchSample: Equatable, Sendable {
        let phase: NSTouch.Phase
        let normalizedPosition: CGPoint?
    }

    struct GestureEventSnapshot: Sendable {
        let location: CGPoint
        let phaseRawValue: NSEvent.Phase.RawValue
        let timestamp: TimeInterval
        let touches: [GestureTouchSample]

        init(
            location: CGPoint,
            phaseRawValue: NSEvent.Phase.RawValue,
            timestamp: TimeInterval = CACurrentMediaTime(),
            touches: [GestureTouchSample]
        ) {
            self.location = location
            self.phaseRawValue = phaseRawValue
            self.timestamp = timestamp
            self.touches = touches
        }
    }

    struct State {
        struct LockedGestureContext {
            let workspaceId: WorkspaceDescriptor.ID
            let monitorId: Monitor.ID
            let fingerCount: Int
            let columnScrollCandidate: Bool
            let columnScrollAxis: WorkspaceSwipeAxis
            let workspaceAxis: WorkspaceSwipeAxis?
        }

        enum GesturePhase {
            case idle
            case armed
            case committed
        }

        enum NativeTitleBarDragPhase {
            case armed
            case dragging
            case awaitingFrameChange
            case awaitingFrameWrite
            case awaitingCorrection
        }

        struct NativeTitleBarDrag {
            let token: WindowToken
            var phase: NativeTitleBarDragPhase = .armed
            var receivedFrameChange = false
            var issuedUnreadableCorrection = false
            var terminalFailureRetryRequestId: AXFrameRequestId?
        }

        struct FocusFollowsMouseSample {
            let location: CGPoint
            let modifiersRawValue: UInt64
            let windowIdUnderPointer: Int?
        }

        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var moveTap: CFMachPort?
        var moveTapRunLoopSource: CFRunLoopSource?
        var currentHoveredEdges: ResizeEdge = []
        var isResizing: Bool = false
        var isMoving: Bool = false
        var activeInteractionButton: MouseButton?
        var capturedInteractionButton: MouseButton?
        var resizeLayout: LayoutType?
        var moveLayout: LayoutType?
        var awaitsNativeTitleBarDragTarget = false
        var nativeTitleBarDragFallbackToken: WindowToken?
        var nativeTitleBarDragFallbackReleased = false
        var nativeTitleBarDrag: NativeTitleBarDrag?

        var lastFocusFollowsMouseTime: Date = .distantPast
        var latestFocusFollowsMouseSample: FocusFollowsMouseSample?
        let focusFollowsMouseDebounce: TimeInterval = 0.1
        var dragGhostController: DragGhostController?

        var gesturePhase: GesturePhase = .idle
        var gestureStartX: CGFloat = 0.0
        var gestureStartY: CGFloat = 0.0
        var gestureLastAverageX: CGFloat = 0.0
        var gestureLastAverageY: CGFloat = 0.0
        var lockedGestureContext: LockedGestureContext?
        var activeGestureMode: TrackpadGestureMode?
        var viewportGestureSessionID: AnimationDriver.GestureSessionID?
        var workspaceSwipeFired = false
        let workspaceSwipeTracker = SwipeTracker()
        var suppressGestureStartUntilAllTouchesLift = false
        var consumeTrackpadScrollUntilAllTouchesLift = false
        var suppressTrackpadMomentumScroll = false
        var suppressTrackpadScrollUntil: TimeInterval?
        var horizontalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
        var verticalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
    }

    nonisolated(unsafe) weak static var _instance: MouseEventHandler?

    weak var controller: WMController?
    var state = State()
    private var multitouchSource: MultitouchGestureSource?
    private var performanceCounters: PerformanceCounters?
    var multitouchSourceFactory: @MainActor () -> MultitouchGestureSource = { MultitouchGestureSource() }
    var pressedMouseButtonsProvider: @MainActor () -> Int = { Int(NSEvent.pressedMouseButtons) }
    var nativeWindowFrameProvider: @MainActor (AXWindowRef) -> CGRect? = {
        AXWindowService.framePreferFast($0)
    }

    init(controller: WMController) {
        self.controller = controller
    }

    nonisolated static func sessionEventMask(annotatedMoveTapInstalled: Bool) -> CGEventMask {
        var mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        if !annotatedMoveTapInstalled {
            mask |= 1 << CGEventType.mouseMoved.rawValue
        }
        return mask
    }

    func setup() {
        tearDownEventTaps()
        MouseEventHandler._instance = self

        let moveCallback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                InputTapHealth.recordTapDisabled(mouse: true, byTimeout: type == .tapDisabledByTimeout)
                if let tap = MouseEventHandler._instance?.state.moveTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .leftMouseDragged, Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let handler = MouseEventHandler._instance,
                          handler.state.awaitsNativeTitleBarDragTarget
                    else { return }
                    if handler.performanceCounters != nil {
                        handler.recordCGEvent(type)
                    }
                    handler.receiveAnnotatedNativeMouseDragged(
                        windowIdUnderPointer: MouseEventHandler.eventWindowIdUnderPointer(event)
                    )
                }
            } else {
                _ = MouseEventHandler.processTapCallback(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        state.moveTap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue),
            callback: moveCallback,
            userInfo: nil
        )

        var annotatedMoveTapInstalled = false
        if let tap = state.moveTap {
            if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                state.moveTapRunLoopSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                annotatedMoveTapInstalled = true
            } else {
                tearDownMoveEventTap()
                FallbackFiringRecorder.shared.note(.input, "mouseMoveTapRunLoopSourceFailed")
            }
        } else {
            FallbackFiringRecorder.shared.note(.input, "mouseMoveTapCreateFailed")
        }
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: annotatedMoveTapInstalled ? "mouse.moveTap.installed" : "mouse.moveTap.failed"
        )

        let eventMask = Self.sessionEventMask(annotatedMoveTapInstalled: annotatedMoveTapInstalled)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                InputTapHealth.recordTapDisabled(mouse: true, byTimeout: type == .tapDisabledByTimeout)
                if let tap = MouseEventHandler._instance?.state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                Task { @MainActor in
                    MouseEventHandler._instance?.recoverAfterTapDisable()
                }
                return Unmanaged.passUnretained(event)
            }

            let suppressEvent = MouseEventHandler.processTapCallback(type: type, event: event)

            return suppressEvent ? nil : Unmanaged.passUnretained(event)
        }

        state.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = state.eventTap {
            state.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = state.runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                tearDownSessionEventTap()
                FallbackFiringRecorder.shared.note(.input, "mouseTapRunLoopSourceFailed")
            }
        } else {
            FallbackFiringRecorder.shared.note(.input, "mouseTapCreateFailed")
        }
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: state.eventTap != nil ? "mouse.tap.installed" : "mouse.tap.failed"
        )

        controller?.settings.onTrackpadGestureAvailabilityChanged = { [weak self] _ in
            self?.reconcileMultitouchSource()
        }
        reconcileMultitouchSource()
    }

    @discardableResult
    func installMultitouchSource(_ source: MultitouchGestureSource) -> Bool {
        let current = multitouchSource
        if let current, current !== source {
            guard current.shutdown() else { return false }
            accumulateRetiredMultitouchPerformance(from: current)
        }
        source.onSnapshot = { [weak self] snapshot in
            self?.receiveTapGestureEvent(snapshot)
        }
        source.onSourceWillReplace = { [weak self] in
            self?.resetForMultitouchSourceReplacement()
        }
        multitouchSource = source
        if performanceCounters != nil, current !== source {
            source.beginPerformanceCapture()
        }
        guard source.startLifecycle() else {
            accumulateRetiredMultitouchPerformance(from: source)
            multitouchSource = nil
            return false
        }
        return true
    }

    func cleanup() {
        state.latestFocusFollowsMouseSample = nil
        clearNativeTitleBarDrag()
        cancelActiveMouseInteraction()
        state.capturedInteractionButton = nil
        tearDownEventTaps()
        let retiringMultitouchSource = multitouchSource
        if retiringMultitouchSource?.shutdown() != false {
            if let retiringMultitouchSource {
                accumulateRetiredMultitouchPerformance(from: retiringMultitouchSource)
            }
            multitouchSource = nil
        }
        MouseEventHandler._instance = nil
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "mouse.moveTap.removed")
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "mouse.tap.removed")
        controller?.eventIntake.removePendingMouseEvents()
        resetForMultitouchSourceReplacement()
    }

    func reconcileMultitouchSource() {
        guard let controller, controller.hasStartedServices else { return }
        let shouldRun = controller.settings.scrollGestureEnabled || controller.settings.workspaceSwipeEnabled
        if shouldRun {
            if let multitouchSource {
                if !multitouchSource.startLifecycle() {
                    FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
                }
                return
            }
            if !installMultitouchSource(multitouchSourceFactory()) {
                FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
            }
        } else {
            let retiringMultitouchSource = multitouchSource
            if retiringMultitouchSource?.shutdown() != false {
                if let retiringMultitouchSource {
                    accumulateRetiredMultitouchPerformance(from: retiringMultitouchSource)
                }
                multitouchSource = nil
                resetForMultitouchSourceReplacement()
            } else {
                FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
            }
        }
    }

    func beginPerformanceCapture() {
        performanceCounters = PerformanceCounters()
        multitouchSource?.beginPerformanceCapture()
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        guard let performanceCounters else { return nil }
        return performanceCounters.snapshot(multitouch: multitouchSource?.performanceSnapshot())
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        guard let performanceCounters else { return nil }
        let multitouch = multitouchSource?.endPerformanceCapture()
        let snapshot = performanceCounters.snapshot(multitouch: multitouch)
        self.performanceCounters = nil
        return snapshot
    }

    private func accumulateRetiredMultitouchPerformance(from source: MultitouchGestureSource) {
        guard var performanceCounters,
              let snapshot = source.endPerformanceCapture()
        else { return }
        performanceCounters.accumulateRetiredMultitouch(snapshot)
        self.performanceCounters = performanceCounters
    }

    private func tearDownEventTaps() {
        tearDownMoveEventTap()
        tearDownSessionEventTap()
    }

    private func tearDownMoveEventTap() {
        var tap = state.moveTap
        var source = state.moveTapRunLoopSource
        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &source)
        state.moveTap = tap
        state.moveTapRunLoopSource = source
    }

    private func tearDownSessionEventTap() {
        var tap = state.eventTap
        var source = state.runLoopSource
        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &source)
        state.eventTap = tap
        state.runLoopSource = source
    }

    func requestMultitouchRevalidation(_ reason: MultitouchGestureSource.RevalidationReason) {
        multitouchSource?.requestRevalidation(reason)
    }

    private func clearGestureLatches() {
        state.suppressGestureStartUntilAllTouchesLift = false
        state.consumeTrackpadScrollUntilAllTouchesLift = false
    }

    private var isTrackpadGestureScrollSuppressed: Bool {
        if isTrackpadSwipeSessionActive || state.consumeTrackpadScrollUntilAllTouchesLift {
            return true
        }
        guard let deadline = state.suppressTrackpadScrollUntil else { return false }
        guard CACurrentMediaTime() < deadline else {
            state.suppressTrackpadScrollUntil = nil
            return false
        }
        return true
    }

    private func armTrackpadScrollTailSuppression() {
        state.suppressTrackpadScrollUntil =
            CACurrentMediaTime() + trackpadGestureScrollTailSuppressionDuration
    }

    func suspendMultitouchForSleep() {
        multitouchSource?.suspendForSleep()
    }

    var multitouchDiagnosticsSnapshot: MultitouchGestureSource.DiagnosticsSnapshot? {
        multitouchSource?.diagnosticsSnapshot()
    }

    func resetForMultitouchSourceReplacement() {
        resetGestureState()
        state.workspaceSwipeTracker.reset()
        clearGestureLatches()
        state.suppressTrackpadMomentumScroll = false
        state.suppressTrackpadScrollUntil = nil
    }

    func dispatchMouseMoved(
        at location: CGPoint,
        modifiersRawValue: UInt64 = 0,
        windowIdUnderPointer: Int? = nil
    ) {
        state.latestFocusFollowsMouseSample = .init(
            location: location,
            modifiersRawValue: modifiersRawValue,
            windowIdUnderPointer: windowIdUnderPointer
        )
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            resetHoveredEdgesIfNeeded()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        performanceCounters?.mouseWarpSamples &+= 1
        handleMouseMovedFromTap(
            at: location,
            modifiersRawValue: modifiersRawValue,
            windowIdUnderPointer: windowIdUnderPointer
        )
    }

    @discardableResult
    func dispatchMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left,
        windowIdUnderPointer: Int? = nil
    ) -> Bool {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return false
        }
        guard controller != nil else { return false }
        let blocked = shouldBlockOwnWindowInput(at: location)
        if MouseTrace.shared.isActive {
            let geometric = controller?.ownedWindowRegistry.containsGeometric(point: location) ?? false
            MouseTrace.record(
                "tap: down \(button == .right ? "R" : "L") loc=\(TraceFormat.point(location)) "
                    + "ownGeom=\(geometric) ownInteractive=\(blocked) "
                    + "decision=\(blocked ? "yieldToOwned" : "handledByWM")"
            )
        }
        if blocked {
            return false
        }
        if button == .left {
            clearNativeTitleBarDrag()
        }
        return handleMouseDownFromTap(
            at: location,
            modifiers: modifiers,
            button: button,
            windowIdUnderPointer: windowIdUnderPointer
        )
    }

    func dispatchMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        performanceCounters?.mouseWarpSamples &+= 1
        beginNativeTitleBarDragIfNeeded(button: button)
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button)
    }

    func dispatchMouseUp(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        markNativeTitleBarDragFallbackReleased(button: button)
        finishNativeTitleBarDragIfNeeded(button: button)
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseUpFromTap(at: location, button: button)
    }

    func dispatchScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        handleScrollWheelFromTap(
            at: location,
            deltaX: deltaX,
            deltaY: deltaY,
            momentumPhase: momentumPhase,
            phase: phase,
            modifiers: modifiers
        )
    }

    var isInteractiveGestureActive: Bool {
        state.isMoving || state.isResizing || isViewportGestureActive
    }

    var isViewportGestureActive: Bool {
        switch state.gesturePhase {
        case .idle:
            false
        case .armed:
            state.lockedGestureContext?.columnScrollCandidate == true
        case .committed:
            state.activeGestureMode == .columnScroll
        }
    }

    var isTrackpadSwipeSessionActive: Bool {
        state.gesturePhase != .idle
    }

    func handleExpiredViewportGesture(
        in workspaceId: WorkspaceDescriptor.ID,
        sessionID: AnimationDriver.GestureSessionID
    ) {
        terminateViewportGesture(
            in: workspaceId,
            sessionID: sessionID,
            disposition: .viewportAlreadySettled
        )
    }

    @discardableResult
    func terminateViewportGesture(
        in workspaceId: WorkspaceDescriptor.ID,
        sessionID: AnimationDriver.GestureSessionID,
        disposition: ViewportGestureTerminationDisposition
    ) -> Bool {
        guard state.gesturePhase == .committed,
              state.lockedGestureContext?.workspaceId == workspaceId,
              state.activeGestureMode == .columnScroll,
              state.viewportGestureSessionID == sessionID
        else { return false }
        let liveSessionID = controller?.workspaceManager.animationDriver.gestureSessionID(in: workspaceId)
        guard liveSessionID == sessionID || disposition == .viewportAlreadySettled && liveSessionID == nil else {
            return false
        }
        switch disposition {
        case .settleLiveOffset:
            cancelCommittedGestureViewportState(for: workspaceId)
        case .settleLiveOffsetWithoutRelayout:
            cancelCommittedGestureViewportState(for: workspaceId, requestRelayout: false)
        case .viewportAlreadySettled:
            break
        }
        if disposition != .viewportAlreadySettled {
            state.suppressGestureStartUntilAllTouchesLift = true
            state.consumeTrackpadScrollUntilAllTouchesLift = true
            state.suppressTrackpadMomentumScroll = true
            armTrackpadScrollTailSuppression()
        }
        resetGestureState(settleViewportGesture: false)
        return true
    }

    func handleInputSuppressionBegan() {
        state.latestFocusFollowsMouseSample = nil
        clearNativeTitleBarDrag()
        cancelActiveMouseInteraction()
        dropPendingTapEvents()
        resetMouseWheelTrackers()
        abortActiveGestureIfNeeded()
        clearGestureLatches()
        state.suppressTrackpadScrollUntil = nil
    }

    func handleAppVisibilityChanged() {
        state.latestFocusFollowsMouseSample = nil
        clearNativeTitleBarDrag()
        cancelActiveMouseInteraction()
        dropPendingTapEvents()
        resetMouseWheelTrackers()
        abortActiveGestureIfNeeded()
        clearGestureLatches()
        state.suppressTrackpadScrollUntil = nil
    }

    func receiveTapMouseMoved(
        at location: CGPoint,
        modifiersRawValue: UInt64,
        windowIdUnderPointer: Int? = nil
    ) {
        EventIntake.post(
            .mouseMoved(
                location: location,
                modifiersRawValue: modifiersRawValue,
                windowIdUnderPointer: windowIdUnderPointer
            )
        )
    }

    @discardableResult
    func receiveTapMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left
    ) -> Bool {
        if shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
            if button == .left, !isInputSuppressed {
                retireNativeTitleBarDragAtInputBoundary()
            }
        }
        return dispatchMouseDown(
            at: location,
            modifiers: modifiers,
            button: button
        )
    }

    func receiveTapMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        if !isInputSuppressed {
            beginNativeTitleBarDragIfNeeded(button: button)
        }
        EventIntake.post(.mouseDragged(button: button, location: location))
    }

    func receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: Int?) {
        guard state.awaitsNativeTitleBarDragTarget,
              state.nativeTitleBarDrag == nil,
              let windowIdUnderPointer,
              let entry = controller?.workspaceManager.entry(forWindowId: windowIdUnderPointer),
              entry.mode == .tiling
        else {
            if windowIdUnderPointer != nil {
                state.awaitsNativeTitleBarDragTarget = false
                state.nativeTitleBarDragFallbackToken = nil
                state.nativeTitleBarDragFallbackReleased = false
            }
            return
        }
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        state.nativeTitleBarDrag = .init(token: entry.token)
        beginNativeTitleBarDragIfNeeded(button: .left)
    }

    func receiveTapMouseUp(at location: CGPoint, button: MouseButton = .left) {
        markNativeTitleBarDragFallbackReleased(button: button)
        defer {
            if state.capturedInteractionButton == button {
                state.capturedInteractionButton = nil
            }
        }
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
        }
        dispatchMouseUp(at: location, button: button)
    }

    func receiveTapScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) -> Bool {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return false
        }
        let suppress = shouldSuppressScroll(
            at: location,
            momentumPhase: momentumPhase,
            phase: phase,
            modifiers: modifiers
        )
        if suppress, MouseTrace.shared.isActive {
            MouseTrace.record("tap: scroll suppressed loc=\(TraceFormat.point(location))")
        }
        // A phase-less scroll event can be the tail of the same three-finger
        // gesture. Do not enqueue it for OmniWM's ordinary mouse-wheel path:
        // the event tap already consumed it, and re-routing it would let a
        // stale gesture sample act after the workspace switch.
        if isTrackpadGestureScrollSuppressed {
            performanceCounters?.droppedTrackpadScrollEvents &+= 1
            return true
        }
        if momentumPhase == 0, phase == 0 {
            EventIntake.post(
                .mouseScroll(
                    MouseScrollIntake(
                        location: location,
                        deltaX: deltaX,
                        deltaY: deltaY,
                        momentumPhase: momentumPhase,
                        phase: phase,
                        modifiersRawValue: modifiers.rawValue
                    )
                )
            )
        } else {
            performanceCounters?.droppedTrackpadScrollEvents &+= 1
        }
        return suppress
    }

    private func shouldSuppressScroll(
        at location: CGPoint,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) -> Bool {
        // Some trackpad scroll-wheel events have no phase or momentum bits.
        // The raw multitouch session is still authoritative, so consume those
        // events before falling through to the ordinary mouse-wheel path.
        if isTrackpadGestureScrollSuppressed {
            return true
        }
        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad {
            if state.suppressTrackpadMomentumScroll {
                if momentumPhase != 0 { return true }
                if phase == CGScrollPhase.ended.rawValue || phase == CGScrollPhase.cancelled.rawValue {
                    return true
                }
                state.suppressTrackpadMomentumScroll = false
            }
            return false
        }

        guard let controller, controller.isEnabled,
              controller.settings.scrollGestureEnabled || controller.settings.workspaceSwipeEnabled
        else {
            return false
        }
        if controller.isOverviewOpen() { return false }
        if shouldBlockOwnWindowInput(at: location) { return false }
        guard !state.isResizing, !state.isMoving else { return false }
        guard controller.settings.scrollGestureEnabled else { return false }
        let requiredModifiers = controller.settings.scrollModifierKey.cgEventFlag
        guard Self.mouseWheelModifiersMatch(modifiers, required: requiredModifiers) else { return false }
        return resolveScrollContext(at: location) != nil
    }

    func receiveTapGestureEvent(_ snapshot: GestureEventSnapshot) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        guard shouldProcessGestureFrame(snapshot) else { return }
        if shouldBlockOwnWindowInput(at: snapshot.location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
        }
        handleGestureEvent(snapshot)
    }

    private func shouldProcessGestureFrame(_ snapshot: GestureEventSnapshot) -> Bool {
        guard state.gesturePhase == .idle else { return true }
        let activeTouchCount = Self.activeTouchCount(in: snapshot.touches)
        guard activeTouchCount > 0 else {
            state.suppressGestureStartUntilAllTouchesLift = false
            state.consumeTrackpadScrollUntilAllTouchesLift = false
            return true
        }
        if state.suppressGestureStartUntilAllTouchesLift { return false }
        guard let config = trackpadGestureConfig else { return false }
        return TrackpadGestureIntent.allowsGestureStart(config, fingerCount: activeTouchCount)
    }

    private nonisolated static func activeTouchCount(in touches: [GestureTouchSample]) -> Int {
        touches.count(where: { $0.phase != .ended && $0.phase != .cancelled })
    }

    private var trackpadGestureConfig: TrackpadGestureIntent.Config? {
        guard let settings = controller?.settings else { return nil }
        return TrackpadGestureIntent.Config(
            columnScrollEnabled: settings.scrollGestureEnabled,
            columnScrollFingerCount: settings.gestureFingerCount.rawValue,
            workspaceSwipeEnabled: settings.workspaceSwipeEnabled,
            workspaceSwipeFingerCount: settings.workspaceSwipeFingerCount.rawValue,
            workspaceSwipeAxis: settings.effectiveWorkspaceSwipeAxis
        )
    }

    private var isInputSuppressed: Bool {
        guard let controller else { return true }
        return controller.isLockScreenActive || controller.isFrontmostAppLockScreen()
    }

    private func dropPendingTapEvents() {
        controller?.eventIntake.removePendingMouseEvents()
    }

    private func flushQueuedTapEventsBeforeImmediateDispatch() {
        controller?.eventIntake.drainNow()
    }

    private func resetMouseWheelTrackers() {
        state.horizontalWheelTracker.reset()
        state.verticalWheelTracker.reset()
    }

    private func cancelActiveMouseInteraction() {
        guard let controller else { return }
        let wasActive = state.isMoving || state.isResizing

        if state.isMoving {
            controller.niriEngine?.interactiveMoveCancel()
            controller.dwindleEngine?.interactiveMoveCancel()
            state.dragGhostController?.endDrag()
            state.isMoving = false
            state.moveLayout = nil
            state.activeInteractionButton = nil
        }

        if state.isResizing {
            finishActiveResize()
            state.isResizing = false
            state.activeInteractionButton = nil
            state.resizeLayout = nil
        }

        resetHoveredEdgesIfNeeded()
        if wasActive {
            NSCursor.arrow.set()
        }
    }

    private func recoverAfterTapDisable() {
        cancelActiveMouseInteraction()
        if pressedMouseButtonsProvider() & MouseButton.left.pressedMask == 0 {
            finishNativeTitleBarDragIfNeeded(button: .left)
        }
        guard let button = state.capturedInteractionButton,
              pressedMouseButtonsProvider() & button.pressedMask == 0
        else {
            return
        }
        state.capturedInteractionButton = nil
    }

    private func finishActiveResize() {
        if state.resizeLayout == .dwindle {
            finishDwindleResize()
        } else {
            finishNiriResize()
        }
    }

    private func finishDwindleResize() {
        guard let controller, let engine = controller.dwindleEngine else { return }
        let workspaceId = engine.interactiveResize?.workspaceId
        guard engine.interactiveResizeEnd(), let workspaceId else { return }
        controller.workspaceManager.recordLayoutOperation(.splitRatioChanged, in: workspaceId, source: .mouse)
        if controller.hasStartedServices {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func finishNiriResize() {
        guard let controller, let engine = controller.niriEngine, let resize = engine.interactiveResize else { return }
        let workspaceId = resize.workspaceId
        let resizedToken = (engine.findNode(by: resize.windowId, in: workspaceId) as? NiriWindow)?.token
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId), let resizedToken else {
            engine.clearInteractiveResize()
            return
        }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            engine.interactiveResizeEnd(
                motion: controller.motionPolicy.snapshot(),
                state: &viewportState,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap
            )
        }
        controller.workspaceManager.recordLayoutOperation(
            .interactiveResizeEnded(token: resizedToken),
            in: workspaceId,
            source: .mouse
        )
        if controller.workspaceManager.animationDriver.hasMotion(in: workspaceId) {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        } else if controller.hasStartedServices {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func workspaceIdForPointer(at location: CGPoint) -> WorkspaceDescriptor.ID? {
        guard let controller else { return nil }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors) else {
            return controller.activeWorkspace()?.id
        }
        return controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
    }

    private func resolvedNiriOrientation(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> Monitor.Orientation {
        controller?.settings.effectiveOrientation(for: monitor)
            ?? engine.monitorForWorkspace(workspaceId)?.orientation
            ?? monitor.autoOrientation
    }

    private func shouldBlockOwnWindowInput(at location: CGPoint) -> Bool {
        guard let controller else { return false }
        return controller.isPointInOwnWindow(location)
    }

    private func resetHoveredEdgesIfNeeded() {
        if !state.currentHoveredEdges.isEmpty {
            NSCursor.arrow.set()
            state.currentHoveredEdges = []
        }
    }

    func dispatchQueuedMouseDragged(at location: CGPoint, button: MouseButton) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        performanceCounters?.mouseWarpSamples &+= 1
        beginNativeTitleBarDragIfNeeded(button: button)
        if shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button, requirePressedButtonCheck: false)
    }

    private func handleMouseMovedFromTap(
        at location: CGPoint,
        modifiersRawValue: UInt64,
        windowIdUnderPointer: Int?
    ) {
        guard let controller else { return }
        guard controller.isEnabled else {
            cancelActiveMouseInteraction()
            return
        }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return
        }

        if shouldBlockOwnWindowInput(at: location) {
            resetHoveredEdgesIfNeeded()
            return
        }

        if controller.focusFollowsMouseEnabled,
           !controller.settings.focusLockModifier.isHeld(inRawFlags: modifiersRawValue),
           shouldHandleFocusFollowsMouse(at: location)
        {
            handleFocusFollowsMouse(at: location, windowIdUnderPointer: windowIdUnderPointer)
        }

        guard !state.isResizing else { return }
        resetHoveredEdgesIfNeeded()
    }

    private func shouldHandleFocusFollowsMouse(at location: CGPoint) -> Bool {
        guard !state.isMoving, !state.isResizing, !isTrackpadSwipeSessionActive else { return false }
        guard let controller else { return false }
        guard let workspaceId = workspaceIdForPointer(at: location) else {
            return true
        }
        return !controller.niriLayoutHandler.hasScrollAnimation(for: workspaceId)
    }

    private func handleMouseDownFromTap(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        windowIdUnderPointer: Int?
    ) -> Bool {
        guard let controller else { return false }
        guard controller.isEnabled else {
            cancelActiveMouseInteraction()
            return false
        }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return false
        }

        if shouldBlockOwnWindowInput(at: location) {
            return false
        }
        guard !state.isMoving, !state.isResizing else { return false }

        guard let wsId = workspaceIdForPointer(at: location) ?? controller.activeWorkspace()?.id else {
            return false
        }

        if button == .left, modifiers.intersection(mouseRelevantModifierFlags).isEmpty {
            state.awaitsNativeTitleBarDragTarget = windowIdUnderPointer == nil
            state.nativeTitleBarDragFallbackReleased = false
            let exactToken = nativeTitleBarDragCandidate(windowIdUnderPointer: windowIdUnderPointer)
            let focusIntentToken = exactToken ?? (windowIdUnderPointer == nil
                ? geometricFocusIntentCandidate(at: location, workspaceId: wsId)
                : nil)
            if let token = focusIntentToken {
                controller.axEventHandler.noteMouseFocusIntent(token: token)
            } else {
                controller.axEventHandler.noteUnmanagedPointerClick()
            }
            state.nativeTitleBarDragFallbackToken = exactToken == nil ? focusIntentToken : nil
            if let exactToken {
                state.awaitsNativeTitleBarDragTarget = false
                let token = exactToken
                state.nativeTitleBarDrag = .init(token: token)
            }
        }

        let layoutType = controller.workspaceManager.descriptor(for: wsId)
            .map { controller.settings.layoutType(for: $0.name) }
        if layoutType == .dwindle {
            return handleDwindleMouseDown(at: location, modifiers: modifiers, button: button, wsId: wsId)
        }

        guard let engine = controller.niriEngine else { return false }

        if button == .left,
           let moveMode = Self.mouseMoveMode(
               modifiers: modifiers,
               required: controller.settings.mouseMoveModifierKey.cgEventFlags
           )
        {
            if let tiledWindow = engine.hitTestTiled(point: location, in: wsId),
               let monitor = controller.workspaceManager.monitor(for: wsId)
            {
                let geometry = controller.niriInteractionGeometry(for: monitor)
                let orientation = resolvedNiriOrientation(
                    engine: engine,
                    workspaceId: wsId,
                    monitor: monitor
                )

                let isInsertMode = moveMode == .insert
                var moveStarted = false
                controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                    if engine.interactiveMoveBegin(
                        windowId: tiledWindow.id,
                        windowToken: tiledWindow.token,
                        startLocation: location,
                        isInsertMode: isInsertMode,
                        in: wsId,
                        motion: controller.motionPolicy.snapshot(),
                        state: &vstate,
                        workingFrame: geometry.workingFrame,
                        gaps: geometry.innerGap,
                        orientation: orientation
                    ) {
                        moveStarted = true
                    }
                }
                if moveStarted {
                    state.isMoving = true
                    state.moveLayout = .niri
                    state.activeInteractionButton = button
                    state.capturedInteractionButton = button
                    NSCursor.closedHand.set()

                    if let entry = controller.workspaceManager.entry(for: tiledWindow.token),
                       let frame = AXWindowService.framePreferFast(entry.axRef)
                    {
                        if state.dragGhostController == nil {
                            state.dragGhostController = DragGhostController()
                        }
                        state.dragGhostController?.beginDrag(
                            windowId: entry.windowId,
                            originalFrame: frame,
                            cursorLocation: location
                        )
                    }
                    return false
                }
            }
            return false
        }

        guard button == .right,
              Self.modifierFlagsMatch(modifiers, required: controller.settings.mouseResizeModifierKey.cgEventFlag)
        else { return false }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let tiledWindow = engine.hitTestTiled(point: location, in: wsId)
            ?? focusedBorderResizeToken(
                at: location,
                in: wsId,
                scale: controller.backingScaleFactor(for: monitor),
                appliedBorder: controller.surfaceReconciler.appliedScene.border
            ).flatMap { engine.findNode(for: $0, in: wsId) }
        guard let tiledWindow,
              let frame = tiledWindow.renderedFrame ?? tiledWindow.frame
        else { return false }

        let edges = resizeEdges(for: location, in: frame)
        let currentViewOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffset
        let orientation = resolvedNiriOrientation(
            engine: engine,
            workspaceId: wsId,
            monitor: monitor
        )
        if engine.interactiveResizeBegin(
            windowId: tiledWindow.id,
            edges: edges,
            startLocation: location,
            in: wsId,
            orientation: orientation,
            viewOffset: currentViewOffset
        ) {
            state.isResizing = true
            state.activeInteractionButton = button
            state.capturedInteractionButton = button
            state.currentHoveredEdges = edges
            controller.niriLayoutHandler.cancelActiveAnimations(for: wsId)
            edges.cursor.set()
            return true
        }
        return false
    }

    private func handleDwindleMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        wsId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller, let engine = controller.dwindleEngine else { return false }
        if button == .left {
            return beginDwindleMove(at: location, modifiers: modifiers, engine: engine, wsId: wsId)
        }
        guard button == .right,
              Self.modifierFlagsMatch(modifiers, required: controller.settings.mouseResizeModifierKey.cgEventFlag)
        else { return false }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let now = controller.animationClock.now()
        let token = engine.hitTestFocusableWindow(point: location, in: wsId, at: now)
            ?? focusedBorderResizeToken(
                at: location,
                in: wsId,
                scale: controller.backingScaleFactor(for: monitor),
                appliedBorder: controller.surfaceReconciler.appliedScene.border
            )
        guard let token,
              let node = engine.findNode(for: token, in: wsId),
              let frame = node.presentedFrame(at: now)
        else { return false }

        let edges = resizeEdges(for: location, in: frame)
        controller.dwindleLayoutHandler.refreshEngineConstraints(workspaceId: wsId, monitor: monitor)
        let innerGap = controller.resolvedDwindleSettings(for: monitor).innerGap
        guard engine.interactiveResizeBegin(
            token: token,
            edges: edges,
            startLocation: location,
            in: wsId,
            innerGap: innerGap
        ) else {
            return false
        }

        controller.layoutRefreshController.stopDwindleAnimation(for: monitor.displayId)
        engine.cancelAnimations(in: wsId)
        state.isResizing = true
        state.activeInteractionButton = button
        state.capturedInteractionButton = button
        state.currentHoveredEdges = edges
        state.resizeLayout = .dwindle
        edges.cursor.set()
        return true
    }

    private func beginDwindleMove(
        at location: CGPoint,
        modifiers: CGEventFlags,
        engine: DwindleLayoutEngine,
        wsId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller else { return false }
        let now = controller.animationClock.now()
        guard Self.mouseMoveMode(
            modifiers: modifiers,
            required: controller.settings.mouseMoveModifierKey.cgEventFlags
        ) == .swap,
            let token = engine.hitTestFocusableWindow(point: location, in: wsId, at: now),
            let frame = engine.presentedFrame(for: token, in: wsId, at: now),
            engine.interactiveMoveBegin(token: token, startLocation: location, in: wsId)
        else { return false }

        state.isMoving = true
        state.moveLayout = .dwindle
        state.activeInteractionButton = .left
        state.capturedInteractionButton = .left
        NSCursor.closedHand.set()
        if state.dragGhostController == nil {
            state.dragGhostController = DragGhostController()
        }
        state.dragGhostController?.beginDrag(windowId: token.windowId, originalFrame: frame, cursorLocation: location)
        return false
    }

    private func handleDwindleMoveDrag(at location: CGPoint) {
        guard let controller, let engine = controller.dwindleEngine, let move = engine.interactiveMove else {
            cancelActiveMouseInteraction()
            return
        }
        let now = controller.animationClock.now()
        state.dragGhostController?.updatePosition(cursorLocation: location)
        if let target = engine.interactiveMoveUpdate(currentLocation: location, at: now),
           let frame = engine.presentedFrame(for: target, in: move.workspaceId, at: now)
        {
            state.dragGhostController?.showSwapTarget(frame: frame)
        } else {
            state.dragGhostController?.hideSwapTarget()
        }
    }

    private func finishDwindleMove() {
        guard let controller, let engine = controller.dwindleEngine, let move = engine.interactiveMove else { return }
        guard move.targetToken != nil else {
            engine.interactiveMoveCancel()
            return
        }
        let wsId = move.workspaceId
        let swapped = controller.workspaceManager.withEngineMutationScope(
            in: wsId,
            label: "dwindle_mouse_swap",
            source: .mouse
        ) {
            engine.interactiveMoveEnd() != nil
        }
        guard swapped else { return }
        controller.workspaceManager.recordLayoutOperation(.windowsSwapped, in: wsId, source: .mouse)
        if controller.hasStartedServices {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func finishNiriMove(at location: CGPoint) {
        guard let controller else { return }
        guard let engine = controller.niriEngine, let move = engine.interactiveMove else {
            controller.niriEngine?.interactiveMoveCancel()
            return
        }
        let wsId = move.workspaceId
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else {
            engine.interactiveMoveCancel()
            return
        }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let movedToken = move.windowToken
        var didEnd = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            didEnd = engine.interactiveMoveEnd(
                at: location,
                motion: controller.motionPolicy.snapshot(),
                state: &vstate,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap
            )
        }
        guard didEnd else { return }
        controller.workspaceManager.recordLayoutOperation(
            .interactiveMoveEnded(token: movedToken),
            in: wsId,
            source: .mouse
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
    }

    func focusedBorderResizeToken(
        at location: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        scale: CGFloat,
        appliedBorder: DesiredBorderSurface?
    ) -> WindowToken? {
        guard let controller,
              let appliedBorder,
              appliedBorder.token == controller.workspaceManager.borderFocusToken,
              let entry = controller.workspaceManager.entry(for: appliedBorder.token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling
        else {
            return nil
        }
        let geometry = appliedBorder.config.resolvedGeometry(for: appliedBorder.frame, scale: scale)
        guard geometry.width > 0,
              geometry.surfaceFrame.contains(location),
              !geometry.targetFrame.contains(location)
        else {
            return nil
        }
        return appliedBorder.token
    }

    private func resizeEdges(for location: CGPoint, in frame: CGRect) -> ResizeEdge {
        var edges: ResizeEdge = location.x < frame.midX ? [.left] : [.right]
        edges.insert(location.y < frame.midY ? .bottom : .top)
        return edges
    }

    private func shouldAcceptInteractionButton(_ button: MouseButton) -> Bool {
        state.activeInteractionButton == nil || state.activeInteractionButton == button
    }

    private func isCapturedInteraction(_ button: MouseButton) -> Bool {
        state.capturedInteractionButton == button
    }

    private func handleMouseDraggedFromTap(
        at location: CGPoint,
        button: MouseButton,
        requirePressedButtonCheck: Bool = true
    ) {
        guard let controller else { return }
        guard controller.isEnabled else {
            cancelActiveMouseInteraction()
            return
        }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return
        }
        if requirePressedButtonCheck {
            guard pressedMouseButtonsProvider() & button.pressedMask != 0 else {
                cancelActiveMouseInteraction()
                return
            }
        }

        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
            if state.moveLayout == .dwindle {
                handleDwindleMoveDrag(at: location)
                return
            }
            guard let engine = controller.niriEngine,
                  let move = engine.interactiveMove
            else {
                cancelActiveMouseInteraction()
                return
            }
            let wsId = move.workspaceId

            let hoverTarget = engine.interactiveMoveUpdate(currentLocation: location)
            state.dragGhostController?.updatePosition(cursorLocation: location)

            if let hoverTarget {
                switch hoverTarget {
                case let .window(nodeId, handle, insertPosition):
                    if insertPosition == .swap {
                        if let entry = controller.workspaceManager.entry(for: handle),
                           let frame = AXWindowService.framePreferFast(entry.axRef)
                        {
                            state.dragGhostController?.showSwapTarget(frame: frame)
                        }
                    } else if let dropFrame = engine.insertionDropzoneFrame(
                        targetWindowId: nodeId,
                        position: insertPosition,
                        in: wsId,
                        gaps: move.gaps,
                        orientation: move.orientation
                    ) {
                        state.dragGhostController?.showSwapTarget(frame: dropFrame)
                    }
                default:
                    state.dragGhostController?.hideSwapTarget()
                }
            } else {
                state.dragGhostController?.hideSwapTarget()
            }
            return
        }

        guard state.isResizing else { return }
        guard shouldAcceptInteractionButton(button) else { return }

        if state.resizeLayout == .dwindle {
            guard let engine = controller.dwindleEngine,
                  let wsId = engine.interactiveResize?.workspaceId
            else {
                cancelActiveMouseInteraction()
                return
            }
            if engine.interactiveResizeUpdate(currentLocation: location) {
                controller.layoutRefreshController.renderDwindleInteractiveResize(for: wsId)
            }
            return
        }

        guard let engine = controller.niriEngine,
              let resize = engine.interactiveResize,
              let monitor = controller.workspaceManager.monitor(for: resize.workspaceId)
        else {
            cancelActiveMouseInteraction()
            return
        }

        let geometry = controller.niriInteractionGeometry(for: monitor)
        let gaps = LayoutGaps(
            horizontal: geometry.innerGap,
            vertical: geometry.innerGap
        )
        let wsId = resize.workspaceId

        if engine.interactiveResizeUpdate(
            currentLocation: location,
            monitorFrame: geometry.workingFrame,
            gaps: gaps,
            viewportState: { mutate in
                controller.workspaceManager.withNiriViewportState(for: wsId, mutate)
            }
        ) {
            controller.layoutRefreshController.renderInteractiveResize(for: wsId)
        }
    }

    private func nativeTitleBarDragCandidate(
        windowIdUnderPointer: Int?
    ) -> WindowToken? {
        guard let windowIdUnderPointer,
              let entry = controller?.workspaceManager.entry(forWindowId: windowIdUnderPointer),
              entry.mode == .tiling
        else { return nil }
        return entry.token
    }

    private func geometricFocusIntentCandidate(
        at location: CGPoint,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let controller else { return nil }
        let layoutType = controller.workspaceManager.descriptor(for: workspaceId)
            .map { controller.settings.layoutType(for: $0.name) }
        let token: WindowToken?
        if layoutType == .dwindle {
            token = controller.dwindleEngine?.hitTestFocusableWindow(
                point: location,
                in: workspaceId,
                at: controller.animationClock.now()
            )
        } else {
            token = controller.niriEngine?.hitTestFocusableWindow(
                point: location,
                in: workspaceId
            )?.token
        }
        guard let token,
              controller.workspaceManager.entry(for: token)?.mode == .tiling
        else { return nil }
        return token
    }

    private func beginNativeTitleBarDragIfNeeded(button: MouseButton) {
        guard button == .left,
              var drag = state.nativeTitleBarDrag,
              drag.phase == .armed,
              let controller,
              controller.workspaceManager.entry(for: drag.token)?.mode == .tiling
        else { return }
        drag.phase = .dragging
        state.nativeTitleBarDrag = drag
        controller.axManager.beginNativeTitleBarDrag(for: drag.token)
    }

    private func finishNativeTitleBarDragIfNeeded(button: MouseButton) {
        guard button == .left else { return }
        markNativeTitleBarDragFallbackReleased(button: button)
        if state.nativeTitleBarDrag == nil,
           state.nativeTitleBarDragFallbackReleased
        {
            return
        }
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        guard var drag = state.nativeTitleBarDrag else { return }
        switch drag.phase {
        case .armed,
             .dragging:
            break
        case .awaitingFrameChange,
             .awaitingFrameWrite,
             .awaitingCorrection:
            return
        }
        guard let controller else {
            state.nativeTitleBarDrag = nil
            return
        }
        let excludedFrameWrite = controller.axManager.endNativeTitleBarDrag(for: drag.token)
        guard drag.phase == .dragging,
              controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            state.nativeTitleBarDrag = nil
            return
        }

        let observedFrame = nativeWindowFrameProvider(entry.axRef)
        let lastAppliedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId)
        let observedDisplacement: Bool
        if let observedFrame, let lastAppliedFrame {
            observedDisplacement = !observedFrame.approximatelyEqual(
                to: lastAppliedFrame,
                tolerance: FrameTolerance.frameWrite
            )
        } else if observedFrame != nil {
            observedDisplacement = true
        } else {
            observedDisplacement = drag.receivedFrameChange
        }
        guard excludedFrameWrite || observedDisplacement else {
            if drag.receivedFrameChange {
                state.nativeTitleBarDrag = nil
            } else {
                drag.phase = .awaitingFrameChange
                state.nativeTitleBarDrag = drag
            }
            return
        }

        drag.phase = .awaitingCorrection
        state.nativeTitleBarDrag = drag
        requestNativeTitleBarDragCorrection(for: entry)
    }

    private func retireNativeTitleBarDragAtInputBoundary() {
        guard let drag = state.nativeTitleBarDrag else {
            discardNativeTitleBarDragState()
            return
        }
        guard drag.phase != .armed,
              let controller,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        if drag.phase == .awaitingFrameChange,
           controller.axManager.pendingFrameWrite(for: entry.windowId) == nil,
           let lastAppliedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId),
           let observedFrame = nativeWindowFrameProvider(entry.axRef),
           observedFrame.approximatelyEqual(
               to: lastAppliedFrame,
               tolerance: FrameTolerance.frameWrite
           )
        {
            discardNativeTitleBarDragState()
            return
        }
        let priorTerminalFailureRequestId = drag.terminalFailureRetryRequestId
        var correctionScheduledDuringCancellation = false
        if controller.axManager.pendingFrameWrite(for: entry.windowId) != nil {
            controller.axManager.cancelPendingFrameJobs(
                [(pid: entry.pid, windowId: entry.windowId)],
                reason: "native-drag-end"
            )
            if let currentDrag = state.nativeTitleBarDrag,
               currentDrag.token == drag.token,
               currentDrag.terminalFailureRetryRequestId != nil,
               currentDrag.terminalFailureRetryRequestId != priorTerminalFailureRequestId
            {
                correctionScheduledDuringCancellation = true
            }
        }
        discardNativeTitleBarDragState()
        if !correctionScheduledDuringCancellation {
            controller.axManager.invalidateAppliedFrame(for: entry.windowId)
            requestNativeTitleBarDragCorrection(for: entry)
        }
    }

    private func discardNativeTitleBarDragState() {
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        if let drag = state.nativeTitleBarDrag {
            _ = controller?.axManager.endNativeTitleBarDrag(for: drag.token)
        }
        state.nativeTitleBarDrag = nil
    }

    private func clearNativeTitleBarDrag() {
        guard let drag = state.nativeTitleBarDrag else {
            discardNativeTitleBarDragState()
            return
        }
        discardNativeTitleBarDragState()
        if drag.phase != .armed || drag.receivedFrameChange,
           let controller,
           controller.workspaceManager.entry(for: drag.token)?.mode == .tiling
        {
            controller.axManager.invalidateAppliedFrame(for: drag.token.windowId)
            controller.axManager.forceApplyNextFrame(for: drag.token.windowId)
        }
    }

    func discardNativeTitleBarDrag(for token: WindowToken) {
        guard state.nativeTitleBarDrag?.token == token
            || state.nativeTitleBarDragFallbackToken == token
        else { return }
        discardNativeTitleBarDragState()
    }

    private func requestNativeTitleBarDragCorrection(for entry: WindowState) {
        guard let controller else { return }
        controller.axManager.forceApplyNextFrame(for: entry.windowId)
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func markNativeTitleBarDragFallbackReleased(button: MouseButton) {
        guard button == .left,
              state.nativeTitleBarDrag == nil,
              state.awaitsNativeTitleBarDragTarget,
              state.nativeTitleBarDragFallbackToken != nil,
              state.moveTap == nil
        else { return }
        state.nativeTitleBarDragFallbackReleased = true
    }

    func handleNativeTitleBarDragFrameChanged(for entry: WindowState) -> Bool {
        if state.nativeTitleBarDrag == nil,
           state.awaitsNativeTitleBarDragTarget,
           state.moveTap == nil,
           (state.nativeTitleBarDragFallbackReleased
               || pressedMouseButtonsProvider() & MouseButton.left.pressedMask != 0),
           state.nativeTitleBarDragFallbackToken == entry.token,
           entry.mode == .tiling,
           let controller
        {
            guard !controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) else {
                return false
            }
            guard let observedFrame = terminalNativeWindowFrame(for: entry),
                  !nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry)
            else { return false }
            let released = state.nativeTitleBarDragFallbackReleased
            state.awaitsNativeTitleBarDragTarget = false
            state.nativeTitleBarDragFallbackToken = nil
            state.nativeTitleBarDragFallbackReleased = false
            var drag = State.NativeTitleBarDrag(token: entry.token)
            if released {
                if let pendingFrame = controller.axManager.pendingFrameWrite(for: entry.windowId) {
                    awaitNativeTitleBarDragFrameWrite(
                        pendingFrame,
                        entry: entry,
                        drag: drag
                    )
                } else {
                    drag.phase = .awaitingCorrection
                    state.nativeTitleBarDrag = drag
                    requestNativeTitleBarDragCorrection(for: entry)
                }
            } else {
                drag.phase = .dragging
                drag.receivedFrameChange = true
                state.nativeTitleBarDrag = drag
                controller.axManager.beginNativeTitleBarDrag(for: entry.token)
            }
            return true
        }
        guard var drag = state.nativeTitleBarDrag,
              drag.token == entry.token
        else { return false }
        switch drag.phase {
        case .armed:
            return false
        case .dragging:
            drag.receivedFrameChange = true
            state.nativeTitleBarDrag = drag
            return true
        case .awaitingFrameChange:
            if controller?.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) == true {
                return false
            }
            let observedFrame = terminalNativeWindowFrame(for: entry)
            if let observedFrame,
               nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry)
            {
                drag.receivedFrameChange = false
                drag.issuedUnreadableCorrection = false
                state.nativeTitleBarDrag = drag
                return true
            }
            if let pendingFrame = controller?.axManager.pendingFrameWrite(for: entry.windowId) {
                awaitNativeTitleBarDragFrameWrite(
                    pendingFrame,
                    entry: entry,
                    drag: drag
                )
                return true
            }
            if observedFrame == nil, drag.issuedUnreadableCorrection {
                drag.receivedFrameChange = true
                state.nativeTitleBarDrag = drag
                controller?.axManager.invalidateAppliedFrame(for: entry.windowId)
                return true
            }
            drag.issuedUnreadableCorrection = observedFrame == nil
            drag.phase = .awaitingCorrection
            drag.receivedFrameChange = false
            state.nativeTitleBarDrag = drag
            requestNativeTitleBarDragCorrection(for: entry)
            return true
        case .awaitingFrameWrite:
            drag.receivedFrameChange = true
            if controller?.axManager.pendingFrameWrite(for: entry.windowId) == nil {
                drag.phase = .awaitingCorrection
                state.nativeTitleBarDrag = drag
                requestNativeTitleBarDragCorrection(for: entry)
            } else {
                state.nativeTitleBarDrag = drag
            }
            return true
        case .awaitingCorrection:
            drag.receivedFrameChange = true
            state.nativeTitleBarDrag = drag
            return true
        }
    }

    private func awaitNativeTitleBarDragFrameWrite(
        _ pendingFrame: CGRect,
        entry: WindowState,
        drag: State.NativeTitleBarDrag
    ) {
        guard let controller else { return }
        var drag = drag
        drag.phase = .awaitingFrameWrite
        drag.receivedFrameChange = true
        state.nativeTitleBarDrag = drag
        controller.axManager.applyFramesParallel(
            [AXFrameApplicationTarget(pid: entry.pid, window: entry.axRef, frame: pendingFrame)],
            terminalObserver: { [weak self] result in
                self?.handleNativeTitleBarDragPendingFrameSettled(result)
            }
        )
    }

    private func nativeWindowFrameMatchesManagedTarget(
        _ observedFrame: CGRect,
        entry: WindowState
    ) -> Bool {
        if let pendingFrame = controller?.axManager.pendingFrameWrite(for: entry.windowId),
           pendingFrame.approximatelyEqual(
               to: observedFrame,
               tolerance: FrameTolerance.frameWrite
           )
        {
            return true
        }
        return controller?.axManager.lastAppliedFrame(for: entry.windowId)?.approximatelyEqual(
            to: observedFrame,
            tolerance: FrameTolerance.frameWrite
        ) == true
    }

    private func terminalNativeWindowFrame(for entry: WindowState) -> CGRect? {
        nativeWindowFrameProvider(entry.axRef)
            ?? (try? AXWindowService.frame(entry.axRef))
    }

    func handleNativeTitleBarDragFrameApplySucceeded(_ result: AXFrameApplyResult) {
        guard var drag = state.nativeTitleBarDrag,
              drag.phase == .awaitingCorrection || drag.phase == .awaitingFrameWrite,
              drag.token == WindowToken(pid: result.pid, windowId: result.windowId),
              let controller
        else { return }
        guard let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        guard sameAXWindowIdentity(result.expectedWindow, entry.axRef) else { return }
        guard let confirmedFrame = result.confirmedFrame else {
            discardNativeTitleBarDragState()
            return
        }
        drag.phase = .awaitingCorrection
        var retainUnreadableFrameChange = false
        if drag.receivedFrameChange {
            let observedFrame = terminalNativeWindowFrame(for: entry)
            if let observedFrame,
               !observedFrame.approximatelyEqual(
                   to: confirmedFrame,
                   tolerance: FrameTolerance.frameWrite
               )
            {
                drag.issuedUnreadableCorrection = false
                drag.receivedFrameChange = false
                state.nativeTitleBarDrag = drag
                requestNativeTitleBarDragCorrection(for: entry)
                return
            }
            if observedFrame == nil {
                controller.axManager.invalidateAppliedFrame(for: entry.windowId)
                if !drag.issuedUnreadableCorrection {
                    drag.issuedUnreadableCorrection = true
                    drag.receivedFrameChange = false
                    state.nativeTitleBarDrag = drag
                    requestNativeTitleBarDragCorrection(for: entry)
                    return
                }
                retainUnreadableFrameChange = true
            } else {
                drag.issuedUnreadableCorrection = false
            }
        }
        drag.phase = .awaitingFrameChange
        drag.receivedFrameChange = retainUnreadableFrameChange
        state.nativeTitleBarDrag = drag
    }

    func handleNativeTitleBarDragPendingFrameSettled(_ result: AXFrameApplyResult) {
        guard let drag = state.nativeTitleBarDrag,
              drag.phase == .awaitingFrameWrite,
              drag.token == WindowToken(pid: result.pid, windowId: result.windowId)
        else { return }
        guard let controller,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        guard sameAXWindowIdentity(result.expectedWindow, entry.axRef) else { return }
        if result.confirmedFrame != nil {
            handleNativeTitleBarDragFrameApplySucceeded(result)
            return
        }
        handleNativeTitleBarDragFrameApplyTerminated(result, allowsAwaitingFrameWrite: true)
    }

    func handleNativeTitleBarDragFrameApplyTerminated(_ result: AXFrameApplyResult) {
        handleNativeTitleBarDragFrameApplyTerminated(result, allowsAwaitingFrameWrite: false)
    }

    private func handleNativeTitleBarDragFrameApplyTerminated(
        _ result: AXFrameApplyResult,
        allowsAwaitingFrameWrite: Bool
    ) {
        guard var drag = state.nativeTitleBarDrag,
              drag.token == WindowToken(pid: result.pid, windowId: result.windowId),
              drag.phase == .awaitingCorrection
              || (allowsAwaitingFrameWrite && drag.phase == .awaitingFrameWrite),
              let controller
        else { return }
        guard let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        guard sameAXWindowIdentity(result.expectedWindow, entry.axRef) else { return }
        guard drag.terminalFailureRetryRequestId != result.requestId else { return }
        controller.axManager.invalidateAppliedFrame(for: entry.windowId)
        guard drag.terminalFailureRetryRequestId == nil else {
            discardNativeTitleBarDragState()
            return
        }
        drag.terminalFailureRetryRequestId = result.requestId
        drag.phase = .awaitingCorrection
        state.nativeTitleBarDrag = drag
        requestNativeTitleBarDragCorrection(for: entry)
    }

    private func handleMouseUpFromTap(at location: CGPoint, button: MouseButton) {
        guard let controller else { return }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return
        }

        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
            if state.moveLayout == .dwindle {
                finishDwindleMove()
            } else {
                finishNiriMove(at: location)
            }

            state.dragGhostController?.endDrag()
            state.isMoving = false
            state.moveLayout = nil
            state.activeInteractionButton = nil
            NSCursor.arrow.set()
            return
        }

        guard state.isResizing else { return }
        guard shouldAcceptInteractionButton(button) else { return }

        finishActiveResize()
        state.isResizing = false
        state.activeInteractionButton = nil
        state.resizeLayout = nil
        NSCursor.arrow.set()
        state.currentHoveredEdges = []
    }

    private func handleScrollWheelFromTap(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard let controller else { return }
        guard controller.isEnabled else {
            cancelActiveMouseInteraction()
            return
        }
        guard controller.settings.scrollGestureEnabled else { return }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return
        }
        if shouldBlockOwnWindowInput(at: location) { return }
        guard !state.isResizing, !state.isMoving else { return }

        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad {
            return
        }

        let requiredModifiers = controller.settings.scrollModifierKey.cgEventFlag
        guard Self.mouseWheelModifiersMatch(modifiers, required: requiredModifiers) else {
            resetMouseWheelTrackers()
            return
        }

        guard let columnDelta = Self.resolvedMouseWheelColumnDelta(
            deltaX: deltaX,
            deltaY: deltaY,
            allowVerticalFallback: modifiers.contains(.maskShift)
        ) else { return }
        guard let context = resolveScrollContext(at: location) else { return }

        let ticks: Int
        switch columnDelta.axis {
        case .horizontal:
            ticks = state.horizontalWheelTracker.accumulate(columnDelta.value)
        case .vertical:
            ticks = state.verticalWheelTracker.accumulate(columnDelta.value)
        }
        guard ticks != 0 else { return }

        applyMouseWheelColumnTicks(
            ticks,
            engine: context.engine,
            wsId: context.wsId,
            monitor: context.monitor
        )
    }

    private func handleFocusFollowsMouse(at location: CGPoint, windowIdUnderPointer: Int?) {
        guard let controller else { return }
        guard controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange else {
            return
        }
        guard !externalFocusBlocksFocusFollowsMouse,
              !hasPendingNativeFullscreenTransition(at: location),
              !isPointerDisplayShowingFullscreenSpace(at: location)
        else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(state.lastFocusFollowsMouseTime) >= state.focusFollowsMouseDebounce else {
            return
        }

        guard let target = resolveFocusFollowsMouseTarget(
            at: location,
            windowIdUnderPointer: windowIdUnderPointer
        ) else { return }
        let token = focusFollowsMouseToken(for: target)

        guard token != controller.workspaceManager.selectedManagedToken else { return }

        state.lastFocusFollowsMouseTime = now
        activateFocusFollowsMouseTarget(target)
    }

    private var externalFocusBlocksFocusFollowsMouse: Bool {
        guard let workspaceManager = controller?.workspaceManager else { return false }
        switch workspaceManager.nativeFocusOwner {
        case .ownedSurface:
            return true
        case .external:
            return workspaceManager.activeNativeFullscreenFocusOwnerToken == nil
        case .managed,
             .none:
            return false
        }
    }

    private func hasPendingNativeFullscreenTransition(at location: CGPoint) -> Bool {
        guard let workspaceManager = controller?.workspaceManager else { return false }
        guard let monitor = location.monitorApproximation(in: workspaceManager.monitors),
              let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return workspaceManager.hasPendingNativeFullscreenTransition
        }
        return workspaceManager.hasPendingNativeFullscreenTransition(in: workspace.id)
    }

    private func isPointerDisplayShowingFullscreenSpace(at location: CGPoint) -> Bool {
        guard let controller else { return false }
        let workspaceManager = controller.workspaceManager
        guard workspaceManager.hasNativeFullscreenLifecycleContext else { return false }
        let topology = workspaceManager.spaceTopology
        guard topology.isPopulated,
              let monitor = location.monitorApproximation(in: workspaceManager.monitors)
        else { return true }
        return topology.isDisplayShowingFullscreenSpace(on: monitor) ?? true
    }

    private func resolveFocusFollowsMouseTarget(
        at location: CGPoint,
        windowIdUnderPointer: Int?
    ) -> FocusFollowsMouseTarget? {
        guard let controller else { return nil }

        if let windowIdUnderPointer, windowIdUnderPointer != 0 {
            guard windowIdUnderPointer > 0,
                  let entry = controller.workspaceManager.entry(
                      forWindowId: windowIdUnderPointer,
                      inVisibleWorkspaces: true
                  ),
                  controller.isManagedWindowDisplayable(entry.token),
                  let workspace = controller.workspaceManager.descriptor(for: entry.workspaceId)
            else {
                return nil
            }

            switch entry.mode {
            case .floating:
                return .floating(token: entry.token)

            case .tiling:
                switch controller.settings.layoutType(for: workspace.name) {
                case .niri,
                     .defaultLayout:
                    guard let window = controller.niriEngine?.findNode(
                        for: entry.token,
                        in: entry.workspaceId
                    ), controller.niriEngine?.isProjectedFocusableWindow(
                        window,
                        in: entry.workspaceId
                    ) == true else {
                        return nil
                    }
                    return .niri(workspaceId: entry.workspaceId, window: window)

                case .dwindle:
                    guard controller.dwindleEngine?.findNode(
                        for: entry.token,
                        in: entry.workspaceId
                    ) != nil else {
                        return nil
                    }
                    return .dwindle(workspaceId: entry.workspaceId, token: entry.token)
                }
            }
        }

        guard let workspaceId = workspaceIdForPointer(at: location),
              let workspace = controller.workspaceManager.descriptor(for: workspaceId)
        else {
            return nil
        }

        switch controller.settings.layoutType(for: workspace.name) {
        case .niri,
             .defaultLayout:
            guard let engine = controller.niriEngine,
                  let window = engine.hitTestFocusableWindow(point: location, in: workspaceId)
            else {
                return nil
            }
            return .niri(workspaceId: workspaceId, window: window)

        case .dwindle:
            guard let engine = controller.dwindleEngine else { return nil }
            let presentationTime = controller.animationClock.now()
            guard let token = engine.hitTestFocusableWindow(
                point: location,
                in: workspaceId,
                at: presentationTime
            ) else {
                return nil
            }
            return .dwindle(workspaceId: workspaceId, token: token)
        }
    }

    private func focusFollowsMouseToken(for target: FocusFollowsMouseTarget) -> WindowToken {
        switch target {
        case let .niri(_, window):
            window.token
        case let .dwindle(_, token):
            token
        case let .floating(token):
            token
        }
    }

    var hasLatestFocusFollowsMouseSample: Bool {
        state.latestFocusFollowsMouseSample != nil
    }

    func latestFocusFollowsMouseToken() -> WindowToken? {
        guard let controller,
              let sample = state.latestFocusFollowsMouseSample,
              !isInputSuppressed,
              controller.isEnabled,
              controller.focusFollowsMouseEnabled,
              !controller.isOverviewOpen(),
              !shouldBlockOwnWindowInput(at: sample.location),
              !controller.settings.focusLockModifier.isHeld(inRawFlags: sample.modifiersRawValue),
              !state.isMoving,
              !state.isResizing,
              !isTrackpadSwipeSessionActive,
              controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange,
              !externalFocusBlocksFocusFollowsMouse,
              !hasPendingNativeFullscreenTransition(at: sample.location),
              !isPointerDisplayShowingFullscreenSpace(at: sample.location),
              let target = resolveFocusFollowsMouseTarget(
                  at: sample.location,
                  windowIdUnderPointer: sample.windowIdUnderPointer
              )
        else {
            return nil
        }
        return focusFollowsMouseToken(for: target)
    }

    private func activateFocusFollowsMouseTarget(_ target: FocusFollowsMouseTarget) {
        guard let controller else { return }

        switch target {
        case let .niri(workspaceId, window):
            controller.niriLayoutHandler.activatePointerHoveredWindow(
                window,
                in: workspaceId
            )
        case let .dwindle(workspaceId, token):
            controller.dwindleLayoutHandler.activateWindow(
                token,
                in: workspaceId,
                origin: .focusFollowsMouse,
                layoutRefresh: false
            )
        case let .floating(token):
            controller.focusWindow(token, origin: .focusFollowsMouse)
        }
    }

    private func handleGestureEvent(_ snapshot: GestureEventSnapshot) {
        let location = snapshot.location
        let phase = NSEvent.Phase(rawValue: snapshot.phaseRawValue)
        let activeTouchCount = Self.activeTouchCount(in: snapshot.touches)

        if phase == .ended || phase == .cancelled {
            let hadGestureSession = state.gesturePhase != .idle
            defer {
                if hadGestureSession {
                    armTrackpadScrollTailSuppression()
                }
                clearGestureLatches()
                resetGestureState()
            }
            guard gestureFramePreconditionsSatisfied(at: location) else { return }
            if state.gesturePhase == .committed {
                finishCommittedGestureOnRelease(timestamp: snapshot.timestamp, allowFlick: phase == .ended)
            }
            return
        }

        guard gestureFramePreconditionsSatisfied(at: location) else { return }

        if phase == .began, state.gesturePhase != .idle {
            abortActiveGestureIfNeeded()
        }

        guard !snapshot.touches.isEmpty else {
            abortActiveGestureIfNeeded()
            return
        }

        let requiredFingers = state.lockedGestureContext?.fingerCount ?? activeTouchCount
        guard let averageTouchPosition = Self.averageGestureTouchPosition(
            requiredFingers: requiredFingers,
            touches: snapshot.touches
        ) else {
            if state.gesturePhase == .committed, activeTouchCount < requiredFingers {
                finalizeCommittedGestureAfterTouchRelease(timestamp: snapshot.timestamp)
                return
            }
            abortActiveGestureIfNeeded()
            return
        }

        if state.gesturePhase == .idle {
            armGestureIfPossible(
                at: location,
                activeTouchCount: activeTouchCount,
                average: averageTouchPosition,
                timestamp: snapshot.timestamp
            )
            return
        }
        processActiveGestureFrame(average: averageTouchPosition, timestamp: snapshot.timestamp)
    }

    private func gestureFramePreconditionsSatisfied(at location: CGPoint) -> Bool {
        guard let controller else { return false }
        guard controller.isEnabled,
              controller.settings.scrollGestureEnabled || controller.settings.workspaceSwipeEnabled
        else {
            abortActiveGestureIfNeeded()
            return false
        }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            abortActiveGestureIfNeeded()
            return false
        }
        if shouldBlockOwnWindowInput(at: location) {
            abortActiveGestureIfNeeded()
            return false
        }
        guard !state.isResizing, !state.isMoving else {
            abortActiveGestureIfNeeded()
            return false
        }
        return true
    }

    private func armGestureIfPossible(
        at location: CGPoint,
        activeTouchCount: Int,
        average: CGPoint,
        timestamp: TimeInterval
    ) {
        guard let context = resolveGestureArmContext(at: location, fingerCount: activeTouchCount) else { return }
        state.lockedGestureContext = context
        if context.workspaceAxis != nil {
            state.workspaceSwipeTracker.reset()
            state.workspaceSwipeTracker.push(delta: 0, timestamp: timestamp)
        }
        state.gestureStartX = average.x
        state.gestureStartY = average.y
        state.gestureLastAverageX = average.x
        state.gestureLastAverageY = average.y
        state.gesturePhase = .armed
    }

    private func resolveGestureArmContext(
        at location: CGPoint,
        fingerCount: Int
    ) -> State.LockedGestureContext? {
        guard let controller, let config = trackpadGestureConfig else { return nil }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else { return nil }
        let supportsColumnScroll = switch controller.settings.layoutType(for: workspace.name) {
        case .niri,
             .defaultLayout:
            controller.niriEngine != nil
        case .dwindle:
            false
        }
        guard TrackpadGestureIntent.hasCandidateMode(
            config,
            fingerCount: fingerCount,
            columnContextAvailable: supportsColumnScroll
        ) else { return nil }
        let columnScrollCandidate = config.columnScrollEnabled
            && fingerCount == config.columnScrollFingerCount
            && supportsColumnScroll
        let isWorkspaceCandidate = config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount
        let columnScrollAxis: WorkspaceSwipeAxis
        if let engine = controller.niriEngine, supportsColumnScroll {
            columnScrollAxis = resolvedNiriOrientation(
                engine: engine,
                workspaceId: workspace.id,
                monitor: monitor
            ) == .horizontal ? .horizontal : .vertical
        } else {
            columnScrollAxis = .horizontal
        }
        let workspaceAxis: WorkspaceSwipeAxis? = if isWorkspaceCandidate {
            if columnScrollCandidate {
                columnScrollAxis == .horizontal ? .vertical : .horizontal
            } else {
                config.workspaceSwipeAxis
            }
        } else {
            nil
        }
        return .init(
            workspaceId: workspace.id,
            monitorId: monitor.id,
            fingerCount: fingerCount,
            columnScrollCandidate: columnScrollCandidate,
            columnScrollAxis: columnScrollAxis,
            workspaceAxis: workspaceAxis
        )
    }

    private struct GestureFrameMetrics {
        var cumulativeX: CGFloat
        var cumulativeY: CGFloat
        var rawDeltaX: CGFloat
        var rawDeltaY: CGFloat
    }

    private func processActiveGestureFrame(average: CGPoint, timestamp: TimeInterval) {
        guard let controller else { return }
        guard let lockedContext = state.lockedGestureContext else {
            assertionFailure("Active gesture missing locked context")
            abortActiveGestureIfNeeded()
            return
        }
        guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            abortActiveGestureIfNeeded()
            return
        }

        let metrics = GestureFrameMetrics(
            cumulativeX: (average.x - state.gestureStartX) * macNormalizedTouchPositionToNiriGestureUnits,
            cumulativeY: (average.y - state.gestureStartY) * macNormalizedTouchPositionToNiriGestureUnits,
            rawDeltaX: (average.x - state.gestureLastAverageX) * macNormalizedTouchPositionToNiriGestureUnits,
            rawDeltaY: (average.y - state.gestureLastAverageY) * macNormalizedTouchPositionToNiriGestureUnits
        )

        if let axis = lockedContext.workspaceAxis,
           state.gesturePhase == .armed || state.activeGestureMode == .workspaceSwitch(axis: axis)
        {
            state.workspaceSwipeTracker.push(
                delta: Double(axis == .horizontal ? metrics.rawDeltaX : metrics.rawDeltaY),
                timestamp: timestamp
            )
        }

        if state.gesturePhase == .armed {
            let distanceSquared = metrics.cumulativeX * metrics.cumulativeX
                + metrics.cumulativeY * metrics.cumulativeY
            let thresholdSquared = niriTouchpadGestureRecognitionThreshold * niriTouchpadGestureRecognitionThreshold
            guard distanceSquared >= thresholdSquared else {
                state.gestureLastAverageX = average.x
                state.gestureLastAverageY = average.y
                return
            }
            guard commitGestureMode(metrics: metrics, lockedContext: lockedContext) else { return }
        }

        state.gestureLastAverageX = average.x
        state.gestureLastAverageY = average.y
        dispatchCommittedGestureFrame(
            metrics: metrics,
            lockedContext: lockedContext,
            monitor: monitor,
            timestamp: timestamp
        )
    }

    private func commitGestureMode(metrics: GestureFrameMetrics, lockedContext: State.LockedGestureContext) -> Bool {
        guard let controller, var config = trackpadGestureConfig else {
            abortActiveGestureIfNeeded()
            return false
        }
        if let axis = lockedContext.workspaceAxis {
            config.workspaceSwipeAxis = axis
        }
        guard let mode = TrackpadGestureIntent.resolveMode(
            config,
            fingerCount: lockedContext.fingerCount,
            cumulativeX: metrics.cumulativeX,
            cumulativeY: metrics.cumulativeY,
            columnScrollAxis: lockedContext.columnScrollAxis,
            columnContextAvailable: lockedContext.columnScrollCandidate && controller.niriEngine != nil
        ) else {
            state.suppressGestureStartUntilAllTouchesLift = true
            resetGestureState()
            return false
        }
        state.activeGestureMode = mode
        state.gesturePhase = .committed
        return true
    }

    private func dispatchCommittedGestureFrame(
        metrics: GestureFrameMetrics,
        lockedContext: State.LockedGestureContext,
        monitor: Monitor,
        timestamp: TimeInterval
    ) {
        guard let controller else { return }
        switch state.activeGestureMode {
        case .columnScroll:
            guard let engine = controller.niriEngine else {
                abortActiveGestureIfNeeded()
                return
            }
            let orientation: Monitor.Orientation = lockedContext.columnScrollAxis == .horizontal
                ? .horizontal
                : .vertical
            let primaryDelta = lockedContext.columnScrollAxis == .horizontal
                ? metrics.rawDeltaX
                : metrics.rawDeltaY
            var deltaUnits = primaryDelta * CGFloat(controller.settings.scrollSensitivity)
            if controller.settings.gestureInvertDirection {
                deltaUnits = -deltaUnits
            }
            applyTrackpadViewportScrollDelta(
                deltaUnits,
                engine: engine,
                wsId: lockedContext.workspaceId,
                monitor: monitor,
                orientation: orientation,
                timestamp: timestamp
            )
        case let .workspaceSwitch(axis):
            handleWorkspaceSwipeFrame(
                axis: axis,
                cumulative: axis == .horizontal ? metrics.cumulativeX : metrics.cumulativeY,
                monitorId: lockedContext.monitorId
            )
        case nil:
            abortActiveGestureIfNeeded()
        }
    }

    private func handleWorkspaceSwipeFrame(
        axis: WorkspaceSwipeAxis,
        cumulative: CGFloat,
        monitorId: Monitor.ID
    ) {
        guard !state.workspaceSwipeFired,
              abs(cumulative) >= TrackpadGestureIntent.workspaceSwipeTriggerUnits,
              let isNext = TrackpadGestureIntent.isNextWorkspace(
                  axis: axis,
                  displacement: cumulative,
                  naturalDirection: controller?.settings.gestureInvertDirection ?? true
              )
        else { return }
        state.workspaceSwipeFired = true
        controller?.workspaceNavigationHandler.switchWorkspaceRelative(isNext: isNext, monitorId: monitorId)
    }

    private func finishCommittedGestureOnRelease(timestamp: TimeInterval, allowFlick: Bool) {
        guard let lockedContext = state.lockedGestureContext else {
            assertionFailure("Committed gesture missing locked context")
            return
        }
        switch state.activeGestureMode {
        case let .workspaceSwitch(axis):
            finalizeWorkspaceSwipe(
                monitorId: lockedContext.monitorId,
                axis: axis,
                allowFlick: allowFlick,
                timestamp: timestamp
            )
        default:
            if let engine = controller?.niriEngine {
                finalizeOrCancelCommittedGesture(
                    using: lockedContext,
                    engine: engine,
                    shouldFocusSelection: allowFlick,
                    timestamp: timestamp
                )
            } else {
                cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
            }
        }
    }

    private func finalizeWorkspaceSwipe(
        monitorId: Monitor.ID,
        axis: WorkspaceSwipeAxis,
        allowFlick: Bool,
        timestamp: TimeInterval
    ) {
        defer { state.suppressTrackpadMomentumScroll = true }
        guard allowFlick, !state.workspaceSwipeFired else { return }
        state.workspaceSwipeTracker.push(delta: 0, timestamp: timestamp)
        let cumulative = (axis == .horizontal
            ? state.gestureLastAverageX - state.gestureStartX
            : state.gestureLastAverageY - state.gestureStartY)
            * macNormalizedTouchPositionToNiriGestureUnits
        guard let displacement = TrackpadGestureIntent.releaseFlickDisplacement(
            cumulativeAxisUnits: cumulative,
            velocity: state.workspaceSwipeTracker.velocity()
        ),
            let isNext = TrackpadGestureIntent.isNextWorkspace(
                axis: axis,
                displacement: displacement,
                naturalDirection: controller?.settings.gestureInvertDirection ?? true
            )
        else { return }
        state.workspaceSwipeFired = true
        controller?.workspaceNavigationHandler.switchWorkspaceRelative(isNext: isNext, monitorId: monitorId)
    }

    func applyTrackpadViewportScrollDelta(
        _ delta: CGFloat,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation,
        timestamp: TimeInterval = CACurrentMediaTime()
    ) {
        guard let controller else { return }
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let driver = controller.workspaceManager.animationDriver
        let viewportSpan = orientation == .horizontal ? insetFrame.width : insetFrame.height

        if !driver.hasGesture(in: wsId) {
            guard !engine.columns(in: wsId).isEmpty else { return }
            let semanticOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffset
            if let liveOffset = driver.liveViewOffset(in: wsId, semanticOffset: semanticOffset) {
                controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                    vstate.jumpOffset(to: liveOffset)
                }
            }
            driver.beginGesture(in: wsId, isTrackpad: true, timestamp: timestamp)
        }

        guard let gestureSessionID = driver.gestureSessionID(in: wsId) else {
            resetGestureState()
            return
        }
        state.viewportGestureSessionID = gestureSessionID

        driver.updateGesture(
            in: wsId,
            delta: Double(delta),
            timestamp: timestamp,
            isTrackpad: true,
            viewportWidth: Double(viewportSpan)
        )
        controller.layoutRefreshController.startScrollAnimation(for: wsId, forGesture: true)
    }

    private func applyMouseWheelColumnTicks(
        _ ticks: Int,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) {
        guard let controller else { return }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let step = ticks > 0 ? 1 : -1
        let motion = controller.motionPolicy.snapshot()
        let orientation = resolvedNiriOrientation(
            engine: engine,
            workspaceId: wsId,
            monitor: monitor
        )

        if controller.workspaceManager.animationDriver.trackpadGestureActive(in: wsId) {
            return
        }

        let columns = engine.projectedColumns(in: wsId)
        var didApply = false
        var shouldStartAnimation = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            for _ in 0 ..< abs(ticks) {
                let activeColumnIndex = engine.projectedActiveColumnIndex(
                    state: vstate,
                    columns: columns,
                    in: wsId
                )
                let targetColumnIndex = activeColumnIndex + step
                guard columns.indices.contains(targetColumnIndex),
                      let currentNode = currentSelectionNode(
                          engine: engine,
                          wsId: wsId,
                          state: vstate,
                          columns: columns
                      ),
                      let newNode = engine.focusColumn(
                          targetColumnIndex,
                          currentSelection: currentNode,
                          in: wsId,
                          motion: motion,
                          state: &vstate,
                          workingFrame: geometry.workingFrame,
                          gaps: geometry.innerGap,
                          orientation: orientation
                      )
                else {
                    break
                }

                controller.niriLayoutHandler.activateNode(
                    newNode,
                    in: wsId,
                    state: &vstate,
                    options: .init(
                        activateWindow: true,
                        ensureVisible: false,
                        updateTimestamp: true,
                        layoutRefresh: false,
                        axFocus: false,
                        startAnimation: false
                    )
                )
                didApply = true
            }
            shouldStartAnimation = vstate.hasPendingOffsetAnimation
        }

        if didApply {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
            if shouldStartAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }

    func finalizeOrCancelCommittedGesture(
        using lockedContext: State.LockedGestureContext,
        engine: NiriLayoutEngine,
        shouldFocusSelection: Bool,
        timestamp: TimeInterval? = nil
    ) {
        guard let controller else { return }
        let wsId = lockedContext.workspaceId
        guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            cancelCommittedGestureViewportState(for: wsId)
            return
        }

        let geometry = controller.niriInteractionGeometry(for: monitor)
        let orientation: Monitor.Orientation = lockedContext.columnScrollAxis == .horizontal
            ? .horizontal
            : .vertical
        let viewportSpan = orientation == .horizontal
            ? geometry.workingFrame.width
            : geometry.workingFrame.height

        guard let sample = controller.workspaceManager.animationDriver.sampleGestureEnd(
            in: wsId,
            isTrackpad: true,
            viewportWidth: Double(viewportSpan),
            timestamp: timestamp
        ) else { return }

        let baseOffset = Double(controller.workspaceManager.niriViewportState(for: wsId).viewOffset)

        var selectedWindow: NiriWindow?
        controller.workspaceManager.withNiriViewportState(for: wsId) { endState in
            selectedWindow = engine.endProjectedGesture(
                state: &endState,
                in: wsId,
                currentOffset: baseOffset + sample.relativeOffset,
                projectedOffset: baseOffset + sample.relativeProjectedOffset,
                gap: geometry.innerGap,
                viewportSpan: viewportSpan,
                orientation: orientation,
                motion: controller.motionPolicy.snapshot(),
                snapToColumn: controller.settings.trackpadScrollStyle == .snap,
                centerMode: engine.centerFocusedColumn,
                alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn,
                workingArea: geometry.workingFrame,
                viewFrame: monitor.frame,
                scale: geometry.scale
            )
        }
        if let selectedWindow {
            rememberViewportFocusAnchor(selectedWindow, engine: engine, wsId: wsId)
            if shouldFocusSelection {
                focusViewportSelectionAfterGesture(selectedWindow)
            }
        }
        if controller.workspaceManager.animationDriver.hasMotion(in: wsId) {
            controller.layoutRefreshController.startScrollAnimation(for: wsId)
        } else {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func finalizeCommittedGestureAfterTouchRelease(timestamp: TimeInterval) {
        finishCommittedGestureOnRelease(timestamp: timestamp, allowFlick: true)
        state.suppressGestureStartUntilAllTouchesLift = true
        state.consumeTrackpadScrollUntilAllTouchesLift = true
        armTrackpadScrollTailSuppression()
        resetGestureState()
        state.suppressTrackpadMomentumScroll = true
    }

    private func cancelCommittedGestureViewportState(
        for wsId: WorkspaceDescriptor.ID,
        requestRelayout: Bool = true
    ) {
        guard let controller else { return }
        let driver = controller.workspaceManager.animationDriver
        let semanticOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffset
        guard let liveOffset = driver.liveViewOffset(in: wsId, semanticOffset: semanticOffset) else { return }
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            vstate.jumpOffset(to: liveOffset)
            vstate.viewOffsetToRestore = nil
            vstate.activatePrevColumnOnRemoval = nil
        }
        if requestRelayout {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func abortActiveGestureIfNeeded() {
        if state.gesturePhase == .committed {
            if case .workspaceSwitch = state.activeGestureMode {
                state.suppressTrackpadMomentumScroll = true
            } else if let lockedContext = state.lockedGestureContext {
                if let engine = controller?.niriEngine {
                    finalizeOrCancelCommittedGesture(
                        using: lockedContext,
                        engine: engine,
                        shouldFocusSelection: false
                    )
                } else {
                    cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
                }
            } else {
                assertionFailure("Committed gesture missing locked context")
            }
            state.suppressGestureStartUntilAllTouchesLift = true
            state.consumeTrackpadScrollUntilAllTouchesLift = true
            armTrackpadScrollTailSuppression()
        }
        resetGestureState()
    }

    private func resolveScrollContext(at location: CGPoint) -> (
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor
    )? {
        guard let controller,
              let engine = controller.niriEngine
        else {
            return nil
        }

        let monitors = controller.workspaceManager.monitors
        guard let monitor = location.monitorApproximation(in: monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return nil
        }

        switch controller.settings.layoutType(for: workspace.name) {
        case .niri,
             .defaultLayout:
            return (engine, workspace.id, monitor)
        case .dwindle:
            return nil
        }
    }

    private func resetGestureState(settleViewportGesture: Bool = true) {
        if settleViewportGesture,
           let lockedContext = state.lockedGestureContext,
           controller?.workspaceManager.animationDriver.hasGesture(in: lockedContext.workspaceId) == true
        {
            cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
        }
        state.gesturePhase = .idle
        state.gestureStartX = 0.0
        state.gestureStartY = 0.0
        state.gestureLastAverageX = 0.0
        state.gestureLastAverageY = 0.0
        state.lockedGestureContext = nil
        state.activeGestureMode = nil
        state.viewportGestureSessionID = nil
        state.workspaceSwipeFired = false
    }

    private func currentSelectionNode(
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        columns: [NiriProjectedColumn]? = nil
    ) -> NiriNode? {
        if let selectedNodeId = state.selectedNodeId,
           let selectedNode = engine.findNode(by: selectedNodeId, in: wsId)
        {
            let isExcluded = (selectedNode as? NiriWindow).map {
                engine.isExcludedFromProjection($0.token, in: wsId)
            } == true
            if !isExcluded {
                return selectedNode
            }
        }

        let columns = columns ?? engine.projectedColumns(in: wsId)
        guard !columns.isEmpty else { return nil }
        let activeColumnIndex = engine.projectedActiveColumnIndex(
            state: state,
            columns: columns,
            in: wsId
        )
        guard columns.indices.contains(activeColumnIndex) else { return nil }
        return engine.projectedActiveWindow(in: columns[activeColumnIndex])
    }

    private func focusViewportSelectionAfterGesture(_ window: NiriWindow) {
        guard let controller else { return }
        guard !controller.hasFrontmostOwnedWindow else { return }
        guard controller.workspaceManager.selectedManagedToken != window.token else { return }
        controller.focusWindow(window.token, origin: .pointerHover)
    }

    private func rememberViewportFocusAnchor(
        _ window: NiriWindow,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: nil,
                rememberedFocusToken: window.token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.workspaceManager.withEngineMutationScope {
            engine.updateFocusTimestamp(for: window.id, in: wsId)
        }
    }

    private nonisolated static func processTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard isMainThread else { return false }

        let location = event.location
        let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)
        let modifiers = event.flags
        let windowIdUnderPointer = type == .mouseMoved ? eventWindowIdUnderPointer(event) : nil
        let scrollPayload: (deltaX: CGFloat, deltaY: CGFloat, momentumPhase: UInt32, phase: UInt32)?
        if type == .scrollWheel {
            scrollPayload = (
                resolvedWheelAxisDelta(
                    pointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
                    fixedPointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
                ),
                resolvedWheelAxisDelta(
                    pointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)),
                    fixedPointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                ),
                UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase)),
                UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
            )
        } else {
            scrollPayload = nil
        }
        var suppressEvent = false

        MainActor.assumeIsolated {
            guard let handler = MouseEventHandler._instance else { return }
            if handler.performanceCounters != nil {
                handler.recordCGEvent(type)
            }
            switch type {
            case .mouseMoved:
                handler.receiveTapMouseMoved(
                    at: screenLocation,
                    modifiersRawValue: modifiers.rawValue,
                    windowIdUnderPointer: windowIdUnderPointer
                )
            case .leftMouseDown:
                _ = handler.receiveTapMouseDown(at: screenLocation, modifiers: modifiers)
            case .leftMouseDragged:
                suppressEvent = handler.isCapturedInteraction(.left)
                handler.receiveTapMouseDragged(at: screenLocation)
            case .leftMouseUp:
                suppressEvent = handler.isCapturedInteraction(.left)
                handler.receiveTapMouseUp(at: screenLocation)
            case .rightMouseDown:
                suppressEvent = handler.receiveTapMouseDown(
                    at: screenLocation,
                    modifiers: modifiers,
                    button: .right
                )
            case .rightMouseDragged:
                suppressEvent = handler.isCapturedInteraction(.right)
                handler.receiveTapMouseDragged(at: screenLocation, button: .right)
            case .rightMouseUp:
                suppressEvent = handler.isCapturedInteraction(.right)
                handler.receiveTapMouseUp(at: screenLocation, button: .right)
            case .scrollWheel:
                guard let scrollPayload else { return }
                suppressEvent = handler.receiveTapScrollWheel(
                    at: screenLocation,
                    deltaX: scrollPayload.deltaX,
                    deltaY: scrollPayload.deltaY,
                    momentumPhase: scrollPayload.momentumPhase,
                    phase: scrollPayload.phase,
                    modifiers: modifiers
                )
            default:
                break
            }
        }

        return suppressEvent
    }

    private func recordCGEvent(_ type: CGEventType) {
        guard performanceCounters != nil else { return }
        performanceCounters?.cgEvents &+= 1
        switch type {
        case .mouseMoved:
            performanceCounters?.mouseMovedEvents &+= 1
        case .leftMouseDragged,
             .rightMouseDragged:
            performanceCounters?.mouseDraggedEvents &+= 1
        case .scrollWheel:
            performanceCounters?.scrollEvents &+= 1
        case .leftMouseDown,
             .leftMouseUp,
             .rightMouseDown,
             .rightMouseUp:
            performanceCounters?.buttonEvents &+= 1
        default:
            break
        }
    }

    nonisolated static func eventWindowIdUnderPointer(_ event: CGEvent) -> Int? {
        let routedWindowId = event.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        if routedWindowId != 0 {
            return normalizedEventWindowId(routedWindowId)
        }
        return normalizedEventWindowId(
            event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        )
    }

    nonisolated static func normalizedEventWindowId(_ value: Int64) -> Int? {
        guard let windowId = UInt32(exactly: value), windowId != 0 else { return nil }
        return Int(windowId)
    }

    nonisolated static func resolvedWheelAxisDelta(pointDelta: CGFloat, fixedPointDelta: CGFloat) -> CGFloat {
        if abs(pointDelta) > mouseWheelAxisEpsilon {
            return pointDelta
        }
        return fixedPointDelta
    }

    nonisolated static func mouseWheelModifiersMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifierFlagsMatch(modifiers, required: required)
    }

    nonisolated static func mouseMoveMode(
        modifiers: CGEventFlags,
        required: CGEventFlags?
    ) -> MouseMoveMode? {
        guard let required, !required.isEmpty else { return nil }
        let relevantModifiers = modifiers.intersection(mouseRelevantModifierFlags)
        if relevantModifiers == required {
            return .swap
        }
        if relevantModifiers == required.union(.maskShift) {
            return .insert
        }
        return nil
    }

    nonisolated static func modifierFlagsMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifiers.intersection(mouseRelevantModifierFlags) == required
    }

    private nonisolated static func resolvedMouseWheelColumnDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        allowVerticalFallback: Bool
    ) -> MouseWheelColumnDelta? {
        if abs(deltaX) > mouseWheelAxisEpsilon {
            return MouseWheelColumnDelta(axis: .horizontal, value: deltaX)
        }
        guard allowVerticalFallback else {
            return nil
        }
        guard abs(deltaY) > mouseWheelAxisEpsilon else {
            return nil
        }
        return MouseWheelColumnDelta(axis: .vertical, value: deltaY)
    }

    static func averageGestureTouchPosition(
        requiredFingers: Int,
        touches: [GestureTouchSample]
    ) -> CGPoint? {
        guard requiredFingers > 0 else { return nil }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var touchCount = 0
        var activeCount = 0

        for touch in touches {
            if touch.phase == .ended || touch.phase == .cancelled {
                continue
            }

            touchCount += 1
            if touchCount > requiredFingers {
                return nil
            }

            guard let normalizedPosition = touch.normalizedPosition else {
                return nil
            }

            sumX += normalizedPosition.x
            sumY += normalizedPosition.y
            activeCount += 1
        }

        guard touchCount == requiredFingers, activeCount > 0 else { return nil }

        return CGPoint(
            x: sumX / CGFloat(activeCount),
            y: sumY / CGFloat(activeCount)
        )
    }
}
