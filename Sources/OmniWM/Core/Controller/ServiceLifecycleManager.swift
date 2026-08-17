// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum ActivationEventSource: String, Sendable {
    case focusedWindowChanged
    case workspaceDidActivateApplication
    case cgsFrontAppChanged

    var isAuthoritative: Bool {
        self == .focusedWindowChanged
    }
}

struct NativeSpaceManagedWindowReference: Equatable, Sendable {
    let pid: pid_t
    let windowId: Int
}

enum NativeSpaceInventoryScopeResolver {
    static func scope(
        spaceIds: Set<UInt64>,
        topologies: [SpaceTopology],
        managedWindows: [NativeSpaceManagedWindowReference]
    ) -> RescanScope {
        guard !spaceIds.isEmpty,
              !spaceIds.contains(0),
              !topologies.isEmpty
        else { return .all }

        let currentKnownSpaceIds = Set(
            topologies.last?.displays.flatMap(\.spaceIds) ?? []
        )
        var relevantSpaceIds = spaceIds
        for topology in topologies.dropLast() {
            for display in topology.displays {
                for spaceId in display.spaceIds where !currentKnownSpaceIds.contains(spaceId) {
                    relevantSpaceIds.insert(spaceId)
                }
            }
        }

        var windowIdsByPID: [pid_t: Set<Int>] = [:]
        for window in managedWindows
            where topologies.contains(where: { topology in
                topology.spaceForWindow(window.windowId).map(relevantSpaceIds.contains) == true
            })
        {
            windowIdsByPID[window.pid, default: []].insert(window.windowId)
        }
        return .targeted(
            appPIDs: [],
            nativeSpaceIds: spaceIds,
            nativeSpaceWindowIdsByPID: windowIdsByPID
        )
    }
}

struct NativeSpaceInventoryRequest: Sendable {
    let baseline: SpaceTopology
    private(set) var reason: RefreshReason
    private(set) var includesActiveSpaceChange: Bool
    private(set) var reconcilesWorkspaceMonitorState: Bool

    init(reason: RefreshReason, baseline: SpaceTopology) {
        self.baseline = baseline
        self.reason = reason
        includesActiveSpaceChange = reason == .activeSpaceChanged
        reconcilesWorkspaceMonitorState = reason == .monitorConfigurationChanged
    }

    mutating func merge(reason: RefreshReason) {
        includesActiveSpaceChange =
            includesActiveSpaceChange
                || reason == .activeSpaceChanged
        reconcilesWorkspaceMonitorState =
            reconcilesWorkspaceMonitorState
                || reason == .monitorConfigurationChanged
        switch (self.reason, reason) {
        case (_, .monitorConfigurationChanged),
             (.activeSpaceChanged, .unlock):
            self.reason = reason
        default:
            break
        }
    }

    func resolution(
        for topology: SpaceTopology
    ) -> (recordsActiveSpaceChange: Bool, rescanReason: RefreshReason?) {
        let recordsActiveSpaceChange =
            includesActiveSpaceChange
                && currentSpacesByDisplay(topology) != currentSpacesByDisplay(baseline)
        let rescanReason = reason == .activeSpaceChanged && !recordsActiveSpaceChange
            ? nil
            : reason
        return (recordsActiveSpaceChange, rescanReason)
    }

    private func currentSpacesByDisplay(_ topology: SpaceTopology) -> [String: UInt64] {
        topology.displays.reduce(into: [:]) {
            $0[$1.displayIdentifier] = $1.currentSpaceId
        }
    }
}

@MainActor
final class ServiceLifecycleManager {
    weak var controller: WMController?

    private var displayObserver: DisplayConfigurationObserver?
    private var screenParametersObserver: NSObjectProtocol?
    private var activeDisplayObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var appDeactivationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var permissionCheckerTask: Task<Void, Never>?
    private var topologyInventoryStabilityTask: Task<Void, Never>?
    private var topologyInventoryStabilityGeneration: UInt64 = 0
    private var topologyInventoryRequest: NativeSpaceInventoryRequest?
    private(set) var isSecureInputActive = false
    private static let topologyInventorySampleInterval: Duration = .milliseconds(100)
    private static let topologyInventoryRetryInterval: Duration = .seconds(1)

