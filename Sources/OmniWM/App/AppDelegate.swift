// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Observation
import OmniWMIPC

struct MonitorSetupPresentationPolicy {
    static func shouldAutomaticallyPresent(
        status: MonitorSetupStatus,
        monitors: [Monitor],
        launchOverlayFinished: Bool
    ) -> Bool {
        status == .notPresented
            && monitors.count >= 2
            && monitors.allSatisfy { $0.frame.width > 1 && $0.frame.height > 1 }
            && launchOverlayFinished
    }
}

@MainActor @Observable
public final class AppBootstrapState {
    var settings: SettingsStore?
    var controller: WMController?
    var updateCoordinator: (any AppUpdateCoordinating)?

    public init() {}

    public var isReady: Bool {
        settings != nil && controller != nil
    }

    public func registerRedirectWindow(_ window: NSWindow) {
        OwnedWindowRegistry.shared.register(window)
    }

    public func unregisterRedirectWindow(_ window: NSWindow) {
        OwnedWindowRegistry.shared.unregister(window)
    }

    public func showSettingsAndCloseRedirectWindow(_ window: NSWindow?) {
        guard let settings, let controller else { return }
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: updateCoordinator
        )
        guard let window else { return }
        unregisterRedirectWindow(window)
        DispatchQueue.main.async {
            window.close()
        }
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public nonisolated(unsafe) weak static var sharedBootstrap: AppBootstrapState?

    override public init() {
        super.init()
    }

    private var statusBarController: StatusBarController?
    private var ipcServer: IPCServerLifecycle?
    private var cliManager: AppCLIManager?
    private var updateCoordinator: (any AppUpdateCoordinating)?
    private var runtimeStateStore: RuntimeStateStore?
    private var launchOverlayController: LaunchOverlayController?
    private var monitorSetupScreenObserver: NSObjectProtocol?
    private var monitorSetupEvaluationTask: Task<Void, Never>?
    private var launchOverlayFinished = false
    private var launchPermissionsWindowController: LaunchPermissionsWindowController?
    private var didFinishBootstrap = false

