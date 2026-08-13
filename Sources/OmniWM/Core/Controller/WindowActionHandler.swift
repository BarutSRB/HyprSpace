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
        case external(pid: pid_t, windowId: Int, axRef: AXWindowRef)
        case owned(NSWindow)

        var windowId: Int {
            switch self {
            case let .managed(entry):
                entry.windowId
            case let .external(_, windowId, _):
                windowId
            case let .owned(window):
                window.windowNumber
            }
        }

        var sortPid: pid_t {
            switch self {
            case let .managed(entry):
                entry.pid
            case let .external(pid, _, _):
                pid
            case .owned:
                getpid()
            }
        }

        var batchKey: RaisableSurfaceBatchKey {
            switch self {
            case let .managed(entry):
                .application(entry.pid)
            case let .external(pid, _, _):
                .application(pid)
            case .owned:
                .ownedApplication
            }
        }
    }

    private struct FloatingWindowRaisePlan {
        let batches: [[RaisableSurface]]
    }

    weak var controller: WMController?
    private let visibleWindowInfoProvider: () -> [WindowServerInfo]
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
            self?.closeWindowFromOverview(handle: handle) ?? false
        }
        overviewControllerStorage = oc
        return oc
    }

    init(
        controller: WMController,
        visibleWindowInfoProvider: @escaping () -> [WindowServerInfo] = {
            SkyLight.shared.queryAllVisibleWindows()
        },
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
        self.visibleWindowInfoProvider = visibleWindowInfoProvider
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

    func isPointInOverview(_ point: CGPoint) -> Bool {
        overviewController.isPointInside(point)
    }

    private func activateWindowFromOverview(handle: WindowHandle, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.entry(for: handle) != nil else { return }
        navigateToWindowInternal(token: handle.id, workspaceId: workspaceId)
    }

    private func closeWindowFromOverview(handle: WindowHandle) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: handle) else { return false }

        let element = entry.axRef.element
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

    @discardableResult
    func focusCreatedFloatingWindow(_ token: WindowToken) -> Bool {
        guard let controller,
              !controller.isLockScreenActive
        else {
            return false
        }
        if controller.hasStartedServices {
            guard !controller.isFrontmostAppLockScreen() else { return false }
        }

        guard let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .floating,
              entry.layoutReason == .standard,
              entry.interactionPolicy.mayFocus,
              !controller.workspaceManager.isAppHidden(pid: entry.pid),
              !controller.workspaceManager.isHiddenInCorner(token),
              controller.workspaceManager.visibleWorkspaceIds().contains(entry.workspaceId)
        else {
            return false
        }

        controller.focusPolicyEngine.beginLease(
            owner: .ruleCreatedFloatingWindow,
            reason: "floating_window_create",
            suppressesFocusFollowsMouse: true,
            duration: 0.35
        )
        controller.performWindowOrdering(windowId: entry.windowId)
        controller.focusWindow(token)
        return true
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
        var excludedWindowIds = Set(managedSurfaces.map(\.windowId))
        excludedWindowIds.formUnion(ownedSurfaces.map(\.windowId))
        let externalSurfaces = visibleExternalFloatingSurfaces(excludingWindowIds: excludedWindowIds)
        let surfaces = managedSurfaces + ownedSurfaces + externalSurfaces
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

    private func visibleExternalFloatingSurfaces(excludingWindowIds: Set<Int>) -> [RaisableSurface] {
        guard let controller else { return [] }

        var seenWindowIds = excludingWindowIds
        return visibleWindowInfoProvider().compactMap { windowInfo in
            let windowId = Int(windowInfo.id)
            guard seenWindowIds.insert(windowId).inserted else { return nil }
            guard !controller.isOwnedWindow(windowNumber: windowId) else { return nil }

            let pid = pid_t(windowInfo.pid)
            guard controller.workspaceManager.entry(forPid: pid, windowId: windowId) == nil else { return nil }
            guard let axRef = AXWindowService.axWindowRef(for: windowInfo.id, pid: pid) else { return nil }

            let evaluation = controller.evaluateWindowDisposition(
                axRef: axRef,
                pid: pid,
                windowInfo: windowInfo
            )
            guard evaluation.decision.trackedMode == .floating || isWindowServerModalFloating(windowInfo) else {
                return nil
            }

            return .external(pid: pid, windowId: windowId, axRef: axRef)
        }
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

        if let focusedToken = controller.focusedOrFrontmostWindowTokenForAutomation(
            preferFrontmostWhenNonManagedFocusActive: true
        ),
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

    private func isWindowServerModalFloating(_ windowInfo: WindowServerInfo) -> Bool {
        let isFloating = (windowInfo.tags & 0x2) != 0
        let isModal = (windowInfo.tags & 0x8000_0000) != 0
        return isFloating && isModal
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
        case let .external(pid, windowId, axRef):
            controller.performWindowFronting(
                pid: pid,
                windowId: windowId,
                axRef: axRef
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
        let destination: AppRevealFocusDestination =
            controller.workspaceManager.isScratchpadToken(handle.id)
                || controller.workspaceManager.hiddenState(for: handle.id)?.isScratchpad == true
                ? .scratchpad(monitorId: nil)
                : .window
        return requestAppRevealIfNeeded(handle: handle, destination: destination)
    }

    @discardableResult
    func revealScratchpadFromBar(handle: WindowHandle, monitorId: Monitor.ID?) -> Bool {
        requestAppRevealIfNeeded(
            handle: handle,
            destination: .scratchpad(monitorId: monitorId)
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
        guard controller.workspaceManager.isAppHidden(pid: entry.pid) else {
            switch destination {
            case .window:
                return navigateToWindowInternal(token: handle.id, workspaceId: entry.workspaceId)
            case let .scratchpad(monitorId):
                return controller.activateScratchpadFromBar(on: monitorId) == .executed
            }
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
        guard entry.interactionPolicy.mayFocus else {
            return reject(
                .focusDisallowed,
                workspaceId: entry.workspaceId,
                generation: controller.workspaceManager.appVisibilityGeneration(for: entry.pid)
            )
        }

        let appVisibilityGeneration = controller.workspaceManager.appVisibilityGeneration(for: entry.pid)
        let intent = controller.intentLedger.beginAppRevealFocus(
            token: entry.token,
            workspaceId: entry.workspaceId,
            handleIdentity: ObjectIdentifier(handle),
            appVisibilityGeneration: appVisibilityGeneration,
            focusFingerprint: appRevealFocusFingerprint(controller: controller),
            destination: destination
        )
        let unhideResult = requestApplicationUnhide(entry.pid)
        let traceOutcome: AppVisibilityTrace.Outcome
        let traceReason: AppVisibilityTrace.Reason?
        let keepsIntentPending: Bool
        switch unhideResult {
        case .applicationUnavailable:
            traceOutcome = .failed
            traceReason = .applicationUnavailable
            keepsIntentPending = false
        case .requestReportedSent:
            traceOutcome = .requested
            traceReason = nil
            keepsIntentPending = true
        case .requestReportedNotSent:
            traceOutcome = .indeterminate
            traceReason = .unhideRequestReportedNotSent
            keepsIntentPending = true
        }
        AppVisibilityTrace.record(
            .reveal,
            pid: entry.pid,
            outcome: traceOutcome,
            intentId: intent.id,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            generation: appVisibilityGeneration,
            intentGeneration: appVisibilityGeneration,
            destination: destination.traceDestination,
            reason: traceReason
        )
        guard keepsIntentPending else {
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
        guard !controller.workspaceManager.isAppHidden(pid: payload.token.pid) else {
            return reject(.stillHidden)
        }
        guard controller.workspaceManager.appVisibilityGeneration(for: payload.token.pid)
            == payload.appVisibilityGeneration &+ 1
        else {
            return reject(.visibilityGenerationChanged)
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
        guard entry.interactionPolicy.mayFocus else {
            return reject(.focusDisallowed)
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
            if controller.isManagedWindowSuspendedForNativeFullscreen(handle.id) {
                controller.activateNativeFullscreenPlaceholder(handle.id)
                return finish(true)
            }
            return finish(navigateToWindowInternal(token: handle.id, workspaceId: payload.workspaceId))
        case let .scratchpad(monitorId):
            return finish(controller.activateScratchpadFromBar(on: monitorId) == .executed)
        }
    }

    private func appRevealFocusFingerprint(controller: WMController) -> AppRevealFocusFingerprint {
        AppRevealFocusFingerprint(
            focusedToken: controller.workspaceManager.focusedToken,
            pendingFocusedToken: controller.workspaceManager.pendingFocusedToken,
            pendingFocusedWorkspaceId: controller.workspaceManager.pendingFocusedWorkspaceId,
            isNonManagedFocusActive: controller.workspaceManager.isNonManagedFocusActive,
            nonManagedFocusToken: controller.workspaceManager.nonManagedFocusToken,
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
              let focusedToken = controller.workspaceManager.focusedToken,
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
                        targetState.selectionProgress = 0
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
        return navigateToExplicitlySelectedWindow(handle: handle)
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