    init(controller: WMController) {
        self.controller = controller
    }

    func start() {
        guard let controller else { return }
        let initialPermissionGranted = currentAccessibilityPermissionGranted()
        controller.updateAccessibilityPermissionGranted(initialPermissionGranted)
        setupSeparateSpacesObserver()
        maybeStartServices()
        startPermissionMonitoring()
    }

    func restart() {
        stop()
        start()
    }

    private func startPermissionMonitoring() {
        permissionCheckerTask?.cancel()
        permissionCheckerTask = Task { @MainActor [weak self, weak controller] in
            guard let self else { return }
            for await granted in self.accessibilityPermissionStream(initial: true) {
                guard let controller, !Task.isCancelled else { return }

                if granted {
                    controller.updateAccessibilityPermissionGranted(true)
                    self.maybeStartServices()
                } else {
                    _ = self.requestAccessibilityPermission()
                    controller.updateAccessibilityPermissionGranted(false)
                }
            }
        }
    }

    private func maybeStartServices() {
        guard let controller else { return }
        controller.updateDisplaySpacesMode(SkyLight.shared.displaysHaveSeparateSpaces)
        if controller.displaySpacesMode == .disabled {
            if controller.hasStartedServices {
                stop()
                startPermissionMonitoring()
            }
            return
        }
        guard !controller.hasStartedServices,
              controller.desiredEnabled,
              currentAccessibilityPermissionGranted()
        else { return }
        startServices()
    }

