// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class WindowActionHandler {
    enum AppUnhideRequestResult {
        case applicationUnavailable
        case requestReportedSent
        case requestReportedNotSent
    }

    private enum RaisableSurfaceBatchKey: Hashable {
        case application(pid_t)
        case ownedApplication
    }

    @MainActor
    private enum RaisableSurface {
        case managed(WindowState)
        case owned(NSWindow)

        var windowId: Int {
            switch self {
            case let .managed(entry):
                entry.windowId
            case let .owned(window):
                window.windowNumber
            }
        }

        var sortPid: pid_t {
            switch self {
            case let .managed(entry):
                entry.pid
            case .owned:
                getpid()
            }
        }

        var batchKey: RaisableSurfaceBatchKey {
            switch self {
            case let .managed(entry):
                .application(entry.pid)
            case .owned:
                .ownedApplication
            }
        }
    }

    private struct FloatingWindowRaisePlan {
        let batches: [[RaisableSurface]]
    }

    weak var controller: WMController?
    private let visibleOwnedWindowsProvider: () -> [NSWindow]
    private let frontOwnedWindow: (NSWindow) -> Void
    private let requestApplicationUnhide: (pid_t) -> AppUnhideRequestResult

    @ObservationIgnored
    private var overviewControllerStorage: OverviewController?
    private var overviewController: OverviewController {
        if let overviewControllerStorage {
            return overviewControllerStorage
        }
        guard let controller else { fatal("WindowActionHandler requires controller") }
        let oc = OverviewController(wmController: controller, motionPolicy: controller.motionPolicy)
        oc.onActivateWindow = { [weak self] handle, workspaceId in
            self?.activateWindowFromOverview(handle: handle, workspaceId: workspaceId)
        }
        oc.onCloseWindow = { [weak self] handle in
            self?.closeWindow(handle: handle) ?? false
        }
        overviewControllerStorage = oc
        return oc
    }

    init(
        controller: WMController,
        visibleOwnedWindowsProvider: @escaping () -> [NSWindow] = {
            OwnedWindowRegistry.shared.visibleWindows(kind: .utility)
        },
        frontOwnedWindow: @escaping (NSWindow) -> Void = { window in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        },
        requestApplicationUnhide: @escaping (pid_t) -> AppUnhideRequestResult = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated
            else {
                return .applicationUnavailable
            }
            return app.unhide() ? .requestReportedSent : .requestReportedNotSent
        }
    ) {
        self.controller = controller
        self.visibleOwnedWindowsProvider = visibleOwnedWindowsProvider
        self.frontOwnedWindow = frontOwnedWindow
        self.requestApplicationUnhide = requestApplicationUnhide
    }

    func openMenuAnywhere() {
        guard controller != nil else { return }
        MenuAnywhereController.shared.showNativeMenu()
    }

    func toggleOverview() {
        overviewController.toggle()
    }

    func handleOverviewHotkey(_ invocation: HotkeyInvocation) -> OverviewHotkeyDisposition {
        overviewControllerStorage?.handleHotkeyInvocation(invocation) ?? .inactive
    }

    func updateOverviewSettings() {
        overviewControllerStorage?.updateSettings()
    }

    func invalidateOverviewDeferredActionsForServiceStop() {
        overviewControllerStorage?.invalidateDeferredActionsForServiceStop()
    }

    func handleOverviewWindowRemoved(_ entry: WindowState) {
        overviewControllerStorage?.handleManagedWindowRemoved(entry)
    }

    func refreshOverviewProjection(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        selectedToken: WindowToken? = nil
    ) {
        let selectedHandle = selectedToken.flatMap { controller?.workspaceManager.handle(for: $0) }
        overviewControllerStorage?.refreshCachedOverviewProjection(
            affectedWorkspaceIds: affectedWorkspaceIds,
            selectedHandle: selectedHandle
        )
    }

    func isOverviewOpen() -> Bool {
        overviewControllerStorage?.isOpen == true
    }

    private func activateWindowFromOverview(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.entry(for: handle) != nil else { return }
        navigateToWindowInternal(token: handle.id, workspaceId: workspaceId)
    }

    func closeWindow(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return false }

        let element = entry.axRef.element
        return MainThreadAXSpanTrace.measure(.closeButtonPress, pid: entry.pid, windowId: entry.windowId) {
            var closeButton: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
               let closeButton,
               CFGetTypeID(closeButton) == AXUIElementGetTypeID()
            {
                return performAXAction(
                    closeButton as! AXUIElement,
                    kAXPressAction as CFString,
                    noteKey: "performPressFailed"
                )
            }
            return false
        } succeeded: { $0 }
    }

    func raiseAllFloatingWindows() {
        guard let controller else { return }
        guard !controller.isLockScreenActive else { return }
        if controller.hasStartedServices {
            guard !controller.isFrontmostAppLockScreen() else { return }
        }

        controller.restoreVisibleWorkspaceInactiveFloatingWindows()
        guard let plan = makeRaiseAllFloatingPlan() else { return }

        for batch in plan.batches {
            for surface in batch {
                controller.performWindowOrdering(windowId: surface.windowId)
            }
            guard let anchor = batch.last else { continue }
            front(surface: anchor)
        }
    }

    func hasRaisableFloatingWindows() -> Bool {
        makeRaiseAllFloatingPlan() != nil || controller?.hasVisibleWorkspaceInactiveFloatingWindows() == true
    }

    private func makeRaiseAllFloatingPlan() -> FloatingWindowRaisePlan? {
        guard let controller else { return nil }

        let managedSurfaces = controller.workspaceManager.visibleWorkspaceIds()
            .flatMap { workspaceId in
                controller.workspaceManager.floatingEntries(in: workspaceId)
            }
            .filter { entry in
                entry.layoutReason == .standard
                    && !controller.workspaceManager.isAppHidden(pid: entry.pid)
                    && !controller.workspaceManager.isHiddenInCorner(entry.token)
            }
            .map(RaisableSurface.managed)
        let ownedSurfaces = visibleOwnedWindowsProvider()
            .filter { $0.windowNumber > 0 }
            .map(RaisableSurface.owned)
        let surfaces = managedSurfaces + ownedSurfaces
        guard !surfaces.isEmpty else { return nil }

        let preferredWindowId = preferredWindowId(in: surfaces)
        let orderedSurfaces = surfaces.sorted { lhs, rhs in
            switch (lhs.windowId == preferredWindowId, rhs.windowId == preferredWindowId) {
            case (true, false):
                return false
            case (false, true):
                return true
            default:
                if lhs.sortPid != rhs.sortPid {
                    return lhs.sortPid < rhs.sortPid
                }
                return lhs.windowId < rhs.windowId
            }
        }

        var surfacesByBatchKey: [RaisableSurfaceBatchKey: [RaisableSurface]] = [:]
        var batchOrder: [RaisableSurfaceBatchKey] = []

        for surface in orderedSurfaces {
            if surfacesByBatchKey[surface.batchKey] == nil {
                batchOrder.append(surface.batchKey)
                surfacesByBatchKey[surface.batchKey] = []
            }
            surfacesByBatchKey[surface.batchKey, default: []].append(surface)
        }

        if let preferredBatchKey = orderedSurfaces.last?.batchKey,
           let focusIndex = batchOrder.firstIndex(of: preferredBatchKey)
        {
            let preferredBatchKey = batchOrder.remove(at: focusIndex)
            batchOrder.append(preferredBatchKey)
        }

        let batches = batchOrder.compactMap { surfacesByBatchKey[$0] }
        return FloatingWindowRaisePlan(batches: batches)
    }

    private func preferredWindowId(in surfaces: [RaisableSurface]) -> Int? {
        guard let controller else { return nil }

        let candidateWindowIds = Set(surfaces.map(\.windowId))
        let preferredOwnedWindowId = (NSApp?.orderedWindows ?? [])
            .map(\.windowNumber)
            .first(where: candidateWindowIds.contains)
            ?? [NSApp?.keyWindow, NSApp?.mainWindow]
            .compactMap { $0?.windowNumber }
            .first(where: candidateWindowIds.contains)
        if let preferredOwnedWindowId {
            return preferredOwnedWindowId
        }

        if let focusedToken = controller.workspaceManager.renderableFocusToken,
           candidateWindowIds.contains(focusedToken.windowId)
        {
            return focusedToken.windowId
        }

        guard let interactionWorkspaceId = controller.activeWorkspace()?.id else { return nil }
        let lastFloatingFocusedToken = controller.workspaceManager.lastFloatingFocusedToken(
            in: interactionWorkspaceId
        )
        guard let lastFloatingFocusedToken,
              candidateWindowIds.contains(lastFloatingFocusedToken.windowId)
        else {
            return nil
        }
        return lastFloatingFocusedToken.windowId
    }

    private func front(surface: RaisableSurface) {
        guard let controller else { return }

        switch surface {
        case let .managed(entry):
            controller.performWindowFronting(
                pid: entry.pid,
                windowId: entry.windowId,
                axRef: entry.axRef
            )
        case let .owned(window):
            frontOwnedWindow(window)
        }
    }

    @discardableResult
    func navigateToWindow(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return false }
        return navigateToWindowInternal(token: handle.id, workspaceId: entry.workspaceId)
    }

    @discardableResult
    func navigateToExplicitlySelectedWindow(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        let destination: AppRevealFocusDestination = controller.workspaceManager
            .scratchpadIndex(for: handle.id)
            .map { .scratchpadWindow(index: $0, monitorId: nil) } ?? .window
        return requestAppRevealIfNeeded(handle: handle, destination: destination)
    }

    @discardableResult
    func revealScratchpadFromBar(
        handle: WindowHandle,
        index: ScratchpadIndex,
        monitorId: Monitor.ID?
    ) -> Bool {
        requestAppRevealIfNeeded(
            handle: handle,
            destination: .scratchpad(index: index, monitorId: monitorId)
        )
    }

    private func requestAppRevealIfNeeded(
        handle: WindowHandle,
        destination: AppRevealFocusDestination
    ) -> Bool {
        func reject(
            _ reason: AppVisibilityTrace.Reason,
            workspaceId: WorkspaceDescriptor.ID? = nil,
            generation: UInt64? = nil
        ) -> Bool {
            AppVisibilityTrace.record(
                .reveal,
                pid: handle.id.pid,
                outcome: .rejected,
                windowId: handle.id.windowId,
                workspaceId: workspaceId,
                generation: generation,
                destination: destination.traceDestination,
                reason: reason
            )
            return false
        }

        guard let controller else {
            return reject(.controllerUnavailable)
        }
        guard let currentHandle = controller.workspaceManager.handle(for: handle.id) else {
            return reject(.handleMissing)
        }
        guard currentHandle === handle else {
            return reject(.handleIdentityChanged)
        }
        guard let entry = controller.workspaceManager.entry(for: handle) else {
            return reject(.entryMissing)
        }
        let pendingApps = pendingAppRevealApplications(
            controller: controller,
            targetPID: entry.pid,
            destination: destination
        )
        guard !pendingApps.isEmpty else {
            return performAppRevealDestination(
                destination,
                token: handle.id,
                workspaceId: entry.workspaceId,
                controller: controller
            )
        }
        guard entry.layoutReason == .standard
            || controller.isManagedWindowSuspendedForNativeFullscreen(entry.token)
        else {
            return reject(
                .ineligibleLayout,
                workspaceId: entry.workspaceId,
                generation: controller.workspaceManager.appVisibilityGeneration(for: entry.pid)
            )
        }
        let intent = controller.intentLedger.beginAppRevealFocus(
            token: entry.token,
            workspaceId: entry.workspaceId,
            handleIdentity: ObjectIdentifier(handle),
            pendingApps: pendingApps,
            focusFingerprint: appRevealFocusFingerprint(controller: controller),
            destination: destination
        )
        var requestFailed = false
        for pid in pendingApps.keys.sorted() {
            let unhideResult = requestApplicationUnhide(pid)
            let traceOutcome: AppVisibilityTrace.Outcome
            let traceReason: AppVisibilityTrace.Reason?
            switch unhideResult {
            case .applicationUnavailable:
                traceOutcome = .failed
                traceReason = .applicationUnavailable
                requestFailed = true
            case .requestReportedSent:
                traceOutcome = .requested
                traceReason = nil
            case .requestReportedNotSent:
                traceOutcome = .indeterminate
                traceReason = .unhideRequestReportedNotSent
            }
            AppVisibilityTrace.record(
                .reveal,
                pid: pid,
                outcome: traceOutcome,
                intentId: intent.id,
                windowId: pid == entry.pid ? entry.windowId : nil,
                workspaceId: entry.workspaceId,
                generation: pendingApps[pid],
                intentGeneration: pendingApps[pid],
                destination: destination.traceDestination,
                reason: traceReason
            )
        }
        guard !requestFailed else {
            controller.intentLedger.cancelAppRevealFocus(intentId: intent.id)
            return false
        }
        return true
    }

    @discardableResult
    func completeAppRevealFocus(intentId: IntentID) -> Bool {
        guard let controller else {
            AppVisibilityTrace.record(
                .reveal,
                outcome: .rejected,
                intentId: intentId,
                reason: .controllerUnavailable
            )
            return false
        }
        guard let intent = controller.intentLedger.openIntent(id: intentId) else {
            AppVisibilityTrace.record(
                .reveal,
                outcome: .rejected,
                intentId: intentId,
                reason: .intentMissing
            )
            return false
        }
        guard case let .appRevealFocus(payload) = intent.kind else {
            controller.intentLedger.cancelAppRevealFocus(intentId: intentId)
            AppVisibilityTrace.record(
                .reveal,
                pid: intent.kind.targetPid,
                outcome: .rejected,
                intentId: intentId,
                reason: .intentKindMismatch
            )
            return false
        }

        func record(
            _ outcome: AppVisibilityTrace.Outcome,
            reason: AppVisibilityTrace.Reason? = nil
        ) {
            AppVisibilityTrace.record(
                .reveal,
                pid: payload.token.pid,
                outcome: outcome,
                intentId: intentId,
                windowId: payload.token.windowId,
                workspaceId: payload.workspaceId,
                generation: controller.workspaceManager.appVisibilityGeneration(for: payload.token.pid),
                destination: payload.destination.traceDestination,
                reason: reason
            )
        }

        func reject(_ reason: AppVisibilityTrace.Reason) -> Bool {
            controller.intentLedger.cancelAppRevealFocus(intentId: intentId)
            record(.rejected, reason: reason)
            return false
        }

        guard controller.intentLedger.newestFocusIntentId() == payload.focusIntentWatermark else {
            return reject(.newerFocusIntent)
        }
        guard appRevealFocusFingerprint(controller: controller) == payload.focusFingerprint else {
            return reject(.focusStateChanged)
        }
        for pid in payload.pendingAppPIDs {
            guard let expectedGeneration = payload.coordinatedAppGenerations[pid] else {
                return reject(.intentNotPending)
            }
            guard !controller.workspaceManager.isAppHidden(pid: pid) else {
                return reject(.stillHidden)
            }
            let generation = controller.workspaceManager.appVisibilityGeneration(for: pid)
            guard generation == expectedGeneration &+ 1 else {
                return reject(.visibilityGenerationChanged)
            }
            guard controller.intentLedger.drainAppRevealFocus(
                intentId: intentId,
                pid: pid,
                appVisibilityGeneration: generation
            ) != nil else {
                return reject(.intentNotPending)
            }
        }
        for (pid, expectedGeneration) in payload.coordinatedAppGenerations {
            guard !controller.workspaceManager.isAppHidden(pid: pid) else {
                return reject(.stillHidden)
            }
            guard controller.workspaceManager.appVisibilityGeneration(for: pid) == expectedGeneration &+ 1 else {
                return reject(.visibilityGenerationChanged)
            }
        }
        guard !controller.workspaceManager.isAppHidden(pid: payload.token.pid) else {
            return reject(.stillHidden)
        }
        guard let handle = controller.workspaceManager.handle(for: payload.token) else {
            return reject(.handleMissing)
        }
        guard ObjectIdentifier(handle) == payload.handleIdentity else {
            return reject(.handleIdentityChanged)
        }
        guard let entry = controller.workspaceManager.entry(for: handle) else {
            return reject(.entryMissing)
        }
        guard entry.pid == payload.token.pid else {
            return reject(.pidChanged)
        }
        guard entry.workspaceId == payload.workspaceId else {
            return reject(.workspaceChanged)
        }
        guard entry.layoutReason == .standard
            || controller.isManagedWindowSuspendedForNativeFullscreen(entry.token)
        else {
            return reject(.ineligibleLayout)
        }
        guard controller.intentLedger.confirmAppRevealFocus(intentId: intentId) != nil else {
            record(.rejected, reason: .intentNotPending)
            return false
        }

        func finish(_ didComplete: Bool) -> Bool {
            record(
                didComplete ? .completed : .failed,
                reason: didComplete ? nil : .navigationFailed
            )
            return didComplete
        }

        switch payload.destination {
        case .window:
            if let originalToken = suspendedNativeFullscreenOriginalToken(
                for: handle.id,
                controller: controller
            ) {
                controller.activateNativeFullscreenPlaceholder(originalToken)
                return finish(true)
            }
            return finish(navigateToWindowInternal(token: handle.id, workspaceId: payload.workspaceId))
        case let .scratchpad(index, monitorId):
            return finish(controller.activateScratchpadFromBar(index: index, on: monitorId) == .executed)
        case let .scratchpadWindow(index, monitorId):
            return finish(
                performSelectedScratchpadReveal(
                    token: handle.id,
                    workspaceId: payload.workspaceId,
                    index: index,
                    monitorId: monitorId,
                    controller: controller
                )
            )
        }
    }

    private func pendingAppRevealApplications(
        controller: WMController,
        targetPID: pid_t,
        destination: AppRevealFocusDestination
    ) -> [pid_t: UInt64] {
        switch destination {
        case .window:
            guard controller.workspaceManager.isAppHidden(pid: targetPID) else { return [:] }
            return [
                targetPID: controller.workspaceManager.appVisibilityGeneration(for: targetPID)
            ]
        case let .scratchpad(index, _),
             let .scratchpadWindow(index, _):
            var pendingApps: [pid_t: UInt64] = [:]
            for token in controller.workspaceManager.scratchpadMembers(in: index) {
                guard let pid = controller.workspaceManager.entry(for: token)?.pid,
                      pendingApps[pid] == nil,
                      controller.workspaceManager.isAppHidden(pid: pid)
                else {
                    continue
                }
                pendingApps[pid] = controller.workspaceManager.appVisibilityGeneration(for: pid)
            }
            return pendingApps
        }
    }

    private func performAppRevealDestination(
        _ destination: AppRevealFocusDestination,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> Bool {
        switch destination {
        case .window:
            navigateToWindowInternal(token: token, workspaceId: workspaceId)
        case let .scratchpad(index, monitorId):
            controller.activateScratchpadFromBar(index: index, on: monitorId) == .executed
        case let .scratchpadWindow(index, monitorId):
            performSelectedScratchpadReveal(
                token: token,
                workspaceId: workspaceId,
                index: index,
                monitorId: monitorId,
                controller: controller
            )
        }
    }

    private func performSelectedScratchpadReveal(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        index: ScratchpadIndex,
        monitorId: Monitor.ID?,
        controller: WMController
    ) -> Bool {
        guard controller.workspaceManager.scratchpadIndex(for: token) == index else {
            return navigateToWindowInternal(token: token, workspaceId: workspaceId)
        }
        return controller.revealScratchpadWindow(token, index: index, on: monitorId) == .executed
    }

    private func appRevealFocusFingerprint(controller: WMController) -> AppRevealFocusFingerprint {
        AppRevealFocusFingerprint(
            selectedManagedToken: controller.workspaceManager.selectedManagedToken,
            pendingFocusedToken: controller.workspaceManager.pendingFocusedToken,
            pendingFocusedWorkspaceId: controller.workspaceManager.pendingFocusedWorkspaceId,
            nativeFocusOwner: controller.workspaceManager.nativeFocusOwner,
            interactionMonitorId: controller.workspaceManager.interactionMonitorId,
            activeWorkspaceIdsByMonitor: Dictionary(
                uniqueKeysWithValues: controller.workspaceManager.monitors.compactMap { monitor in
                    controller.workspaceManager.activeWorkspace(on: monitor.id).map {
                        (monitor.id, $0.id)
                    }
                }
            )
        )
    }

    @discardableResult
    func summonWindowRight(handle: WindowHandle) -> Bool {
        guard let controller,
              let currentWorkspace = controller.activeWorkspace(),
              let focusedToken = controller.workspaceManager.selectedManagedToken,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              focusedEntry.workspaceId == currentWorkspace.id
        else {
            return false
        }

        return summonWindowRight(
            handle: handle,
            anchorToken: focusedToken,
            anchorWorkspaceId: currentWorkspace.id
        )
    }

    @discardableResult
    func summonWindowRight(
        handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let anchorEntry = controller.workspaceManager.entry(for: anchorToken),
              anchorEntry.workspaceId == anchorWorkspaceId,
              !controller.workspaceManager.isAppHidden(pid: anchorEntry.pid),
              let targetEntry = controller.workspaceManager.entry(for: handle),
              !controller.workspaceManager.isAppHidden(pid: targetEntry.pid)
        else {
            return false
        }

        let token = handle.id
        guard token != anchorToken else { return false }

        let targetWorkspaceId = anchorWorkspaceId
        switch layoutType(for: targetWorkspaceId) {
        case .dwindle:
            return summonWindowRightInDwindle(
                token: token,
                sourceWorkspaceId: targetEntry.workspaceId,
                targetWorkspaceId: targetWorkspaceId,
                focusedToken: anchorToken
            )
        case .niri,
             .defaultLayout:
            return summonWindowRightInNiri(
                token: token,
                sourceWorkspaceId: targetEntry.workspaceId,
                targetWorkspaceId: targetWorkspaceId,
                focusedToken: anchorToken
            )
        }
    }

    @discardableResult
    func navigateToWindowInternal(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              let handle = controller.workspaceManager.handle(for: token),
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              !controller.workspaceManager.isAppHidden(pid: entry.pid)
        else {
            return false
        }
        let targetLayoutKind = controller.workspaceManager.activeLayoutKind(for: workspaceId)
        if targetLayoutKind == .niri, controller.niriEngine == nil {
            return false
        }

        let currentWsId = controller.activeWorkspace()?.id

        if workspaceId != currentWsId {
            let wsName = controller.workspaceManager.descriptor(for: workspaceId)?.name ?? ""
            if let result = controller.workspaceManager.focusWorkspace(named: wsName) {
                _ = controller.workspaceManager.setInteractionMonitor(result.monitor.id)
                controller.syncMonitorsToNiriEngine()
            }
        }

        switch targetLayoutKind {
        case .dwindle:
            if !prepareDwindleNavigationTarget(token, workspaceId: workspaceId) {
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: workspaceId,
                        viewportState: nil,
                        rememberedFocusToken: token,
                        plannedSeq: controller.workspaceManager.worldSeq
                    )
                )
            }
        case .niri:
            guard let engine = controller.niriEngine else { return false }
            var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)
            if let niriWindow = engine.findNode(for: token, in: workspaceId) {
                targetState.selectedNodeId = niriWindow.id

                if engine.findColumn(containing: niriWindow, in: workspaceId) != nil,
                   let monitor = controller.workspaceManager.monitor(for: workspaceId)
                {
                    let gap = controller.innerGap(for: monitor)
                    let workingFrame = controller.insetWorkingFrame(for: monitor)
                    let orientation = controller.settings.effectiveOrientation(for: monitor)
                    controller.workspaceManager.withEngineMutationScope {
                        engine.activateWindow(niriWindow.id, in: workspaceId)
                        engine.resolvePrimaryContainerSpans(
                            in: workspaceId,
                            workingFrame: workingFrame,
                            gaps: gap,
                            orientation: orientation
                        )
                        engine.ensureProjectedSelectionVisible(
                            node: niriWindow,
                            in: workspaceId,
                            motion: .disabled,
                            state: &targetState,
                            workingFrame: workingFrame,
                            gaps: gap,
                            orientation: orientation,
                            animationConfig: nil,
                            fromContainerIndex: nil
                        )
                    }
                }
            }

            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: workspaceId,
                    viewportState: targetState,
                    rememberedFocusToken: token,
                    plannedSeq: controller.workspaceManager.worldSeq
                )
            )
        }
        let newestFocusIntentId = controller.intentLedger.newestFocusIntentId()
        let focusTarget: LayoutRefreshController.PostLayoutAction = { [weak controller] in
            guard let controller,
                  controller.activeWorkspace()?.id == workspaceId,
                  controller.workspaceManager.handle(for: handle.id) === handle,
                  controller.workspaceManager.entry(for: handle)?.workspaceId == workspaceId
            else {
                return
            }
            controller.focusWindow(handle.id)
        }
        let focusTargetIfStillCurrent: LayoutRefreshController.PostLayoutAction = { [weak controller] in
            guard let controller,
                  controller.intentLedger.newestFocusIntentId() == newestFocusIntentId
            else {
                return
            }
            focusTarget()
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            reason: .workspaceTransition,
            postLayoutGateWorkspaceIds: [workspaceId],
            postLayout: focusTarget,
            postLayoutInvalidated: focusTargetIfStillCurrent
        )
        return true
    }

    @discardableResult
    private func summonWindowRightInNiri(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken
    ) -> Bool {
        guard let controller,
              let handle = controller.workspaceManager.handle(for: token),
              let engine = controller.niriEngine,
              let focusedNode = engine.findNode(for: focusedToken, in: targetWorkspaceId),
              let focusedColumn = engine.findColumn(containing: focusedNode, in: targetWorkspaceId),
              let focusedColumnIndex = engine.columnIndex(of: focusedColumn, in: targetWorkspaceId)
        else {
            return false
        }

        let insertIndex = focusedColumnIndex + 1
        let sourceLayoutType = layoutType(for: sourceWorkspaceId)

        if sourceWorkspaceId == targetWorkspaceId {
            guard controller.niriLayoutHandler.insertWindowInNewColumn(
                handle: handle,
                insertIndex: insertIndex,
                in: targetWorkspaceId
            ) else {
                return false
            }
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
            return true
        }

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: handle,
            toWorkspaceId: targetWorkspaceId
        ).didMutate else {
            return false
        }

        if sourceLayoutType == .dwindle {
            commitSummonedWindowFocus(
                token: token,
                workspaceId: targetWorkspaceId,
                rememberedFocusToken: focusedToken,
                startNiriScrollAnimation: true
            )
            return true
        }

        guard controller.niriLayoutHandler.insertWindowInNewColumn(
            handle: handle,
            insertIndex: insertIndex,
            in: targetWorkspaceId,
            sizingPolicy: .inheritSource
        ) else {
            return false
        }
        commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId, startNiriScrollAnimation: true)
        return true
    }

    @discardableResult
    private func summonWindowRightInDwindle(
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken
    ) -> Bool {
        guard let controller,
              let engine = controller.dwindleEngine,
              let focusedNode = engine.findNode(for: focusedToken, in: targetWorkspaceId),
              focusedNode.isLeaf
        else {
            return false
        }

        if sourceWorkspaceId == targetWorkspaceId {
            guard controller.workspaceManager.withEngineMutationScope(label: "summon_window", {
                engine.summonWindowRight(token, beside: focusedToken, in: targetWorkspaceId)
            }) else {
                return false
            }
            controller.workspaceManager.recordLayoutOperation(.windowInserted(token: token), in: targetWorkspaceId)
            commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId)
            return true
        }

        _ = controller.dwindleLayoutHandler.activateWindow(
            focusedToken,
            in: targetWorkspaceId,
            layoutRefresh: false,
            focusAfterLayout: false
        )
        controller.workspaceManager.withEngineMutationScope {
            engine.setPreselection(.right, in: targetWorkspaceId)
        }

        guard controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ).didMutate else {
            return false
        }

        commitSummonedWindowFocus(token: token, workspaceId: targetWorkspaceId)
        return true
    }

    private func commitSummonedWindowFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken? = nil,
        startNiriScrollAnimation: Bool = false
    ) {
        guard let controller else { return }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: rememberedFocusToken ?? token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId]
        ) { [weak controller] in
            controller?.focusWindow(token)
        }
        if startNiriScrollAnimation {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    private func layoutType(for workspaceId: WorkspaceDescriptor.ID) -> LayoutType {
        guard let controller,
              let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name
        else {
            return .defaultLayout
        }
        return controller.settings.layoutType(for: workspaceName)
    }

    private func prepareDwindleNavigationTarget(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling,
              entry.layoutReason == .standard,
              controller.dwindleEngine?.findNode(for: token, in: workspaceId) != nil
        else {
            return false
        }

        return controller.dwindleLayoutHandler.activateWindow(
            token,
            in: workspaceId,
            layoutRefresh: false,
            focusAfterLayout: false
        ) != .missing
    }

    @discardableResult
    func focusWorkspaceFromBar(named name: String) -> Bool {
        guard let controller else { return false }
        if let currentWorkspace = controller.activeWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = controller.workspaceManager.focusWorkspace(named: name) else { return false }
        return completeWorkspaceFocusFromBar(result)
    }

    @discardableResult
    func focusWorkspaceFromBar(id workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return false }
        if let currentWorkspace = controller.activeWorkspace() {
            controller.workspaceNavigationHandler.saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let result = controller.workspaceManager.focusWorkspace(id: workspaceId) else { return false }
        return completeWorkspaceFocusFromBar(result)
    }

    private func completeWorkspaceFocusFromBar(
        _ result: (workspace: WorkspaceDescriptor, monitor: Monitor)
    ) -> Bool {
        guard let controller else { return false }
        let focusedToken = controller.resolveAndSetWorkspaceFocusToken(for: result.workspace.id)
        if let focusedToken {
            _ = prepareDwindleNavigationTarget(focusedToken, workspaceId: result.workspace.id)
        }
        controller.layoutRefreshController
            .commitWorkspaceTransition(reason: .workspaceTransition) { [weak controller] in
                if let focusedToken {
                    controller?.focusWindow(focusedToken)
                }
            }
        return true
    }

    @discardableResult
    func focusWindowFromBar(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let handle = controller.workspaceManager.handle(for: token) else { return false }
        return focusWindowFromBar(handle: handle)
    }

    @discardableResult
    func focusWindowFromBar(handle: WindowHandle) -> Bool {
        let navigated = navigateToExplicitlySelectedWindow(handle: handle)
        if navigated,
           let controller,
           let originalToken = suspendedNativeFullscreenOriginalToken(
               for: handle.id,
               controller: controller
           )
        {
            controller.activateNativeFullscreenPlaceholder(originalToken)
        }
        return navigated
    }

    private func suspendedNativeFullscreenOriginalToken(
        for currentToken: WindowToken,
        controller: WMController
    ) -> WindowToken? {
        guard controller.workspaceManager.showsNativeFullscreenPlaceholder(for: currentToken),
              let record = controller.workspaceManager.nativeFullscreenRecord(for: currentToken),
              record.transition == .suspended
        else {
            return nil
        }
        return record.originalToken
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        guard let controller else { return [] }
        var appInfoMap: [String: RunningAppInfo] = [:]

        for entry in controller.workspaceManager.allEntries() {
            guard entry.layoutReason == .standard else { continue }

            let cachedInfo = controller.appInfoCache.info(for: entry.pid)
            let bundleId = cachedInfo?.bundleId
            let key = bundleId ?? "pid:\(entry.pid)"

            if appInfoMap[key] != nil { continue }

            let frame = (AXWindowService.framePreferFast(entry.axRef)) ?? .zero

            appInfoMap[key] = RunningAppInfo(
                id: key,
                pid: entry.pid,
                bundleId: bundleId,
                appName: cachedInfo?.name ?? "Unknown",
                icon: cachedInfo?.icon,
                windowSize: frame.size
            )
        }

        return appInfoMap.values.sorted { $0.appName < $1.appName }
    }
}
