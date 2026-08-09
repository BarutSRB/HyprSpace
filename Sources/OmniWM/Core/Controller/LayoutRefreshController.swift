// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor final class LayoutRefreshController: NSObject {
    typealias PostLayoutAction = @MainActor () -> Void

    enum RefreshRoute: Equatable {
        case relayout
        case immediateRelayout
        case visibilityRefresh
        case windowRemoval
    }

    enum ScheduledRefreshKind: Int {
        case relayout
        case immediateRelayout
        case visibilityRefresh
        case windowRemoval
        case fullRescan
    }

    struct WindowRemovalPayload {
        var workspaceId: WorkspaceDescriptor.ID
        let layoutType: LayoutType
        let removedNodeId: NodeId?
        let removedNiriColumn: Bool
        let niriOldFrames: [WindowToken: CGRect]
        let shouldRecoverFocus: Bool
        let allowsPreferredRecoveryToken: Bool
    }

    struct FollowUpRefresh {
        var kind: ScheduledRefreshKind
        var reason: RefreshReason
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var additionalAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var workspaceMonitorRelocations: [WindowToken: ScheduledWorkspaceMonitorRelocation] = [:]
        var reconcilesWorkspaceMonitorState = false
        var suppressesWindowActivation = false
    }

    struct WorkspaceRefreshScope {
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
        var additionalAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    }

    struct ScheduledRefresh {
        var kind: ScheduledRefreshKind
        var reason: RefreshReason
        var rescanScope: RescanScope
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var additionalAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var postLayoutActions: [RefreshPostLayoutAction] = []
        var windowRemovalPayloads: [WindowRemovalPayload] = []
        var workspaceMonitorRelocations: [WindowToken: ScheduledWorkspaceMonitorRelocation] = [:]
        var followUpRefresh: FollowUpRefresh?
        var subsumesRelayout = false
        var reconcilesWorkspaceMonitorState: Bool
        var suppressesWindowActivation: Bool
        var needsVisibilityReconciliation: Bool = false
        var visibilityReason: RefreshReason?

        init(
            kind: ScheduledRefreshKind,
            reason: RefreshReason,
            rescanScope: RescanScope = .all,
            affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
            postLayout: RefreshPostLayoutAction? = nil,
            windowRemovalPayload: WindowRemovalPayload? = nil,
            workspaceMonitorRelocations: [ScheduledWorkspaceMonitorRelocation] = [],
            reconcilesWorkspaceMonitorState: Bool? = nil,
            suppressesWindowActivation: Bool = false
        ) {
            self.kind = kind
            self.reason = reason
            self.rescanScope = rescanScope
            self.affectedWorkspaceIds = affectedWorkspaceIds
            self.workspaceMonitorRelocations = Dictionary(
                workspaceMonitorRelocations.map { ($0.token, $0) },
                uniquingKeysWith: { _, incoming in incoming }
            )
            self.reconcilesWorkspaceMonitorState = reconcilesWorkspaceMonitorState
                ?? (
                    reason == .workspaceConfigChanged
                        || reason == .monitorConfigurationChanged
                )
            self.suppressesWindowActivation = suppressesWindowActivation || reason == .overviewMutation
            if let postLayout {
                postLayoutActions = [postLayout]
            }
            if let windowRemovalPayload {
                windowRemovalPayloads = [windowRemovalPayload]
            }
        }
    }

    struct NativeSpaceRescanEvidence {
        var resolvedPIDs: Set<pid_t> = []
        var windowIds: Set<Int> = []
        var windowServerInfoByWindowId: [Int: WindowServerInfo] = [:]
    }

    @MainActor
    private final class RefreshFrameContext {
        private var cache: [WindowToken: CGRect?] = [:]
        private(set) var requests = 0
        private(set) var hits = 0

        func fastFrame(for token: WindowToken, axRef: AXWindowRef) -> CGRect? {
            requests += 1
            if let cached = cache[token] {
                hits += 1
                return cached
            }
            let frame = AXWindowService.framePreferFast(axRef)
            cache[token] = .some(frame)
            return frame
        }
    }

    weak var controller: WMController?
    static let hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0
    private static let delayedRevealVerificationDelay: Duration = .milliseconds(50)

    enum HideReason {
        case workspaceInactive
        case layoutTransient
        case scratchpad
    }

    private enum HiddenRevealOperation {
        case none
        case positionPlan(WindowPositionPlan)
        case asyncFrame(CGRect)
    }

    private enum HiddenRevealTerminalOutcome {
        case success
        case delayedVerification
        case failure
    }

    private struct PendingRevealTransaction {
        let id: UInt64
        var token: WindowToken
        var pid: pid_t
        var windowId: Int
        var workspaceId: WorkspaceDescriptor.ID
        var plannedSeq: UInt64
        let targetFrame: CGRect
        let targetMonitorId: Monitor.ID
        let hiddenState: HiddenState
        var postSuccessActions: [RefreshPostLayoutAction]
        var delayedVerificationScheduled: Bool = false
    }

    struct LayoutState {
        struct ClosingAnimation {
            let windowId: Int
            let axRef: AXWindowRef
            let fromFrame: CGRect
            let displacement: CGPoint
            let animation: SpringAnimation

            func progress(at time: TimeInterval) -> Double {
                animation.value(at: time)
            }

            func isComplete(at time: TimeInterval) -> Bool {
                animation.isComplete(at: time)
            }

            func currentFrame(at time: TimeInterval) -> CGRect {
                let clamped = min(max(progress(at: time), 0), 1)
                let offset = CGPoint(
                    x: displacement.x * CGFloat(clamped),
                    y: displacement.y * CGFloat(clamped)
                )
                return fromFrame.offsetBy(dx: offset.x, dy: offset.y)
            }
        }

        var activeRefreshTask: Task<Void, Never>?
        var activeRefresh: ScheduledRefresh?
        var pendingRefresh: ScheduledRefresh?
        var isImmediateLayoutInProgress: Bool = false
        var isIncrementalRefreshInProgress: Bool = false
        var activeFullEnumerationCount: Int = 0
        var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
        var lastDisplayLinkTimestampByDisplay: [CGDirectDisplayID: CFTimeInterval] = [:]
        var lastParkAuditTime: CFTimeInterval = 0
        var trailingAuditTask: Task<Void, Never>?
        var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
        var closingAnimationsByDisplay: [CGDirectDisplayID: [Int: ClosingAnimation]] = [:]
        var screenChangeObserver: NSObjectProtocol?
        var hasCompletedInitialRefresh: Bool = false
        var didExecuteEffectPlan: Bool = false
        var refreshGeneration: UInt64 = 0
        var pendingDebounceTask: Task<Void, Never>?
        var missingConfirmationTask: Task<Void, Never>?
        var pendingMissingConfirmationScope: RescanScope?
        var consecutiveMissCountByHandle: [WindowHandle: Int] = [:]
        var inventoryStabilityBarrierActive = false
        var inventoryStabilityHoldFullRescans = false
        var inventoryStabilityHeldFullRescan: ScheduledRefresh?
    }

    var layoutState = LayoutState()
    private var layoutBuildMetrics = LayoutBuildMetrics()
    private var activeFrameContext: RefreshFrameContext?
    private var nextPendingRevealTransactionId: UInt64 = 1
    private var pendingRevealTransactionsByWindowId: [Int: PendingRevealTransaction] = [:]
    private var pendingRevealVerificationTasksByWindowId: [Int: Task<Void, Never>] = [:]
    var nativeFullscreenRestoredFrameApplyTokens: Set<WindowToken> = []

    var fastFrameProvider: (WindowToken, AXWindowRef) -> CGRect? = { _, axRef in
        AXWindowService.framePreferFast(axRef)
    }

    var nativeSpaceWindowInventoryProvider: (Set<UInt64>) -> NativeSpaceWindowInventoryResult = {
        SkyLight.shared.nativeSpaceWindowInventory(spaceIds: $0)
    }

    func fastFrame(for token: WindowToken, axRef: AXWindowRef) -> CGRect? {
        activeFrameContext?.fastFrame(for: token, axRef: axRef)
            ?? fastFrameProvider(token, axRef)
    }

    private(set) lazy var niriHandler = NiriLayoutHandler(controller: controller)
    private(set) lazy var dwindleHandler = DwindleLayoutHandler(controller: controller)
    private lazy var diffExecutor = LayoutDiffExecutor(refreshController: self)

    var isDiscoveryInProgress: Bool {
        layoutState.activeFullEnumerationCount > 0
    }

    init(controller: WMController) {
        self.controller = controller
        super.init()
    }

    func setup() {
        detectRefreshRates()
        layoutState.screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    private func getOrCreateDisplayLink(for displayId: CGDirectDisplayID) -> CADisplayLink? {
        if let existing = layoutState.displayLinksByDisplay[displayId] {
            return existing
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        layoutState.displayLinksByDisplay[displayId] = link
        return link
    }

    private func handleScreenParametersChanged() {
        detectRefreshRates()
        controller?.syncMonitorsToNiriEngine()
        controller?.surfaceReconciler.noteWorldChanged()
    }

    func cleanupForMonitorDisconnect(displayId: CGDirectDisplayID, migrateAnimations: Bool) {
        if let link = layoutState.displayLinksByDisplay.removeValue(forKey: displayId) {
            link.invalidate()
        }

        layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)

        if migrateAnimations {
            if let wsId = niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId) {
                startScrollAnimation(for: wsId)
            }
        } else if let workspaceId = niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId) {
            controller?.workspaceManager.animationDriver.removeMotions(for: [workspaceId])
        }
        dwindleHandler.dwindleAnimationByDisplay.removeValue(forKey: displayId)
    }

    private func detectRefreshRates() {
        layoutState.refreshRateByDisplay.removeAll()
        for screen in NSScreen.screens {
            guard let displayId = screen.displayId else { continue }
            layoutState.refreshRateByDisplay[displayId] = Monitor.refreshRate(for: displayId)
        }
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        guard let displayId = layoutState.displayLinksByDisplay.first(where: { $0.value === displayLink })?.key
        else { return }

        let traceActive = AnimationTickTrace.shared.isActive
        let t0 = traceActive ? CACurrentMediaTime() : 0
        var t1: CFTimeInterval = 0
        var t2: CFTimeInterval = 0
        var t3: CFTimeInterval = 0

        SkyLight.shared.withTransactionScope {
            niriHandler.tickScrollAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
            t1 = traceActive ? CACurrentMediaTime() : 0
            dwindleHandler.tickDwindleAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
            t2 = traceActive ? CACurrentMediaTime() : 0
            tickClosingAnimations(targetTime: displayLink.targetTimestamp, displayId: displayId)
            t3 = traceActive ? CACurrentMediaTime() : 0
            controller?.surfaceReconciler.reconcileAnimationTick()
        }

        auditParkVisibility(displayId: displayId)

        guard traceActive else { return }
        let t4 = CACurrentMediaTime()
        let previousTimestamp = layoutState.lastDisplayLinkTimestampByDisplay[displayId]
        layoutState.lastDisplayLinkTimestampByDisplay[displayId] = displayLink.timestamp

        let expectedMs = displayLink.duration * 1000
        let intervalMs = previousTimestamp.map { (displayLink.timestamp - $0) * 1000 } ?? 0
        let totalMs = (t4 - t0) * 1000
        let dropped = (previousTimestamp != nil && intervalMs > 1.5 * expectedMs)
            || (expectedMs > 0 && totalMs > expectedMs)

        AnimationTickTrace.shared.record(
            AnimationTickTrace.Record(
                mediaTime: t4,
                displayId: displayId,
                intervalMs: intervalMs,
                expectedMs: expectedMs,
                scrollMs: (t1 - t0) * 1000,
                dwindleMs: (t2 - t1) * 1000,
                closingMs: (t3 - t2) * 1000,
                reconcileMs: (t4 - t3) * 1000,
                totalMs: totalMs,
                dropped: dropped
            )
        )
    }

    private func auditParkVisibility(displayId: CGDirectDisplayID) {
        guard ParkVisibilityAudit.shared.isActive, let controller else { return }
        let now = CACurrentMediaTime()
        guard now - layoutState.lastParkAuditTime >= 0.1 else { return }
        layoutState.lastParkAuditTime = now

        let monitorFrames = controller.workspaceManager.monitors.map(\.frame)
        var laggards: [String] = []
        var strays: [String] = []
        var visible: [Int] = []
        var parkedCount = 0
        for entry in controller.workspaceManager.allEntries() {
            guard let windowId = UInt32(exactly: entry.windowId) else { continue }
            guard controller.workspaceManager.hiddenState(for: entry.token) != nil else {
                visible.append(entry.windowId)
                if entry.mode == .tiling,
                   let bounds = SkyLight.shared.getWindowBounds(windowId)
                {
                    let frame = ScreenCoordinateSpace.toAppKit(rect: bounds)
                    let expectations = [
                        controller.axManager.lastAppliedFrame(for: entry.windowId)?.origin,
                        controller.axManager.pendingFrameWrite(for: entry.windowId)?.origin,
                        controller.axManager.skyLightLivePosition(for: entry.windowId)
                    ].compactMap(\.self)
                    let strayEpsilon: CGFloat = 32
                    let matchesExpectation = expectations.contains {
                        abs($0.x - frame.origin.x) <= strayEpsilon
                            && abs($0.y - frame.origin.y) <= strayEpsilon
                    }
                    if !matchesExpectation {
                        let expected = expectations.first.map { TraceFormat.point($0) } ?? "none"
                        strays.append(
                            "\(entry.windowId):\(TraceFormat.point(frame.origin))→\(expected)"
                        )
                    }
                }
                continue
            }
            guard let bounds = SkyLight.shared.getWindowBounds(windowId) else { continue }
            let frame = ScreenCoordinateSpace.toAppKit(rect: bounds)
            let overlap = monitorFrames
                .map { $0.intersection(frame) }
                .filter { !$0.isNull && !$0.isEmpty }
                .max { $0.width * $0.height < $1.width * $1.height }
            if let overlap, overlap.width > 16, overlap.height > 16 {
                laggards.append(
                    "\(entry.windowId):\(Int(overlap.width))x\(Int(overlap.height))"
                        + "@\(TraceFormat.point(frame.origin))"
                )
            } else {
                parkedCount += 1
            }
        }
        ParkVisibilityAudit.shared.record(
            ParkVisibilityAudit.Record(
                mediaTime: now,
                displayId: displayId,
                laggards: laggards,
                strays: strays,
                visible: visible.sorted(),
                parkedCount: parkedCount
            )
        )
    }

    func startScrollAnimation(for workspaceId: WorkspaceDescriptor.ID, forGesture: Bool = false) {
        guard forGesture || controller?.motionPolicy.animationsEnabled != false else { return }
        guard let controller else { return }
        let targetDisplayId: CGDirectDisplayID
        if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            targetDisplayId = monitor.displayId
        } else if let mainDisplayId = NSScreen.main?.displayId {
            targetDisplayId = mainDisplayId
        } else {
            return
        }

        guard let displayLink = getOrCreateDisplayLink(for: targetDisplayId) else { return }
        guard niriHandler.registerScrollAnimation(workspaceId, on: targetDisplayId) else {
            return
        }
        displayLink.add(to: .main, forMode: .common)
    }

    func stopScrollAnimation(for displayId: CGDirectDisplayID) {
        niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllScrollAnimations() {
        let displayIds = Array(niriHandler.scrollAnimationByDisplay.keys)
        niriHandler.scrollAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func startDwindleAnimation(for workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard controller?.motionPolicy.animationsEnabled != false else { return }
        let targetDisplayId = monitor.displayId

        guard dwindleHandler.registerDwindleAnimation(workspaceId, monitor: monitor, on: targetDisplayId)
        else { return }

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func startWindowCloseAnimation(entry: WindowState, monitor: Monitor) {
        guard controller?.motionPolicy.animationsEnabled != false else { return }
        guard controller != nil else { return }
        guard let frame = fastFrame(for: entry.token, axRef: entry.axRef) else { return }

        let displacement = CGPoint(x: 0, y: -12)

        let now = CACurrentMediaTime()
        let refreshRate = layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0
        let animation = SpringAnimation(
            from: 0,
            to: 1,
            startTime: now,
            config: .balanced.with(epsilon: 0.01, velocityEpsilon: 0.1),
            displayRefreshRate: refreshRate
        )

        var animations = layoutState.closingAnimationsByDisplay[monitor.displayId] ?? [:]
        guard animations[entry.windowId] == nil else { return }
        animations[entry.windowId] = LayoutState.ClosingAnimation(
            windowId: entry.windowId,
            axRef: entry.axRef,
            fromFrame: frame,
            displacement: displacement,
            animation: animation
        )
        layoutState.closingAnimationsByDisplay[monitor.displayId] = animations

        if let displayLink = getOrCreateDisplayLink(for: monitor.displayId) {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    func stopDwindleAnimation(for displayId: CGDirectDisplayID) {
        dwindleHandler.dwindleAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllDwindleAnimations() {
        let displayIds = Array(dwindleHandler.dwindleAnimationByDisplay.keys)
        dwindleHandler.dwindleAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleHandler.hasDwindleAnimationRunning(in: workspaceId)
    }

    private func stopDisplayLinkIfIdle(for displayId: CGDirectDisplayID) {
        if niriHandler.scrollAnimationByDisplay[displayId] == nil,
           dwindleHandler.dwindleAnimationByDisplay[displayId] == nil,
           layoutState.closingAnimationsByDisplay[displayId].map({ $0.isEmpty }) ?? true
        {
            // Idle display links must not remain cached after teardown.
            if let link = layoutState.displayLinksByDisplay.removeValue(forKey: displayId) {
                link.invalidate()
            }
            layoutState.lastDisplayLinkTimestampByDisplay.removeValue(forKey: displayId)
            scheduleTrailingParkAudits(displayId: displayId)
        }
    }

    private func scheduleTrailingParkAudits(displayId: CGDirectDisplayID) {
        guard ParkVisibilityAudit.shared.isActive else { return }
        layoutState.trailingAuditTask?.cancel()
        layoutState.trailingAuditTask = Task { @MainActor [weak self] in
            for _ in 0 ..< 30 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.auditParkVisibility(displayId: displayId)
            }
        }
    }

    private func tickClosingAnimations(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let animations = layoutState.closingAnimationsByDisplay[displayId], !animations.isEmpty else {
            return
        }

        var remaining: [Int: LayoutState.ClosingAnimation] = [:]

        for (windowId, animation) in animations {
            if animation.isComplete(at: targetTime) {
                _ = AXWindowService.setFrame(
                    animation.axRef,
                    frame: animation.currentFrame(at: targetTime)
                )
                continue
            }

            let frame = animation.currentFrame(at: targetTime)
            if !AXWindowService.setFrame(animation.axRef, frame: frame).isVerifiedSuccess {
                continue
            }
            remaining[windowId] = animation
        }

        if remaining.isEmpty {
            layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
            stopDisplayLinkIfIdle(for: displayId)
        } else {
            layoutState.closingAnimationsByDisplay[displayId] = remaining
        }
    }

    func applyLayoutForWorkspaces(_ workspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }

        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) else { continue }
            let wsId = workspace.id
            guard workspaceIds.contains(wsId) else { continue }

            let layoutType = controller.settings.layoutType(for: workspace.name)

            switch layoutType {
            case .niri,
                 .defaultLayout:
                guard let engine = controller.niriEngine else { continue }
                let state = controller.workspaceManager.niriViewportState(for: wsId)

                niriHandler.applyFramesOnDemand(
                    wsId: wsId,
                    state: state,
                    engine: engine,
                    monitor: monitor,
                    animationTime: nil
                )

            case .dwindle:
                dwindleHandler.applyFramesOnDemand(workspaceId: wsId, monitor: monitor)
            }
        }

        let preferredSides = preferredHideSides(for: controller.workspaceManager.monitors)
        for ws in controller.workspaceManager.workspaces where workspaceIds.contains(ws.id) {
            guard let monitor = controller.workspaceManager.monitor(for: ws.id) else { continue }
            let isActive = controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == ws.id
            if !isActive {
                let preferredSide = preferredSides[monitor.id] ?? .right
                hideWorkspace(
                    controller.workspaceManager.entries(in: ws.id),
                    monitor: monitor,
                    preferredSide: preferredSide
                )
            }
        }
    }

    private func executeLayoutPlans(
        _ plans: [WorkspaceLayoutPlan],
        suppressWindowActivation: Bool
    ) -> [WorkspaceDescriptor.ID: AcceptedSeq] {
        var acceptedSeqs: [WorkspaceDescriptor.ID: AcceptedSeq] = [:]
        for plan in plans {
            if let acceptedSeq = executeLayoutPlanReturningAcceptedSeq(
                plan,
                suppressWindowActivation: suppressWindowActivation
            ) {
                acceptedSeqs[plan.workspaceId] = acceptedSeq
            }
        }
        return acceptedSeqs
    }

    @discardableResult
    func executeLayoutPlan(_ plan: WorkspaceLayoutPlan) -> Bool {
        executeLayoutPlanReturningAcceptedSeq(plan, suppressWindowActivation: false) != nil
    }

    func executeLayoutPlanReturningAcceptedSeq(
        _ plan: WorkspaceLayoutPlan,
        suppressWindowActivation: Bool = false
    ) -> AcceptedSeq? {
        guard let controller else { return nil }

        controller.withRuntimeFrameJobCancellationSuppressed {
            applySessionPatch(plan.sessionPatch)
            diffExecutor.execute(plan)
            controller.workspaceManager.setNiriRestorePlacements(plan.niriRestorePlacements)
        }
        applyAnimationDirectives(
            plan.animationDirectives,
            workspaceId: plan.workspaceId,
            focusSeqAccepted: true,
            suppressWindowActivation: suppressWindowActivation
        )
        if !plan.isAnimationTick {
            controller.surfaceReconciler.noteWorldChanged()
        }
        return AcceptedSeq(
            after: controller.workspaceManager.worldSeq,
            domains: .layoutCommit.union(.focusCommit)
        )
    }

    private func executeEffectPlan(_ plan: EffectPlan, generation: UInt64) async -> Bool {
        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }

        activeFrameContext = RefreshFrameContext()
        defer { activeFrameContext = nil }

        // Rebuild the inactive-workspace window set BEFORE executing layout plans
        // so that applyFramesParallel (inside executeLayoutPlans) uses the correct
        // active/inactive classification. Without this, windows on a newly-active
        // workspace are still marked inactive from the previous cycle, causing their
        // frame writes to be silently skipped and leaving blank gaps on screen.
        var currentEffectActiveWorkspaceIds: Set<WorkspaceDescriptor.ID>?
        if plan.effects.visibility != nil {
            let activeWorkspaceIds = currentActiveWorkspaceIds()
            currentEffectActiveWorkspaceIds = activeWorkspaceIds
            rebuildInactiveWorkspaceWindowSet(activeWorkspaceIds: activeWorkspaceIds)
        }

        let actionWorkspacesCurrentAtEntry = plan.postLayoutActions.map {
            $0.currentWorkspaces(using: controller.workspaceManager)
        }
        let forwardedPostLayoutActions = { (acceptedSeqs: [WorkspaceDescriptor.ID: AcceptedSeq]) in
            zip(plan.postLayoutActions, actionWorkspacesCurrentAtEntry).map { action, currentAtEntry in
                action.forwarded(by: acceptedSeqs, currentAtEntry: currentAtEntry)
            }
        }

        var acceptedSeqs = executeLayoutPlans(
            plan.workspacePlans,
            suppressWindowActivation: plan.effects.suppressWindowActivation
        )
        layoutState.didExecuteEffectPlan = true

        if plan.effects.visibility != nil {
            let activeWorkspaceIds = currentEffectActiveWorkspaceIds ?? currentActiveWorkspaceIds()
            currentEffectActiveWorkspaceIds = activeWorkspaceIds
            controller.withRuntimeFrameJobCancellationSuppressed {
                restoreWorkspaceInactiveFloatingWindows(activeWorkspaceIds: activeWorkspaceIds)
                hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
            }
            for workspaceId in Array(acceptedSeqs.keys) {
                guard let accepted = acceptedSeqs[workspaceId] else { continue }
                acceptedSeqs[workspaceId] = AcceptedSeq(
                    after: controller.workspaceManager.worldSeq,
                    domains: accepted.domains
                )
            }
        }

        let activeWorkspaceIdsForFocusValidation = currentEffectActiveWorkspaceIds ?? currentActiveWorkspaceIds()
        for workspaceId in plan.effects.focusValidationWorkspaceIds
            where activeWorkspaceIdsForFocusValidation.contains(workspaceId)
        {
            let preferredRecoveryToken = plan.effects.focusValidationPreferredTokens[workspaceId]
            controller.ensureFocusedTokenValid(
                in: workspaceId,
                preferredRecoveryToken: preferredRecoveryToken
            )
        }

        for postLayoutAction in forwardedPostLayoutActions(acceptedSeqs) {
            postLayoutAction.runIfCurrent(using: controller.workspaceManager)
        }

        if plan.effects.markInitialRefreshComplete {
            layoutState.hasCompletedInitialRefresh = true
        }

        if plan.effects.drainDeferredCreatedWindows {
            await controller.axEventHandler.drainDeferredCreatedWindows()
        }

        if plan.effects.subscribeManagedWindows {
            controller.axEventHandler.subscribeToManagedWindows()
        }

        return true
    }

    func applyResolvedConstraints(_ fact: WindowConstraintsFact) {
        guard let controller,
              let workspaceId = controller.workspaceManager.workspace(for: fact.token)
        else { return }
        let previous = controller.workspaceManager.cachedConstraints(
            for: fact.token,
            maxAge: .greatestFiniteMagnitude
        )
        controller.workspaceManager.setCachedConstraints(fact.constraints, for: fact.token)
        if previous != fact.constraints {
            requestRelayout(reason: .observedConstraintsChanged, affectedWorkspaceIds: [workspaceId])
        }
    }

    func buildWindowSnapshots(
        for entries: [WindowState],
        resolveConstraints: Bool,
        workArea: CGSize,
        neighborAxes: MonitorNeighborAxes
    ) -> [LayoutWindowSnapshot] {
        guard let controller else { return [] }

        var snapshots: [LayoutWindowSnapshot] = []
        snapshots.reserveCapacity(entries.count)

        for entry in entries {
            let layoutReason = controller.workspaceManager.layoutReason(for: entry.token)
            let constraints: WindowSizeConstraints
            if !resolveConstraints || layoutReason == .nativeFullscreen {
                constraints = controller.workspaceManager.cachedConstraints(for: entry.token) ?? .unconstrained
            } else if let cached = controller.workspaceManager.cachedConstraints(for: entry.token) {
                constraints = cached
            } else {
                controller.factResolver.resolveWindowConstraints(token: entry.token, axRef: entry.axRef)
                constraints = controller.workspaceManager.cachedConstraints(
                    for: entry.token,
                    maxAge: .greatestFiniteMagnitude
                ) ?? .unconstrained
            }

            var mergedConstraints = constraints
            if resolveConstraints {
                if let minW = entry.ruleEffects.minWidth {
                    mergedConstraints.minSize.width = max(mergedConstraints.minSize.width, minW)
                }
                if let minH = entry.ruleEffects.minHeight {
                    mergedConstraints.minSize.height = max(mergedConstraints.minSize.height, minH)
                }
                if let observedMin = controller.workspaceManager.observedMinSize(for: entry.token) {
                    mergedConstraints.minSize.width = max(mergedConstraints.minSize.width, observedMin.width)
                    mergedConstraints.minSize.height = max(mergedConstraints.minSize.height, observedMin.height)
                }
                mergedConstraints = mergedConstraints.normalized()
            }

            let hiddenState = controller.workspaceManager.hiddenState(for: entry.token)

            snapshots.append(
                LayoutWindowSnapshot(
                    token: entry.token,
                    constraints: Self.overflowCappedConstraints(
                        mergedConstraints,
                        layoutReason: layoutReason,
                        workArea: workArea,
                        cappedAxes: neighborAxes
                    ),
                    hiddenState: hiddenState,
                    layoutReason: layoutReason
                )
            )
        }

        return snapshots
    }

    nonisolated static func overflowCappedConstraints(
        _ constraints: WindowSizeConstraints,
        layoutReason: LayoutReason,
        workArea: CGSize,
        cappedAxes: MonitorNeighborAxes
    ) -> WindowSizeConstraints {
        var effective = constraints.normalized()
        if effective.isFixed || layoutReason == .nativeFullscreen {
            return effective
        }
        if cappedAxes.horizontal {
            effective.minSize.width = min(effective.minSize.width, workArea.width)
        }
        if cappedAxes.vertical {
            effective.minSize.height = min(effective.minSize.height, workArea.height)
        }
        return effective
    }

    func buildMonitorSnapshot(
        for monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> LayoutMonitorSnapshot {
        LayoutMonitorSnapshot(
            monitorId: monitor.id,
            displayId: monitor.displayId,
            frame: monitor.frame,
            visibleFrame: monitor.visibleFrame,
            workingFrame: controller?.insetWorkingFrame(for: monitor) ?? monitor.visibleFrame,
            fullscreenLayoutFrame: controller?.fullscreenLayoutFrame(for: monitor) ?? monitor.visibleFrame,
            scale: backingScale(for: monitor),
            orientation: orientation ?? monitor.autoOrientation
        )
    }

    func buildRefreshInput(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        resolveConstraints: Bool,
        orientation: Monitor.Orientation? = nil,
        isActiveWorkspace: Bool
    ) -> WorkspaceRefreshInput? {
        guard let controller else { return nil }

        let monitorSnapshot = buildMonitorSnapshot(for: monitor, orientation: orientation)
        let entries = controller.workspaceManager.tiledEntries(in: workspaceId)
        let windows = buildWindowSnapshots(
            for: entries,
            resolveConstraints: resolveConstraints,
            workArea: monitorSnapshot.workingFrame.size,
            neighborAxes: monitor.neighborAxes(among: controller.workspaceManager.monitors)
        )

        return WorkspaceRefreshInput(
            workspaceId: workspaceId,
            monitor: monitorSnapshot,
            windows: windows,
            isActiveWorkspace: isActiveWorkspace
        )
    }

    private func applySessionPatch(_ patch: WorkspaceSessionPatch) {
        controller?.workspaceManager.applySessionPatch(patch)
    }

    private func applyAnimationDirectives(
        _ directives: [AnimationDirective],
        workspaceId: WorkspaceDescriptor.ID,
        focusSeqAccepted: Bool,
        suppressWindowActivation: Bool
    ) {
        guard let controller else { return }

        for directive in directives {
            switch directive {
            case .none:
                continue
            case let .startNiriScroll(workspaceId):
                startScrollAnimation(for: workspaceId)
            case let .startDwindleAnimation(workspaceId, monitorId):
                guard let monitor = controller.workspaceManager.monitor(byId: monitorId) else { continue }
                startDwindleAnimation(for: workspaceId, monitor: monitor)
            case let .activateWindow(token):
                guard !suppressWindowActivation,
                      !controller.shouldSuppressManagedFocusRecovery,
                      !controller.workspaceManager.hasPendingNativeFullscreenTransition,
                      focusSeqAccepted
                else { continue }
                if let workspaceId = controller.workspaceManager.workspace(for: token) {
                    controller.recordNiriCreateFocusTrace(
                        .relayoutActivatedWindow(
                            token: token,
                            workspaceId: workspaceId
                        )
                    )
                }
                controller.focusWindow(token)
            }
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        niriHandler.cancelActiveAnimations(for: workspaceId)
    }

    func requestFullRescan(
        reason: RefreshReason,
        scope: RescanScope = .all,
        reconcilesWorkspaceMonitorState: Bool? = nil
    ) {
        assert(reason.requestRoute == .fullRescan, "Invalid full-rescan reason: \(reason)")
        scheduleFullRescan(
            reason: reason,
            scope: scope.isEmpty ? .all : scope,
            reconcilesWorkspaceMonitorState: reconcilesWorkspaceMonitorState
        )
    }

    func requestRelayout(
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) {
        assert(reason.requestRoute == .relayout, "Invalid relayout reason: \(reason)")
        scheduleRefreshSession(
            reason.relayoutSchedulingPolicy,
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaceIds
        )
    }

    func requestImmediateRelayout(
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayout: PostLayoutAction? = nil,
        postLayoutInvalidated: PostLayoutAction? = nil,
        postLayoutDomains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen],
        postLayoutGateWorkspaceIds: Set<WorkspaceDescriptor.ID>? = nil
    ) {
        assert(reason.requestRoute == .immediateRelayout, "Invalid immediate-relayout reason: \(reason)")
        let postLayoutWorkspaceIds = postLayoutGateWorkspaceIds
            ?? self.postLayoutWorkspaceIds(for: affectedWorkspaceIds)
        let postLayoutAction = makePostLayoutAction(
            postLayout,
            workspaceIds: postLayoutWorkspaceIds,
            domains: postLayoutDomains,
            invalidatedAction: postLayoutInvalidated
        )
        enqueueRefresh(
            .init(
                kind: .immediateRelayout,
                reason: reason,
                affectedWorkspaceIds: affectedWorkspaceIds,
                postLayout: postLayoutAction
            )
        )
    }

    func renderInteractiveResize(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else { return }
        _ = niriHandler.applyFramesOnDemand(
            wsId: workspaceId,
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            engine: engine,
            monitor: monitor,
            animationTime: nil
        )
    }

    func renderDwindleInteractiveResize(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else { return }
        _ = dwindleHandler.applyFramesOnDemand(workspaceId: workspaceId, monitor: monitor)
    }

    func requestLayoutCommandRelayout(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        postLayout: PostLayoutAction? = nil,
        postLayoutDomains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen]
    ) {
        assert(!affectedWorkspaceIds.isEmpty, "Layout command relayout must name affected workspaces")
        controller?.workspaceManager.invalidateLayout(for: affectedWorkspaceIds)
        requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: affectedWorkspaceIds,
            postLayout: postLayout,
            postLayoutDomains: postLayoutDomains
        )
    }

    func requestVisibilityRefresh(
        reason: RefreshReason,
        postLayout: PostLayoutAction? = nil
    ) {
        assert(reason.requestRoute == .visibilityRefresh, "Invalid visibility-refresh reason: \(reason)")
        enqueueRefresh(
            .init(
                kind: .visibilityRefresh,
                reason: reason,
                postLayout: makePostLayoutAction(postLayout, workspaceIds: currentActiveWorkspaceIds())
            )
        )
    }

    func requestWindowRemoval(
        workspaceId: WorkspaceDescriptor.ID,
        layoutType: LayoutType,
        removedNodeId: NodeId?,
        removedNiriColumn: Bool,
        niriOldFrames: [WindowToken: CGRect],
        shouldRecoverFocus: Bool,
        allowsPreferredRecoveryToken: Bool = false,
        postLayout: PostLayoutAction? = nil
    ) {
        assert(RefreshReason.windowDestroyed.requestRoute == .windowRemoval, "Invalid window-removal reason")
        enqueueRefresh(
            .init(
                kind: .windowRemoval,
                reason: .windowDestroyed,
                postLayout: makePostLayoutAction(postLayout, workspaceIds: [workspaceId]),
                windowRemovalPayload: .init(
                    workspaceId: workspaceId,
                    layoutType: layoutType,
                    removedNodeId: removedNodeId,
                    removedNiriColumn: removedNiriColumn,
                    niriOldFrames: niriOldFrames,
                    shouldRecoverFocus: shouldRecoverFocus,
                    allowsPreferredRecoveryToken: allowsPreferredRecoveryToken
                )
            )
        )
    }

    func commitWorkspaceTransition(
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [],
        reason: RefreshReason = .workspaceTransition,
        postLayoutGateWorkspaceIds: Set<WorkspaceDescriptor.ID>? = nil,
        postLayout: PostLayoutAction? = nil,
        postLayoutInvalidated: PostLayoutAction? = nil
    ) {
        requestImmediateRelayout(
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaces,
            postLayout: postLayout,
            postLayoutInvalidated: postLayoutInvalidated,
            postLayoutGateWorkspaceIds: postLayoutGateWorkspaceIds
        )
    }

    private func makePostLayoutAction(
        _ postLayout: PostLayoutAction?,
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        domains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen],
        invalidatedAction: PostLayoutAction? = nil
    ) -> RefreshPostLayoutAction? {
        guard let postLayout else { return nil }
        guard let controller, !workspaceIds.isEmpty else { return nil }
        let plannedSeq = controller.workspaceManager.worldSeq
        var seqs: [WorkspaceDescriptor.ID: UInt64] = [:]
        seqs.reserveCapacity(workspaceIds.count)
        for workspaceId in workspaceIds {
            seqs[workspaceId] = plannedSeq
        }
        return RefreshPostLayoutAction(
            workspaceSeqs: seqs,
            domains: domains,
            action: postLayout,
            invalidatedAction: invalidatedAction
        )
    }

    private func acceptedPostLayoutAction(
        _ postLayout: PostLayoutAction?,
        workspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> RefreshPostLayoutAction? {
        guard let action = makePostLayoutAction(postLayout, workspaceIds: workspaceIds),
              let controller,
              action.isCurrent(using: controller.workspaceManager)
        else {
            return nil
        }
        return action
    }

    private func postLayoutWorkspaceIds(
        for affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        affectedWorkspaceIds.isEmpty ? currentActiveWorkspaceIds() : affectedWorkspaceIds
    }

    private func scheduleFullRescan(
        reason: RefreshReason,
        scope: RescanScope,
        reconcilesWorkspaceMonitorState: Bool?
    ) {
        enqueueRefresh(
            .init(
                kind: .fullRescan,
                reason: reason,
                rescanScope: scope,
                reconcilesWorkspaceMonitorState: reconcilesWorkspaceMonitorState
            )
        )
    }

    private func scheduleRefreshSession(
        _ policy: RelayoutSchedulingPolicy,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    ) {
        if policy.shouldDropWhileBusy {
            if layoutState.isIncrementalRefreshInProgress || layoutState.isImmediateLayoutInProgress {
                return
            }
            if !niriHandler.scrollAnimationByDisplay.isEmpty
                || !dwindleHandler.dwindleAnimationByDisplay.isEmpty
            {
                return
            }
        }
        let refresh = ScheduledRefresh(kind: .relayout, reason: reason, affectedWorkspaceIds: affectedWorkspaceIds)
        let debounce = policy.debounceInterval
        if debounce > 0 {
            enqueueDebouncedRelayout(refresh, debounce: debounce)
        } else {
            enqueueRefresh(refresh)
        }
    }

    private func enqueueDebouncedRelayout(_ refresh: ScheduledRefresh, debounce intervalNanos: UInt64) {
        if layoutState.activeRefresh != nil {
            enqueueRefresh(refresh)
            return
        }
        mergePendingRefresh(refresh)
        guard layoutState.pendingDebounceTask == nil else { return }
        layoutState.pendingDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: intervalNanos)
            guard let self else { return }
            self.layoutState.pendingDebounceTask = nil
            self.startNextRefreshIfNeeded()
        }
    }

    private func executeScheduledRelayout(refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard !layoutState.isIncrementalRefreshInProgress else { return false }
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isIncrementalRefreshInProgress = true
        defer { layoutState.isIncrementalRefreshInProgress = false }
        return await executeRelayout(
            refresh: refresh,
            route: .relayout,
            useScrollAnimationPath: false,
            recoverFocus: true,
            generation: generation
        )
    }

    private func executeRelayout(
        refresh: ScheduledRefresh,
        route: RefreshRoute,
        useScrollAnimationPath: Bool,
        recoverFocus: Bool,
        generation: UInt64
    ) async -> Bool {
        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        let buildStart = CACurrentMediaTime()
        var plan = buildRelayoutEffectPlan(
            useScrollAnimationPath: useScrollAnimationPath,
            recoverFocus: recoverFocus,
            affectedWorkspaceIds: resolvedScheduledWorkspaceIds(refresh)
        )
        layoutBuildMetrics.recordBuild(
            seconds: CACurrentMediaTime() - buildStart,
            route: .relayout,
            workspaceCount: plan.workspacePlans.count,
            windowCount: plan.workspacePlans.reduce(0) {
                $0 + controller.workspaceManager.entries(in: $1.workspaceId).count
            }
        )
        applyRefreshMetadata(refresh, to: &plan)
        return await executeEffectPlan(plan, generation: generation)
    }

    private func executeVisibilityRefresh(refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        var plan = buildVisibilityEffectPlan()
        applyRefreshMetadata(refresh, to: &plan)
        return await executeEffectPlan(plan, generation: generation)
    }

    func hideInactiveWorkspacesSync() {
        guard let controller else { return }
        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }
        hideInactiveWorkspaces(activeWorkspaceIds: activeWorkspaceIds)
    }

    private func executeImmediateRelayout(refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isImmediateLayoutInProgress = true
        defer { layoutState.isImmediateLayoutInProgress = false }
        return await executeRelayout(
            refresh: refresh,
            route: .immediateRelayout,
            useScrollAnimationPath: !niriHandler.scrollAnimationByDisplay.isEmpty,
            recoverFocus: false,
            generation: generation
        )
    }

    private func executeWindowRemoval(refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        let payloads = refresh.windowRemovalPayloads
        guard let controller else { return false }
        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        var plan = buildWindowRemovalEffectPlan(payloads: payloads)
        applyRefreshMetadata(refresh, to: &plan)
        return await executeEffectPlan(plan, generation: generation)
    }

    func resetState() {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.pendingDebounceTask?.cancel()
        layoutState.pendingDebounceTask = nil
        layoutState.missingConfirmationTask?.cancel()
        layoutState.missingConfirmationTask = nil
        layoutState.pendingMissingConfirmationScope = nil
        layoutState.consecutiveMissCountByHandle.removeAll(keepingCapacity: true)
        layoutState.inventoryStabilityBarrierActive = false
        layoutState.inventoryStabilityHoldFullRescans = false
        layoutState.inventoryStabilityHeldFullRescan = nil
        layoutState.trailingAuditTask?.cancel()
        layoutState.trailingAuditTask = nil
        layoutState.activeRefresh = nil
        layoutState.pendingRefresh = nil
        layoutState.didExecuteEffectPlan = false
        layoutState.refreshGeneration &+= 1
        for (_, task) in pendingRevealVerificationTasksByWindowId {
            task.cancel()
        }
        pendingRevealVerificationTasksByWindowId.removeAll()
        pendingRevealTransactionsByWindowId.removeAll()
        nextPendingRevealTransactionId = 1
        dwindleHandler.resetPendingGroupReveals()
        nativeFullscreenRestoredFrameApplyTokens.removeAll()

        for (_, link) in layoutState.displayLinksByDisplay {
            link.invalidate()
        }
        layoutState.displayLinksByDisplay.removeAll()
        niriHandler.scrollAnimationByDisplay.removeAll()
        dwindleHandler.dwindleAnimationByDisplay.removeAll()
        layoutState.closingAnimationsByDisplay.removeAll()

        controller?.axManager.clearInactiveWorkspaceWindows()

        if let observer = layoutState.screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            layoutState.screenChangeObserver = nil
        }
    }

    private func executeFullRefresh(refresh: ScheduledRefresh, generation: UInt64) async throws -> Bool {
        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        await controller.axEventHandler.awaitPendingManagedReplacementBursts(
            for: refresh.rescanScope == .all ? nil : refresh.rescanScope.targetedPIDs
        )
        try Task.checkCancellation()
        guard isCurrentRefreshGeneration(generation) else { return false }

        layoutState.activeFullEnumerationCount += 1
        defer { layoutState.activeFullEnumerationCount -= 1 }

        var plan = try await buildFullEffectPlan(
            removalPayloads: refresh.windowRemovalPayloads,
            scope: refresh.rescanScope,
            permitsMissingRetirement: !layoutState.inventoryStabilityBarrierActive,
            relayoutWorkspaceIds: refresh.subsumesRelayout
                ? resolvedScheduledWorkspaceIds(refresh)
                : nil,
            postLayoutActions: refresh.postLayoutActions
        )
        applyRefreshMetadata(refresh, includePostLayoutActions: false, to: &plan)
        try Task.checkCancellation()
        guard isCurrentRefreshGeneration(generation) else { return false }
        return await executeEffectPlan(plan, generation: generation)
    }

    func selectTabInNiri(
        info: TabRailInfo,
        visualIndex: Int,
        expectedToken: WindowToken?
    ) {
        niriHandler.selectTabInNiri(
            info: info,
            visualIndex: visualIndex,
            expectedToken: expectedToken
        )
    }

    func layoutBuildMetricsDump() -> String {
        layoutBuildMetrics.dump()
    }

    func recordScrollBuild(seconds: Double, workspaceCount: Int, windowCount: Int) {
        layoutBuildMetrics.recordBuild(
            seconds: seconds,
            route: .scrollTick,
            workspaceCount: workspaceCount,
            windowCount: windowCount
        )
    }

    private func buildVisibilityEffectPlan() -> EffectPlan {
        EffectPlan(effects: EffectPlanEffects())
    }

    private func buildWorkspacePlansInBatch(_ build: () -> [WorkspaceLayoutPlan]) -> [WorkspaceLayoutPlan] {
        guard let controller else { return [] }
        return controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.withBatchedLayoutBuild(build)
        }
    }

    private func buildRelayoutEffectPlan(
        useScrollAnimationPath: Bool,
        recoverFocus: Bool,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> EffectPlan {
        guard let controller else { return .init() }

        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let layoutWorkspaceIds = affectedWorkspaceIds.isEmpty
            ? activeWorkspaceIds
            : liveLayoutWorkspaceIds(affectedWorkspaceIds, controller: controller)
        if !affectedWorkspaceIds.isEmpty, layoutWorkspaceIds.isEmpty {
            return .init()
        }
        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(layoutWorkspaceIds)

        let workspacePlans = buildWorkspacePlansInBatch {
            var plans: [WorkspaceLayoutPlan] = []
            plans.reserveCapacity(niriWorkspaces.count + dwindleWorkspaces.count)
            if !niriWorkspaces.isEmpty {
                plans.append(contentsOf: self.niriHandler.layoutWithNiriEngine(
                    activeWorkspaces: niriWorkspaces,
                    useScrollAnimationPath: useScrollAnimationPath
                ))
            }
            if !dwindleWorkspaces.isEmpty {
                plans.append(
                    contentsOf: self.dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
                )
            }
            return plans
        }

        var effects = EffectPlanEffects()
        effects.visibility = .init()

        if recoverFocus,
           !controller.workspaceManager.isAppFullscreenActive,
           !controller.workspaceManager.hasPendingNativeFullscreenTransition,
           !controller.shouldSuppressManagedFocusRecovery,
           let focusedWorkspaceId = controller.activeWorkspace()?.id
        {
            effects.focusValidationWorkspaceIds = [focusedWorkspaceId]
        }

        return EffectPlan(workspacePlans: workspacePlans, effects: effects)
    }

    private func buildWindowRemovalEffectPlan(
        payloads: [WindowRemovalPayload]
    ) -> EffectPlan {
        guard let controller else { return .init() }

        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var focusedWorkspacesToRecover: Set<WorkspaceDescriptor.ID> = []
        var workspacesAllowingPreferredRecovery: Set<WorkspaceDescriptor.ID> = []
        let niriRemovalSeeds = makeNiriRemovalSeeds(from: payloads)

        for payload in payloads {
            switch payload.layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(payload.workspaceId)
            case .niri,
                 .defaultLayout:
                break
            }

            if payload.shouldRecoverFocus {
                focusedWorkspacesToRecover.insert(payload.workspaceId)
            }
            if payload.allowsPreferredRecoveryToken {
                workspacesAllowingPreferredRecovery.insert(payload.workspaceId)
            }
        }

        let workspacePlans = buildWorkspacePlansInBatch {
            var plans: [WorkspaceLayoutPlan] = []
            plans.reserveCapacity(dwindleWorkspaces.count + niriRemovalSeeds.count)
            if !niriRemovalSeeds.isEmpty {
                plans.append(contentsOf: self.niriHandler.layoutWithNiriEngine(
                    activeWorkspaces: Set(niriRemovalSeeds.keys),
                    useScrollAnimationPath: true,
                    removalSeeds: niriRemovalSeeds
                ))
            }
            if !dwindleWorkspaces.isEmpty {
                plans.append(
                    contentsOf: self.dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
                )
            }
            return plans
        }

        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let focusValidationWorkspaceIds: [WorkspaceDescriptor.ID]
        if controller.workspaceManager.isAppFullscreenActive
            || controller.workspaceManager.hasPendingNativeFullscreenTransition
            || controller.shouldSuppressManagedFocusRecovery
        {
            focusValidationWorkspaceIds = []
        } else {
            focusValidationWorkspaceIds = focusedWorkspacesToRecover
                .intersection(activeWorkspaceIds)
                .sorted { $0.uuidString < $1.uuidString }
        }

        let focusValidationPreferredTokens = workspacePlans.reduce(
            into: [WorkspaceDescriptor.ID: WindowToken]()
        ) { result, plan in
            guard let rememberedFocusToken = plan.sessionPatch.rememberedFocusToken,
                  focusValidationWorkspaceIds.contains(plan.workspaceId),
                  workspacesAllowingPreferredRecovery.contains(plan.workspaceId)
            else {
                return
            }
            result[plan.workspaceId] = rememberedFocusToken
        }

        var effects = EffectPlanEffects()
        effects.visibility = .init()

        effects.focusValidationWorkspaceIds = focusValidationWorkspaceIds
        effects.focusValidationPreferredTokens = focusValidationPreferredTokens

        return EffectPlan(workspacePlans: workspacePlans, effects: effects)
    }

    func resolveNativeSpaceRescanEvidence(
        scope: RescanScope
    ) throws -> NativeSpaceRescanEvidence {
        guard case let .targeted(_, nativeSpaceIds, _) = scope,
              !nativeSpaceIds.isEmpty
        else {
            return .init()
        }

        let inventory: [UInt64: [WindowServerInfo]]
        switch nativeSpaceWindowInventoryProvider(nativeSpaceIds) {
        case let .authoritative(authoritativeInventory):
            inventory = authoritativeInventory
        case .queryFailed,
             .unavailable:
            requestFullRescan(reason: .staleFullRescan, scope: .all)
            throw CancellationError()
        }

        var evidence = NativeSpaceRescanEvidence()
        for info in inventory.values.joined() {
            let windowId = Int(info.id)
            evidence.windowIds.insert(windowId)
            evidence.windowServerInfoByWindowId[windowId] = info
            if SkyLight.isSuitableNativeSpaceWindow(info) {
                evidence.resolvedPIDs.insert(info.pid)
            }
        }
        return evidence
    }

    private func buildFullEffectPlan(
        removalPayloads: [WindowRemovalPayload],
        scope: RescanScope,
        permitsMissingRetirement: Bool,
        relayoutWorkspaceIds: Set<WorkspaceDescriptor.ID>?,
        postLayoutActions: [RefreshPostLayoutAction]
    ) async throws -> EffectPlan {
        guard let controller else { return .init() }

        let rescanSeq = controller.workspaceManager.worldSeq
        let hadNativeFullscreenLifecycleContextAtStart = controller.workspaceManager.hasNativeFullscreenLifecycleContext
        let entriesAtStart = controller.workspaceManager.allEntries()
        let preservingPIDsByWindowId = Dictionary(
            uniqueKeysWithValues: entriesAtStart.map { ($0.windowId, $0.pid) }
        )
        var affectedWorkspaceIds = Set(removalPayloads.map(\.workspaceId))
        if case let .targeted(appPIDs, _, nativeSpaceWindowIdsByPID) = scope {
            for entry in entriesAtStart
                where appPIDs.contains(entry.pid)
                || nativeSpaceWindowIdsByPID[entry.pid]?.contains(entry.windowId) == true
            {
                affectedWorkspaceIds.insert(entry.workspaceId)
            }
        }
        let nativeSpaceEvidence = try resolveNativeSpaceRescanEvidence(scope: scope)
        let enumerationSnapshot = try await controller.axManager.fullRescanEnumerationSnapshot(
            scope: scope,
            resolvedTargetPIDs: nativeSpaceEvidence.resolvedPIDs.union(
                scope.nativeSpaceWindowIdsByPID.keys
            ),
            resolvedTargetWindowIds: nativeSpaceEvidence.windowIds.union(
                scope.nativeSpaceWindowIds
            ),
            supplementalWindowServerInfoByWindowId: nativeSpaceEvidence.windowServerInfoByWindowId,
            preservingPIDsByWindowId: preservingPIDsByWindowId,
            identityDependencyPIDsByWindowId: controller.axEventHandler
                .fullRescanIdentityDependencyPIDsByWindowId(entries: entriesAtStart),
            requiresTitleForApp: {
                controller.windowRuleEngine.requiresTitle(for: $0, appName: $1)
            }
        )
        try Task.checkCancellation()
        guard controller.workspaceManager.isSeqEpochCurrent(rescanSeq, domains: .layoutCommit) else {
            throw CancellationError()
        }
        let postLayoutActionWorkspacesCurrentAtMutation = postLayoutActions.map {
            $0.currentWorkspaces(using: controller.workspaceManager)
        }
        var seenKeys: Set<WindowToken> = []
        var decisionBasedRemovals: [WindowToken] = []
        var floatingFocusCandidate: FullRescanFloatingFocusCandidate?
        let focusedWorkspaceId = controller.activeWorkspace()?.id
        let screenFrames = NSScreen.screens.map(\.frame)

        for candidate in enumerationSnapshot.windows {
            let ax = candidate.axRef
            let pid = candidate.pid
            let winId = candidate.windowId
            let token = WindowToken(pid: pid, windowId: winId)
            let existingEntry: WindowState?
            switch controller.axEventHandler.resolveFullRescanIdentity(
                axRef: ax,
                pid: pid,
                windowId: winId,
                observedAliases: enumerationSnapshot.identityAliasesByWindowId[winId],
                failedPIDs: enumerationSnapshot.failedPIDs,
                sizeConstraints: candidate.enumeratedWindow.decisionEvidence.sizeConstraints
            ) {
            case let .process(entry):
                existingEntry = entry
            case let .preserve(token):
                seenKeys.insert(token)
                if let entry = controller.workspaceManager.entry(for: token) {
                    affectedWorkspaceIds.insert(entry.workspaceId)
                }
                continue
            }
            if let existingEntry {
                affectedWorkspaceIds.insert(existingEntry.workspaceId)
            }
            let bundleId = controller.appInfoCache.bundleId(for: pid)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if let bundleId {
                if bundleId == LockScreenObserver.lockScreenAppBundleId {
                    continue
                }
            }

            if existingEntry == nil,
               controller.axEventHandler.isAdmissionQuarantined(windowId: winId, axRef: ax)
            {
                controller.axEventHandler.discardCreatePlacementContext(for: winId)
                continue
            }
            let appFullscreen = candidate.isFullscreen(screenFrames: screenFrames)
            let evaluation = controller.evaluateWindowDisposition(
                token: token,
                evidence: candidate.enumeratedWindow.decisionEvidence,
                appFullscreen: appFullscreen,
                windowInfo: candidate.windowServerInfo,
                admissionGeometry: candidate.enumeratedWindow.admissionGeometry
            )
            let decision = evaluation.decision
            let createPlacementContext = existingEntry == nil
                ? controller.axEventHandler.pendingCreatePlacementContext(for: winId)
                : nil
            let placementOrigin: WorkspacePlacementOrigin = createPlacementContext == nil
                ? .discovery
                : .liveCreate
            let shouldPreservePreFullscreenState = existingEntry.map { existingEntry in
                !appFullscreen
                    && (
                        controller.workspaceManager.nativeFullscreenRecord(for: existingEntry.token) != nil
                            || existingEntry.layoutReason == .nativeFullscreen
                    )
            } ?? false
            let effectiveTrackedMode: TrackedWindowMode?
            if shouldPreservePreFullscreenState {
                effectiveTrackedMode = existingEntry?.mode
            } else {
                effectiveTrackedMode = controller.trackedModePreservingAutomaticFallbackState(
                    decision: decision,
                    existingEntry: existingEntry,
                    context: .automatic
                )
            }

            if yieldToDeferredCreate(
                token: token,
                bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                mode: effectiveTrackedMode,
                factsAreDeferred: decision.disposition == .undecided,
                facts: evaluation.facts,
                scope: scope,
                capturedWindowServerInfoByWindowId: enumerationSnapshot.windowServerInfoByWindowId,
                capturedWindowServerAuthoritativeWindowIds: enumerationSnapshot.exactWindowIds,
                capturedWindowServerAuthoritativePIDs: enumerationSnapshot.authoritativeTargetPIDs,
                entry: existingEntry,
                seenKeys: &seenKeys
            ) {
                continue
            }

            guard let trackedMode = effectiveTrackedMode else {
                if existingEntry != nil {
                    controller.axEventHandler.cancelTrackedTilingPromotionRetry(windowId: winId)
                    decisionBasedRemovals.append(existingEntry?.token ?? token)
                } else {
                    if decision.disposition == .undecided,
                       let windowId = UInt32(exactly: winId)
                    {
                        let reason: WindowAdmissionPendingReason = decision.deferredReason
                            == .windowServerEvidenceMissing ? .windowServerEvidenceMissing : .factsDeferred
                        _ = controller.axEventHandler.scheduleCandidateAdmissionRetry(
                            windowId: windowId,
                            pid: pid,
                            axRef: ax,
                            reason: reason,
                            placementOrigin: placementOrigin
                        )
                    } else {
                        controller.axEventHandler.discardCreatePlacementContext(for: winId)
                    }
                }
                continue
            }
            if trackedMode != .tiling {
                controller.axEventHandler.cancelTrackedTilingPromotionRetry(windowId: winId)
            }

            if controller.axEventHandler.deferAdmissionIfNeeded(
                evaluation: evaluation,
                axRef: ax,
                token: token,
                mode: trackedMode,
                existingEntry: existingEntry,
                placementOrigin: placementOrigin
            ) {
                if let existingEntry {
                    seenKeys.insert(existingEntry.token)
                }
                continue
            }

            let structuralMatch = existingEntry == nil
                ? controller.axEventHandler.structuralReplacementMatch(
                    token: token,
                    bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                    mode: trackedMode,
                    facts: evaluation.facts,
                    capturedWindowServerInfoByWindowId: enumerationSnapshot.windowServerInfoByWindowId,
                    capturedWindowServerAuthoritativeWindowIds: enumerationSnapshot.exactWindowIds,
                    capturedWindowServerAuthoritativePIDs: enumerationSnapshot.authoritativeTargetPIDs
                )
                : nil
            if existingEntry == nil,
               let windowId = UInt32(exactly: winId),
               let structuralMatch,
               controller.axEventHandler.rekeyStructuralManagedReplacement(
                   match: structuralMatch,
                   token: token,
                   windowId: windowId,
                   axRef: ax,
                   bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                   mode: trackedMode,
                   facts: evaluation.facts,
                   admissionHints: evaluation.decision.admissionHints,
                   sizeConstraints: candidate.enumeratedWindow.decisionEvidence.sizeConstraints
               )
            {
                restoreNativeFullscreenAfterStructuralReplacement(
                    from: structuralMatch.token,
                    to: token,
                    appFullscreen: appFullscreen
                )
                seenKeys.insert(token)
                seenKeys.insert(structuralMatch.token)
                affectedWorkspaceIds.insert(structuralMatch.workspaceId)
                continue
            }

            let defaultWorkspace = controller.resolvedWorkspaceId(
                for: evaluation,
                axRef: nil,
                existingEntry: existingEntry,
                fallbackWorkspaceId: focusedWorkspaceId,
                structuralReplacementWorkspaceId: structuralMatch?.workspaceId,
                placementMode: trackedMode,
                placementOrigin: placementOrigin,
                createPlacementContext: createPlacementContext,
                windowFrame: candidate.capturedFrame
            )
            let wsForWindow: WorkspaceDescriptor.ID
            let ruleEffects: ManagedWindowRuleEffects
            let admissionHints: ManagedWindowAdmissionHints
            if let existingEntry {
                if shouldPreservePreFullscreenState {
                    controller.workspaceManager.restoreNativeFullscreenRecord(for: existingEntry.token)
                    markNativeFullscreenRestoredForFrameApply(existingEntry.token)
                    let restoredEntry = controller.workspaceManager.entry(for: existingEntry.token) ?? existingEntry
                    wsForWindow = restoredEntry.workspaceId
                    ruleEffects = restoredEntry.ruleEffects
                    admissionHints = restoredEntry.admissionHints
                } else if appFullscreen {
                    _ = controller.workspaceManager.markNativeFullscreenSuspended(existingEntry.token)
                    let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
                    wsForWindow = existingAssignment ?? defaultWorkspace
                    ruleEffects = decision.ruleEffects
                    admissionHints = decision.admissionHints
                } else {
                    let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
                    wsForWindow = existingAssignment ?? defaultWorkspace
                    ruleEffects = decision.ruleEffects
                    admissionHints = decision.admissionHints
                }
            } else {
                let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
                wsForWindow = existingAssignment ?? defaultWorkspace
                ruleEffects = decision.ruleEffects
                admissionHints = decision.admissionHints
            }
            affectedWorkspaceIds.insert(wsForWindow)
            let refreshedEntry = existingEntry
                .flatMap { controller.workspaceManager.entry(for: $0.token) }
                ?? existingEntry
            let oldMode = refreshedEntry?.mode
            let admittedMode = oldMode ?? trackedMode
            let parentWindowId = if let windowServer = evaluation.facts.windowServer {
                windowServer.parentId == 0 ? nil : windowServer.parentId
            } else {
                refreshedEntry?.managedReplacementMetadata?.parentWindowId
            }
            let managedReplacementMetadata = ManagedReplacementMetadata(
                bundleId: evaluation.facts.ax.bundleId ?? bundleId ?? refreshedEntry?.managedReplacementMetadata?
                    .bundleId,
                workspaceId: wsForWindow,
                mode: admittedMode,
                role: evaluation.facts.ax.role ?? refreshedEntry?.managedReplacementMetadata?.role,
                subrole: evaluation.facts.ax.subrole ?? refreshedEntry?.managedReplacementMetadata?.subrole,
                title: evaluation.facts.ax.title ?? refreshedEntry?.managedReplacementMetadata?.title,
                windowLevel: evaluation.facts.windowServer?.level ?? refreshedEntry?.managedReplacementMetadata?
                    .windowLevel,
                parentWindowId: parentWindowId,
                frame: evaluation.facts.windowServer?.frame ?? refreshedEntry?.managedReplacementMetadata?.frame,
                transientWindowServerEvidence: refreshedEntry?.managedReplacementMetadata?
                    .transientWindowServerEvidence == true
                    || evaluation.facts.windowServer?.hasTransientSurfaceEvidence == true,
                degradedWindowServerChildEvidence: refreshedEntry?.managedReplacementMetadata?
                    .degradedWindowServerChildEvidence == true
                    || evaluation.facts.degradedWindowServerChildEvidence
            )

            let admittedToken: WindowToken
            if let refreshedEntry,
               !Self.shouldReadmitTrackedWindow(
                   entry: refreshedEntry,
                   workspaceId: wsForWindow,
                   mode: admittedMode,
                   ruleEffects: ruleEffects,
                   shouldPreservePreFullscreenState: shouldPreservePreFullscreenState,
                   appFullscreen: appFullscreen
               )
            {
                _ = controller.workspaceManager.setManagedReplacementMetadata(
                    managedReplacementMetadata,
                    for: refreshedEntry.token
                )
                admittedToken = refreshedEntry.token
            } else {
                admittedToken = controller.workspaceManager.addWindow(
                    ax,
                    pid: pid,
                    windowId: winId,
                    to: wsForWindow,
                    mode: admittedMode,
                    ruleEffects: ruleEffects,
                    admissionHints: admissionHints,
                    managedReplacementMetadata: managedReplacementMetadata
                )
            }
            guard admittedToken == token else {
                seenKeys.insert(admittedToken)
                if let admittedEntry = controller.workspaceManager.entry(for: admittedToken) {
                    affectedWorkspaceIds.insert(admittedEntry.workspaceId)
                }
                if let windowId = UInt32(exactly: winId) {
                    controller.axEventHandler.finishAdmissionRetryAfterTracking(
                        windowId: windowId
                    )
                }
                continue
            }
            controller.workspaceManager.setCachedConstraints(
                candidate.enumeratedWindow.decisionEvidence.sizeConstraints,
                for: admittedToken
            )
            let interactionPolicy = WindowInteractionPolicy.resolve(for: evaluation)
            controller.workspaceManager.setInteractionPolicy(interactionPolicy, for: admittedToken)
            if refreshedEntry != nil {
                _ = controller.workspaceManager.updateAdmissionHints(admissionHints, for: admittedToken)
            }
            let admittedEntry = controller.workspaceManager.entry(for: admittedToken)
            if let candidate = FullRescanFloatingFocusCandidate(
                token: admittedToken,
                workspaceId: admittedEntry?.workspaceId ?? wsForWindow,
                isNewAdmission: existingEntry == nil,
                mode: admittedEntry?.mode ?? admittedMode,
                interactionPolicy: interactionPolicy,
                createPlacementContext: createPlacementContext
            ) {
                floatingFocusCandidate = Self.newestFullRescanFloatingFocusCandidate(
                    floatingFocusCandidate,
                    considering: candidate
                )
            }
            if existingEntry == nil {
                controller.axEventHandler.discardCreatePlacementContext(for: winId)
            }
            if let windowId = UInt32(exactly: winId) {
                controller.axEventHandler.finishAdmissionRetryAfterTracking(
                    windowId: windowId
                )
            }

            if shouldPreservePreFullscreenState {
                seenKeys.insert(admittedToken)
                continue
            }

            if let oldMode, oldMode != trackedMode {
                _ = controller.transitionWindowMode(
                    for: admittedToken,
                    to: trackedMode,
                    preferredMonitor: controller.workspaceManager.monitor(for: wsForWindow),
                    applyFloatingFrame: false,
                    observedFrame: candidate.capturedFrame,
                    allowLiveFrameFallback: false
                )
            } else if trackedMode == .floating {
                controller.seedFloatingGeometryIfNeeded(
                    for: admittedToken,
                    preferredMonitor: controller.workspaceManager.monitor(for: wsForWindow),
                    observedFrame: candidate.capturedFrame,
                    allowLiveFrameFallback: false
                )
            }
            seenKeys.insert(admittedToken)
        }

        let focusValidationWorkspaceId = controller.hasStartedServices
            ? focusFullRescanFloatingCandidate(
                floatingFocusCandidate,
                fallbackWorkspaceId: focusedWorkspaceId
            )
            : focusedWorkspaceId

        controller.axEventHandler.updateIdentityAliases(
            enumerationSnapshot.identityAliasesByWindowId
        )

        for token in decisionBasedRemovals {
            guard let entry = controller.workspaceManager.entry(for: token) else { continue }
            controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(entry)
        }

        let shouldPreserveMissingWindows = hadNativeFullscreenLifecycleContextAtStart
            || controller.workspaceManager.hasNativeFullscreenLifecycleContext
        let trackedEntries = controller.workspaceManager.allEntries()
        let nativeFullscreenRetirementKeys = exactNativeFullscreenRetirementKeys(
            scope: scope,
            trackedEntries: trackedEntries
        )
        if shouldPreserveMissingWindows {
            for entry in trackedEntries where !nativeFullscreenRetirementKeys.contains(entry.token) {
                seenKeys.insert(.init(pid: entry.pid, windowId: entry.windowId))
            }
        } else {
            for entry in trackedEntries
                where controller.hiddenAppPIDs.contains(entry.pid)
                || controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp
                || (
                    controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen
                        && !nativeFullscreenRetirementKeys.contains(entry.token)
                )
            {
                seenKeys.insert(.init(pid: entry.pid, windowId: entry.windowId))
            }

            for entry in trackedEntries
                where enumerationSnapshot.failedPIDs.contains(entry.pid)
            {
                seenKeys.insert(.init(pid: entry.pid, windowId: entry.windowId))
            }

            preserveScratchpadHiddenWindowsDuringFullRescan(
                trackedEntries,
                windowServerInfoByWindowId: enumerationSnapshot.windowServerInfoByWindowId,
                seenKeys: &seenKeys
            )
        }

        preserveFocusedSheetDuringFullRescan(
            windowServerInfoByWindowId: enumerationSnapshot.windowServerInfoByWindowId,
            seenKeys: &seenKeys
        )

        let eligibleKeys: Set<WindowToken>? = switch scope {
        case .all:
            nil
        case let .targeted(appPIDs, _, nativeSpaceWindowIdsByPID):
            Set(
                trackedEntries.lazy
                    .filter {
                        enumerationSnapshot.authoritativeTargetPIDs.contains($0.pid)
                            && (
                                appPIDs.contains($0.pid)
                                    || nativeSpaceWindowIdsByPID[$0.pid]?.contains($0.windowId) == true
                            )
                    }
                    .map(\.token)
            )
        }
        if let eligibleKeys {
            for entry in trackedEntries
                where eligibleKeys.contains(entry.token)
                && enumerationSnapshot.windowServerInfoByWindowId[entry.windowId] != nil
            {
                seenKeys.insert(entry.token)
            }
        }
        let missingCandidateKeys = eligibleKeys ?? Set(trackedEntries.map(\.token))
        let admissionProtectedMissingKeys = permitsMissingRetirement
            ? controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: missingCandidateKeys.subtracting(seenKeys),
                scope: scope
            )
            : []
        let missingDetectionEligibleKeys = missingCandidateKeys
            .subtracting(admissionProtectedMissingKeys)
        let missingCandidates = if permitsMissingRetirement {
            Set(missingDetectionEligibleKeys.filter { token in
                guard !seenKeys.contains(token),
                      let entry = controller.workspaceManager.entry(for: token)
                else { return false }
                return (
                    entry.layoutReason != .nativeFullscreen
                        || nativeFullscreenRetirementKeys.contains(token)
                )
                    && !controller.workspaceManager.spaceTopology
                    .isWindowOnKnownInactiveSpace(entry.windowId)
            })
        } else {
            Set<WindowToken>()
        }
        let missingEntries = confirmedMissingEntriesDuringFullRescan(
            seenKeys: seenKeys,
            eligibleKeys: missingDetectionEligibleKeys,
            nativeFullscreenRetirementKeys: nativeFullscreenRetirementKeys,
            permitsMissingRetirement: permitsMissingRetirement
        )
        for entry in missingEntries {
            controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(entry)
        }
        let unresolvedMissingCandidates = missingCandidates
            .subtracting(missingEntries.map(\.token))
        if permitsMissingRetirement, !unresolvedMissingCandidates.isEmpty {
            scheduleMissingConfirmation(scope: scope)
        }
        if !shouldPreserveMissingWindows,
           scope == .all || !decisionBasedRemovals.isEmpty || !missingEntries.isEmpty
        {
            controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWorkspaceId)
        }

        let retainedEntries = controller.workspaceManager.allEntries()
        let scopedBindingPIDs: Set<pid_t>? = switch scope {
        case .all:
            nil
        case let .targeted(appPIDs, _, _):
            Set(
                enumerationSnapshot.successfullyEnumeratedPIDs
                    .union(
                        controller.axManager.pendingManagedWindowBindingRetryPIDs(
                            intersecting: appPIDs
                        )
                    )
                    .filter { pid in
                        AppAXContext.contexts[pid] != nil
                            || retainedEntries.contains { $0.pid == pid }
                    }
            )
        }
        controller.axManager.reconcileManagedWindowBindings(
            retainedEntries,
            scopedPIDs: scopedBindingPIDs
        )
        controller.axEventHandler.pruneIdentityAliases(
            retainingWindowIds: Set(retainedEntries.map(\.windowId))
                .union(controller.axEventHandler.activeAdmissionRetryWindowIds)
                .union(controller.axEventHandler.admissionQuarantineByWindowId.keys)
        )

        try Task.checkCancellation()

        let niriRemovalSeeds = makeNiriRemovalSeeds(from: removalPayloads)
        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let scanLayoutWorkspaceIds = switch scope {
        case .all:
            activeWorkspaceIds.union(removalPayloads.map(\.workspaceId))
        case .targeted:
            activeWorkspaceIds.intersection(affectedWorkspaceIds)
                .union(removalPayloads.map(\.workspaceId))
        }
        let explicitRelayoutWorkspaceIds = if let relayoutWorkspaceIds {
            relayoutWorkspaceIds.isEmpty
                ? activeWorkspaceIds
                : liveLayoutWorkspaceIds(relayoutWorkspaceIds, controller: controller)
        } else {
            Set<WorkspaceDescriptor.ID>()
        }
        let layoutWorkspaceIds = scanLayoutWorkspaceIds.union(explicitRelayoutWorkspaceIds)
        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(layoutWorkspaceIds)

        let workspacePlans = buildWorkspacePlansInBatch {
            var plans: [WorkspaceLayoutPlan] = []
            plans.reserveCapacity(niriWorkspaces.count + dwindleWorkspaces.count)
            if !niriWorkspaces.isEmpty {
                plans.append(contentsOf: self.niriHandler.layoutWithNiriEngine(
                    activeWorkspaces: niriWorkspaces,
                    useScrollAnimationPath: false,
                    removalSeeds: niriRemovalSeeds
                ))
            }
            if !dwindleWorkspaces.isEmpty {
                plans.append(
                    contentsOf: self.dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
                )
            }
            return plans
        }

        var effects = EffectPlanEffects()
        effects.visibility = .init()

        if !controller.workspaceManager.isAppFullscreenActive,
           !controller.workspaceManager.hasPendingNativeFullscreenTransition,
           !controller.shouldSuppressManagedFocusRecovery,
           let focusValidationWorkspaceId
        {
            effects.focusValidationWorkspaceIds = [focusValidationWorkspaceId]
        }
        effects.markInitialRefreshComplete = true
        effects.drainDeferredCreatedWindows = true
        effects.subscribeManagedWindows = true

        if postLayoutActions.isEmpty {
            return EffectPlan(workspacePlans: workspacePlans, effects: effects)
        }
        let acceptedSeqs = Dictionary(
            uniqueKeysWithValues: layoutWorkspaceIds.map {
                (
                    $0,
                    AcceptedSeq(
                        after: controller.workspaceManager.worldSeq,
                        domains: .layoutCommit.union(.focusCommit)
                    )
                )
            }
        )
        let forwardedPostLayoutActions = zip(
            postLayoutActions,
            postLayoutActionWorkspacesCurrentAtMutation
        ).map { action, currentAtMutation in
            action.forwarded(
                by: acceptedSeqs,
                currentAtEntry: currentAtMutation
            )
        }
        return EffectPlan(
            workspacePlans: workspacePlans,
            effects: effects,
            postLayoutActions: forwardedPostLayoutActions
        )
    }

    private enum ScratchpadRescanEvidence {
        case visibleFrame
        case windowServer
        case pinnedAX
    }

    private struct ScratchpadRescanObservation {
        let evidence: ScratchpadRescanEvidence
        let visibleFrame: CGRect?
    }

    func preserveScratchpadHiddenWindowsDuringFullRescan(
        _ entries: [WindowState],
        windowServerInfoByWindowId: [Int: WindowServerInfo],
        seenKeys: inout Set<WindowToken>,
        hasPinnedAXElement: (UInt32) -> Bool = { AXWindowService.hasPinnedAXElement(for: $0) }
    ) {
        guard let controller else { return }
        for entry in entries where controller.workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true {
            let observation = scratchpadRescanObservation(
                for: entry,
                windowServerInfo: windowServerInfoByWindowId[entry.windowId],
                hasPinnedAXElement: hasPinnedAXElement
            )
            switch observation?.evidence {
            case .visibleFrame:
                if pendingRevealTransactionsByWindowId[entry.windowId]?.token == entry.token,
                   let visibleFrame = observation?.visibleFrame
                {
                    finalizePendingRevealTransactionSuccess(
                        forWindowId: entry.windowId,
                        confirmedFrame: visibleFrame
                    )
                } else {
                    cancelPendingScratchpadReveal(for: entry.token)
                    if controller.axManager.pendingParkWindowIds.contains(entry.windowId),
                       let visibleFrame = observation?.visibleFrame
                    {
                        applyPositionPlans([
                            WindowPositionPlan(entry: entry, frame: visibleFrame)
                        ])
                    }
                    controller.workspaceManager.setHiddenState(nil, for: entry.token)
                    controller.axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
                }
                seenKeys.insert(entry.token)
            case .windowServer,
                 .pinnedAX:
                seenKeys.insert(entry.token)
            case nil:
                break
            }
        }
    }

    private func scratchpadRescanObservation(
        for entry: WindowState,
        windowServerInfo: WindowServerInfo?,
        hasPinnedAXElement: (UInt32) -> Bool
    ) -> ScratchpadRescanObservation? {
        guard controller != nil else { return nil }
        guard let windowId = UInt32(exactly: entry.windowId) else { return nil }

        if let windowInfo = windowServerInfo {
            guard windowInfo.pid == entry.pid else { return nil }
            if let visibleFrame = scratchpadVisibleWindowServerFrame(windowInfo.frame, for: entry) {
                return ScratchpadRescanObservation(evidence: .visibleFrame, visibleFrame: visibleFrame)
            }
            return ScratchpadRescanObservation(evidence: .windowServer, visibleFrame: nil)
        }

        if hasPinnedAXElement(windowId) {
            return ScratchpadRescanObservation(evidence: .pinnedAX, visibleFrame: nil)
        }

        return nil
    }

    private func scratchpadVisibleWindowServerFrame(_ frame: CGRect, for entry: WindowState) -> CGRect? {
        if scratchpadFrameIsVisible(frame, for: entry) {
            return frame
        }
        let appKitFrame = ScreenCoordinateSpace.toAppKit(rect: frame)
        return scratchpadFrameIsVisible(appKitFrame, for: entry) ? appKitFrame : nil
    }

    private func scratchpadFrameIsVisible(_ frame: CGRect, for entry: WindowState) -> Bool {
        guard let controller else { return false }
        if let floatingFrame = controller.workspaceManager.floatingState(for: entry.token)?.lastFrame,
           frame.approximatelyEqual(to: floatingFrame, tolerance: FrameTolerance.screenMatch)
        {
            return true
        }
        return controller.workspaceManager.monitors.contains { monitor in
            frame.intersects(monitor.visibleFrame)
                && monitor.visibleFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private func partitionWorkspacesByLayoutType(
        _ workspaces: Set<WorkspaceDescriptor.ID>
    ) -> (niri: Set<WorkspaceDescriptor.ID>, dwindle: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return ([], []) }

        var niriWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for wsId in workspaces {
            guard let ws = controller.workspaceManager.descriptor(for: wsId) else {
                continue
            }
            let layoutType = controller.settings.layoutType(for: ws.name)
            switch layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(wsId)
            case .niri,
                 .defaultLayout:
                niriWorkspaces.insert(wsId)
            }
        }

        return (niriWorkspaces, dwindleWorkspaces)
    }

    private func liveLayoutWorkspaceIds(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>,
        controller: WMController
    ) -> Set<WorkspaceDescriptor.ID> {
        var liveWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        liveWorkspaceIds.reserveCapacity(workspaceIds.count)
        for workspaceId in workspaceIds
            where controller.workspaceManager.descriptor(for: workspaceId) != nil
            && controller.workspaceManager.monitor(for: workspaceId) != nil
        {
            liveWorkspaceIds.insert(workspaceId)
        }
        return liveWorkspaceIds
    }

    func currentActiveWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        guard let controller else { return [] }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }
        return activeWorkspaceIds
    }

    func enqueueRefresh(_ refresh: ScheduledRefresh) {
        if layoutState.inventoryStabilityHoldFullRescans,
           refresh.kind == .fullRescan
        {
            holdInventoryStabilityFullRescan(refresh, isNewerThanHeld: true)
            return
        }
        if let activeRefresh = layoutState.activeRefresh {
            handleRefresh(refresh, whileActive: activeRefresh)
            return
        }

        mergePendingRefresh(refresh)
        startNextRefreshIfNeeded()
    }

    func mergePendingRefresh(_ refresh: ScheduledRefresh) {
        guard var pendingRefresh = layoutState.pendingRefresh else {
            layoutState.pendingRefresh = refresh
            return
        }

        var relayoutWorkspaceScope = mergedRelayoutWorkspaceScope(
            scheduledRelayoutWorkspaceScope(pendingRefresh),
            scheduledRelayoutWorkspaceScope(refresh)
        )
        let existingAffectedWorkspaceIds = pendingRefresh.affectedWorkspaceIds
        let existingAdditionalAffectedWorkspaceIds =
            pendingRefresh.additionalAffectedWorkspaceIds
        let windowRemovalPayloads = mergeWindowRemovalPayloads(
            pendingRefresh.windowRemovalPayloads,
            with: refresh.windowRemovalPayloads
        )
        var workspaceMonitorRelocations = mergedWorkspaceMonitorRelocations(
            pendingRefresh.workspaceMonitorRelocations,
            refresh.workspaceMonitorRelocations
        )
        var reconcilesWorkspaceMonitorState = pendingRefresh.reconcilesWorkspaceMonitorState
            || refresh.reconcilesWorkspaceMonitorState
        let suppressesWindowActivation = pendingRefresh.suppressesWindowActivation
            || refresh.suppressesWindowActivation
        let existingWorkspaceMonitorRelocations = pendingRefresh.workspaceMonitorRelocations
        let existingReconcilesWorkspaceMonitorState =
            pendingRefresh.reconcilesWorkspaceMonitorState
        var routedRelayoutMetadataToFollowUp = false

        switch (pendingRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.rescanScope = pendingRefresh.rescanScope.merged(with: refresh.rescanScope)
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFullRescanFollowUp(into: &pendingRefresh, from: refresh)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.fullRescan, .immediateRelayout),
             (.fullRescan, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            routedRelayoutMetadataToFollowUp = mergeRelayoutIntoFullRescan(
                refresh,
                fullRescan: &pendingRefresh
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.fullRescan, .visibilityRefresh),
             (.fullRescan, .windowRemoval):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.visibilityRefresh, .visibilityRefresh):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        case (.windowRemoval, .fullRescan),
             (.immediateRelayout, .fullRescan),
             (.relayout, .fullRescan):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.insert(
                contentsOf: pendingRefresh.postLayoutActions,
                at: 0
            )
            mergeFullRescanFollowUp(
                into: &upgradedRefresh,
                from: pendingRefresh,
                absorbedPrecedesExistingFollowUp: true
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case (.windowRemoval, .windowRemoval):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .immediateRelayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .immediateRelayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds,
                additionalAffectedWorkspaceIds:
                refresh.additionalAffectedWorkspaceIds,
                workspaceMonitorRelocations: refresh.workspaceMonitorRelocations,
                reconcilesWorkspaceMonitorState: refresh.reconcilesWorkspaceMonitorState,
                suppressesWindowActivation: refresh.suppressesWindowActivation
            )
            workspaceMonitorRelocations = pendingRefresh.workspaceMonitorRelocations
            reconcilesWorkspaceMonitorState =
                pendingRefresh.reconcilesWorkspaceMonitorState
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .relayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds,
                additionalAffectedWorkspaceIds:
                refresh.additionalAffectedWorkspaceIds,
                workspaceMonitorRelocations: refresh.workspaceMonitorRelocations,
                reconcilesWorkspaceMonitorState: refresh.reconcilesWorkspaceMonitorState,
                suppressesWindowActivation: refresh.suppressesWindowActivation
            )
            workspaceMonitorRelocations = pendingRefresh.workspaceMonitorRelocations
            reconcilesWorkspaceMonitorState =
                pendingRefresh.reconcilesWorkspaceMonitorState
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.windowRemoval, .visibilityRefresh):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeDeferredLayout(
                into: &upgradedRefresh,
                from: pendingRefresh
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
            workspaceMonitorRelocations = refresh.workspaceMonitorRelocations
            reconcilesWorkspaceMonitorState =
                refresh.reconcilesWorkspaceMonitorState
        case (.relayout, .windowRemoval):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            mergeDeferredLayout(
                into: &upgradedRefresh,
                from: pendingRefresh
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
            workspaceMonitorRelocations = refresh.workspaceMonitorRelocations
            reconcilesWorkspaceMonitorState =
                refresh.reconcilesWorkspaceMonitorState
        case (.immediateRelayout, .visibilityRefresh),
             (.relayout, .visibilityRefresh):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .immediateRelayout),
             (.relayout, .relayout):
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.immediateRelayout, .relayout):
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            mergeFollowUp(
                into: &pendingRefresh,
                kind: .relayout,
                reason: refresh.reason,
                affectedWorkspaceIds: refresh.affectedWorkspaceIds,
                additionalAffectedWorkspaceIds:
                refresh.additionalAffectedWorkspaceIds,
                reconcilesWorkspaceMonitorState: refresh.reconcilesWorkspaceMonitorState,
                suppressesWindowActivation: refresh.suppressesWindowActivation
            )
            mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case (.relayout, .immediateRelayout):
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            upgradedRefresh.followUpRefresh = mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            mergeFollowUp(
                into: &upgradedRefresh,
                kind: .relayout,
                reason: pendingRefresh.reason,
                affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds,
                additionalAffectedWorkspaceIds:
                pendingRefresh.additionalAffectedWorkspaceIds,
                reconcilesWorkspaceMonitorState: pendingRefresh.reconcilesWorkspaceMonitorState,
                suppressesWindowActivation: pendingRefresh.suppressesWindowActivation
            )
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        }

        if routedRelayoutMetadataToFollowUp {
            relayoutWorkspaceScope =
                scheduledRelayoutWorkspaceScope(pendingRefresh)
        }
        let resolvedRelayoutWorkspaceScope = pendingRefresh.kind == .fullRescan
            ? mergedRelayoutWorkspaceScope(
                relayoutWorkspaceScope,
                scheduledRelayoutWorkspaceScope(pendingRefresh)
            )
            : nil
        if let resolvedRelayoutWorkspaceScope {
            pendingRefresh.subsumesRelayout = true
            pendingRefresh.affectedWorkspaceIds =
                resolvedRelayoutWorkspaceScope.affectedWorkspaceIds
            pendingRefresh.additionalAffectedWorkspaceIds =
                resolvedRelayoutWorkspaceScope.additionalAffectedWorkspaceIds
        } else {
            var mergedScope = mergedWorkspaceRefreshScope(
                WorkspaceRefreshScope(
                    affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds,
                    additionalAffectedWorkspaceIds:
                    pendingRefresh.additionalAffectedWorkspaceIds
                ),
                WorkspaceRefreshScope(
                    affectedWorkspaceIds: existingAffectedWorkspaceIds,
                    additionalAffectedWorkspaceIds:
                    existingAdditionalAffectedWorkspaceIds
                )
            )
            mergedScope = mergedWorkspaceRefreshScope(
                mergedScope,
                WorkspaceRefreshScope(
                    affectedWorkspaceIds: refresh.affectedWorkspaceIds,
                    additionalAffectedWorkspaceIds:
                    refresh.additionalAffectedWorkspaceIds
                )
            )
            pendingRefresh.affectedWorkspaceIds = mergedScope.affectedWorkspaceIds
            pendingRefresh.additionalAffectedWorkspaceIds =
                mergedScope.additionalAffectedWorkspaceIds
        }
        pendingRefresh.windowRemovalPayloads = windowRemovalPayloads
        pendingRefresh.workspaceMonitorRelocations = mergedWorkspaceMonitorRelocations(
            pendingRefresh.workspaceMonitorRelocations,
            workspaceMonitorRelocations
        )
        pendingRefresh.reconcilesWorkspaceMonitorState =
            pendingRefresh.reconcilesWorkspaceMonitorState
                || reconcilesWorkspaceMonitorState
        pendingRefresh.suppressesWindowActivation =
            pendingRefresh.suppressesWindowActivation
                || suppressesWindowActivation
        if routedRelayoutMetadataToFollowUp {
            pendingRefresh.workspaceMonitorRelocations =
                existingWorkspaceMonitorRelocations
            pendingRefresh.reconcilesWorkspaceMonitorState =
                existingReconcilesWorkspaceMonitorState
        }

        layoutState.pendingRefresh = pendingRefresh
    }

    func startNextRefreshIfNeeded() {
        guard layoutState.activeRefreshTask == nil, let refresh = layoutState.pendingRefresh else { return }
        guard !layoutState.inventoryStabilityHoldFullRescans || refresh.kind != .fullRescan else { return }

        layoutState.pendingRefresh = nil
        layoutState.activeRefresh = refresh
        layoutState.didExecuteEffectPlan = false
        let refreshGeneration = layoutState.refreshGeneration
        layoutState.activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didComplete = await self.execute(refresh, generation: refreshGeneration)
            self.finishRefresh(refresh, didComplete: didComplete, generation: refreshGeneration)
        }
    }

    private func isCurrentRefreshGeneration(_ generation: UInt64) -> Bool {
        generation == layoutState.refreshGeneration
    }

    private func execute(_ refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard isCurrentRefreshGeneration(generation) else { return false }
        do {
            switch refresh.kind {
            case .fullRescan:
                return try await executeFullRefresh(refresh: refresh, generation: generation)
            case .relayout:
                return await executeScheduledRelayout(refresh: refresh, generation: generation)
            case .immediateRelayout:
                return await executeImmediateRelayout(refresh: refresh, generation: generation)
            case .visibilityRefresh:
                return await executeVisibilityRefresh(refresh: refresh, generation: generation)
            case .windowRemoval:
                return await executeWindowRemoval(refresh: refresh, generation: generation)
            }
        } catch {
            return false
        }
    }

    private func finishRefresh(_ refresh: ScheduledRefresh, didComplete: Bool, generation: UInt64) {
        guard generation == layoutState.refreshGeneration else { return }
        let completedRefresh = layoutState.activeRefresh ?? refresh
        let didExecuteEffectPlan = layoutState.didExecuteEffectPlan

        if !didComplete {
            preserveCancelledRefreshState(completedRefresh)
        }

        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.didExecuteEffectPlan = false

        if didComplete {
            layoutBuildMetrics.recordCompletedCycle()
            if !didExecuteEffectPlan, let controller {
                let shouldRequestWorkspaceBarRefresh =
                    completedRefresh.kind != .visibilityRefresh && completedRefresh.needsVisibilityReconciliation

                for postLayoutAction in completedRefresh.postLayoutActions {
                    postLayoutAction.runIfCurrent(using: controller.workspaceManager)
                }
                if shouldRequestWorkspaceBarRefresh {
                    controller.requestWorkspaceBarRefresh()
                }
            }
            if let followUpRefresh = completedRefresh.followUpRefresh {
                let affectedWorkspaceIds = resolvedFollowUpWorkspaceIds(
                    followUpRefresh
                )
                let refresh = ScheduledRefresh(
                    kind: followUpRefresh.kind,
                    reason: followUpRefresh.reason,
                    affectedWorkspaceIds: affectedWorkspaceIds,
                    workspaceMonitorRelocations: Array(
                        followUpRefresh.workspaceMonitorRelocations.values
                    ),
                    reconcilesWorkspaceMonitorState: followUpRefresh.reconcilesWorkspaceMonitorState,
                    suppressesWindowActivation: completedRefresh.suppressesWindowActivation
                        || followUpRefresh.suppressesWindowActivation
                )
                let newerPendingRefresh = layoutState.pendingRefresh
                layoutState.pendingRefresh = refresh
                if let newerPendingRefresh {
                    mergePendingRefresh(newerPendingRefresh)
                }
            }
        }

        startNextRefreshIfNeeded()
    }

    func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
    }

    private func workspaceEntriesSnapshot(
        on controller: WMController
    ) -> [(workspace: WorkspaceDescriptor, entries: [WindowState])] {
        controller.workspaceManager.workspaces.map { workspace in
            (workspace, controller.workspaceManager.entries(in: workspace.id))
        }
    }

    private func rebuildInactiveWorkspaceWindowSet(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        for workspace in controller.workspaceManager.workspaces {
            for entry in controller.workspaceManager.entries(in: workspace.id) {
                allEntries.append((workspace.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds,
            nativeInactiveWindowIds: nativeInactiveWindowIds()
        )
    }

    private func nativeInactiveWindowIds() -> Set<Int> {
        guard let controller else { return [] }
        let topology = controller.workspaceManager.spaceTopology
        guard topology.isPopulated else { return [] }
        var result: Set<Int> = []
        for entry in controller.workspaceManager.allEntries()
            where topology.isWindowOnKnownInactiveSpace(entry.windowId)
        {
            result.insert(entry.windowId)
        }
        return result
    }

    private func isWindowOnKnownInactiveNativeSpace(_ windowId: Int) -> Bool {
        controller?.workspaceManager.spaceTopology.isWindowOnKnownInactiveSpace(windowId) ?? false
    }

    func hasWorkspaceInactiveFloatingWindows(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) -> Bool {
        guard let controller else { return false }
        for workspaceId in activeWorkspaceIds {
            guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { continue }
            for entry in controller.workspaceManager.floatingEntries(in: workspaceId)
                where workspaceInactiveFloatingRestoreFrame(for: entry, monitor: monitor) != nil
            {
                return true
            }
        }
        return false
    }

    @discardableResult
    func restoreWorkspaceInactiveFloatingWindows(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) -> Int {
        guard let controller else { return 0 }
        var frameUpdates: [AXFrameApplicationTarget] = []
        var visibleJobs: [(pid: pid_t, windowId: Int)] = []

        for workspaceId in activeWorkspaceIds {
            guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { continue }
            for entry in controller.workspaceManager.floatingEntries(in: workspaceId) {
                guard let frame = workspaceInactiveFloatingRestoreFrame(for: entry, monitor: monitor) else { continue }
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
                visibleJobs.append((entry.pid, entry.windowId))
                controller.axManager.markWindowActive(entry.windowId)
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
                frameUpdates.append(.init(pid: entry.pid, window: entry.axRef, frame: frame))
            }
        }

        if !visibleJobs.isEmpty {
            controller.axManager.unsuppressFrameWrites(visibleJobs)
        }
        controller.axManager.applyFramesParallel(frameUpdates)
        return frameUpdates.count
    }

    private func workspaceInactiveFloatingRestoreFrame(
        for entry: WindowState,
        monitor: Monitor
    ) -> CGRect? {
        guard let controller else { return nil }
        guard !isWindowOnKnownInactiveNativeSpace(entry.windowId) else { return nil }
        guard entry.mode == .floating,
              entry.layoutReason == .standard,
              controller.workspaceManager.hiddenState(for: entry.token)?.workspaceInactive == true
        else {
            return nil
        }
        return controller.workspaceManager.resolvedFloatingFrame(for: entry.token, preferredMonitor: monitor)
    }

    func hideInactiveWorkspaces(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }
        let workspaceEntries = workspaceEntriesSnapshot(on: controller)

        // Rebuild the workspace-level frame suppression set (live check in applyFramesParallel).
        // Note: this is also called earlier in executeEffectPlan to unblock frame
        // writes for newly-active workspaces. The rebuild here keeps the set consistent with
        // the snapshot used for the hide pass below.
        var allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)] = []
        allEntries.reserveCapacity(workspaceEntries.reduce(into: 0) { $0 += $1.entries.count })
        for snapshot in workspaceEntries {
            for entry in snapshot.entries {
                allEntries.append((snapshot.workspace.id, entry.windowId))
            }
        }
        controller.axManager.updateInactiveWorkspaceWindows(
            allEntries: allEntries,
            activeWorkspaceIds: activeWorkspaceIds,
            nativeInactiveWindowIds: nativeInactiveWindowIds()
        )

        // Bulk cancel in-flight frame jobs for all inactive workspace windows upfront,
        // before the per-window hide loop, to prevent AX batch races with SkyLight moves.
        var inactiveWindowJobs: [(pid: pid_t, windowId: Int)] = []
        let hiddenPlacementMonitors = controller.workspaceManager.monitors.map(HiddenPlacementMonitorContext.init)
        for snapshot in workspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
            for entry in snapshot.entries {
                inactiveWindowJobs.append((entry.pid, entry.windowId))
            }
        }
        if !inactiveWindowJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(inactiveWindowJobs)
        }

        let preferredSides = preferredHideSides(for: controller.workspaceManager.monitors)
        for snapshot in workspaceEntries where !activeWorkspaceIds.contains(snapshot.workspace.id) {
            guard let monitor = controller.workspaceManager.monitor(for: snapshot.workspace.id) else { continue }
            let preferredSide = preferredSides[monitor.id] ?? .right
            hideWorkspace(
                snapshot.entries,
                monitor: monitor,
                preferredSide: preferredSide,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
        }
    }

    func unhideWorkspace(_ workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        let entries = controller.workspaceManager.entries(in: workspaceId)
        for entry in entries {
            if isWindowOnKnownInactiveNativeSpace(entry.windowId) {
                continue
            }
            controller.axManager.markWindowActive(entry.windowId)
            unhideWindow(entry, monitor: monitor)
        }
    }

    private func hideWorkspace(
        _ entries: [WindowState],
        monitor: Monitor,
        preferredSide: HideSide,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) {
        guard let controller else { return }
        for entry in entries {
            guard controller.workspaceManager.layoutReason(for: entry.token) != .nativeFullscreen else {
                continue
            }
            controller.axManager.markWindowInactive(entry.windowId)
            if isWindowOnKnownInactiveNativeSpace(entry.windowId) {
                continue
            }
            hideWindow(
                entry,
                monitor: monitor,
                side: preferredSide,
                reason: .workspaceInactive,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
        }
    }

    struct WindowPositionPlan {
        let entry: WindowState
        let frame: CGRect
    }

    fileprivate enum HideOperationResolution {
        case movable(WindowPositionPlan, hiddenState: HiddenState)
        case alreadyHidden(WindowPositionPlan, hiddenState: HiddenState)
        case unavailable
    }

    fileprivate func resolveHideOperation(
        for entry: WindowState,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil,
        animationTick: Bool = false,
        preserveWorkspaceInactive: Bool = true
    ) -> HideOperationResolution {
        guard let controller, entry.interactionPolicy.mayPark else { return .unavailable }
        var resolvedFrame = fastFrame(for: entry.token, axRef: entry.axRef)
            ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
        if resolvedFrame == nil, !animationTick {
            resolvedFrame = try? AXWindowService.frame(entry.axRef)
        }
        guard var frame = resolvedFrame else {
            return .unavailable
        }
        if animationTick, let liveOrigin = controller.axManager.skyLightLivePosition(for: entry.windowId) {
            frame.origin = liveOrigin
        }
        let hiddenState = updatedHiddenState(
            for: entry,
            frame: frame,
            monitor: monitor,
            side: side,
            reason: reason,
            preserveWorkspaceInactive: preserveWorkspaceInactive
        )

        guard let origin = liveFrameHideOrigin(
            for: frame,
            monitor: monitor,
            side: side,
            pid: entry.pid,
            reason: reason,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) else {
            return .unavailable
        }

        let moveEpsilon: CGFloat = 0.01
        if abs(frame.origin.x - origin.x) < moveEpsilon,
           abs(frame.origin.y - origin.y) < moveEpsilon
        {
            return .alreadyHidden(
                WindowPositionPlan(
                    entry: entry,
                    frame: CGRect(origin: origin, size: frame.size)
                ),
                hiddenState: hiddenState
            )
        }

        // A corner park settles above the origin it asked for, and re-issuing an origin macOS will
        // never grant leaves a park write that can never verify.
        if isSettledCornerPark(for: entry, frame: frame, target: origin, monitor: monitor, reason: reason) {
            return .alreadyHidden(WindowPositionPlan(entry: entry, frame: frame), hiddenState: hiddenState)
        }

        return .movable(
            WindowPositionPlan(
                entry: entry,
                frame: CGRect(origin: origin, size: frame.size)
            ),
            hiddenState: hiddenState
        )
    }

    private func updatedHiddenState(
        for entry: WindowState,
        frame: CGRect,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        preserveWorkspaceInactive: Bool
    ) -> HiddenState {
        guard let controller else {
            return HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: hiddenWindowReason(
                    for: reason,
                    side: side,
                    existingState: nil,
                    preserveWorkspaceInactive: preserveWorkspaceInactive
                )
            )
        }

        let existingState = controller.workspaceManager.hiddenState(for: entry.token)
        let proportionalPosition: CGPoint
        let referenceMonitorId: Monitor.ID?

        if let existingState {
            proportionalPosition = existingState.proportionalPosition
            referenceMonitorId = existingState.referenceMonitorId
        } else {
            let center = frame.center
            let referenceMonitor = center.monitorApproximation(in: controller.workspaceManager.monitors) ?? monitor
            proportionalPosition = self.proportionalPosition(topLeft: frame.topLeftCorner, in: referenceMonitor.frame)
            referenceMonitorId = referenceMonitor.id
        }

        return HiddenState(
            proportionalPosition: proportionalPosition,
            referenceMonitorId: referenceMonitorId,
            reason: hiddenWindowReason(
                for: reason,
                side: side,
                existingState: existingState,
                preserveWorkspaceInactive: preserveWorkspaceInactive
            )
        )
    }

    private func hiddenWindowReason(
        for reason: HideReason,
        side: HideSide,
        existingState: HiddenState?,
        preserveWorkspaceInactive: Bool
    ) -> HiddenReason {
        if existingState?.isScratchpad == true, reason != .scratchpad {
            return .scratchpad
        }

        if preserveWorkspaceInactive,
           existingState?.workspaceInactive == true,
           reason == .layoutTransient
        {
            return .workspaceInactive
        }

        switch reason {
        case .workspaceInactive:
            return .workspaceInactive
        case .layoutTransient:
            return .layoutTransient(side)
        case .scratchpad:
            return .scratchpad
        }
    }

    func hideWindow(
        _ entry: WindowState,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) {
        guard let controller else { return }
        let frameEntry = (pid: entry.pid, windowId: entry.windowId)
        switch resolveHideOperation(
            for: entry,
            monitor: monitor,
            side: side,
            reason: reason,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) {
        case let .movable(plan, hiddenState):
            controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
            controller.axManager.cancelPendingFrameJobs([frameEntry])
            controller.axManager.suppressFrameWrites([frameEntry])
            applyParkPositionPlans([plan], movablePlans: [plan], animationTick: false)
        case let .alreadyHidden(plan, hiddenState):
            controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
            controller.axManager.cancelPendingFrameJobs([frameEntry])
            controller.axManager.suppressFrameWrites([frameEntry])
            applyParkPositionPlans([plan], movablePlans: [], animationTick: false)
        case .unavailable:
            controller.axManager.cancelPendingFrameJobs([frameEntry])
            controller.axManager.suppressFrameWrites([frameEntry])
        }
    }

    func applyLayoutTransientHides(
        _ hiddenEntries: [(entry: WindowState, side: HideSide)],
        monitor: Monitor,
        isAnimationTick: Bool,
        preserveWorkspaceInactive: Bool
    ) {
        guard !hiddenEntries.isEmpty, let controller else { return }
        var hiddenJobs: [(pid: pid_t, windowId: Int)] = []
        hiddenJobs.reserveCapacity(hiddenEntries.count)
        var parkPlans: [WindowPositionPlan] = []
        parkPlans.reserveCapacity(hiddenEntries.count)
        var movableParkPlans: [WindowPositionPlan] = []
        movableParkPlans.reserveCapacity(hiddenEntries.count)
        let hiddenPlacementMonitors = controller.workspaceManager.monitors.map(
            HiddenPlacementMonitorContext.init
        )

        for (entry, side) in hiddenEntries {
            switch resolveHideOperation(
                for: entry,
                monitor: monitor,
                side: side,
                reason: .layoutTransient,
                hiddenPlacementMonitors: hiddenPlacementMonitors,
                animationTick: isAnimationTick,
                preserveWorkspaceInactive: preserveWorkspaceInactive
            ) {
            case let .movable(movePlan, hiddenState):
                controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
                hiddenJobs.append((entry.pid, entry.windowId))
                parkPlans.append(movePlan)
                movableParkPlans.append(movePlan)
            case let .alreadyHidden(plan, hiddenState):
                controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
                hiddenJobs.append((entry.pid, entry.windowId))
                parkPlans.append(plan)
            case .unavailable:
                hiddenJobs.append((entry.pid, entry.windowId))
            }
        }

        if !hiddenJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(hiddenJobs)
            controller.axManager.suppressFrameWrites(hiddenJobs)
        }
        if !parkPlans.isEmpty {
            applyParkPositionPlans(
                parkPlans,
                movablePlans: movableParkPlans,
                animationTick: isAnimationTick
            )
        }
    }

    func liveFrameHideOrigin(
        for frame: CGRect,
        monitor: Monitor,
        side: HideSide,
        pid: pid_t,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) -> CGPoint? {
        guard let controller else { return nil }
        let scale = backingScale(for: monitor)
        let baseReveal = Self.hiddenEdgeReveal(isZoomApp: isZoomApp(pid))
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let resolvedHiddenPlacementMonitors = hiddenPlacementMonitors
            ?? controller.workspaceManager.monitors.map(HiddenPlacementMonitorContext.init)

        switch reason {
        case .workspaceInactive,
             .scratchpad:
            return HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
                for: frame.size,
                requestedSide: side,
                targetY: frame.origin.y,
                baseReveal: baseReveal,
                scale: scale,
                monitor: hiddenPlacementMonitor,
                monitors: resolvedHiddenPlacementMonitors
            )
        case .layoutTransient:
            let orientation = controller.settings.effectiveOrientation(for: monitor)
            let orthogonalOrigin: CGFloat = switch orientation {
            case .horizontal: frame.origin.y
            case .vertical: frame.origin.x
            }
            let requestedEdge = AxisHideEdge(encodedHideSide: side)
            let placement = HiddenWindowPlacementResolver.placement(
                for: frame.size,
                requestedEdge: requestedEdge,
                orthogonalOrigin: orthogonalOrigin,
                baseReveal: baseReveal,
                scale: scale,
                orientation: orientation,
                monitor: hiddenPlacementMonitor,
                monitors: resolvedHiddenPlacementMonitors
            )
            return placement.origin
        }
    }

    @discardableResult
    func unhideWindow(
        _ entry: WindowState,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) -> Bool {
        guard let controller else { return false }
        guard let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) else {
            if controller.axManager.pendingParkWindowIds.contains(entry.windowId),
               let frame = fastFrame(for: entry.token, axRef: entry.axRef)
               ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
            {
                applyPositionPlans([WindowPositionPlan(entry: entry, frame: frame)])
            } else {
                controller.axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
            }
            return true
        }
        guard hiddenState.workspaceInactive else { return false }

        return executeHiddenReveal(
            entry,
            monitor: monitor,
            hiddenState: hiddenState,
            onSuccess: onSuccess
        )
    }

    @discardableResult
    func restoreScratchpadWindow(
        _ entry: WindowState,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) -> Bool {
        guard let controller,
              let hiddenState = controller.workspaceManager.hiddenState(for: entry.token),
              hiddenState.isScratchpad
        else {
            return false
        }

        return executeHiddenReveal(
            entry,
            monitor: monitor,
            hiddenState: hiddenState,
            onSuccess: onSuccess
        )
    }

    func proportionalPosition(topLeft: CGPoint, in frame: CGRect) -> CGPoint {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        let x = (topLeft.x - frame.minX) / width
        let y = (frame.maxY - topLeft.y) / height
        return CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1))
    }

    private func preferredHideSides(for monitors: [Monitor]) -> [Monitor.ID: HideSide] {
        let important = 10
        var preferredSides: [Monitor.ID: HideSide] = [:]

        for monitor in monitors {
            let monitorFrame = monitor.frame
            let xOff = monitorFrame.width * 0.1
            let yOff = monitorFrame.height * 0.1

            let bottomRight = CGPoint(x: monitorFrame.maxX, y: monitorFrame.minY)
            let bottomLeft = CGPoint(x: monitorFrame.minX, y: monitorFrame.minY)

            let rightPoints = [
                CGPoint(x: bottomRight.x + 2, y: bottomRight.y - yOff),
                CGPoint(x: bottomRight.x - xOff, y: bottomRight.y + 2),
                CGPoint(x: bottomRight.x + 2, y: bottomRight.y + 2)
            ]

            let leftPoints = [
                CGPoint(x: bottomLeft.x - 2, y: bottomLeft.y - yOff),
                CGPoint(x: bottomLeft.x + xOff, y: bottomLeft.y + 2),
                CGPoint(x: bottomLeft.x - 2, y: bottomLeft.y + 2)
            ]

            func sideScore(_ points: [CGPoint]) -> Int {
                monitors.reduce(0) { partial, other in
                    let c1 = other.frame.contains(points[0]) ? 1 : 0
                    let c2 = other.frame.contains(points[1]) ? 1 : 0
                    let c3 = other.frame.contains(points[2]) ? 1 : 0
                    return partial + c1 + c2 + important * c3
                }
            }

            let leftScore = sideScore(leftPoints)
            let rightScore = sideScore(rightPoints)
            preferredSides[monitor.id] = leftScore < rightScore ? .left : .right
        }

        return preferredSides
    }

    func preferredHideSide(for monitor: Monitor) -> HideSide {
        guard let controller else { return .right }
        return preferredHideSides(for: controller.workspaceManager.monitors)[monitor.id] ?? .right
    }

    func hasPendingRevealTransaction(for windowId: Int) -> Bool {
        pendingRevealTransactionsByWindowId[windowId] != nil
    }

    func pendingRevealTransactionId(forWindowId windowId: Int) -> UInt64? {
        pendingRevealTransactionsByWindowId[windowId]?.id
    }

    func shouldUsePendingRevealTransaction(
        for entry: WindowState,
        hiddenState: HiddenState
    ) -> Bool {
        !hiddenState.workspaceInactive
            && entry.mode == .floating
            && hiddenState.restoresViaFloatingState
    }

    func beginPendingRevealTransaction(
        for entry: WindowState,
        hiddenState: HiddenState,
        targetFrame: CGRect,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil
    ) -> UInt64? {
        guard let controller else { return nil }
        let entry = controller.workspaceManager.entry(for: entry.token) ?? entry
        if var pendingTransaction = pendingRevealTransactionsByWindowId[entry.windowId] {
            if let onSuccess = makePostLayoutAction(
                onSuccess,
                workspaceIds: [entry.workspaceId]
            ) {
                if !pendingTransaction.hiddenState.isScratchpad || pendingTransaction.postSuccessActions.isEmpty {
                    pendingTransaction.postSuccessActions.append(onSuccess)
                    pendingRevealTransactionsByWindowId[entry.windowId] = pendingTransaction
                }
            }
            return nil
        }

        let transactionId = nextPendingRevealTransactionId
        pendingRevealTransactionsByWindowId[entry.windowId] = PendingRevealTransaction(
            id: transactionId,
            token: entry.token,
            pid: entry.pid,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            plannedSeq: controller.workspaceManager.worldSeq,
            targetFrame: targetFrame,
            targetMonitorId: monitor.id,
            hiddenState: hiddenState,
            postSuccessActions: makePostLayoutAction(
                onSuccess,
                workspaceIds: [entry.workspaceId]
            ).map { [$0] } ?? []
        )
        nextPendingRevealTransactionId &+= 1
        return transactionId
    }

    func rekeyPendingRevealTransaction(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        entry: WindowState
    ) {
        let oldWindowId = oldToken.windowId
        let newWindowId = newToken.windowId
        guard oldWindowId != newWindowId || oldToken != newToken else { return }
        guard var transaction = pendingRevealTransactionsByWindowId.removeValue(forKey: oldWindowId) else {
            return
        }

        transaction.token = newToken
        transaction.pid = entry.pid
        transaction.windowId = entry.windowId
        transaction.workspaceId = entry.workspaceId
        if let controller {
            transaction.plannedSeq = controller.workspaceManager.worldSeq
        }
        pendingRevealTransactionsByWindowId[newWindowId] = transaction

        if let verificationTask = pendingRevealVerificationTasksByWindowId.removeValue(forKey: oldWindowId) {
            verificationTask.cancel()
            if transaction.delayedVerificationScheduled {
                scheduleDelayedRevealVerification(forWindowId: newWindowId)
            }
        }
    }

    func refreshPendingRevealTransactionPlannedSeq(
        forWindowId windowId: Int,
        transactionId: UInt64
    ) {
        guard let controller,
              var transaction = pendingRevealTransactionsByWindowId[windowId],
              transaction.id == transactionId
        else {
            return
        }
        transaction.plannedSeq = controller.workspaceManager.worldSeq
        pendingRevealTransactionsByWindowId[windowId] = transaction
    }

    func cancelPendingScratchpadReveal(for token: WindowToken) {
        guard let transaction = pendingRevealTransactionsByWindowId[token.windowId],
              transaction.token == token,
              transaction.hiddenState.isScratchpad
        else {
            return
        }
        pendingRevealTransactionsByWindowId.removeValue(forKey: token.windowId)
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: token.windowId)?.cancel()
        controller?.axManager.cancelPendingFrameJobs([(transaction.pid, transaction.windowId)])
    }

    func completePendingRevealTransaction(
        with result: AXFrameApplyResult,
        transactionId: UInt64
    ) {
        guard let transaction = pendingRevealTransactionsByWindowId[result.windowId],
              transaction.id == transactionId
        else {
            return
        }

        let outcome = hiddenRevealTerminalOutcome(for: result, transaction: transaction)

        switch outcome {
        case .success:
            finalizePendingRevealTransactionSuccess(
                forWindowId: result.windowId,
                confirmedFrame: result.confirmedFrame,
                transactionId: transaction.id
            )
        case .delayedVerification:
            guard var pendingTransaction = pendingRevealTransactionsByWindowId[result.windowId],
                  !pendingTransaction.delayedVerificationScheduled
            else {
                return
            }
            pendingTransaction.delayedVerificationScheduled = true
            pendingRevealTransactionsByWindowId[result.windowId] = pendingTransaction
            scheduleDelayedRevealVerification(forWindowId: result.windowId)
        case .failure:
            finalizePendingRevealTransactionFailure(
                forWindowId: result.windowId,
                transactionId: transaction.id
            )
        }
    }

    private func hiddenRevealTerminalOutcome(
        for result: AXFrameApplyResult,
        transaction: PendingRevealTransaction
    ) -> HiddenRevealTerminalOutcome {
        if result.confirmedFrame != nil {
            guard let failureReason = result.writeResult.failureReason else {
                return .success
            }
            if isConfirmedRevealFailureTerminal(failureReason) {
                return .failure
            }
            if transaction.hiddenState.isScratchpad {
                return .delayedVerification
            }
            return .success
        }

        guard let failureReason = result.writeResult.failureReason else {
            return .failure
        }

        return isDelayedRevealRecoverable(failureReason) ? .delayedVerification : .failure
    }

    private func isDelayedRevealRecoverable(_ failureReason: AXFrameWriteFailureReason) -> Bool {
        switch failureReason {
        case .verificationMismatch,
             .readbackFailed,
             .sizeWriteFailed,
             .positionWriteFailed:
            return true
        default:
            return false
        }
    }

    private func isConfirmedRevealFailureTerminal(_ failureReason: AXFrameWriteFailureReason) -> Bool {
        switch failureReason {
        case .cancelled,
             .suppressed:
            return true
        default:
            return false
        }
    }

    private func finalizePendingRevealTransactionSuccess(
        forWindowId windowId: Int,
        confirmedFrame: CGRect?,
        transactionId: UInt64? = nil
    ) {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId.removeValue(forKey: windowId)
        else {
            return
        }
        if let transactionId, pendingTransaction.id != transactionId {
            pendingRevealTransactionsByWindowId[windowId] = pendingTransaction
            return
        }
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: windowId)?.cancel()

        guard pendingRevealTransactionIsCurrent(pendingTransaction, using: controller.workspaceManager) else {
            restoreStalePendingRevealSideEffects(pendingTransaction, using: controller)
            requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: stalePendingRevealWorkspaceIds(pendingTransaction, using: controller)
            )
            return
        }
        let actionWorkspacesCurrentAtEntry = pendingTransaction.postSuccessActions.map {
            $0.currentWorkspaces(using: controller.workspaceManager)
        }
        let focusSeqAccepted = controller.workspaceManager.isSeqCurrent(
            pendingTransaction.plannedSeq,
            for: pendingTransaction.workspaceId,
            domains: .focusCommit
        )
        controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.setHiddenState(nil, for: pendingTransaction.token)
        }
        controller.axManager.clearParkPending(for: pendingTransaction.windowId, pid: pendingTransaction.pid)
        if pendingTransaction.hiddenState.isScratchpad {
            controller.requestWorkspaceBarRefresh()
        }
        if let confirmedFrame {
            controller.axManager.confirmFrameWrite(for: pendingTransaction.windowId, frame: confirmedFrame)
        }
        let acceptedSeqs: [WorkspaceDescriptor.ID: AcceptedSeq] = [
            pendingTransaction.workspaceId: AcceptedSeq(
                after: controller.workspaceManager.worldSeq,
                domains: focusSeqAccepted ? .layoutCommit.union(.focusCommit) : .layoutCommit
            )
        ]
        for (action, currentAtEntry) in zip(pendingTransaction.postSuccessActions, actionWorkspacesCurrentAtEntry) {
            action
                .forwarded(by: acceptedSeqs, currentAtEntry: currentAtEntry)
                .runIfCurrent(using: controller.workspaceManager)
        }
    }

    private func finalizePendingRevealTransactionFailure(
        forWindowId windowId: Int,
        transactionId: UInt64? = nil
    ) {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId.removeValue(forKey: windowId)
        else {
            return
        }
        if let transactionId, pendingTransaction.id != transactionId {
            pendingRevealTransactionsByWindowId[windowId] = pendingTransaction
            return
        }
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: windowId)?.cancel()
        let frameEntry = [(pendingTransaction.pid, pendingTransaction.windowId)]

        guard pendingRevealTransactionIsCurrent(pendingTransaction, using: controller.workspaceManager) else {
            restoreStalePendingRevealSideEffects(pendingTransaction, using: controller)
            requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: stalePendingRevealWorkspaceIds(pendingTransaction, using: controller)
            )
            return
        }

        if pendingTransaction.hiddenState.isScratchpad,
           controller.workspaceManager.hiddenState(for: pendingTransaction.token)?.isScratchpad != true
        {
            controller.axManager.unsuppressFrameWrites(frameEntry)
            return
        }

        if pendingTransaction.hiddenState.workspaceInactive {
            controller.withRuntimeFrameJobCancellationSuppressed {
                controller.workspaceManager.setHiddenState(nil, for: pendingTransaction.token)
            }
            controller.axManager.unsuppressFrameWrites(frameEntry)
            return
        }

        if controller.workspaceManager.hiddenState(for: pendingTransaction.token) == nil {
            controller.withRuntimeFrameJobCancellationSuppressed {
                controller.workspaceManager.setHiddenState(
                    pendingTransaction.hiddenState,
                    for: pendingTransaction.token
                )
            }
        }
        if controller.workspaceManager.hiddenState(for: pendingTransaction.token) != nil {
            controller.axManager.suppressFrameWrites(frameEntry)
        }
    }

    private func restoreStalePendingRevealSideEffects(
        _ transaction: PendingRevealTransaction,
        using controller: WMController
    ) {
        let pendingFrameEntry = (pid: transaction.pid, windowId: transaction.windowId)
        guard let entry = controller.workspaceManager.entry(for: transaction.token) else {
            controller.axManager.suppressFrameWrites([pendingFrameEntry])
            return
        }

        let liveFrameEntry = (pid: entry.pid, windowId: entry.windowId)
        let frameEntries = liveFrameEntry.windowId == pendingFrameEntry.windowId
            ? [liveFrameEntry]
            : [pendingFrameEntry, liveFrameEntry]

        guard let hiddenState = controller.workspaceManager.hiddenState(for: transaction.token) else {
            controller.axManager.unsuppressFrameWrites(frameEntries)
            return
        }

        controller.axManager.cancelPendingFrameJobs(frameEntries)
        controller.axManager.suppressFrameWrites(frameEntries)

        let monitor = stalePendingRevealMonitor(
            for: entry,
            hiddenState: hiddenState,
            transaction: transaction,
            using: controller
        )
        hideWindow(
            entry,
            monitor: monitor,
            side: hiddenState.offscreenSide ?? preferredHideSide(for: monitor),
            reason: hideReason(for: hiddenState)
        )
    }

    private func stalePendingRevealWorkspaceIds(
        _ transaction: PendingRevealTransaction,
        using controller: WMController
    ) -> Set<WorkspaceDescriptor.ID> {
        var workspaceIds: Set<WorkspaceDescriptor.ID> = [transaction.workspaceId]
        if let currentWorkspaceId = controller.workspaceManager.entry(for: transaction.token)?.workspaceId {
            workspaceIds.insert(currentWorkspaceId)
        }
        return workspaceIds
    }

    private func stalePendingRevealMonitor(
        for entry: WindowState,
        hiddenState: HiddenState,
        transaction: PendingRevealTransaction,
        using controller: WMController
    ) -> Monitor {
        hiddenState.referenceMonitorId.flatMap { controller.workspaceManager.monitor(byId: $0) }
            ?? controller.workspaceManager.monitor(byId: transaction.targetMonitorId)
            ?? controller.workspaceManager.monitor(for: entry.workspaceId)
            ?? Monitor.fallback()
    }

    private func hideReason(for hiddenState: HiddenState) -> HideReason {
        switch hiddenState.reason {
        case .workspaceInactive:
            .workspaceInactive
        case .layoutTransient:
            .layoutTransient
        case .scratchpad:
            .scratchpad
        }
    }

    private func pendingRevealTransactionIsCurrent(
        _ transaction: PendingRevealTransaction,
        using workspaceManager: WorkspaceManager
    ) -> Bool {
        workspaceManager.isSeqCurrent(
            transaction.plannedSeq,
            for: transaction.workspaceId,
            domains: .layoutCommit
        )
    }

    private func scheduleDelayedRevealVerification(forWindowId windowId: Int) {
        pendingRevealVerificationTasksByWindowId[windowId]?.cancel()
        guard let transactionId = pendingRevealTransactionsByWindowId[windowId]?.id else { return }
        pendingRevealVerificationTasksByWindowId[windowId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.delayedRevealVerificationDelay)
            } catch {
                return
            }
            guard let self else { return }
            let verifiedFrame = self.delayedVerifiedRevealFrame(
                forWindowId: windowId,
                transactionId: transactionId
            )
            if let verifiedFrame {
                self.finalizePendingRevealTransactionSuccess(
                    forWindowId: windowId,
                    confirmedFrame: verifiedFrame,
                    transactionId: transactionId
                )
            } else {
                self.finalizePendingRevealTransactionFailure(
                    forWindowId: windowId,
                    transactionId: transactionId
                )
            }
        }
    }

    private func delayedVerifiedRevealFrame(
        forWindowId windowId: Int,
        transactionId: UInt64
    ) -> CGRect? {
        guard let controller,
              let pendingTransaction = pendingRevealTransactionsByWindowId[windowId],
              pendingTransaction.id == transactionId,
              let entry = controller.workspaceManager.entry(for: pendingTransaction.token),
              let observedFrame = observedWindowFrame(entry)
        else {
            return nil
        }

        let monitor = controller.workspaceManager.monitor(byId: pendingTransaction.targetMonitorId)
            ?? controller.workspaceManager.monitor(for: entry.workspaceId)
        guard let monitor else { return nil }
        guard observedFrame.intersects(monitor.visibleFrame),
              monitor.visibleFrame.contains(CGPoint(x: observedFrame.midX, y: observedFrame.midY))
        else {
            return nil
        }

        return observedFrame
    }

    private func executeHiddenReveal(
        _ entry: WindowState,
        monitor: Monitor,
        hiddenState: HiddenState,
        onSuccess: PostLayoutAction? = nil
    ) -> Bool {
        guard let controller else { return false }
        let entry = controller.workspaceManager.entry(for: entry.token) ?? entry
        let frameEntry = [(entry.pid, entry.windowId)]
        switch restoreWindowFromHiddenState(entry, monitor: monitor, hiddenState: hiddenState) {
        case .none:
            if hiddenState.workspaceInactive {
                controller.withRuntimeFrameJobCancellationSuppressed {
                    controller.workspaceManager.setHiddenState(nil, for: entry.token)
                }
                if hiddenState.isScratchpad {
                    controller.requestWorkspaceBarRefresh()
                }
                controller.axManager.unsuppressFrameWrites(frameEntry)
                acceptedPostLayoutAction(
                    onSuccess,
                    workspaceIds: [controller.workspaceManager.workspace(for: entry.token) ?? entry.workspaceId]
                )?.runIfCurrent(using: controller.workspaceManager)
                return true
            } else {
                controller.axManager.suppressFrameWrites(frameEntry)
                return false
            }
        case let .positionPlan(plan):
            applyPositionPlans([plan])
            controller.withRuntimeFrameJobCancellationSuppressed {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
            if hiddenState.isScratchpad {
                controller.requestWorkspaceBarRefresh()
            }
            controller.axManager.unsuppressFrameWrites(frameEntry)
            acceptedPostLayoutAction(
                onSuccess,
                workspaceIds: [controller.workspaceManager.workspace(for: entry.token) ?? entry.workspaceId]
            )?.runIfCurrent(using: controller.workspaceManager)
            return true
        case let .asyncFrame(frame):
            if !shouldUsePendingRevealTransaction(for: entry, hiddenState: hiddenState) {
                controller.withRuntimeFrameJobCancellationSuppressed {
                    controller.workspaceManager.setHiddenState(nil, for: entry.token)
                }
                if hiddenState.isScratchpad {
                    controller.requestWorkspaceBarRefresh()
                }
                controller.axManager.unsuppressFrameWrites(frameEntry)
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
                controller.axManager.applyFramesParallel([
                    .init(pid: entry.pid, window: entry.axRef, frame: frame)
                ])
                acceptedPostLayoutAction(
                    onSuccess,
                    workspaceIds: [controller.workspaceManager.workspace(for: entry.token) ?? entry.workspaceId]
                )?.runIfCurrent(using: controller.workspaceManager)
                return true
            }
            guard let transactionId = beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: frame,
                monitor: monitor,
                onSuccess: onSuccess
            ) else {
                return true
            }
            controller.axManager.unsuppressFrameWrites(frameEntry)
            controller.axManager.forceApplyNextFrame(for: entry.windowId)
            controller.axManager.applyFramesParallel(
                [.init(pid: entry.pid, window: entry.axRef, frame: frame)],
                terminalObserver: { [weak self] result in
                    self?.completePendingRevealTransaction(
                        with: result,
                        transactionId: transactionId
                    )
                }
            )
            return true
        }
    }

    private func restoreWindowFromHiddenState(
        _ entry: WindowState,
        monitor: Monitor,
        hiddenState: HiddenState
    ) -> HiddenRevealOperation {
        if entry.mode == .floating,
           hiddenState.restoresViaFloatingState,
           let controller,
           let frame = controller.workspaceManager.resolvedFloatingFrame(
               for: entry.token,
               preferredMonitor: monitor
           )
        {
            return .asyncFrame(frame)
        }

        if let plan = makeRestorePositionPlan(
            for: entry,
            monitor: monitor,
            hiddenState: hiddenState
        ) {
            return .positionPlan(plan)
        }

        return .none
    }

    func makeRestorePositionPlan(
        for entry: WindowState,
        monitor: Monitor,
        hiddenState: HiddenState
    ) -> WindowPositionPlan? {
        guard let controller else { return nil }
        guard let frame = fastFrame(for: entry.token, axRef: entry.axRef)
            ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
            ?? entry.observedState.frame
            ?? entry.floatingState?.lastFrame
        else {
            return nil
        }

        let fallbackMonitor = hiddenState.referenceMonitorId
            .flatMap { controller.workspaceManager.monitor(byId: $0) }
        let restoreFrame: CGRect
        if monitor.frame.width > 1, monitor.frame.height > 1 {
            restoreFrame = monitor.frame
        } else {
            restoreFrame = fallbackMonitor?.frame ?? monitor.frame
        }

        let topLeft = topLeftPoint(from: hiddenState.proportionalPosition, in: restoreFrame)
        let restoredOrigin = clampedOrigin(forTopLeft: topLeft, windowSize: frame.size, in: restoreFrame)

        return WindowPositionPlan(
            entry: entry,
            frame: CGRect(origin: restoredOrigin, size: frame.size)
        )
    }

    private func topLeftPoint(from proportionalPosition: CGPoint, in frame: CGRect) -> CGPoint {
        let xRatio = min(max(proportionalPosition.x, 0), 1)
        let yRatio = min(max(proportionalPosition.y, 0), 1)
        return CGPoint(
            x: frame.minX + frame.width * xRatio,
            y: frame.maxY - frame.height * yRatio
        )
    }

    private func clampedOrigin(forTopLeft topLeft: CGPoint, windowSize: CGSize, in frame: CGRect) -> CGPoint {
        let minX = frame.minX
        let maxX = frame.maxX - windowSize.width
        let clampedX: CGFloat
        if maxX >= minX {
            clampedX = min(max(topLeft.x, minX), maxX)
        } else {
            clampedX = minX
        }

        let minTopLeftY = frame.minY + windowSize.height
        let maxTopLeftY = frame.maxY
        let clampedTopLeftY: CGFloat
        if maxTopLeftY >= minTopLeftY {
            clampedTopLeftY = min(max(topLeft.y, minTopLeftY), maxTopLeftY)
        } else {
            clampedTopLeftY = maxTopLeftY
        }

        return CGPoint(x: clampedX, y: clampedTopLeftY - windowSize.height)
    }
}
