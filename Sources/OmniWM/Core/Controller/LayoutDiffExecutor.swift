// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
final class LayoutDiffExecutor {
    private struct DeferredRevealFrameUpdate {
        let pid: pid_t
        let windowId: Int
        let frame: CGRect
        let token: WindowToken
    }

    private unowned let refreshController: LayoutRefreshController

    init(refreshController: LayoutRefreshController) {
        self.refreshController = refreshController
    }

    func execute(_ plan: WorkspaceLayoutPlan) {
        guard let controller = refreshController.controller,
              let monitor = resolveMonitor(from: plan.monitor, controller: controller)
        else {
            return
        }

        let diff = plan.diff

        var resolvedEntries: [WindowToken: WindowState] = [:]
        var hiddenEntries: [(entry: WindowState, side: HideSide)] = []
        var hiddenTokens: Set<WindowToken> = []
        var shownEntries: [(entry: WindowState, hiddenState: HiddenState?)] = []
        var restoreEntries: [(entry: WindowState, hiddenState: HiddenState)] = []
        var restoreTokens: Set<WindowToken> = []
        var frameChangeByToken: [WindowToken: CGRect] = [:]
        var pendingRevealTransactionIdsByToken: [WindowToken: UInt64] = [:]
        var blockedRevealTokens: Set<WindowToken> = []

        for change in diff.frameChanges {
            frameChangeByToken[change.token] = change.frame
        }

        func resolveEntry(for token: WindowToken) -> WindowState? {
            if let cached = resolvedEntries[token] {
                return cached
            }
            guard let entry = controller.workspaceManager.entry(for: token) else {
                return nil
            }
            resolvedEntries[token] = entry
            return entry
        }

        for change in diff.visibilityChanges {
            switch change {
            case let .show(token):
                guard let entry = resolveEntry(for: token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                shownEntries.append((entry, controller.workspaceManager.hiddenState(for: token)))
            case let .hide(token, side):
                hiddenTokens.insert(token)
                guard let entry = resolveEntry(for: token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                hiddenEntries.append((entry, side))
            }
        }

        for change in diff.deferredHides {
            hiddenTokens.insert(change.token)
        }

        func isDeferredReveal(_ token: WindowToken) -> Bool {
            diff.deferredHides.contains { $0.revealToken == token }
        }

        for restoreChange in diff.restoreChanges where !hiddenTokens.contains(restoreChange.token) {
            guard restoreTokens.insert(restoreChange.token).inserted,
                  let entry = resolveEntry(for: restoreChange.token)
            else {
                continue
            }
            guard entry.layoutReason != .nativeFullscreen else { continue }
            restoreEntries.append((entry, restoreChange.hiddenState))
        }

        for (entry, hiddenState) in shownEntries
            where !hiddenTokens.contains(entry.token) && !isDeferredReveal(entry.token)
        {
            guard let hiddenState, restoreTokens.insert(entry.token).inserted else { continue }
            restoreEntries.append((entry, hiddenState))
        }

        for (entry, hiddenState) in restoreEntries {
            guard refreshController.shouldUsePendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState
            ) else {
                continue
            }
            if let targetFrame = frameChangeByToken[entry.token] {
                if let transactionId = refreshController.beginPendingRevealTransaction(
                    for: entry,
                    hiddenState: hiddenState,
                    targetFrame: targetFrame,
                    monitor: monitor
                ) {
                    pendingRevealTransactionIdsByToken[entry.token] = transactionId
                } else {
                    blockedRevealTokens.insert(entry.token)
                }
            } else if refreshController.hasPendingRevealTransaction(for: entry.windowId) {
                blockedRevealTokens.insert(entry.token)
            }
        }

        for (entry, hiddenState) in shownEntries where !restoreTokens.contains(entry.token) {
            guard let hiddenState else { continue }
            guard refreshController.shouldUsePendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState
            ) else {
                continue
            }
            if let targetFrame = frameChangeByToken[entry.token] {
                if let transactionId = refreshController.beginPendingRevealTransaction(
                    for: entry,
                    hiddenState: hiddenState,
                    targetFrame: targetFrame,
                    monitor: monitor
                ) {
                    pendingRevealTransactionIdsByToken[entry.token] = transactionId
                } else {
                    blockedRevealTokens.insert(entry.token)
                }
            } else if refreshController.hasPendingRevealTransaction(for: entry.windowId) {
                blockedRevealTokens.insert(entry.token)
            }
        }

        refreshController.applyLayoutTransientHides(
            hiddenEntries,
            monitor: monitor,
            isAnimationTick: plan.isAnimationTick,
            preserveWorkspaceInactive: !plan.isActiveWorkspace
        )

        if !restoreEntries.isEmpty {
            let restorePlans: [LayoutRefreshController.WindowPositionPlan] = restoreEntries
                .compactMap { entry, hiddenState in
                    guard !blockedRevealTokens.contains(entry.token),
                          pendingRevealTransactionIdsByToken[entry.token] == nil
                    else { return nil }
                    return refreshController.makeRestorePositionPlan(
                        for: entry,
                        monitor: monitor,
                        hiddenState: hiddenState
                    )
                }
            refreshController.applyPositionPlans(restorePlans)

            for (entry, _) in restoreEntries
                where pendingRevealTransactionIdsByToken[entry.token] == nil
                && !blockedRevealTokens.contains(entry.token)
            {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
        }

        if !shownEntries.isEmpty {
            for (entry, _) in shownEntries
                where !restoreTokens.contains(entry.token)
                && pendingRevealTransactionIdsByToken[entry.token] == nil
                && !blockedRevealTokens.contains(entry.token)
                && !isDeferredReveal(entry.token)
            {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
        }

        if !restoreEntries.isEmpty || !shownEntries.isEmpty {
            var visibleJobs: [(pid: pid_t, windowId: Int)] = []
            visibleJobs.reserveCapacity(restoreEntries.count + shownEntries.count)
            var seenTokens: Set<WindowToken> = []

            for (entry, _) in restoreEntries
                where !blockedRevealTokens.contains(entry.token)
                && seenTokens.insert(entry.token).inserted
            {
                visibleJobs.append((entry.pid, entry.windowId))
            }

            for (entry, _) in shownEntries
                where !blockedRevealTokens.contains(entry.token)
                && seenTokens.insert(entry.token).inserted
            {
                visibleJobs.append((entry.pid, entry.windowId))
            }

            if !visibleJobs.isEmpty {
                controller.axManager.unsuppressFrameWrites(visibleJobs)
            }
        }

        var frameUpdates: [AXFrameApplicationTarget] = []
        frameUpdates.reserveCapacity(diff.frameChanges.count)
        var terminalRecoveryFrameUpdates: [AXFrameApplicationTarget] = []
        var revealFrameUpdates: [(
            pid: pid_t,
            window: AXWindowRef,
            frame: CGRect,
            transactionId: UInt64
        )] = []
        revealFrameUpdates.reserveCapacity(pendingRevealTransactionIdsByToken.count)
        var deferredRevealFrameUpdates: [DeferredRevealFrameUpdate] = []
        deferredRevealFrameUpdates.reserveCapacity(diff.deferredHides.count)

        for change in diff.frameChanges {
            guard !hiddenTokens.contains(change.token),
                  let entry = resolveEntry(for: change.token),
                  !blockedRevealTokens.contains(change.token)
            else {
                continue
            }
            guard entry.layoutReason != .nativeFullscreen else { continue }
            if pendingRevealTransactionIdsByToken[change.token] != nil {
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
            }
            if let transactionId = pendingRevealTransactionIdsByToken[change.token] {
                revealFrameUpdates.append((entry.pid, entry.axRef, change.frame, transactionId))
            } else {
                if isDeferredReveal(change.token) {
                    controller.axManager.forceApplyNextFrame(for: entry.windowId)
                    deferredRevealFrameUpdates.append(
                        DeferredRevealFrameUpdate(
                            pid: entry.pid,
                            windowId: entry.windowId,
                            frame: change.frame,
                            token: change.token
                        )
                    )
                    continue
                }
                let forceNativeFullscreenRestoreApply = refreshController
                    .consumeNativeFullscreenRestoredFrameApply(for: change.token)
                if change.forceApply {
                    controller.axManager.forceApplyNextFrame(for: entry.windowId)
                }
                if forceNativeFullscreenRestoreApply {
                    controller.axManager.forceApplyNextFrame(for: entry.windowId)
                }
                let frameUpdate = AXFrameApplicationTarget(
                    pid: entry.pid,
                    window: entry.axRef,
                    frame: change.frame
                )
                if change.allowsTerminalRecovery {
                    terminalRecoveryFrameUpdates.append(frameUpdate)
                } else {
                    frameUpdates.append(frameUpdate)
                }
            }
        }

        applyFrameUpdates(frameUpdates, isAnimationTick: plan.isAnimationTick, controller: controller)
        refreshController.applyWorkspaceMonitorRelocationFrameUpdates(
            terminalRecoveryFrameUpdates,
            workspaceId: plan.workspaceId,
            monitorId: monitor.id,
            controller: controller
        )

        applyDeferredRevealFrames(
            deferredRevealFrameUpdates,
            deferredHides: diff.deferredHides,
            plan: plan,
            monitor: monitor,
            controller: controller
        )

        if !revealFrameUpdates.isEmpty {
            var revealTransactionIdsByWindowId: [Int: UInt64] = [:]
            revealTransactionIdsByWindowId.reserveCapacity(revealFrameUpdates.count)
            for update in revealFrameUpdates {
                refreshController.refreshPendingRevealTransactionPlannedSeq(
                    forWindowId: update.window.windowId,
                    transactionId: update.transactionId
                )
                revealTransactionIdsByWindowId[update.window.windowId] = update.transactionId
            }
            controller.axManager.applyFramesParallel(
                revealFrameUpdates.map {
                    .init(pid: $0.pid, window: $0.window, frame: $0.frame)
                },
                terminalObserver: { [weak refreshController, revealTransactionIdsByWindowId] result in
                    guard let refreshController,
                          let transactionId = revealTransactionIdsByWindowId[result.windowId]
                          ?? refreshController.pendingRevealTransactionId(forWindowId: result.windowId)
                    else {
                        return
                    }
                    refreshController.completePendingRevealTransaction(
                        with: result,
                        transactionId: transactionId
                    )
                }
            )
        }
    }

    private func applyDeferredRevealFrames(
        _ updates: [DeferredRevealFrameUpdate],
        deferredHides: [LayoutDeferredHide],
        plan: WorkspaceLayoutPlan,
        monitor: Monitor,
        controller: WMController
    ) {
        guard !updates.isEmpty else { return }
        for update in updates {
            guard let entry = controller.workspaceManager.entry(for: update.token),
                  let transactionId = refreshController.dwindleHandler.beginPendingGroupRevealTransaction(
                      for: entry,
                      targetFrame: update.frame,
                      monitor: monitor,
                      hides: deferredHides.filter { $0.revealToken == update.token },
                      preserveWorkspaceInactive: !plan.isActiveWorkspace
                  )
            else {
                continue
            }
            controller.axManager.applyFramesParallel(
                [.init(pid: entry.pid, window: entry.axRef, frame: update.frame)],
                terminalObserver: { [weak refreshController] result in
                    refreshController?.dwindleHandler.completePendingGroupRevealTransaction(
                        with: result,
                        transactionId: transactionId
                    )
                }
            )
        }
    }

    private func applyFrameUpdates(
        _ frameUpdates: [AXFrameApplicationTarget],
        isAnimationTick: Bool,
        controller: WMController
    ) {
        guard !frameUpdates.isEmpty else { return }
        let axManager = controller.axManager
        guard isAnimationTick else {
            for update in frameUpdates where axManager.skyLightLivePosition(for: update.windowId) != nil {
                axManager.forceApplyNextFrame(for: update.windowId)
            }
            axManager.applyFramesParallel(frameUpdates, verify: true)
            axManager.clearSkyLightLivePositions()
            return
        }

        axManager.applyFramesParallel(frameUpdates, verify: false)
    }

    private func resolveMonitor(
        from snapshot: LayoutMonitorSnapshot,
        controller: WMController
    ) -> Monitor? {
        if let monitor = controller.workspaceManager.monitor(byId: snapshot.monitorId) {
            return monitor
        }

        return controller.workspaceManager.monitors.first(where: { $0.displayId == snapshot.displayId })
    }
}
