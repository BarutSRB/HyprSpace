// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor private func hasPendingNiriAnimationWork(
    state: ViewportState,
    driver: AnimationDriver,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    state.hasPendingOffsetAnimation
        || driver.hasMotion(in: workspaceId)
        || engine.hasAnyWindowAnimationsRunning(in: workspaceId)
        || engine.hasAnyColumnAnimationsRunning(in: workspaceId)
}

struct StructuralMutation: Equatable {
    let sourceWorkspaceId: WorkspaceDescriptor.ID
    let destinationWorkspaceId: WorkspaceDescriptor.ID
    let selectedHandle: WindowHandle
    let movedTokens: [WindowToken]
    let scrollWorkspaceId: WorkspaceDescriptor.ID?

    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> {
        if sourceWorkspaceId == destinationWorkspaceId {
            return [sourceWorkspaceId]
        }
        return [sourceWorkspaceId, destinationWorkspaceId]
    }
}

enum StructuralMutationOutcome: Equatable {
    case changed(StructuralMutation)
    case atWorkspaceEdge
    case unchanged

    var mutation: StructuralMutation? {
        guard case let .changed(mutation) = self else { return nil }
        return mutation
    }

    var didMutate: Bool {
        mutation != nil
    }
}

@MainActor final class NiriLayoutHandler {
    weak var controller: WMController?

    struct NiriLayoutPass {
        let wsId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let orientation: Monitor.Orientation
        let insetFrame: CGRect
        let gap: CGFloat
        let windows: [LayoutWindowSnapshot]

        var primarySpanKeyPath: KeyPath<NiriContainer, CGFloat> {
            switch orientation {
            case .horizontal: \.cachedWidth
            case .vertical: \.cachedHeight
            }
        }
    }

    struct RemovalContext {
        var existingHandleIds: Set<WindowToken>
        var wasEmptyBeforeSync: Bool
        var removalResult: NiriLayoutEngine.NiriRemovalResult
        var externallyRemovedColumn: Bool

        var removedColumn: Bool {
            externallyRemovedColumn || !removalResult.removedColumnIndicesBefore.isEmpty
        }
    }

    private struct InsertionContext {
        var newTokens: [WindowToken]
        var tabLocalTokens: Set<WindowToken>
        var viewOriginBeforeInsertion: CGFloat?
    }

    private struct ArrivalContext {
        var activateWindowToken: WindowToken?
        var rememberedFocusToken: WindowToken?
        var hasNewWindowArrival: Bool
        var shouldStartScrollForNewWindow: Bool
    }

    private struct NiriStructuralMutation {
        let movedTokens: [WindowToken]
        let operation: LayoutOperation
    }

    private enum ColumnMoveTarget {
        case direction(Direction)
        case first
        case last
        case index(Int)
    }

    var scrollAnimationByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    private func resolvedOrientation(
        for workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        engine: NiriLayoutEngine
    ) -> Monitor.Orientation {
        controller?.settings.effectiveOrientation(for: monitor)
            ?? engine.monitorForWorkspace(workspaceId)?.orientation
            ?? monitor.autoOrientation
    }

    private func startScrollAnimationIfNeeded(
        for workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine
    ) {
        guard let controller else { return }
        guard hasPendingNiriAnimationWork(
            state: state,
            driver: controller.workspaceManager.animationDriver,
            engine: engine,
            workspaceId: workspaceId
        ) else {
            return
        }
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
    }

    func registerScrollAnimation(_ workspaceId: WorkspaceDescriptor.ID, on displayId: CGDirectDisplayID) -> Bool {
        if scrollAnimationByDisplay[displayId] == workspaceId {
            return false
        }
        scrollAnimationByDisplay[displayId] = workspaceId
        return true
    }

    func hasScrollAnimation(for workspaceId: WorkspaceDescriptor.ID) -> Bool {
        scrollAnimationByDisplay.values.contains(workspaceId)
    }

