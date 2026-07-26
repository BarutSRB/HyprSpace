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
    private(set) var isSecureInputActive = false

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
        controller.hasStartedServices = true
        controller.reconcileEnabledAndHotkeysState()
        controller.eventIntake.open(sink: controller.eventInterpreter)
        controller.layoutRefreshController.setup()
        controller.axEventHandler.setup()
        controller.axManager.installWorkspaceObservers()
        controller.axManager.onAppLaunched = { [weak controller] app in
            controller?.refreshUnavailableWorkspaceBarIconOverride(
                bundleId: app.bundleIdentifier
            )
            EventIntake.post(.appLaunched)
        }
        for app in NSWorkspace.shared.runningApplications {
            controller.refreshUnavailableWorkspaceBarIconOverride(
                bundleId: app.bundleIdentifier
            )
        }
        controller.axManager.onAppTerminated = { pid in
            EventIntake.post(.appTerminated(pid: pid))
        }
        controller.axManager.onTerminalFrameRefusal = { [weak controller] refusal in
            controller?.axEventHandler.handleTerminalFrameRefusal(refusal)
        }
        controller.axManager.onFrameApplySucceeded = { [weak self] result in
            self?.handleFrameApplySucceeded(result)
        }
        controller.axManager.onManagedWindowBindingFailed = { [weak controller] in
            controller?.layoutRefreshController.requestFullRescan(reason: .staleFullRescan)
        }
        setupWorkspaceObservation()
        controller.mouseEventHandler.setup()
        controller.syncMouseWarpPolicy()
        controller.syncWorkspaceBarRevealMonitor()
        setupDisplayObserver()
        setupAppActivationObserver()
        setupAppDeactivationObserver()
        setupAppHideObservers()
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

    func applyMonitorConfigurationChanged(
        currentMonitors: [Monitor],
        performPostUpdateActions: Bool = true
    ) {
        guard let controller else { return }
        guard !currentMonitors.isEmpty else { return }
        guard currentMonitors.allSatisfy({ $0.frame.width > 1 && $0.frame.height > 1 }) else { return }

        controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
        controller.resetMouseWarpTransientState()
        controller.syncMouseWarpPolicy(for: controller.workspaceManager.monitors)
        guard performPostUpdateActions else { return }

        controller.syncMonitorsToNiriEngine()

        let focusedWsId = controller.workspaceManager.focusedToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWsId)

        controller.layoutRefreshController.requestFullRescan(reason: .monitorConfigurationChanged)
        controller.reapplyQuakeTerminalGeometryForMonitorChange()
    }

    func handleAppTerminated(pid: pid_t) {
        guard let controller else { return }
        controller.axEventHandler.cleanupFocusStateForTerminatedApp(pid: pid)
        let removedEntries = controller.workspaceManager.entries(forPid: pid)
        let scratchpadTokens = Set(removedEntries.compactMap { entry in
            let token = entry.token
            return controller.workspaceManager.isScratchpadToken(token)
                || controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true
                ? token
                : nil
        })
        let affectedWorkspaces = controller.workspaceManager.removeWindowsForApp(pid: pid)
        for entry in removedEntries {
            controller.axManager.removeWindowState(pid: entry.pid, expectedWindow: entry.axRef)
            if scratchpadTokens.contains(entry.token) {
                controller.cleanupScratchpadWindowResources(for: entry.token)
            }
        }
        for workspaceId in affectedWorkspaces {
            if let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
               controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
            {
                controller.ensureFocusedTokenValid(in: workspaceId)
            }
        }
        controller.surfaceReconciler.noteRestackOccurred()
        controller.appInfoCache.evict(pid: pid)
        controller.layoutRefreshController.requestFullRescan(reason: .appTerminated)
    }

    func handleGapsChanged() {
        controller?.layoutRefreshController.requestRelayout(reason: .gapsChanged)
    }

    func handleAppLaunched() {
        controller?.layoutRefreshController.requestFullRescan(reason: .appLaunched)
    }

    func handleUnlockDetected() {
        guard let controller else { return }
        controller.layoutRefreshController.requestFullRescan(reason: .unlock)
        controller.mouseEventHandler.requestMultitouchRevalidation(.unlock)
    }

    func performStartupRefresh() {
        controller?.layoutRefreshController.requestFullRescan(reason: .startup)
    }

    func handleActiveSpaceDidChange() {
        guard let controller else { return }
        let previousCurrentSpaces = currentSpacesByDisplay(controller.workspaceManager.spaceTopology)
        controller.spaceTracker.refresh()
        guard currentSpacesByDisplay(controller.workspaceManager.spaceTopology) != previousCurrentSpaces else {
            return
        }
        controller.workspaceManager.recordReconcileEvent(.activeSpaceChanged(source: .service))
        controller.layoutRefreshController.requestFullRescan(reason: .activeSpaceChanged)
    }

    private func currentSpacesByDisplay(_ topology: SpaceTopology) -> [String: UInt64] {
        topology.displays.reduce(into: [:]) { $0[$1.displayIdentifier] = $1.currentSpaceId }
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
            EventIntake.post(.appHidden(pid: app.processIdentifier))
        }

        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            EventIntake.post(.appUnhidden(pid: app.processIdentifier))
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

        controller.eventIntake.close()
        controller.factResolver.stop()
        controller.deadlineWheel.stop()
        controller.intentLedger.reset()
        clearPendingManagedFocus(controller)
        controller.axManager.onAppLaunched = nil
        controller.axManager.onAppTerminated = nil
        controller.axManager.onTerminalFrameRefusal = nil
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