    private func setupSeparateSpacesObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            ScreenCoordinateSpace.invalidateCache()
            Task { @MainActor in self?.maybeStartServices() }
        }
    }

    private func startServices() {
        guard let controller, !controller.hasStartedServices else { return }
        if refreshMonitorConfigurationForServiceStart(currentMonitors: Monitor.current()) {
            controller.syncMonitorsToNiriEngine()
        }
        controller.hasStartedServices = true
        controller.reconcileEnabledAndHotkeysState()
        controller.eventIntake.open(sink: controller.eventInterpreter)
        controller.layoutRefreshController.setup()
        controller.axManager.onAppLaunched = { [weak controller] app in
            controller?.refreshUnavailableWorkspaceBarIconOverride(
                bundleId: app.bundleIdentifier
            )
            EventIntake.post(.appLaunched(pid: app.processIdentifier))
        }
        controller.axManager.installWorkspaceObservers()
        let runningApplications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        reconcileStoppedApplicationTerminationsAndResumeTimeouts(
            liveApplicationPIDs: Set(runningApplications.lazy.map(\.processIdentifier))
        )
        controller.axEventHandler.setup()
        for app in runningApplications {
            controller.refreshUnavailableWorkspaceBarIconOverride(
                bundleId: app.bundleIdentifier
            )
        }
        controller.axManager.onTerminalFrameRefusal = { [weak controller] refusal in
            controller?.axEventHandler.handleTerminalFrameRefusal(refusal)
        }
        controller.axManager.onFrameApplyTerminated = { [weak controller] result in
            controller?.mouseEventHandler.handleNativeTitleBarDragFrameApplyTerminated(result)
        }
        controller.axManager.onFrameApplySucceeded = { [weak self] result in
            self?.handleFrameApplySucceeded(result)
        }
        controller.axManager.onManagedWindowBindingFailed = { [weak controller] pid in
            controller?.layoutRefreshController.requestFullRescan(
                reason: .staleFullRescan,
                scope: .targeted(appPIDs: [pid], nativeSpaceIds: [])
            )
        }
        setupWorkspaceObservation()
        controller.mouseEventHandler.setup()
        controller.syncMouseWarpPolicy()
        controller.syncWorkspaceBarRevealMonitor()
        setupDisplayObserver()
        setupAppActivationObserver()
        setupAppDeactivationObserver()
        setupAppHideObservers()
        reconcileHiddenApplications()
        setupSleepWakeObservation()
        controller.workspaceManager.onGapsChanged = { [weak self] in
            self?.handleGapsChanged()
        }

        controller.spaceTracker.start()
        performStartupRefresh()
        startSecureInputMonitor()
        startLockScreenObserver()
    }

    func handleFrameApplySucceeded(_ result: AXFrameApplyResult) {
        guard let controller else { return }
        controller.axEventHandler.clearTerminalFrameFailure(windowId: result.windowId)
        controller.mouseEventHandler.handleNativeTitleBarDragFrameApplySucceeded(result)
        guard result.writeResult.observedFrame != nil, result.confirmedFrame != nil else { return }
        controller.surfaceReconciler.handleVerifiedFrameApplySuccess(result)
    }

    private func startLockScreenObserver() {
        guard let controller else { return }
        controller.lockScreenObserver.onLockDetected = { [weak controller] in
            controller?.isLockScreenActive = true
        }
        controller.lockScreenObserver.onUnlockDetected = { [weak controller] in
            guard let controller else { return }
            controller.isLockScreenActive = false
            controller.serviceLifecycleManager.handleUnlockDetected()
        }
        controller.lockScreenObserver.start()
    }

    private func startSecureInputMonitor() {
        guard let controller else { return }
        controller.secureInputMonitor.start { [weak self] isSecure in
            self?.handleSecureInputChange(isSecure)
        }
    }

    private func handleSecureInputChange(_ isSecure: Bool) {
        guard let controller else { return }
        let didSuppressActiveHotkeys = isSecure && controller.hotkeysEnabled
        isSecureInputActive = isSecure
        controller.reconcileEnabledAndHotkeysState()
        if isSecure {
            controller.resetWorkspaceBarReveal()
            if didSuppressActiveHotkeys {
                SecureInputIndicatorController.shared.show()
            }
        } else {
            SecureInputIndicatorController.shared.hide()
        }
    }

    private func setupDisplayObserver() {
        displayObserver = DisplayConfigurationObserver()
        displayObserver?.setEventHandler { event in
            EventIntake.post(.display(event))
        }
    }

    func handleDisplayEvent(_ event: DisplayConfigurationObserver.DisplayEvent) {
        switch event {
        case let .disconnected(monitorId):
            handleMonitorDisconnect(monitorId: monitorId)
        case .connected,
             .reconfigured:
            break
        }
        handleMonitorConfigurationChanged()
    }

    private func handleMonitorDisconnect(monitorId: Monitor.ID) {
        guard let controller else { return }
        controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: monitorId.displayId,
            migrateAnimations: false
        )

        controller.workspaceManager.withEngineMutationScope {
            controller.niriEngine?.cleanupRemovedMonitor(monitorId)
            controller.dwindleEngine?.cleanupRemovedMonitor(monitorId)
        }
    }

    private func handleMonitorConfigurationChanged() {
        applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
    }

    @discardableResult
    func refreshMonitorConfigurationForServiceStart(currentMonitors: [Monitor]) -> Bool {
        guard let controller else { return false }
        guard isUsableMonitorConfiguration(currentMonitors) else { return false }
        guard controller.workspaceManager.monitors != currentMonitors else { return false }
        controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
        return true
    }

    func applyMonitorConfigurationChanged(
        currentMonitors: [Monitor],
        performPostUpdateActions: Bool = true
    ) {
        guard let controller else { return }
        guard isUsableMonitorConfiguration(currentMonitors) else {
            if performPostUpdateActions {
                scheduleStableTopologyInventory(reason: .monitorConfigurationChanged)
            }
            return
        }

        controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
        controller.resetMouseWarpTransientState()
        controller.syncMouseWarpPolicy(for: controller.workspaceManager.monitors)
        guard performPostUpdateActions else { return }

        controller.syncMonitorsToNiriEngine()
        controller.surfaceReconciler.noteWorldChanged()

        let focusedWsId = controller.workspaceManager.focusedToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWsId)

        scheduleStableTopologyInventory(reason: .monitorConfigurationChanged)
        controller.reapplyQuakeTerminalGeometryForMonitorChange()
    }

    private func isUsableMonitorConfiguration(_ monitors: [Monitor]) -> Bool {
        !monitors.isEmpty
            && monitors.allSatisfy { $0.frame.width > 1 && $0.frame.height > 1 }
    }

    func handleAppTerminated(pid: pid_t, frontmostPID: pid_t? = nil) {
        guard let controller else { return }
        let allEntries = controller.workspaceManager.allEntries()
        if !allEntries.contains(where: { $0.pid == pid }),
           let recovery = controller.intentLedger.openAppTerminationFocusRecovery()?.payload,
           recovery.departingToken.pid == pid,
           recovery.terminationHandled
        {
            return
        }
        let focusRecovery = controller.axEventHandler.beginAppTerminationFocusRecovery(
            pid: pid,
            fallbackPID: frontmostPID
        )
        controller.intentLedger.cancelAppRevealFocus(pid: pid)
        let wasHidden = controller.workspaceManager.isAppHidden(pid: pid)
        if !wasHidden {
            controller.workspaceManager.invalidateAppVisibility(for: pid, source: .service)
        }
        let dependentTargetPIDs = controller.axEventHandler.fullRescanTargetPIDsDepending(
            onTerminatedPID: pid,
            entries: allEntries
        )
        controller.axEventHandler.cleanupFocusStateForTerminatedApp(pid: pid)
        let removedEntries = allEntries.filter { $0.pid == pid }
        let scratchpadTokens = Set(removedEntries.compactMap { entry in
            let token = entry.token
            return controller.workspaceManager.isScratchpadToken(token)
                || controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true
                ? token
                : nil
        })
        let affectedWorkspaces = controller.workspaceManager.removeWindowsForApp(pid: pid)
        if wasHidden {
            controller.axManager.setMacOSAppHidden(
                false,
                pid: pid,
                entries: removedEntries.map { (pid: $0.pid, windowId: $0.windowId) }
            )
            controller.workspaceManager.setAppHidden(false, pid: pid, source: .service)
        }
        for entry in removedEntries {
            controller.mouseEventHandler.discardNativeTitleBarDrag(for: entry.token)
            controller.axManager.removeWindowState(pid: entry.pid, expectedWindow: entry.axRef)
            if scratchpadTokens.contains(entry.token) {
                controller.cleanupScratchpadWindowResources(for: entry.token)
            }
        }
        var focusValidationWorkspaces = affectedWorkspaces
        if let focusRecovery {
            focusValidationWorkspaces.insert(focusRecovery.workspaceId)
        }
        for workspaceId in focusValidationWorkspaces {
            if let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
               controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
            {
                controller.ensureFocusedTokenValid(
                    in: workspaceId,
                    preferredRecoveryToken: focusRecovery?.workspaceId == workspaceId
                        ? focusRecovery?.preferredToken
                        : nil
                )
            }
        }
        controller.surfaceReconciler.noteRestackOccurred()
        controller.appInfoCache.evict(pid: pid)
        if !dependentTargetPIDs.isEmpty {
            controller.layoutRefreshController.requestFullRescan(
                reason: .staleFullRescan,
                scope: .targeted(appPIDs: dependentTargetPIDs, nativeSpaceIds: [])
            )
        }
        if !affectedWorkspaces.isEmpty {
            controller.layoutRefreshController.requestRelayout(
                reason: .appTerminated,
                affectedWorkspaceIds: affectedWorkspaces
            )
        }
    }

    func reconcileStoppedApplicationTerminationsAndResumeTimeouts(liveApplicationPIDs: Set<pid_t>) {
        guard let controller else { return }
        let trackedPIDs = Set(controller.workspaceManager.allEntries().lazy.map(\.pid))
        let terminatedPIDs = trackedPIDs.subtracting(liveApplicationPIDs).sorted()
        if !terminatedPIDs.isEmpty {
            for pid in terminatedPIDs {
                _ = controller.eventIntake.enqueue(
                    .appTerminated(pid: pid, frontmostPID: nil)
                )
            }
            controller.eventIntake.drainNow()
        }
        controller.workspaceManager.resumeNativeFullscreenTransitionTimeouts()
    }

    func handleGapsChanged() {
        controller?.layoutRefreshController.requestRelayout(reason: .gapsChanged)
    }

    func handleAppLaunched(pid: pid_t) {
        controller?.layoutRefreshController.requestFullRescan(
            reason: .appLaunched,
            scope: .targeted(appPIDs: [pid], nativeSpaceIds: [])
        )
    }

    func handleUnlockDetected() {
        guard let controller else { return }
        reconcileHiddenApplications()
        scheduleStableTopologyInventory(reason: .unlock)
        controller.mouseEventHandler.requestMultitouchRevalidation(.unlock)
    }

    func handleSystemWake() {
        guard let controller else { return }
        _ = controller.workspaceManager.recordReconcileEvent(.systemWake(source: .service))
        reconcileHiddenApplications()
        controller.workspaceBarManager.cleanup()
        scheduleStableTopologyInventory(reason: .unlock)
        controller.mouseEventHandler.requestMultitouchRevalidation(.wake)
    }

    func performStartupRefresh() {
        guard let controller else { return }
        controller.surfaceReconciler.noteWorldChanged()
        controller.layoutRefreshController.requestFullRescan(reason: .startup)
    }

    func handleActiveSpaceDidChange() {
        guard let controller else { return }
        scheduleStableTopologyInventory(
            reason: .activeSpaceChanged,
            baseline: controller.workspaceManager.spaceTopology
        )
    }

    private func scheduleStableTopologyInventory(
        reason: RefreshReason,
        baseline: SpaceTopology? = nil
    ) {
        guard let controller else { return }
        if var request = topologyInventoryRequest {
            request.merge(reason: reason)
            topologyInventoryRequest = request
        } else {
            topologyInventoryRequest = NativeSpaceInventoryRequest(
                reason: reason,
                baseline: baseline ?? controller.workspaceManager.spaceTopology
            )
        }
        controller.layoutRefreshController.beginInventoryStabilityBarrier()
        topologyInventoryStabilityGeneration &+= 1
        let generation = topologyInventoryStabilityGeneration
        topologyInventoryStabilityTask?.cancel()
        topologyInventoryStabilityTask = Task { @MainActor [weak self] in
            var gate = NativeSpaceInventoryStabilityGate()
            while !Task.isCancelled {
                guard let self, let controller = self.controller else { return }
                let sample = controller.spaceTracker.currentTopologySample()
                let observation = gate.observe(sample)
                if let topologyToApply = observation.topologyToApply {
                    controller.spaceTracker.refresh(
                        using: topologyToApply,
                        windowMembershipUpdate: .carryForwardKnown,
                        reconcilesNativeFullscreen: false
                    )
                }
                if let authoritativeTopologyToApply = observation.authoritativeTopologyToApply {
                    guard
                        !Task.isCancelled,
                        generation == self.topologyInventoryStabilityGeneration
                    else { return }
                    controller.spaceTracker.refresh(
                        using: authoritativeTopologyToApply,
                        windowMembershipUpdate: .query(preservesKnownOnMissing: true)
                    )
                    guard let request = self.topologyInventoryRequest else { return }
                    let spaceIds = authoritativeTopologyToApply.inventorySpaceIds
                    let scope = NativeSpaceInventoryScopeResolver.scope(
                        spaceIds: spaceIds,
                        topologies: [request.baseline, controller.workspaceManager.spaceTopology],
                        managedWindows: self.managedWindowReferences(controller)
                    )
                    let authoritativeTopology = authoritativeTopologyToApply.topology
                    let resolution = request.resolution(for: authoritativeTopology)
                    self.topologyInventoryStabilityTask = nil
                    self.topologyInventoryRequest = nil
                    if resolution.recordsActiveSpaceChange {
                        controller.workspaceManager.recordReconcileEvent(
                            .activeSpaceChanged(source: .service)
                        )
                    }
                    guard let rescanReason = resolution.rescanReason else {
                        controller.layoutRefreshController.endInventoryStabilityBarrier()
                        return
                    }
                    controller.layoutRefreshController.beginInventoryStabilityBarrier()
                    controller.layoutRefreshController.requestFullRescan(
                        reason: rescanReason,
                        scope: scope,
                        reconcilesWorkspaceMonitorState: request.reconcilesWorkspaceMonitorState
                    )
                    controller.layoutRefreshController.endInventoryStabilityBarrier()
                    return
                }
                if observation.requestsGlobalFallback {
                    guard
                        !Task.isCancelled,
                        generation == self.topologyInventoryStabilityGeneration,
                        let request = self.topologyInventoryRequest
                    else { return }
                    controller.layoutRefreshController.requestFullRescan(
                        reason: .staleFullRescan,
                        scope: .all,
                        reconcilesWorkspaceMonitorState: request.reconcilesWorkspaceMonitorState
                    )
                    controller.layoutRefreshController.releaseInventoryStabilityHold()
                }
                let interval = gate.usesRetryInterval
                    ? Self.topologyInventoryRetryInterval
                    : Self.topologyInventorySampleInterval
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func managedWindowReferences(_ controller: WMController) -> [NativeSpaceManagedWindowReference] {
        controller.workspaceManager.allEntries().map {
            NativeSpaceManagedWindowReference(pid: $0.pid, windowId: $0.windowId)
        }
    }

    private func cancelStableTopologyInventory() {
        topologyInventoryStabilityGeneration &+= 1
        topologyInventoryStabilityTask?.cancel()
        topologyInventoryStabilityTask = nil
        topologyInventoryRequest = nil
        controller?.layoutRefreshController.cancelInventoryStabilityBarrier()
    }

    private func setupWorkspaceObservation() {
        guard controller != nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            EventIntake.post(.activeSpaceChanged)
        }
        activeDisplayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
            object: nil,
            queue: .main
        ) { _ in
            EventIntake.post(.activeSpaceChanged)
        }
    }

    private func setupAppActivationObserver() {
        guard controller != nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            EventIntake.post(.appActivated(pid: app.processIdentifier))
        }
    }

    private func setupAppDeactivationObserver() {
        guard controller != nil else { return }
        appDeactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            EventIntake.post(.appDeactivated(pid: app.processIdentifier))
        }
    }

    private func setupAppHideObservers() {
        guard controller != nil else { return }
        appHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            DiagnosticsEventRecorder.shared.recordLifecycle(
                name: "workspace.appHidden",
                pid: app.processIdentifier
            )
            AppVisibilityTrace.record(
                .notification,
                pid: app.processIdentifier,
                visibility: .hidden,
                outcome: .observed,
                source: .service
            )
            let didEnqueue = EventIntake.post(.appHidden(pid: app.processIdentifier))
            AppVisibilityTrace.record(
                .intake,
                pid: app.processIdentifier,
                visibility: .hidden,
                outcome: didEnqueue ? .enqueued : .dropped,
                reason: didEnqueue ? nil : .intakeClosed,
                source: .service
            )
        }

        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            DiagnosticsEventRecorder.shared.recordLifecycle(
                name: "workspace.appUnhidden",
                pid: app.processIdentifier
            )
            AppVisibilityTrace.record(
                .notification,
                pid: app.processIdentifier,
                visibility: .visible,
                outcome: .observed,
                source: .service
            )
            let didEnqueue = EventIntake.post(.appUnhidden(pid: app.processIdentifier))
            AppVisibilityTrace.record(
                .intake,
                pid: app.processIdentifier,
                visibility: .visible,
                outcome: didEnqueue ? .enqueued : .dropped,
                reason: didEnqueue ? nil : .intakeClosed,
                source: .service
            )
        }
    }

    private func setupSleepWakeObservation() {
        guard controller != nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            EventIntake.post(.systemSleep)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            EventIntake.post(.systemWake)
        }
    }

    func stop() {
        guard let controller else { return }
        controller.hasStartedServices = false
        cancelStableTopologyInventory()

        let hiddenPIDs = controller.workspaceManager.hiddenAppPIDs
        let trackedPIDs = Set(controller.workspaceManager.allEntries().map(\.pid))
        for pid in trackedPIDs.subtracting(hiddenPIDs) {
            controller.workspaceManager.invalidateAppVisibility(for: pid, source: .service)
        }
        for pid in hiddenPIDs {
            let entries = controller.workspaceManager.entries(forPid: pid)
            controller.axManager.setMacOSAppHidden(
                false,
                pid: pid,
                entries: entries.map { (pid: $0.pid, windowId: $0.windowId) }
            )
        }
        controller.workspaceManager.replaceHiddenAppPIDs([], source: .service)

        controller.eventIntake.close()
        controller.factResolver.stop()
        controller.deadlineWheel.stop()
        controller.workspaceManager.cancelNativeFullscreenTransitionTimeouts()
        controller.intentLedger.reset()
        clearPendingManagedFocus(controller)
        controller.axManager.onAppLaunched = nil
        controller.axManager.onTerminalFrameRefusal = nil
        controller.axManager.onFrameApplyTerminated = nil
        controller.axManager.onFrameApplySucceeded = nil
        controller.axManager.onManagedWindowBindingFailed = nil
        controller.workspaceManager.onGapsChanged = nil

        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        controller.resetMouseWarpPolicy()
        controller.axEventHandler.cleanup()

        controller.tabRailManager.removeAll()
        controller.nativeFullscreenPlaceholderManager.removeAll()
        controller.surfaceReconciler.cleanup()
        controller.cleanupUIOnStop()

        controller.axManager.cleanup()

        displayObserver = nil

        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        if let observer = appDeactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appDeactivationObserver = nil
        }
        if let observer = appHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appHideObserver = nil
        }
        if let observer = appUnhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appUnhideObserver = nil
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let observer = activeDisplayObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activeDisplayObserver = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }

        controller.secureInputMonitor.stop()
        isSecureInputActive = false
        SecureInputIndicatorController.shared.hide()
        controller.lockScreenObserver.stop()
        permissionCheckerTask?.cancel()
        permissionCheckerTask = nil
        controller.reconcileEnabledAndHotkeysState()
    }

    private func reconcileHiddenApplications() {
        guard let controller else { return }
        let hiddenPIDs = Set(
            NSWorkspace.shared.runningApplications.lazy
                .filter { !$0.isTerminated && $0.isHidden }
                .map(\.processIdentifier)
        )
        let previousPIDs = controller.workspaceManager.hiddenAppPIDs
        for pid in previousPIDs.subtracting(hiddenPIDs) {
            controller.axEventHandler.handleAppUnhidden(pid: pid, source: .service)
        }
        for pid in hiddenPIDs.subtracting(previousPIDs) {
            controller.axEventHandler.handleAppHidden(pid: pid, source: .service)
        }
    }

    private func clearPendingManagedFocus(_ controller: WMController) {
        let pendingManagedFocus = controller.workspaceManager.reconcileSnapshot().focusSession.pendingManagedFocus
        guard pendingManagedFocus != .empty else { return }
        controller.workspaceManager.recordReconcileEvent(
            .managedFocusCancelled(
                token: nil,
                workspaceId: nil,
                requestId: pendingManagedFocus.requestId,
                source: .service
            )
        )
    }

    private func accessibilityPermissionStream(initial: Bool) -> AsyncStream<Bool> {
        AccessibilityPermissionMonitor.shared.stream(initial: initial)
    }

    private func currentAccessibilityPermissionGranted() -> Bool {
        AccessibilityPermissionMonitor.shared.isGranted
    }

    @discardableResult
    private func requestAccessibilityPermission() -> Bool {
        controller?.axManager.requestPermission() ?? false
    }
}