    func tickScrollAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let wsId = scrollAnimationByDisplay[displayId] else { return }
        guard let controller, let engine = controller.niriEngine else {
            controller?.layoutRefreshController.stopScrollAnimation(for: displayId)
            return
        }

        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == displayId }) else {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            return
        }

        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId else {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            controller.workspaceManager.animationDriver.removeMotions(for: [wsId])
            controller.layoutRefreshController.hideInactiveWorkspaces(
                activeWorkspaceIds: activeWorkspaceIds(controller: controller)
            )
            return
        }

        let scrollTrace = ScrollTickTrace.shared.isActive
        let animsStart = scrollTrace ? CACurrentMediaTime() : 0
        let windowAnimationsRunning = engine.tickAllWindowAnimations(in: wsId, at: targetTime)
        let columnAnimationsRunning = engine.tickAllColumnAnimations(in: wsId, at: targetTime)
        let viewportMotionRunning = controller.workspaceManager.animationDriver.tick(in: wsId, at: targetTime)
        let animsMs = scrollTrace ? (CACurrentMediaTime() - animsStart) * 1000 : 0
        let state = controller.workspaceManager.niriViewportState(for: wsId)

        let didApplyFrames = applyFramesOnDemand(
            wsId: wsId,
            state: state,
            engine: engine,
            monitor: monitor,
            animationTime: targetTime,
            animsMs: animsMs
        )
        guard didApplyFrames else {
            controller.layoutRefreshController.requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: [wsId]
            )
            return
        }
        let animationsOngoing = viewportMotionRunning
            || windowAnimationsRunning
            || columnAnimationsRunning

        if !animationsOngoing {
            applyFramesOnDemand(
                wsId: wsId,
                state: controller.workspaceManager.niriViewportState(for: wsId),
                engine: engine,
                monitor: monitor
            )
            finalizeAnimation()
            controller.layoutRefreshController.hideInactiveWorkspaces(
                activeWorkspaceIds: activeWorkspaceIds(controller: controller)
            )
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
        }
    }

    private func activeWorkspaceIds(controller: WMController) -> Set<WorkspaceDescriptor.ID> {
        var activeIds = Set<WorkspaceDescriptor.ID>()
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeIds.insert(workspace.id)
            }
        }
        return activeIds
    }

    @discardableResult
    func applyFramesOnDemand(
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval? = nil,
        animsMs: Double = 0
    ) -> Bool {
        guard let controller,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            return false
        }

        let trace = ScrollTickTrace.shared.isActive && animationTime != nil
        let snapshotStart = trace ? CACurrentMediaTime() : 0
        guard let snapshot = makeWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitor,
            viewportState: state,
            useScrollAnimationPath: true,
            removalSeed: nil,
            isActiveWorkspace: activeWorkspaceId == wsId
        ) else {
            return false
        }
        let snapshotMs = trace ? (CACurrentMediaTime() - snapshotStart) * 1000 : 0

        let buildStart = CACurrentMediaTime()
        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine,
            monitor: monitor,
            animationTime: animationTime
        )
        let buildSeconds = CACurrentMediaTime() - buildStart
        controller.layoutRefreshController.recordScrollBuild(
            seconds: buildSeconds,
            workspaceCount: 1,
            windowCount: controller.workspaceManager.windowCount(in: wsId)
        )

        let commitStart = trace ? CACurrentMediaTime() : 0
        let applied = controller.layoutRefreshController.executeLayoutPlan(plan)
        if trace {
            recordScrollTickBreakdown(
                plan: plan,
                monitor: monitor,
                windowCount: snapshot.windows.count,
                spans: ScrollTickSpans(
                    anims: animsMs,
                    snapshot: snapshotMs,
                    build: buildSeconds * 1000,
                    commit: (CACurrentMediaTime() - commitStart) * 1000
                )
            )
        }
        return applied
    }

    private struct ScrollTickSpans {
        let anims: Double
        let snapshot: Double
        let build: Double
        let commit: Double
    }

    private func recordScrollTickBreakdown(
        plan: WorkspaceLayoutPlan,
        monitor: Monitor,
        windowCount: Int,
        spans: ScrollTickSpans
    ) {
        var show = 0
        var hide = 0
        for change in plan.diff.visibilityChanges {
            switch change {
            case .show: show += 1
            case .hide: hide += 1
            }
        }
        ScrollTickTrace.shared.record(
            ScrollTickTrace.Record(
                mediaTime: CACurrentMediaTime(),
                displayId: monitor.displayId,
                animsMs: spans.anims,
                snapshotMs: spans.snapshot,
                buildMs: spans.build,
                commitMs: spans.commit,
                totalMs: spans.anims + spans.snapshot + spans.build + spans.commit,
                show: show,
                hide: hide,
                frames: plan.diff.frameChanges.count,
                windowCount: windowCount,
                isAnimationTick: true
            )
        )
    }

    private func finalizeAnimation() {
        guard let controller else { return }

        controller.surfaceReconciler.noteRestackOccurred()

        if controller.moveMouseToFocusedWindowEnabled,
           controller.workspaceManager.pendingFocusedToken == nil,
           let token = controller.workspaceManager.focusedToken,
           !controller.axEventHandler.hasRecentMouseFocusIntent(for: token),
           controller.intentLedger.allowsMouseToFocusedWarp(for: token)
        {
            controller.moveMouseToWindow(token, preferredFrame: controller.preferredKeyboardFocusFrame(for: token))
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }

        let hadScrollAnimation = scrollAnimationByDisplay.values.contains(workspaceId)
        for (displayId, wsId) in scrollAnimationByDisplay where wsId == workspaceId {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
        }

        let hadMotion = controller.workspaceManager.animationDriver.hasMotion(in: workspaceId)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.cancelAnimation()
        }

        guard hadScrollAnimation || hadMotion,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else {
            return
        }
        applyFramesOnDemand(
            wsId: workspaceId,
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            engine: engine,
            monitor: monitor
        )
    }

    private func requestLayoutCommandRelayout(
        in workspaceId: WorkspaceDescriptor.ID,
        postLayout: LayoutRefreshController.PostLayoutAction? = nil
    ) {
        controller?.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId],
            postLayout: postLayout,
            postLayoutDomains: .layoutCommit
        )
    }

    private func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        controller?.workspaceManager.recordLayoutOperation(operation, in: workspaceId, source: source)
    }

    func focusSelectedWindowAndRequestRelayout(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        let viewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let selectedNodeId = viewportState.selectedNodeId,
           let selectedWindow = controller.niriEngine?.findNode(
               by: selectedNodeId,
               in: workspaceId
           ) as? NiriWindow,
           controller.workspaceManager.entry(for: selectedWindow.token)?.workspaceId == workspaceId,
           !controller.isManagedWindowSuppressedByMacOSHide(selectedWindow.token)
        {
            controller.focusWindow(selectedWindow.token)
        }
        requestLayoutCommandRelayout(in: workspaceId)
    }

    func activatePointerHoveredWindow(
        _ window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        var shouldStartScrollAnimation = false
        var shouldRequestRelayout = false

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            activateNode(
                window,
                in: workspaceId,
                state: &state,
                options: .init(
                    layoutRefresh: false,
                    axFocus: false,
                    startAnimation: false
                )
            )
            shouldStartScrollAnimation = state.hasPendingOffsetAnimation
            shouldRequestRelayout = state.offsetTransition.kind == .jump
        }

        controller.focusWindow(window.token, origin: .pointerHover)

        if shouldStartScrollAnimation {
            startScrollAnimationIfNeeded(
                for: workspaceId,
                state: controller.workspaceManager.niriViewportState(for: workspaceId),
                engine: engine
            )
        } else if shouldRequestRelayout {
            requestLayoutCommandRelayout(in: workspaceId)
        }
    }

    func layoutWithNiriEngine(
        activeWorkspaces: Set<WorkspaceDescriptor.ID>,
        useScrollAnimationPath: Bool = false,
        removalSeeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]
    ) -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.niriEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        let workspaceIds = activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString })
        for wsId in workspaceIds {
            guard let workspace = controller.workspaceManager.descriptor(for: wsId),
                  let monitor = controller.workspaceManager.monitor(for: wsId)
            else { continue }

            let layoutType = controller.settings.layoutType(for: workspace.name)
            if layoutType == .dwindle { continue }
            let isActiveWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId

            guard let snapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                viewportState: nil,
                useScrollAnimationPath: useScrollAnimationPath,
                removalSeed: removalSeeds[wsId],
                isActiveWorkspace: isActiveWorkspace
            ) else { continue }

            plans.append(
                buildRelayoutPlan(
                    snapshot: snapshot,
                    engine: engine,
                    monitor: monitor
                )
            )
        }

        return plans
    }

    private func makeWorkspaceSnapshot(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        viewportState: ViewportState?,
        useScrollAnimationPath: Bool,
        removalSeed: NiriWindowRemovalSeed?,
        isActiveWorkspace: Bool
    ) -> NiriWorkspaceSnapshot? {
        guard let controller else { return nil }

        let shouldResolveConstraints = viewportState == nil
        let orientation = controller.settings.effectiveOrientation(for: monitor)
        guard let refreshInput = controller.layoutRefreshController.buildRefreshInput(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: shouldResolveConstraints,
            orientation: orientation,
            isActiveWorkspace: isActiveWorkspace
        ) else {
            return nil
        }

        let effectiveViewportState = viewportState ?? controller.workspaceManager.niriViewportState(for: wsId)

        return NiriWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            excludedTokens: refreshInput.excludedTokens,
            plannedSeq: refreshInput.plannedSeq,
            viewportState: effectiveViewportState,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            hasCompletedInitialRefresh: controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh,
            useScrollAnimationPath: useScrollAnimationPath,
            removalSeed: removalSeed,
            gap: controller.innerGap(for: monitor),
            outerGaps: controller.workspaceManager.outerGaps,
            displayRefreshRate: controller.layoutRefreshController.layoutState
                .refreshRateByDisplay[monitor.displayId] ?? 60.0,
            isActiveWorkspace: refreshInput.isActiveWorkspace
        )
    }

    private func buildOnDemandLayoutPlan(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval?
    ) -> WorkspaceLayoutPlan {
        let gaps = LayoutGaps(
            horizontal: snapshot.gap,
            vertical: snapshot.gap,
            outer: snapshot.outerGaps
        )

        let area = WorkingAreaContext(
            workingFrame: snapshot.monitor.workingFrame,
            fullscreenLayoutFrame: snapshot.monitor.fullscreenLayoutFrame,
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: snapshot.workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: snapshot.viewportState,
            workingArea: area,
            animationTime: animationTime,
            viewOffsetOverride: controller?.workspaceManager.animationDriver.liveViewOffset(
                in: snapshot.workspaceId,
                semanticOffset: snapshot.viewportState.viewOffset,
                at: animationTime ?? CACurrentMediaTime()
            ),
            settledVisibilityOffset: controller?.workspaceManager.animationDriver.settledVisibilityOffset(
                in: snapshot.workspaceId,
                semanticOffset: snapshot.viewportState.viewOffset
            ),
            excludedTokens: snapshot.excludedTokens
        )

        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            hiddenHandles: hiddenHandles,
            engine: engine,
            workspaceId: snapshot.workspaceId,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            reassertHidden: animationTime == nil,
            excludedTokens: snapshot.excludedTokens,
            pendingParkWindowIds: controller?.axManager.pendingParkWindowIds ?? []
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                viewportState: nil,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            isAnimationTick: animationTime != nil,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    private func buildRelayoutPlan(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor
    ) -> WorkspaceLayoutPlan {
        let motion = controller?.motionPolicy.snapshot() ?? .enabled
        var state = snapshot.viewportState
        let pass = NiriLayoutPass(
            wsId: snapshot.workspaceId,
            engine: engine,
            monitor: monitor,
            orientation: snapshot.monitor.orientation,
            insetFrame: snapshot.monitor.workingFrame,
            gap: snapshot.gap,
            windows: snapshot.windows
        )
        let windowTokens = snapshot.windows.map(\.token)
        let currentSelection = state.selectedNodeId
        pass.engine.setProjectionExclusions(snapshot.excludedTokens, in: pass.wsId)

        let removal = processWindowRemovals(
            pass: pass,
            motion: motion,
            state: &state,
            windowTokens: windowTokens,
            currentSelection: currentSelection,
            removedNodeIds: snapshot.removalSeed?.removedNodeIds ?? [],
            externallyRemovedColumn: snapshot.removalSeed?.removedColumn == true
        )

        let viewOriginBeforeInsertion = currentViewOrigin(pass: pass, state: state)

        restoreInitialNiriPlacementsIfNeeded(pass: pass, windowTokens: windowTokens)

        let insertion = syncAndInsert(
            pass: pass,
            motion: motion,
            state: &state,
            windowTokens: windowTokens,
            removal: removal,
            preferredFocusToken: snapshot.preferredFocusToken,
            viewOriginBeforeInsertion: viewOriginBeforeInsertion
        )

        let selection = resolveSelection(
            pass: pass,
            motion: motion,
            state: &state,
            windowTokens: windowTokens,
            removal: removal,
            snapshot: snapshot
        )

        let arrival = handleNewWindowArrival(
            pass: pass,
            motion: motion,
            state: &state,
            insertion: insertion,
            existingHandleIds: removal.existingHandleIds,
            snapshot: snapshot
        )

        var plan = computeLayoutPlan(
            pass: pass,
            motion: motion,
            state: state,
            rememberedFocusToken: arrival.rememberedFocusToken ?? selection.rememberedFocusToken,
            activateWindowToken: arrival.activateWindowToken,
            hasNewWindowArrival: arrival.hasNewWindowArrival,
            shouldStartScrollForNewWindow: arrival.shouldStartScrollForNewWindow,
            viewportNeedsRecalc: selection.viewportNeedsRecalc,
            snapshot: snapshot
        )
        plan.niriRestorePlacements = pass.engine.persistedPlacements(in: pass.wsId)

        return plan
    }

    private func restoreInitialNiriPlacementsIfNeeded(
        pass: NiriLayoutPass,
        windowTokens: [WindowToken]
    ) {
        guard let controller else { return }

        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(windowTokens.count)

        for token in windowTokens {
            if let placement = controller.workspaceManager.restoreIntent(for: token)?.niriPlacement {
                placements[token] = placement
            }
        }

        pass.engine.restoreInitialPlacements(placements, matching: windowTokens, in: pass.wsId)
    }

    private func processWindowRemovals(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        currentSelection: NodeId?,
        removedNodeIds: [NodeId],
        externallyRemovedColumn: Bool
    ) -> RemovalContext {
        let existingHandleIds = pass.engine.root(for: pass.wsId)?.windowIdSet ?? []
        let removedHandleIds = existingHandleIds.subtracting(Set(windowTokens))
        let wasEmptyBeforeSync = pass.engine.columns(in: pass.wsId).isEmpty

        let removalResult = pass.engine.removeWindows(
            removedHandleIds,
            in: pass.wsId,
            state: &state,
            motion: motion,
            workingFrame: pass.insetFrame,
            gaps: pass.gap,
            orientation: pass.orientation,
            selectedNodeId: currentSelection,
            removedNodeIds: removedNodeIds
        )

        return RemovalContext(
            existingHandleIds: existingHandleIds,
            wasEmptyBeforeSync: wasEmptyBeforeSync,
            removalResult: removalResult,
            externallyRemovedColumn: externallyRemovedColumn
        )
    }

    private func syncAndInsert(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        removal: RemovalContext,
        preferredFocusToken: WindowToken?,
        viewOriginBeforeInsertion: CGFloat?
    ) -> InsertionContext {
        let currentSelection = state.selectedNodeId
        syncWindowsAndInstallConstraints(
            pass: pass,
            windowTokens: windowTokens,
            selectedNodeId: currentSelection,
            preferredFocusToken: preferredFocusToken
        )
        let newTokens = windowTokens.filter { !removal.existingHandleIds.contains($0) }
        let visibleNewTokens = newTokens.filter {
            !pass.engine.isExcludedFromProjection($0, in: pass.wsId)
        }
        var tabLocalTokens = Set<WindowToken>()

        let columns = pass.engine.columns(in: pass.wsId)
        resolvePrimaryContainerSpansIfNeeded(pass: pass)

        if !removal.wasEmptyBeforeSync, !visibleNewTokens.isEmpty {
            let newTokenSet = Set(visibleNewTokens)
            let preexistingSurvivingTokens = Set(windowTokens).intersection(removal.existingHandleIds)
            var newColumnData: [(col: NiriContainer, colIdx: Int)] = []

            for (colIdx, col) in columns.enumerated() {
                var columnNewTokens: [WindowToken] = []
                var hasPreexistingToken = false
                for window in col.windowNodes {
                    if newTokenSet.contains(window.token) {
                        columnNewTokens.append(window.token)
                    }
                    if preexistingSurvivingTokens.contains(window.token) {
                        hasPreexistingToken = true
                    }
                }
                guard !columnNewTokens.isEmpty else { continue }

                if hasPreexistingToken {
                    if col.displayMode == .tabbed {
                        tabLocalTokens.formUnion(columnNewTokens)
                    }
                } else {
                    newColumnData.append((col, colIdx))
                }
            }

            let originalActiveIdx = state.activeColumnIndex
            let insertedBeforeActive = newColumnData.filter { $0.colIdx <= originalActiveIdx }
            if !insertedBeforeActive.isEmpty, !removal.removedColumn {
                let totalInsertedSpan = insertedBeforeActive.reduce(CGFloat(0)) { total, data in
                    total + data.col[keyPath: pass.primarySpanKeyPath] + pass.gap
                }
                state.rebaseOffset(by: -totalInsertedSpan)
                state.activeColumnIndex = originalActiveIdx + insertedBeforeActive.count
            }

            let sortedNewColumns = newColumnData.sorted { $0.colIdx < $1.colIdx }
            for addedData in sortedNewColumns {
                pass.engine.animateColumnsForAddition(
                    columnIndex: addedData.colIdx,
                    in: pass.wsId,
                    motion: motion,
                    state: state,
                    gaps: pass.gap,
                    workingFrame: pass.insetFrame,
                    orientation: pass.orientation
                )
            }
        }

        return InsertionContext(
            newTokens: visibleNewTokens,
            tabLocalTokens: tabLocalTokens,
            viewOriginBeforeInsertion: viewOriginBeforeInsertion
        )
    }

    private func syncWindowsAndInstallConstraints(
        pass: NiriLayoutPass,
        windowTokens: [WindowToken],
        selectedNodeId: NodeId?,
        preferredFocusToken: WindowToken?
    ) {
        let containerSizingStates = containerSizingStatesForMissingWindows(pass: pass, windowTokens: windowTokens)
        _ = pass.engine.syncWindows(
            windowTokens,
            in: pass.wsId,
            selectedNodeId: selectedNodeId,
            focusedToken: preferredFocusToken,
            containerSizingStates: containerSizingStates
        )
        for window in pass.windows {
            pass.engine.updateWindowConstraints(
                for: window.token,
                constraints: window.constraints,
                in: pass.wsId
            )
        }
    }

    private func containerSizingStatesForMissingWindows(
        pass: NiriLayoutPass,
        windowTokens: [WindowToken]
    ) -> [WindowToken: NiriContainerSizingState]? {
        guard let controller else { return nil }

        var states: [WindowToken: NiriContainerSizingState]?
        for token in windowTokens where pass.engine.findNode(for: token, in: pass.wsId) == nil {
            let state: NiriContainerSizingState?
            if let detached = controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState {
                state = detached
            } else if let initial = controller.workspaceManager.admissionHints(for: token)?
                .initialNiriContainerPrimarySpan
            {
                state = pass.engine.initialContainerSizingState(for: CGFloat(initial))
            } else {
                state = nil
            }

            guard let state else { continue }
            if states == nil {
                states = [:]
            }
            states?[token] = state
        }
        return states
    }

    private func resolveSelection(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        windowTokens: [WindowToken],
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot
    ) -> (viewportNeedsRecalc: Bool, rememberedFocusToken: WindowToken?) {
        state.displayRefreshRate = snapshot.displayRefreshRate
        let visibleWindowTokens = windowTokens.filter { !snapshot.excludedTokens.contains($0) }

        if let finalSelectionId = removal.removalResult.finalSelectionId {
            state.selectedNodeId = finalSelectionId
        } else if let selectedId = state.selectedNodeId,
                  pass.engine.findNode(by: selectedId, in: pass.wsId) == nil
        {
            state.selectedNodeId = pass.engine.validateSelection(selectedId, in: pass.wsId)
        }

        if let selectedNodeId = state.selectedNodeId,
           let selectedWindow = pass.engine.findNode(by: selectedNodeId, in: pass.wsId) as? NiriWindow,
           snapshot.excludedTokens.contains(selectedWindow.token)
        {
            state.selectedNodeId = nil
        }

        if state.selectedNodeId == nil {
            let fallbackToken = snapshot.preferredFocusToken.flatMap {
                visibleWindowTokens.contains($0) ? $0 : nil
            } ?? visibleWindowTokens.first
            if let firstToken = fallbackToken,
               let firstNode = pass.engine.findNode(for: firstToken, in: pass.wsId)
            {
                state.selectedNodeId = firstNode.id
            }
        }

        let usesSingleWindowFit = pass.engine.singleWindowLayoutContext(
            in: pass.wsId,
            excluding: snapshot.excludedTokens
        ) != nil
        if usesSingleWindowFit {
            resetViewportForSingleWindowFit(state: &state)
        }

        let offsetBefore = state.viewOffset
        let rebaseDeltaBefore = state.offsetTransition.rebaseDelta
        var viewportNeedsRecalc = removal.removalResult.viewportNeedsRecalc

        let isGestureOrAnimation = controller?.workspaceManager.animationDriver.hasMotion(in: pass.wsId) == true

        resolvePrimaryContainerSpansIfNeeded(pass: pass)

        if !usesSingleWindowFit,
           !isGestureOrAnimation,
           snapshot.isActiveWorkspace,
           let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId, in: pass.wsId),
           !removal.removalResult.visibilityWasCorrected,
           removal.removalResult.removedTokens.isEmpty || removal.removalResult.fromIndexForVisibility != nil
        {
            if snapshot.excludedTokens.isEmpty {
                pass.engine.ensureSelectionVisible(
                    node: selectedNode,
                    in: pass.wsId,
                    motion: motion,
                    state: &state,
                    workingFrame: pass.insetFrame,
                    gaps: pass.gap,
                    orientation: pass.orientation,
                    fromContainerIndex: removal.removalResult.fromIndexForVisibility
                )
            } else {
                pass.engine.ensureProjectedSelectionVisible(
                    node: selectedNode,
                    in: pass.wsId,
                    motion: motion,
                    state: &state,
                    workingFrame: pass.insetFrame,
                    gaps: pass.gap,
                    orientation: pass.orientation,
                    animationConfig: nil,
                    fromContainerIndex: removal.removalResult.fromIndexForVisibility
                )
            }
            let liveOffsetDelta = state.hasPendingOffsetAnimation
                ? state.offsetTransition.rebaseDelta - rebaseDeltaBefore
                : state.viewOffset - offsetBefore
            if abs(liveOffsetDelta) > 1 {
                viewportNeedsRecalc = true
            }
        }

        if !usesSingleWindowFit,
           snapshot.excludedTokens.isEmpty,
           removal.removalResult.removedColumnIndicesBefore.isEmpty,
           pass.engine.correctViewportAfterColumnRemoval(
               in: pass.wsId,
               state: &state,
               motion: motion,
               workingFrame: pass.insetFrame,
               gaps: pass.gap,
               orientation: pass.orientation
           )
        {
            viewportNeedsRecalc = true
        }

        let rememberedFocusToken: WindowToken?
        if let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId, in: pass.wsId) as? NiriWindow,
           !snapshot.excludedTokens.contains(selectedNode.token)
        {
            rememberedFocusToken = selectedNode.token
        } else {
            rememberedFocusToken = nil
        }

        return (viewportNeedsRecalc, rememberedFocusToken)
    }

    private func handleNewWindowArrival(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: inout ViewportState,
        insertion: InsertionContext,
        existingHandleIds: Set<WindowToken>,
        snapshot: NiriWorkspaceSnapshot
    ) -> ArrivalContext {
        let wasEmpty = existingHandleIds.subtracting(snapshot.excludedTokens).isEmpty
        let newTokens = insertion.newTokens

        var activateWindowToken: WindowToken?
        var rememberedFocusToken: WindowToken?
        var hasNewWindowArrival = false
        var shouldStartScrollForNewWindow = false
        if snapshot.hasCompletedInitialRefresh,
           let newToken = newTokens.last,
           let newNode = pass.engine.findNode(for: newToken, in: pass.wsId),
           snapshot.isActiveWorkspace
        {
            let isTabLocalArrival = insertion.tabLocalTokens.contains(newToken)
            state.selectedNodeId = newNode.id

            if wasEmpty {
                if pass.engine.singleWindowLayoutContext(
                    in: pass.wsId,
                    excluding: snapshot.excludedTokens
                ) != nil {
                    resetViewportForSingleWindowFit(state: &state)
                    if let column = pass.engine.column(of: newNode),
                       let durableIndex = pass.engine.columnIndex(of: column, in: pass.wsId)
                    {
                        state.activeColumnIndex = durableIndex
                    }
                } else {
                    pass.engine.ensureSelectionVisible(
                        node: newNode,
                        in: pass.wsId,
                        motion: .disabled,
                        state: &state,
                        workingFrame: pass.insetFrame,
                        gaps: pass.gap,
                        orientation: pass.orientation
                    )
                }
            } else if isTabLocalArrival {
                activateTabLocalWindow(
                    newNode,
                    pass: pass,
                    state: &state,
                    viewOrigin: insertion.viewOriginBeforeInsertion
                )
            } else if let newCol = pass.engine.column(of: newNode),
                      let newColIdx = pass.engine.columnIndex(of: newCol, in: pass.wsId)
            {
                resolvePrimaryContainerSpansIfNeeded(pass: pass)

                let shouldRestorePrevOffset = newColIdx == state.activeColumnIndex + 1
                let offsetBeforeActivation = state.viewOffset

                pass.engine.ensureSelectionVisible(
                    node: newNode,
                    in: pass.wsId,
                    motion: motion,
                    state: &state,
                    workingFrame: pass.insetFrame,
                    gaps: pass.gap,
                    orientation: pass.orientation,
                    fromContainerIndex: state.activeColumnIndex
                )

                if shouldRestorePrevOffset {
                    state.activatePrevColumnOnRemoval = offsetBeforeActivation
                }
            }
            rememberedFocusToken = newToken
            pass.engine.updateFocusTimestamp(for: newNode.id, in: pass.wsId)
            activateWindowToken = newToken
            hasNewWindowArrival = true
            shouldStartScrollForNewWindow = !isTabLocalArrival
        }

        let animatedNewTokens = newTokens.filter { !insertion.tabLocalTokens.contains($0) }
        if snapshot.hasCompletedInitialRefresh,
           snapshot.isActiveWorkspace,
           !animatedNewTokens.isEmpty
        {
            for token in animatedNewTokens {
                guard let window = pass.engine.findNode(for: token, in: pass.wsId),
                      !window.isHiddenInTabbedMode else { continue }

                window.animateMoveFrom(
                    displacement: CGPoint(x: 0, y: -16),
                    clock: pass.engine.animationClock,
                    config: pass.engine.windowMovementAnimationConfig,
                    displayRefreshRate: state.displayRefreshRate,
                    animated: motion.animationsEnabled
                )
            }
        }

        return ArrivalContext(
            activateWindowToken: activateWindowToken,
            rememberedFocusToken: rememberedFocusToken,
            hasNewWindowArrival: hasNewWindowArrival,
            shouldStartScrollForNewWindow: shouldStartScrollForNewWindow
        )
    }

    private func activateTabLocalWindow(
        _ node: NiriNode,
        pass: NiriLayoutPass,
        state: inout ViewportState,
        viewOrigin: CGFloat?
    ) {
        guard let column = pass.engine.column(of: node),
              let columnIndex = pass.engine.columnIndex(of: column, in: pass.wsId)
        else { return }

        if let window = node as? NiriWindow,
           let tileIndex = column.windowNodes.firstIndex(where: { $0 === window })
        {
            column.setActiveTileIdx(tileIndex)
            pass.engine.updateTabbedColumnVisibility(column: column)
        }

        state.activeColumnIndex = columnIndex
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil
        state.selectionProgress = 0

        if let viewOrigin {
            restoreViewOrigin(viewOrigin, pass: pass, state: &state)
        } else {
            state.jumpOffset(to: state.viewOffset)
        }
    }

    private func resolvePrimaryContainerSpansIfNeeded(pass: NiriLayoutPass) {
        pass.engine.resolvePrimaryContainerSpans(
            in: pass.wsId,
            workingFrame: pass.insetFrame,
            gaps: pass.gap,
            orientation: pass.orientation
        )
    }

    private func currentViewOrigin(pass: NiriLayoutPass, state: ViewportState) -> CGFloat? {
        let columns = pass.engine.columns(in: pass.wsId)
        guard !columns.isEmpty else { return nil }
        resolvePrimaryContainerSpansIfNeeded(pass: pass)
        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        return state.containerPosition(
            at: activeIndex,
            containers: columns,
            gap: pass.gap,
            sizeKeyPath: pass.primarySpanKeyPath
        ) + state.viewOffset
    }

    private func restoreViewOrigin(_ viewOrigin: CGFloat, pass: NiriLayoutPass, state: inout ViewportState) {
        let columns = pass.engine.columns(in: pass.wsId)
        guard !columns.isEmpty else { return }
        resolvePrimaryContainerSpansIfNeeded(pass: pass)
        let activeColumnIndex = state.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        state.activeColumnIndex = activeColumnIndex
        let activeContainerPosition = state.containerPosition(
            at: activeColumnIndex,
            containers: columns,
            gap: pass.gap,
            sizeKeyPath: pass.primarySpanKeyPath
        )
        state.jumpOffset(to: viewOrigin - activeContainerPosition)
    }

    private func resetViewportForSingleWindowFit(state: inout ViewportState) {
        state.activeColumnIndex = 0
        state.jumpOffset(to: 0)
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil
        state.selectionProgress = 0
    }

    private func computeLayoutPlan(
        pass: NiriLayoutPass,
        motion: MotionSnapshot,
        state: ViewportState,
        rememberedFocusToken: WindowToken?,
        activateWindowToken: WindowToken?,
        hasNewWindowArrival: Bool,
        shouldStartScrollForNewWindow: Bool,
        viewportNeedsRecalc: Bool,
        snapshot: NiriWorkspaceSnapshot
    ) -> WorkspaceLayoutPlan {
        let gaps = LayoutGaps(
            horizontal: pass.gap,
            vertical: pass.gap,
            outer: snapshot.outerGaps
        )

        let area = WorkingAreaContext(
            workingFrame: pass.insetFrame,
            fullscreenLayoutFrame: snapshot.monitor.fullscreenLayoutFrame,
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        let (frames, hiddenHandles) = pass.engine.calculateCombinedLayoutUsingPools(
            in: pass.wsId,
            monitor: pass.monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil,
            viewOffsetOverride: controller.map {
                $0.workspaceManager.animationDriver.plannedRenderOffset(
                    in: pass.wsId,
                    localState: state,
                    storeOffset: $0.workspaceManager.niriViewportState(for: pass.wsId).viewOffset
                )
            },
            excludedTokens: snapshot.excludedTokens
        )

        let hasColumnAnimations = pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)
        var directives: [AnimationDirective] = []

        if viewportNeedsRecalc,
           !hasNewWindowArrival,
           !snapshot.useScrollAnimationPath || state.hasPendingOffsetAnimation
        {
            directives.append(.startNiriScroll(workspaceId: pass.wsId))
        } else if !snapshot.useScrollAnimationPath, hasColumnAnimations {
            directives.append(.startNiriScroll(workspaceId: pass.wsId))
        }

        if let activateWindowToken {
            if shouldStartScrollForNewWindow {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
            directives.append(.activateWindow(token: activateWindowToken))
        }

        if let removalSeed = snapshot.removalSeed, !removalSeed.oldFrames.isEmpty {
            let newFrames = pass.engine.captureWindowFrames(
                in: pass.wsId,
                excluding: snapshot.excludedTokens
            )
            let animationsTriggered = pass.engine.triggerMoveAnimations(
                in: pass.wsId,
                oldFrames: removalSeed.oldFrames,
                newFrames: newFrames,
                motion: motion
            )
            let hasWindowAnimations = pass.engine.hasAnyWindowAnimationsRunning(in: pass.wsId)
            let hasColumnAnimations = pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)
            if animationsTriggered || hasWindowAnimations || hasColumnAnimations {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
        }

        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            hiddenHandles: hiddenHandles,
            engine: pass.engine,
            workspaceId: pass.wsId,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            reassertHidden: true,
            excludedTokens: snapshot.excludedTokens
        )
        let startsAnimation = directives.contains {
            if case .startNiriScroll = $0 { return true }
            return false
        }
        let hasPendingAnimationWork = controller.map {
            hasPendingNiriAnimationWork(
                state: state,
                driver: $0.workspaceManager.animationDriver,
                engine: pass.engine,
                workspaceId: pass.wsId
            )
        } == true
        let hasRegisteredAnimation = hasScrollAnimation(for: pass.wsId)
        if hasPendingAnimationWork, !startsAnimation, !hasRegisteredAnimation {
            directives.append(.startNiriScroll(workspaceId: pass.wsId))
        }
        return WorkspaceLayoutPlan(
            workspaceId: pass.wsId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: pass.wsId,
                viewportState: state,
                rememberedFocusToken: rememberedFocusToken,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            animationDirectives: directives,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        hiddenHandles: [WindowToken: HideSide],
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        canRestoreHiddenWorkspaceWindows: Bool,
        reassertHidden: Bool,
        excludedTokens: Set<WindowToken> = [],
        pendingParkWindowIds: Set<Int> = []
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        for window in windows {
            let token = window.token
            if window.isNativeFullscreenSuspended {
                if let originalToken = window.nativeFullscreenOriginalToken {
                    let frame = frames[token]
                    let validFrame = frame.map {
                        !$0.isNull && !$0.isInfinite && $0.width > 1 && $0.height > 1
                    } == true
                    diff.nativeFullscreenSlots[originalToken] =
                        NativeFullscreenSlotProjection(
                            currentToken: token,
                            frame: validFrame ? frame ?? .zero : .zero,
                            visible: canRestoreHiddenWorkspaceWindows
                                && !excludedTokens.contains(token)
                                && hiddenHandles[token] == nil
                                && validFrame
                        )
                }
                continue
            }
            if excludedTokens.contains(token) {
                continue
            }
            let previousOffscreenSide = window.hiddenState?.offscreenSide
            if let side = hiddenHandles[token] {
                if previousOffscreenSide != side || reassertHidden
                    || pendingParkWindowIds.contains(token.windowId)
                {
                    diff.visibilityChanges.append(.hide(token, side: side))
                }
                continue
            }

            if previousOffscreenSide != nil, frames[token] != nil {
                diff.visibilityChanges.append(.show(token))
            }

            if canRestoreHiddenWorkspaceWindows,
               let hiddenState = window.hiddenState,
               hiddenState.workspaceInactive
            {
                diff.restoreChanges.append(
                    .init(token: token, hiddenState: hiddenState)
                )
            }

            guard let frame = frames[token] else { continue }
            let forceApply = if let node = engine.findNode(for: token, in: workspaceId) {
                node.sizingMode == .fullscreen
            } else {
                false
            }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: token,
                    frame: frame,
                    forceApply: forceApply
                )
            )
        }
        return diff
    }

    func desiredTabRailInfos() -> [TabRailInfo] {
        guard let controller, let engine = controller.niriEngine else { return [] }

        var infos: [TabRailInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
                  controller.workspaceManager.activeLayoutKind(for: workspace.id) == .niri
            else { continue }

            infos.append(contentsOf: niriTabRailInfos(
                engine: engine,
                workspaceId: workspace.id,
                monitor: monitor
            ))
        }
        return infos
    }

    private func niriTabRailInfos(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> [TabRailInfo] {
        guard let controller else { return [] }
        var infos: [TabRailInfo] = []
        for column in engine.columns(in: workspaceId) where column.isTabbed {
            guard let frame = column.renderedFrame ?? column.frame else { continue }
            let visibleColumnFrame = frame.intersection(monitor.visibleFrame)
            guard TabRailManager.shouldShowRail(
                tileFrame: frame,
                visibleFrame: monitor.visibleFrame
            ) else { continue }

            let windows = engine.projectedWindows(in: column, workspaceId: workspaceId)
            guard windows.count > 1 else { continue }

            guard let activeWindow = engine.projectedActiveWindow(
                in: column,
                workspaceId: workspaceId
            ) else { continue }
            let activeWindowId = controller.workspaceManager.entry(for: activeWindow.token)?.windowId
            guard let activeStorageIndex = windows.firstIndex(where: { $0 === activeWindow }) else { continue }
            let activeVisualIndex = windows.count - 1 - activeStorageIndex
            let tabs = tabbedColumnTabs(
                windows: windows,
                activeVisualIndex: activeVisualIndex,
                controller: controller
            )

            infos.append(
                TabRailInfo(
                    workspaceId: workspaceId,
                    owner: .niriColumn(column.id),
                    plannedSeq: controller.workspaceManager.worldSeq,
                    tileFrame: frame,
                    visibleTileFrame: visibleColumnFrame,
                    tabCount: windows.count,
                    activeVisualIndex: activeVisualIndex,
                    activeWindowId: activeWindowId,
                    tabs: tabs
                )
            )
        }
        return infos
    }

    private func tabbedColumnTabs(
        windows: [NiriWindow],
        activeVisualIndex: Int,
        controller: WMController
    ) -> [TabRailTabInfo] {
        guard !windows.isEmpty else { return [] }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), windows.count - 1)
        var tabs: [TabRailTabInfo] = []
        tabs.reserveCapacity(windows.count)
        for visualIndex in 0 ..< windows.count {
            let storageIndex = windows.count - 1 - visualIndex
            let window = windows[storageIndex]
            let entry = controller.workspaceManager.entry(for: window.token)
            let appName: String?
            if let entry, controller.appInfoCache.hasCachedInfo(for: entry.pid) {
                appName = controller.appInfoCache.name(for: entry.pid)
            } else {
                appName = nil
            }
            let title = entry?.managedReplacementMetadata?.title
            tabs.append(
                TabRailTabInfo(
                    visualIndex: visualIndex,
                    token: window.token,
                    windowId: entry?.windowId,
                    appName: appName,
                    title: title,
                    isActive: visualIndex == clampedActiveVisualIndex
                )
            )
        }
        return tabs
    }

    func selectTabInNiri(
        info: TabRailInfo,
        visualIndex: Int,
        expectedToken: WindowToken?
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard case let .niriColumn(columnId) = info.owner else { return }
        let workspaceId = info.workspaceId
        guard controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri else { return }
        guard controller.workspaceManager.isSeqCurrent(
            info.plannedSeq,
            for: workspaceId,
            domains: .layoutCommit
        ) else {
            return
        }
        guard let column = engine.columns(in: workspaceId).first(where: { $0.id == columnId }) else { return }

        let windows = engine.projectedWindows(in: column, workspaceId: workspaceId)
        let target: NiriWindow
        if let expectedToken {
            guard let expectedWindow = windows.first(where: { $0.token == expectedToken }) else { return }
            target = expectedWindow
        } else {
            let storageIndex = windows.count - 1 - visualIndex
            guard windows.indices.contains(storageIndex) else { return }
            target = windows[storageIndex]
        }
        guard let storageIndex = column.windowNodes.firstIndex(where: { $0 === target }) else { return }

        let activeTileChanged = column.activeTileIdx != storageIndex
        controller.workspaceManager.withEngineMutationScope {
            column.setActiveTileIdx(storageIndex)
            engine.updateTabbedColumnVisibility(column: column)
        }
        if activeTileChanged {
            recordLayoutOperation(.tabActivated(token: target.token), in: workspaceId, source: .mouse)
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        controller.workspaceManager.withEngineMutationScope {
            if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
                let gap = controller.innerGap(for: monitor)
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                engine.ensureSelectionVisible(
                    node: target,
                    in: workspaceId,
                    motion: controller.motionPolicy.snapshot(),
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gap,
                    orientation: resolvedOrientation(
                        for: workspaceId,
                        monitor: monitor,
                        engine: engine
                    )
                )
            }
        }
        activateNode(
            target, in: workspaceId, state: &state,
            options: .init(activateWindow: false, ensureVisible: false, startAnimation: false)
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        if controller.workspaceManager.animationDriver.hasMotion(in: workspaceId)
            || engine.hasAnyWindowAnimationsRunning(in: workspaceId)
        {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    // MARK: - Layout Capability Commands

    func focusNeighbor(direction: Direction) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.niriEngine else { return false }
        guard let wsId = controller.activeWorkspace()?.id else { return false }

        var state = controller.workspaceManager.niriViewportState(for: wsId)
        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId, in: wsId)
        else {
            var recovered = false
            if let lastFocused = controller.workspaceManager.lastFocusedToken(in: wsId),
               !controller.isManagedWindowSuppressedByMacOSHide(lastFocused),
               let lastNode = engine.findNode(for: lastFocused, in: wsId)
            {
                activateNode(
                    lastNode, in: wsId, state: &state,
                    options: .init(
                        activateWindow: false,
                        ensureVisible: false,
                        layoutRefresh: false,
                        startAnimation: false
                    )
                )
                recovered = true
            } else if let firstEntry = controller.workspaceManager.tiledEntries(in: wsId).first(where: {
                !controller.isManagedWindowSuppressedByMacOSHide($0.token)
            }),
                let firstNode = engine.findNode(for: firstEntry.token, in: wsId)
            {
                activateNode(
                    firstNode, in: wsId, state: &state,
                    options: .init(
                        activateWindow: false,
                        ensureVisible: false,
                        layoutRefresh: false,
                        startAnimation: false
                    )
                )
                recovered = true
            }
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: state,
                    rememberedFocusToken: nil,
                    plannedSeq: controller.workspaceManager.worldSeq
                )
            )
            return recovered
        }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let gap = controller.innerGap(for: monitor)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let orientation = resolvedOrientation(
            for: wsId,
            monitor: monitor,
            engine: engine
        )

        let newNode = controller.workspaceManager.withEngineMutationScope { () -> NiriNode? in
            return engine.focusTarget(
                direction: direction,
                currentSelection: currentNode,
                in: wsId,
                motion: controller.motionPolicy.snapshot(),
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation
            )
        }
        guard let newNode else { return false }
        if let windowNode = newNode as? NiriWindow,
           controller.isManagedWindowSuppressedByMacOSHide(windowNode.token)
        {
            requestLayoutCommandRelayout(in: wsId)
            return false
        }
        activateNode(
            newNode, in: wsId, state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                layoutRefresh: false,
                axFocus: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        focusSelectedWindowAndRequestRelayout(in: wsId)
        return true
    }

    func toggleFullscreen() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let currentNode = engine.findNode(by: currentId, in: wsId),
                  let windowNode = currentNode as? NiriWindow
            else { return }

            engine.toggleFullscreen(windowNode, motion: motion, state: &state)
            if windowNode.sizingMode == .normal {
                engine.recoverSettledCoverage(
                    in: wsId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                )
            }

            recordLayoutOperation(.fullscreenToggled(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleSize(forward: Bool) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleContainerPrimarySpan(
                column,
                forwards: forward,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.containerPrimarySpanChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleWindowPrimarySpan(forward: Bool) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.toggleWindowPrimarySpan(
                windowNode,
                forwards: forward,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func cycleWindowSecondarySpan(forward: Bool) {
        withNiriWorkspaceContext { engine, wsId, _, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.toggleWindowSecondarySpan(
                windowNode,
                forwards: forward,
                in: wsId,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func toggleContainerFullPrimarySpan() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.toggleContainerFullPrimarySpan(
                column,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.containerPrimarySpanChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func expandContainerToAvailablePrimarySpan() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.expandContainerToAvailablePrimarySpan(
                column,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.containerPrimarySpanChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func resetWindowSecondarySpan() {
        withNiriWorkspaceContext { engine, wsId, _, state, _, _, _, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.resetWindowSecondarySpan(windowNode, in: wsId, orientation: orientation)
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func centerColumn() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.centerColumn(
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            ) else { return }

            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func centerVisibleColumns() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.centerVisibleColumns(
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            ) else { return }

            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setContainerPrimarySpan(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow,
                  let column = engine.findColumn(containing: windowNode, in: wsId)
            else { return }

            engine.setContainerPrimarySpan(
                column,
                change: change,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.containerPrimarySpanChanged, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setWindowPrimarySpan(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.setWindowPrimarySpan(
                windowNode,
                change: change,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func setWindowSecondarySpan(_ change: NiriSizeChange) {
        withNiriWorkspaceContext { engine, wsId, _, state, _, workingFrame, gaps, orientation in
            guard let currentId = state.selectedNodeId,
                  let windowNode = engine.findNode(by: currentId, in: wsId) as? NiriWindow
            else { return }

            engine.setWindowSecondarySpan(
                windowNode,
                change: change,
                in: wsId,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.windowSizeChanged(token: windowNode.token), in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func balanceSizes() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.balanceSizes(
                in: wsId,
                motion: motion,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            ) else { return }
            engine.recoverSettledCoverage(
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            recordLayoutOperation(.sizesBalanced, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func balanceSizesAllWorkspaces() {
        guard let controller else { return }
        var changed: Set<WorkspaceDescriptor.ID> = []
        for descriptor in controller.workspaceManager.workspaces {
            guard controller.settings.layoutType(for: descriptor.name) != .dwindle else { continue }
            withNiriWorkspaceContext(for: descriptor.id) {
                engine, wsId, motion, state, _, workingFrame, gaps, orientation in
                guard engine.balanceSizes(
                    in: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ) else { return }
                engine.recoverSettledCoverage(
                    in: wsId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                )
                changed.insert(wsId)
                recordLayoutOperation(.sizesBalanced, in: wsId)
                startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
            }
        }
        if !changed.isEmpty {
            controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: changed)
        }
    }

    // MARK: - Layout Engine Configuration

    func enableNiriLayout(
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard let controller else { return }
        let engine = NiriLayoutEngine()
        engine.centerFocusedColumn = centerFocusedColumn
        engine.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        engine.renderStyle.tabIndicatorWidth = TabRailManager.tabIndicatorWidth
        engine.animationClock = controller.animationClock
        controller.niriEngine = engine

        syncMonitorsToNiriEngine()

        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func syncMonitorsToNiriEngine() {
        guard let controller, let engine = controller.niriEngine else { return }

        let currentMonitors = controller.workspaceManager.monitors
        var orientations: [Monitor.ID: Monitor.Orientation] = [:]
        orientations.reserveCapacity(currentMonitors.count)
        for monitor in currentMonitors {
            orientations[monitor.id] = controller.settings.effectiveOrientation(for: monitor)
        }
        let workspaceAssignments: [(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)] =
            controller.workspaceManager.workspaces.compactMap { workspace in
                guard let monitor = controller.workspaceManager.monitor(for: workspace.id) else { return nil }
                return (workspaceId: workspace.id, monitor: monitor)
            }
        controller.workspaceManager.withEngineMutationScope {
            engine.updateMonitors(currentMonitors, orientations: orientations)
            engine.syncWorkspaceAssignments(workspaceAssignments, orientations: orientations)
        }

        refreshResolvedMonitorSettings()
    }

    func refreshResolvedMonitorSettings() {
        guard let controller, let engine = controller.niriEngine else { return }

        controller.workspaceManager.withEngineMutationScope {
            for monitor in controller.workspaceManager.monitors {
                let resolved = controller.settings.resolvedNiriSettings(for: monitor)
                engine.updateMonitorSettings(resolved, for: monitor.id)
            }
        }
    }

    func updateNiriConfig(
        visibleContainerCount: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        containerPrimarySpanPresets: [Double]? = nil,
        defaultContainerPrimarySpan: Double?? = nil
    ) {
        guard let controller else { return }
        controller.workspaceManager.withEngineMutationScope {
            controller.niriEngine?.updateConfiguration(
                visibleContainerCount: visibleContainerCount,
                infiniteLoop: infiniteLoop,
                centerFocusedColumn: centerFocusedColumn,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn,
                singleWindowFit: singleWindowFit,
                presetContainerPrimarySpans: containerPrimarySpanPresets?.map { .proportion($0) },
                defaultContainerPrimarySpan: defaultContainerPrimarySpan.map { $0.map { CGFloat($0) } }
            )
        }
        refreshResolvedMonitorSettings()
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    // MARK: - Node Activation & Operation Context

    func activateNode(
        _ node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        options: NodeActivationOptions = NodeActivationOptions()
    ) {
        guard let controller, let engine = controller.niriEngine else { return }

        state.selectedNodeId = node.id
        controller.workspaceManager.withEngineMutationScope {
            if !options.ensureVisible, !options.preserveViewportAnchor {
                rebaseViewportAnchor(to: node, in: workspaceId, state: &state)
            }

            if options.activateWindow {
                engine.activateWindow(node.id, in: workspaceId)
            }

            if options.ensureVisible, let monitor = controller.workspaceManager.monitor(for: workspaceId) {
                let gap = controller.innerGap(for: monitor)
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                engine.ensureSelectionVisible(
                    node: node,
                    in: workspaceId,
                    motion: controller.motionPolicy.snapshot(),
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gap,
                    orientation: resolvedOrientation(
                        for: workspaceId,
                        monitor: monitor,
                        engine: engine
                    )
                )
            }
        }

        let focusedToken = (node as? NiriWindow)?.token
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        if options.updateTimestamp, let windowNode = node as? NiriWindow {
            controller.workspaceManager.withEngineMutationScope {
                engine.updateFocusTimestamp(for: windowNode.id, in: workspaceId)
            }
        }

        if options.layoutRefresh {
            let focusToken = options.axFocus ? (node as? NiriWindow)?.token : nil
            requestLayoutCommandRelayout(
                in: workspaceId
            ) { [weak controller] in
                if let focusToken {
                    controller?.focusWindow(focusToken, origin: options.focusOrigin)
                }
            }
            if options.startAnimation, state.hasPendingOffsetAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
        } else {
            if options.axFocus, let windowNode = node as? NiriWindow {
                controller.focusWindow(windowNode.token, origin: options.focusOrigin)
            }
            if options.startAnimation, state.hasPendingOffsetAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
        }
    }

    private func rebaseViewportAnchor(
        to node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let column = engine.column(of: node) else { return }
        let columns = engine.columns(in: workspaceId)
        guard let targetIndex = columns.firstIndex(where: { $0 === column }) else { return }
        let currentIndex = min(max(state.activeColumnIndex, 0), columns.count - 1)
        guard currentIndex != targetIndex else { return }

        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else {
            state.activeColumnIndex = targetIndex
            return
        }

        let gap = controller.innerGap(for: monitor)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let orientation = controller.settings.effectiveOrientation(for: monitor)

        switch orientation {
        case .horizontal:
            for column in columns where column.cachedWidth <= 0 {
                column.resolveAndCacheWidth(
                    workingAreaWidth: workingFrame.width,
                    gaps: gap,
                    contentInset: engine.tabContentInset(for: column)
                )
            }
            rebaseViewportAnchor(
                from: currentIndex,
                to: targetIndex,
                workspaceId: workspaceId,
                columns: columns,
                gap: gap,
                state: &state,
                sizeKeyPath: \.cachedWidth
            )
        case .vertical:
            for column in columns where column.cachedHeight <= 0 {
                column.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: gap)
            }
            rebaseViewportAnchor(
                from: currentIndex,
                to: targetIndex,
                workspaceId: workspaceId,
                columns: columns,
                gap: gap,
                state: &state,
                sizeKeyPath: \.cachedHeight
            )
        }
    }

    private func rebaseViewportAnchor(
        from currentIndex: Int,
        to targetIndex: Int,
        workspaceId: WorkspaceDescriptor.ID,
        columns: [NiriContainer],
        gap: CGFloat,
        state: inout ViewportState,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) {
        let previousPosition = state.containerPosition(
            at: currentIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let targetPosition = state.containerPosition(
            at: targetIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        state.rebaseOffset(by: previousPosition - targetPosition)
        state.activeColumnIndex = targetIndex
    }

    private func selectedWindowHandleInActiveWorkspace() -> WindowHandle? {
        guard let controller,
              let workspaceId = controller.activeWorkspace()?.id,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
              let engine = controller.niriEngine,
              let window = engine.projectedSelectedWindow(
                  state: controller.workspaceManager.niriViewportState(for: workspaceId),
                  in: workspaceId
              ),
              let handle = controller.workspaceManager.handle(for: window.token)
        else {
            return nil
        }
        return handle
    }

    private func performStructuralMutation(
        handle: WindowHandle,
        operation: (NiriOperationContext, inout ViewportState) -> NiriStructuralMutation?
    ) -> StructuralMutationOutcome {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: handle.id),
              controller.workspaceManager.handle(for: handle.id) === handle,
              !controller.workspaceManager.isAppHidden(pid: entry.pid),
              controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              let engine = controller.niriEngine,
              !engine.isExcludedFromProjection(handle.id, in: entry.workspaceId),
              let windowNode = engine.findNode(for: handle, in: entry.workspaceId),
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        else {
            return .unchanged
        }

        let workspaceId = entry.workspaceId
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = resolvedOrientation(
            for: workspaceId,
            monitor: monitor,
            engine: engine
        )
        let context = NiriOperationContext(
            controller: controller,
            engine: engine,
            motion: controller.motionPolicy.snapshot(),
            wsId: workspaceId,
            windowNode: windowNode,
            monitor: monitor,
            orientation: orientation,
            workingFrame: workingFrame,
            gaps: gaps
        )
        var completedMutation: NiriStructuralMutation?
        var committedState: ViewportState?

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            let originalState = state
            state.selectedNodeId = windowNode.id
            guard let mutation = operation(context, &state) else {
                state = originalState
                return
            }

            engine.activateWindow(windowNode.id, in: workspaceId)
            state.selectedNodeId = windowNode.id
            if engine.projectionExclusions(in: workspaceId).isEmpty {
                engine.ensureSelectionVisible(
                    node: windowNode,
                    in: workspaceId,
                    motion: context.motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                )
            } else {
                engine.ensureProjectedSelectionVisible(
                    node: windowNode,
                    in: workspaceId,
                    motion: context.motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation,
                    animationConfig: nil,
                    fromContainerIndex: nil
                )
            }
            completedMutation = mutation
            committedState = state
        }

        guard let completedMutation, let committedState else { return .unchanged }

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: windowNode.id,
            focusedToken: handle.id,
            in: workspaceId,
            onMonitor: monitor.id
        )
        recordLayoutOperation(completedMutation.operation, in: workspaceId)

        let scrollWorkspaceId = hasPendingNiriAnimationWork(
            state: committedState,
            driver: controller.workspaceManager.animationDriver,
            engine: engine,
            workspaceId: workspaceId
        ) ? workspaceId : nil

        return .changed(
            StructuralMutation(
                sourceWorkspaceId: workspaceId,
                destinationWorkspaceId: workspaceId,
                selectedHandle: handle,
                movedTokens: completedMutation.movedTokens,
                scrollWorkspaceId: scrollWorkspaceId
            )
        )
    }

    private func commitNormalStructuralMutation(_ outcome: StructuralMutationOutcome) {
        guard let controller, case let .changed(mutation) = outcome else { return }
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: mutation.affectedWorkspaceIds
        )
        if let scrollWorkspaceId = mutation.scrollWorkspaceId {
            controller.layoutRefreshController.startScrollAnimation(for: scrollWorkspaceId)
        }
    }

    @discardableResult
    func moveWindow(direction: Direction) -> WindowMoveOutcome {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return .blocked }
        let outcome = moveWindow(handle: handle, direction: direction)
        return commitWindowMoveOutcome(outcome)
    }

    private func commitWindowMoveOutcome(_ outcome: StructuralMutationOutcome) -> WindowMoveOutcome {
        commitNormalStructuralMutation(outcome)
        return switch outcome {
        case .changed:
            .movedWithinWorkspace
        case .atWorkspaceEdge:
            .atWorkspaceEdge
        case .unchanged:
            .blocked
        }
    }

    func moveWindow(handle: WindowHandle, direction: Direction) -> StructuralMutationOutcome {
        let allowEdgeWrap = !(controller?.settings.moveCrossesMonitorAtEdge ?? false)
        var edgeOutcome = WindowMoveOutcome.blocked
        let outcome = performStructuralMutation(handle: handle) { ctx, state in
            let movesAcrossContainers = direction.primaryStep(for: ctx.orientation) != nil
            let usesPredictedAnimation = ctx.orientation == .vertical || !movesAcrossContainers
            edgeOutcome = windowMoveOutcomeAtEdge(
                for: ctx.windowNode,
                direction: direction,
                engine: ctx.engine,
                in: ctx.wsId,
                orientation: ctx.orientation
            )
            let oldFrames = usesPredictedAnimation
                ? ctx.engine.captureWindowFrames(in: ctx.wsId)
                : [:]
            let motion = ctx.orientation == .vertical && movesAcrossContainers
                ? MotionSnapshot.disabled
                : ctx.motion
            guard ctx.engine.moveWindow(
                ctx.windowNode,
                direction: direction,
                in: ctx.wsId,
                orientation: ctx.orientation,
                motion: motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps,
                allowEdgeWrap: allowEdgeWrap
            ) else {
                return nil
            }

            if usesPredictedAnimation {
                ctx.preparePredictedAnimation(
                    state: state,
                    oldFrames: oldFrames,
                    yContainmentFrame: ctx.orientation == .vertical
                        ? ctx.monitor.frame
                        : nil
                )
            }
            return NiriStructuralMutation(
                movedTokens: [ctx.windowNode.token],
                operation: movesAcrossContainers
                    ? .windowConsumedOrExpelled(token: ctx.windowNode.token)
                    : .windowMovedInColumn(token: ctx.windowNode.token)
            )
        }

        if case .unchanged = outcome, edgeOutcome == .atWorkspaceEdge {
            return .atWorkspaceEdge
        }
        return outcome
    }

    @discardableResult
    func moveWindowWithinContainer(direction: Direction) -> WindowMoveOutcome {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return .blocked }
        return commitWindowMoveOutcome(
            moveWindowWithinContainer(handle: handle, direction: direction)
        )
    }

    func moveWindowWithinContainer(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard let step = direction.secondaryStep(for: .horizontal) else { return .unchanged }
        var edgeOutcome = WindowMoveOutcome.blocked
        let outcome = performStructuralMutation(handle: handle) { ctx, state in
            edgeOutcome = windowMoveOutcomeAtEdge(
                for: ctx.windowNode,
                direction: direction,
                engine: ctx.engine,
                in: ctx.wsId,
                orientation: .horizontal
            )
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveWindowWithinContainer(
                ctx.windowNode,
                step: step,
                in: ctx.wsId
            ) else {
                return nil
            }
            ctx.preparePredictedAnimation(
                state: state,
                oldFrames: oldFrames
            )
            return NiriStructuralMutation(
                movedTokens: [ctx.windowNode.token],
                operation: .windowMovedInColumn(token: ctx.windowNode.token)
            )
        }

        if case .unchanged = outcome, edgeOutcome == .atWorkspaceEdge {
            return .atWorkspaceEdge
        }
        return outcome
    }

    func moveWindowOrToAdjacentWorkspace(direction: Direction) {
        guard direction == .down || direction == .up else { return }
        guard moveWindowWithinContainer(direction: direction) == .atWorkspaceEdge else { return }
        controller?.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: direction)
    }

    func moveWindowOrToAdjacentWorkspace(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .down || direction == .up else { return .unchanged }
        let outcome = moveWindowWithinContainer(handle: handle, direction: direction)
        guard case .atWorkspaceEdge = outcome else { return outcome }
        return controller?.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(
            handle: handle,
            direction: direction
        ) ?? .unchanged
    }

    func consumeTransferredWindow(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        enteringFrom direction: Direction,
        anchorToken: WindowToken?
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = resolvedOrientation(
            for: workspaceId,
            monitor: monitor,
            engine: engine
        )
        var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)

        var consumed = false

        controller.workspaceManager.withEngineMutationScope(in: workspaceId, label: "drag_drop_move") {
            guard let movedNode = engine.findNode(for: token, in: workspaceId),
                  let column = engine.findColumn(containing: movedNode, in: workspaceId)
            else { return }

            movedNode.stopMoveAnimations()

            let anchorColumn = anchorToken
                .flatMap { engine.findNode(for: $0, in: workspaceId) }
                .flatMap { engine.findColumn(containing: $0, in: workspaceId) }

            if let anchorColumn, anchorColumn.id != column.id {
                consumed = engine.consumeWindow(
                    movedNode, into: anchorColumn, enteringFrom: direction,
                    in: workspaceId, motion: .disabled, state: &targetState,
                    workingFrame: workingFrame, gaps: gaps,
                    orientation: orientation
                )
            }

            if !consumed {
                engine.activateWindow(movedNode.id, in: workspaceId)
                targetState.selectedNodeId = movedNode.id
                engine.ensureSelectionVisible(
                    node: movedNode, in: workspaceId, motion: .disabled, state: &targetState,
                    workingFrame: workingFrame, gaps: gaps,
                    orientation: orientation
                )
            }
        }

        targetState.cancelAnimation()

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: targetState,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
    }

    func consumeOrExpelWindow(direction: Direction) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(consumeOrExpelWindow(handle: handle, direction: direction))
    }

    func consumeOrExpelWindow(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .left || direction == .right else { return .unchanged }
        return performStructuralMutation(handle: handle) { ctx, state in
            guard ctx.engine.consumeOrExpelWindow(
                ctx.windowNode,
                direction: direction,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps,
                orientation: ctx.orientation,
                allowEdgeWrap: false
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                movedTokens: [ctx.windowNode.token],
                operation: .windowConsumedOrExpelled(token: ctx.windowNode.token)
            )
        }
    }

    func consumeWindowIntoColumn() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(consumeWindowIntoColumn(containing: handle))
    }

    func consumeWindowIntoColumn(containing handle: WindowHandle) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else {
                return nil
            }
            let projectedColumns = ctx.engine.projectedColumns(in: ctx.wsId)
            guard let projectedIndex = projectedColumns.firstIndex(where: { $0.column === column }),
                  projectedColumns.indices.contains(projectedIndex + 1),
                  let movedToken = projectedColumns[projectedIndex + 1].windows.last?.token
            else { return nil }
            guard ctx.engine.consumeWindowIntoColumn(
                focusedColumn: column,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps,
                orientation: ctx.orientation
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                movedTokens: [movedToken],
                operation: .windowConsumedOrExpelled(token: movedToken)
            )
        }
    }

    func expelWindowFromColumn() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(expelWindowFromColumn(containing: handle))
    }

    func expelWindowFromColumn(containing handle: WindowHandle) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else {
                return nil
            }
            guard let movedToken = ctx.engine.projectedWindows(
                in: column,
                workspaceId: ctx.wsId
            ).first?.token else { return nil }
            guard ctx.engine.expelWindowFromColumn(
                focusedColumn: column,
                in: ctx.wsId,
                motion: ctx.motion,
                state: &state,
                workingFrame: ctx.workingFrame,
                gaps: ctx.gaps,
                orientation: ctx.orientation
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                movedTokens: [movedToken],
                operation: .windowConsumedOrExpelled(token: movedToken)
            )
        }
    }

    func moveColumn(direction: Direction) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumn(containing: handle, direction: direction))
    }

    func moveColumn(
        containing handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .direction(direction))
    }

    func moveColumnToFirst() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumnToFirst(containing: handle))
    }

    func moveColumnToFirst(containing handle: WindowHandle) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .first)
    }

    func moveColumnToLast() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumnToLast(containing: handle))
    }

    func moveColumnToLast(containing handle: WindowHandle) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .last)
    }

    func moveColumn(toOneBasedIndex index: Int) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumn(containing: handle, toOneBasedIndex: index))
    }

    func moveColumnToIndex(_ index: Int) {
        moveColumn(toOneBasedIndex: index)
    }

    func moveColumn(
        containing handle: WindowHandle,
        toOneBasedIndex index: Int
    ) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .index(index))
    }

    private func moveColumn(
        containing handle: WindowHandle,
        target: ColumnMoveTarget
    ) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else { return nil }
            let movedTokens = column.windowNodes.map(\.token)
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            let moved = switch target {
            case let .direction(direction):
                ctx.engine.moveColumn(
                    column,
                    direction: direction,
                    in: ctx.wsId,
                    motion: ctx.motion,
                    state: &state,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                )
            case .first:
                ctx.engine.moveColumnToFirst(
                    column,
                    in: ctx.wsId,
                    motion: ctx.motion,
                    state: &state,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                )
            case .last:
                ctx.engine.moveColumnToLast(
                    column,
                    in: ctx.wsId,
                    motion: ctx.motion,
                    state: &state,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                )
            case let .index(index):
                ctx.engine.moveColumnToIndex(
                    column,
                    index,
                    in: ctx.wsId,
                    motion: ctx.motion,
                    state: &state,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                )
            }
            guard moved else { return nil }
            ctx.prepareCapturedAnimation(oldFrames: oldFrames)
            return NiriStructuralMutation(movedTokens: movedTokens, operation: .columnMoved)
        }
    }

    func moveColumnToIndex(
        containing handle: WindowHandle,
        index: Int
    ) -> StructuralMutationOutcome {
        moveColumn(containing: handle, toOneBasedIndex: index)
    }

    private func windowMoveOutcomeAtEdge(
        for node: NiriWindow,
        direction: Direction,
        engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) -> WindowMoveOutcome {
        guard node.parent is NiriContainer else {
            return .blocked
        }

        if let step = direction.secondaryStep(for: orientation) {
            guard let column = engine.findColumn(containing: node, in: workspaceId) else {
                return .blocked
            }
            let visibleWindows = engine.projectedWindows(in: column, workspaceId: workspaceId)
            guard let index = visibleWindows.firstIndex(where: { $0 === node }) else { return .blocked }
            return visibleWindows.indices.contains(index + step) ? .blocked : .atWorkspaceEdge
        }

        guard let step = direction.primaryStep(for: orientation) else { return .blocked }
        return isAtPrimaryWorkspaceEdge(node, step: step, engine: engine, in: workspaceId)
            ? .atWorkspaceEdge : .blocked
    }

    private func isAtPrimaryWorkspaceEdge(
        _ node: NiriWindow,
        step: Int,
        engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let column = engine.findColumn(containing: node, in: workspaceId),
              engine.projectedWindows(in: column, workspaceId: workspaceId).count == 1
        else {
            return false
        }

        let projectedColumns = engine.projectedColumns(in: workspaceId)
        guard let index = projectedColumns.firstIndex(where: { $0.column === column }) else { return false }
        return step > 0 ? index == projectedColumns.count - 1 : index == 0
    }

    func withNiriWorkspaceContext(
        perform: (
            NiriLayoutEngine,
            WorkspaceDescriptor.ID,
            MotionSnapshot,
            inout ViewportState,
            Monitor,
            CGRect,
            CGFloat,
            Monitor.Orientation
        ) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = resolvedOrientation(for: wsId, monitor: monitor, engine: engine)
        controller.workspaceManager.withNiriViewportState(for: wsId) { state in
            _ = engine.reconcileProjectedSelection(state: &state, in: wsId)
            perform(engine, wsId, motion, &state, monitor, workingFrame, gaps, orientation)
        }
    }

    func withNiriWorkspaceContext(
        for workspaceId: WorkspaceDescriptor.ID,
        perform: (
            NiriLayoutEngine,
            WorkspaceDescriptor.ID,
            MotionSnapshot,
            inout ViewportState,
            Monitor,
            CGRect,
            CGFloat,
            Monitor.Orientation
        ) -> Void
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = resolvedOrientation(for: workspaceId, monitor: monitor, engine: engine)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            _ = engine.reconcileProjectedSelection(state: &state, in: workspaceId)
            perform(engine, workspaceId, motion, &state, monitor, workingFrame, gaps, orientation)
        }
    }

    @discardableResult
    func insertWindow(
        handle: WindowHandle,
        targetHandle: WindowHandle,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) -> Bool {
        guard let controller,
              let sourceEntry = controller.workspaceManager.entry(for: handle.id),
              sourceEntry.workspaceId == workspaceId,
              controller.workspaceManager.handle(for: handle.id) === handle,
              !controller.workspaceManager.isAppHidden(pid: sourceEntry.pid),
              let targetEntry = controller.workspaceManager.entry(for: targetHandle.id),
              targetEntry.workspaceId == workspaceId,
              controller.workspaceManager.handle(for: targetHandle.id) === targetHandle,
              !controller.workspaceManager.isAppHidden(pid: targetEntry.pid)
        else {
            return false
        }
        var didMove = false
        withNiriWorkspaceContext(
            for: workspaceId
        ) { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let sourceNode = engine.findNode(for: handle, in: wsId) else { return }
            guard let target = engine.findNode(for: targetHandle, in: wsId) else { return }
            didMove = engine.insertWindowByMove(
                sourceWindowId: sourceNode.id,
                targetWindowId: target.id,
                position: position,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
        if didMove {
            recordLayoutOperation(.windowInserted(token: handle.id), in: workspaceId, source: source)
        }
        return didMove
    }

    @discardableResult
    func insertWindowInNewColumn(
        handle: WindowHandle,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        sizingPolicy: NiriLayoutEngine.NewContainerSizingPolicy = .workspaceDefault,
        source: WMEventSource = .command
    ) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: handle.id),
              entry.workspaceId == workspaceId,
              controller.workspaceManager.handle(for: handle.id) === handle,
              !controller.workspaceManager.isAppHidden(pid: entry.pid)
        else {
            return false
        }
        var didMove = false
        withNiriWorkspaceContext(
            for: workspaceId
        ) { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard let window = engine.findNode(for: handle, in: wsId) else { return }
            didMove = engine.insertWindowInNewColumn(
                window,
                insertIndex: insertIndex,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                sizingPolicy: sizingPolicy
            )
        }
        if didMove {
            recordLayoutOperation(.windowInserted(token: handle.id), in: workspaceId, source: source)
        }
        return didMove
    }
}