    public func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        bootstrapApplication()
    }

    public func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    public func applicationWillTerminate(_: Notification) {
        statusBarController?.cleanup()
        if let controller = AppDelegate.sharedBootstrap?.controller {
            controller.serviceLifecycleManager.stop()
            controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        }
        AppDelegate.sharedBootstrap?.settings?.flushNow()
        stopMonitorSetupPresentationObservation()
        stopIPCServer()
        runtimeStateStore?.flushNow()
    }

    func bootstrapApplication() {
        let checker = LaunchConflictChecker()
        LaunchConflictGate.run(
            scan: checker.scan,
            present: presentLaunchConflictAlert,
            onClear: beginPermissionGate,
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }

    private func beginPermissionGate() {
        guard !didFinishBootstrap, launchPermissionsWindowController == nil else { return }

        let windowController = LaunchPermissionsWindowController()
        guard !windowController.snapshot.allGranted else {
            finishBootstrap()
            return
        }

        launchPermissionsWindowController = windowController
        NSApplication.shared.setActivationPolicy(.regular)
        windowController.show(
            onStart: { [weak self] in
                self?.endPermissionGate()
                self?.finishBootstrap()
            },
            onQuit: { [weak self] in
                self?.endPermissionGate()
                NSApplication.shared.terminate(nil)
            }
        )
    }

    private func endPermissionGate() {
        launchPermissionsWindowController = nil
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func finishBootstrap() {
        guard !didFinishBootstrap else { return }
        didFinishBootstrap = true

        let storagePaths = OmniWMStoragePaths.live
        let runtimeState = RuntimeStateStore(directory: storagePaths.stateDirectory)
        self.runtimeStateStore = runtimeState

        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: storagePaths.configDirectory),
            runtimeState: runtimeState
        )
        let hiddenBarController = HiddenBarController(settings: settings)
        let controller = WMController(
            settings: settings,
            hiddenBarController: hiddenBarController,
            clipboardHistoryDirectory: storagePaths.stateDirectory
        )
        controller.applyPersistedSettings(settings)
        let cliManager = AppCLIManager()
        let updateCoordinator = UpdateCoordinator(settings: settings, runtimeState: runtimeState)
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator

        AppDelegate.sharedBootstrap?.settings = settings
        AppDelegate.sharedBootstrap?.controller = controller
        AppDelegate.sharedBootstrap?.updateCoordinator = updateCoordinator

        FatalCapture.install(controllerProvider: { AppDelegate.sharedBootstrap?.controller })
        controller.pendingCrashReport = FatalCapture.consumePending()

        statusBarController = StatusBarController(
            settings: settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            cliManager: cliManager,
            updateCoordinator: updateCoordinator
        )
        controller.statusBarController = statusBarController
        settings.onIPCEnabledChanged = { [weak self, weak controller] isEnabled in
            guard let self, let controller else { return }
            do {
                try self.setIPCEnabled(isEnabled, controller: controller)
            } catch {
                self.presentInfoAlert(
                    title: "IPC Failed to Start",
                    message: error.localizedDescription
                )
                if isEnabled {
                    settings.ipcEnabled = false
                }
            }
        }
        settings.onExternalSettingsReloaded = { [weak controller] in
            guard let controller else { return }
            controller.applyPersistedSettings(settings)
        }
        settings.onConfigNoticeChanged = { [weak controller] in
            controller?.refreshDiagnosticsIssues()
        }
        statusBarController?.setup()
        do {
            try setIPCEnabled(settings.ipcEnabled, controller: controller)
        } catch {
            presentInfoAlert(
                title: "IPC Failed to Start",
                message: error.localizedDescription
            )
            settings.ipcEnabled = false
        }
        updateCoordinator.startAutomaticChecks()

        startMonitorSetupPresentationObservation()
        let overlay = LaunchOverlayController()
        launchOverlayController = overlay
        overlay.play { [weak self] in
            guard let self else { return }
            launchOverlayController = nil
            launchOverlayFinished = true
            scheduleMonitorSetupEvaluation()
        }
    }

    func startIPCServer(controller: WMController) throws {
        if ipcServer != nil {
            stopIPCServer()
        }
        let server = IPCServer(controller: controller)
        try server.start()
        ipcServer = server
    }

    func setIPCEnabled(_ enabled: Bool, controller: WMController) throws {
        if enabled {
            try startIPCServer(controller: controller)
        } else {
            stopIPCServer()
        }
    }

    private func stopIPCServer() {
        ipcServer?.stop()
        ipcServer = nil
    }

    private func startMonitorSetupPresentationObservation() {
        guard monitorSetupScreenObserver == nil else { return }
        monitorSetupScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleMonitorSetupEvaluation()
            }
        }
    }

    private func scheduleMonitorSetupEvaluation() {
        guard launchOverlayFinished else { return }
        monitorSetupEvaluationTask?.cancel()
        monitorSetupEvaluationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.evaluateMonitorSetupPresentation()
        }
    }

    private func evaluateMonitorSetupPresentation() {
        guard let bootstrap = AppDelegate.sharedBootstrap,
              let settings = bootstrap.settings,
              let controller = bootstrap.controller
        else { return }
        let shouldPresent = MonitorSetupPresentationPolicy.shouldAutomaticallyPresent(
            status: settings.monitorSetupStatus,
            monitors: Monitor.current(),
            launchOverlayFinished: launchOverlayFinished
        )
        guard shouldPresent else {
            if settings.monitorSetupStatus != .notPresented {
                stopMonitorSetupPresentationObservation()
            }
            return
        }

        settings.monitorSetupStatus = .dismissed
        stopMonitorSetupPresentationObservation()
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: bootstrap.updateCoordinator,
            presentMonitorSetup: true
        )
    }

    private func stopMonitorSetupPresentationObservation() {
        monitorSetupEvaluationTask?.cancel()
        monitorSetupEvaluationTask = nil
        if let monitorSetupScreenObserver {
            NotificationCenter.default.removeObserver(monitorSetupScreenObserver)
            self.monitorSetupScreenObserver = nil
        }
    }

    private func presentLaunchConflictAlert(
        reason: LaunchConflictBlockReason
    ) -> LaunchConflictGateAction {
        let previousApplication = NSWorkspace.shared.frontmostApplication.flatMap { application in
            application.processIdentifier == getpid() ? nil : application
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch reason {
        case let .conflicts(conflicts):
            alert.messageText = "Conflicting Window Managers Detected"
            alert.informativeText =
                "OmniWM has not started. Quit these window managers or stop their background services, "
                    + "then click Check Again:\n\n"
                    + conflicts.map { "• \($0.displayName)" }.joined(separator: "\n")
        case .scanUnavailable:
            alert.messageText = "Couldn’t Check Running Processes"
            alert.informativeText =
                "OmniWM has not started because it could not safely inspect every running process. "
                    + "Click Check Again to retry, or quit OmniWM."
        }
        alert.addButton(withTitle: "Check Again")
        alert.addButton(withTitle: "Quit OmniWM")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApplication.shared.activate(ignoringOtherApps: true)
        let action: LaunchConflictGateAction = alert.runModal() == .alertFirstButtonReturn ? .checkAgain : .quit
        if action == .checkAgain {
            NSApplication.shared.deactivate()
            if let previousApplication, !previousApplication.isTerminated {
                previousApplication.activate(options: [])
            }
        }
        return action
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }
}
