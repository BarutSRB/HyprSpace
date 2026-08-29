// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
extension AXEventHandler {
    func setup() {
        CGSEventObserver.shared.start()
    }

    func requestTargetedFullRescan(for appPIDs: Set<pid_t>) {
        guard let controller, !appPIDs.isEmpty else { return }
        controller.layoutRefreshController.requestFullRescan(
            reason: .staleFullRescan,
            scope: .targeted(appPIDs: appPIDs, nativeSpaceIds: [])
        )
    }

    func isWorkspaceActive(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId)
        else {
            return false
        }
        return controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
    }

    func rescanAppThatLostFocus() {
        guard let controller else { return }
        let focusedToken = controller.workspaceManager.focusedToken
        // Focus that landed on no tracked window went to a foreign front process, such as a
        // menu bar extra showing its menu. That is not the ordered-out signal, and the
        // rescan's focus recovery would front the tile and cancel that menu. Returning
        // before the memo update keeps the rescan pending for the next real focus change.
        guard focusedToken != nil else { return }
        defer { previouslyFocusedManagedToken = focusedToken }
        guard let previousToken = previouslyFocusedManagedToken,
              previousToken != focusedToken,
              controller.workspaceManager.entry(for: previousToken) != nil
        else { return }
        requestTargetedFullRescan(for: [previousToken.pid])
    }

    static func effectivePlacementOrigin(
        _ placementOrigin: WorkspacePlacementOrigin,
        createPlacementContext: WindowCreatePlacementContext?
    ) -> WorkspacePlacementOrigin {
        createPlacementContext == nil ? placementOrigin : .liveCreate
    }

    func captureCreatePlacementContext(windowId: UInt32, spaceId: UInt64) {
        guard let controller else { return }
        guard pendingCreatePlacementContext(for: Int(windowId))?.nativeSpaceMonitorId == nil else { return }
        let nativeSpaceMonitorId = spaceId == 0
            ? nil
            : resolveNativeSpacePlacementMonitorId(spaceId: spaceId, controller: controller)
        _ = retainedCreatePlacementContext(
            windowId: windowId,
            controller: controller,
            nativeSpaceMonitorId: nativeSpaceMonitorId
        )
    }

    func retainedCreatePlacementContext(
        windowId: UInt32,
        controller: WMController,
        nativeSpaceMonitorId: Monitor.ID? = nil
    ) -> WindowCreatePlacementContext {
        if let context = pendingCreatePlacementContext(for: Int(windowId)) {
            guard context.nativeSpaceMonitorId == nil, let nativeSpaceMonitorId else {
                return context
            }
            let mergedContext = WindowCreatePlacementContext(
                nativeSpaceMonitorId: nativeSpaceMonitorId,
                pendingFocusedWorkspaceId: context.pendingFocusedWorkspaceId,
                pendingFocusedMonitorId: context.pendingFocusedMonitorId,
                focusedWorkspaceId: context.focusedWorkspaceId,
                focusedMonitorId: context.focusedMonitorId,
                interactionWorkspaceId: context.interactionWorkspaceId,
                interactionMonitorId: context.interactionMonitorId,
                createdAt: context.createdAt
            )
            createPlacementContextsByWindowId[windowId] = mergedContext
            return mergedContext
        }
        pruneExpiredCreatePlacementContexts()
        let context = liveCreatePlacementContext(
            controller: controller,
            nativeSpaceMonitorId: nativeSpaceMonitorId
        )
        createPlacementContextsByWindowId[windowId] = context
        return context
    }

    func liveCreatePlacementContext(
        controller: WMController,
        nativeSpaceMonitorId: Monitor.ID? = nil
    ) -> WindowCreatePlacementContext {
        let focusedWorkspaceId = resolveFocusedPlacementWorkspaceId(controller: controller)
        let interactionMonitorId = controller.workspaceManager.interactionMonitorId
        let interactionWorkspaceId = interactionMonitorId.flatMap {
            controller.workspaceManager.activeWorkspaceOrFirst(on: $0)?.id
        }
        return WindowCreatePlacementContext(
            nativeSpaceMonitorId: nativeSpaceMonitorId,
            pendingFocusedWorkspaceId: controller.workspaceManager.pendingFocusedWorkspaceId,
            pendingFocusedMonitorId: resolvePendingFocusedPlacementMonitorId(controller: controller),
            focusedWorkspaceId: focusedWorkspaceId,
            focusedMonitorId: focusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            },
            interactionWorkspaceId: interactionWorkspaceId,
            interactionMonitorId: interactionMonitorId,
            createdAt: Date()
        )
    }

    private func resolvePendingFocusedPlacementMonitorId(
        controller: WMController
    ) -> Monitor.ID? {
        controller.workspaceManager.pendingFocusedMonitorId
            ?? controller.workspaceManager.pendingFocusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            }
    }

    private func resolveFocusedPlacementWorkspaceId(
        controller: WMController
    ) -> WorkspaceDescriptor.ID? {
        guard let focusedToken = controller.workspaceManager.focusedToken,
              let workspaceId = controller.workspaceManager.workspace(for: focusedToken)
        else {
            return nil
        }
        return workspaceId
    }

    private func resolveNativeSpacePlacementMonitorId(
        spaceId: UInt64,
        controller: WMController
    ) -> Monitor.ID? {
        let monitors = controller.workspaceManager.monitors
        let displayId = SkyLight.shared.displayId(forSpaceId: spaceId, among: monitors)
        guard let displayId,
              let monitor = monitors.first(where: { $0.displayId == displayId })
        else {
            return nil
        }

        return monitor.id
    }

    func discardCreatePlacementContext(windowId: UInt32) {
        createPlacementContextsByWindowId.removeValue(forKey: windowId)
    }

    func resetCreatePlacementContextState() {
        createPlacementContextsByWindowId.removeAll()
    }

    func pruneExpiredCreatePlacementContexts(now: Date = Date()) {
        createPlacementContextsByWindowId = createPlacementContextsByWindowId.filter { _, context in
            now.timeIntervalSince(context.createdAt) < Self.createPlacementContextTTL
        }
    }

    func pendingCreatePlacementContext(
        for windowId: Int,
        now: Date = Date()
    ) -> WindowCreatePlacementContext? {
        guard let windowId = UInt32(exactly: windowId) else { return nil }
        guard let context = createPlacementContextsByWindowId[windowId] else { return nil }
        guard now.timeIntervalSince(context.createdAt) < Self.createPlacementContextTTL else {
            createPlacementContextsByWindowId.removeValue(forKey: windowId)
            return nil
        }
        return context
    }

    func discardCreatePlacementContext(for windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        discardCreatePlacementContext(windowId: windowId)
    }

    func recordCreatePlacementTrace(
        token: WindowToken,
        placement: WorkspacePlacementResolution,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        controller: WMController
    ) {
        recordNiriCreateFocusTrace(
            .init(
                kind: .createPlacementResolved(
                    token: token,
                    workspaceId: placement.workspaceId,
                    rung: placement.rung,
                    pendingWorkspaceId: createPlacementContext?.pendingFocusedWorkspaceId,
                    pendingMonitorId: createPlacementContext?.pendingFocusedMonitorId,
                    focusedWorkspaceId: createPlacementContext?.focusedWorkspaceId,
                    focusedMonitorId: createPlacementContext?.focusedMonitorId,
                    nativeSpaceMonitorId: createPlacementContext?.nativeSpaceMonitorId,
                    frameMonitorId: placementTraceMonitorId(for: windowFrame, controller: controller),
                    interactionWorkspaceId: createPlacementContext?.interactionWorkspaceId,
                    interactionMonitorId: createPlacementContext?.interactionMonitorId,
                    ruleSkipReason: placement.ruleSkipReason
                )
            )
        )
    }

    private func placementTraceMonitorId(
        for frame: CGRect?,
        controller: WMController
    ) -> Monitor.ID? {
        guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
        return frame.center.monitorApproximation(in: controller.workspaceManager.monitors)?.id
    }

    func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        windowInfoProvider(windowId)
    }

    func resolveWindowToken(_ windowId: UInt32) -> WindowToken? {
        guard let windowInfo = resolveWindowInfo(windowId) else { return nil }
        return .init(pid: windowInfo.pid, windowId: Int(windowId))
    }

    func resolveTrackedToken(
        _ windowId: UInt32,
        resolvedWindowToken: WindowToken? = nil
    ) -> WindowToken? {
        guard let controller else { return nil }
        if let token = resolvedWindowToken ?? resolveWindowToken(windowId),
           controller.workspaceManager.entry(for: token) != nil
        {
            return token
        }
        return controller.workspaceManager.entry(forWindowId: Int(windowId))?.token
    }

    func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    func subscribeToWindows(_ windowIds: [UInt32]) {
        CGSEventObserver.shared.subscribeToWindows(windowIds)
    }

    func resolveBundleId(_ pid: pid_t) -> String? {
        guard let controller else { return nil }
        return controller.appInfoCache.bundleId(for: pid) ?? NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier
    }
}