struct NodeActivationOptions {
    var activateWindow: Bool = true
    var ensureVisible: Bool = true
    var preserveViewportAnchor: Bool = false
    var updateTimestamp: Bool = true
    var layoutRefresh: Bool = true
    var axFocus: Bool = true
    var focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    var startAnimation: Bool = true
}

@MainActor private struct NiriOperationContext {
    let controller: WMController
    let engine: NiriLayoutEngine
    let motion: MotionSnapshot
    let wsId: WorkspaceDescriptor.ID
    let windowNode: NiriWindow
    let monitor: Monitor
    let orientation: Monitor.Orientation
    let workingFrame: CGRect
    let gaps: CGFloat

    func preparePredictedAnimation(
        state: ViewportState,
        oldFrames: [WindowToken: CGRect],
        yContainmentFrame: CGRect? = nil
    ) {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?
            .backingScaleFactor ?? 2.0
        let workingArea = WorkingAreaContext(
            workingFrame: workingFrame,
            fullscreenLayoutFrame: controller.fullscreenLayoutFrame(for: monitor),
            viewFrame: monitor.frame,
            scale: scale
        )
        let layoutGaps = LayoutGaps(
            horizontal: gaps,
            vertical: gaps,
            outer: controller.workspaceManager.outerGaps
        )
        let animationTime = (engine.animationClock?.now() ?? CACurrentMediaTime()) + 2.0
        let newFrames = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: layoutGaps,
            state: state,
            workingArea: workingArea,
            animationTime: animationTime
        ).frames
        _ = engine.triggerMoveAnimations(
            in: wsId,
            oldFrames: oldFrames,
            newFrames: newFrames,
            motion: motion,
            yContainmentFrame: yContainmentFrame
        )
    }

    func prepareCapturedAnimation(oldFrames: [WindowToken: CGRect]) {
        let newFrames = engine.captureWindowFrames(in: wsId)
        _ = engine.triggerMoveAnimations(
            in: wsId,
            oldFrames: oldFrames,
            newFrames: newFrames,
            motion: motion
        )
    }
}

extension NiriLayoutHandler: LayoutFocusable, LayoutSizable {}
