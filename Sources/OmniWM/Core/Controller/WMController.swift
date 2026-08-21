// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct WindowFocusOperations {
    let activateApp: (pid_t) -> Void
    let focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let raiseWindow: (AXUIElement) -> Void
    let orderWindow: (UInt32) -> Void

    init(
        activateApp: @escaping (pid_t) -> Void,
        focusSpecificWindow: @escaping (pid_t, UInt32, AXUIElement) -> Void,
        raiseWindow: @escaping (AXUIElement) -> Void,
        orderWindow: @escaping (UInt32) -> Void = { _ in }
    ) {
        self.activateApp = activateApp
        self.focusSpecificWindow = focusSpecificWindow
        self.raiseWindow = raiseWindow
        self.orderWindow = orderWindow
    }

    static let live = WindowFocusOperations(
        activateApp: { pid in
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate(options: [])
            }
        },
        focusSpecificWindow: { pid, windowId, element in
            OmniWM.focusWindow(pid: pid, windowId: windowId, windowRef: element)
        },
        raiseWindow: { element in
            performAXAction(element, kAXRaiseAction as CFString, noteKey: "performRaiseFailed")
        },
        orderWindow: { windowId in
            SkyLight.shared.orderWindow(windowId, relativeTo: 0, order: .above)
        }
    )
}

@MainActor @Observable
final class WMController {
    struct StatusBarWorkspaceSummary: Equatable {
        let monitorId: Monitor.ID
        let workspaceLabel: String
        let workspaceRawName: String
        let focusedAppName: String?
    }

    struct WindowDecisionEvaluation {
        let token: WindowToken
        let facts: WindowRuleFacts
        let decision: WindowDecision
        let appFullscreen: Bool
        let manualOverride: ManualWindowOverride?
    }

    var isEnabled: Bool = true
    var hotkeysEnabled: Bool = true
    private(set) var desiredEnabled: Bool = true
    private(set) var desiredHotkeysEnabled: Bool = true
    private(set) var accessibilityPermissionGranted = AccessibilityPermissionMonitor.shared.isGranted
    private(set) var focusFollowsMouseEnabled: Bool = false
    private(set) var moveMouseToFocusedWindowEnabled: Bool = false
    private(set) var displaySpacesMode: DisplaySpacesMode = .enabled
    private var displaySpacesAlertShown = false
    var pendingCrashReport: FatalCapture.PendingCrashReport?
    var diagnosticsIssues: [DiagnosticsIssue] = []

    let settings: SettingsStore
    let workspaceManager: WorkspaceManager
    let hotkeys = HotkeyCenter()
    private(set) var hotkeyRegistrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
    private(set) var systemHyperTriggerFailure: SystemHyperTriggerFailure?
    var isHyperTriggerActive: Bool {
        hotkeys.isHyperTriggerActive
    }

    let secureInputMonitor = SecureInputMonitor()
    let lockScreenObserver = LockScreenObserver()
    var isLockScreenActive: Bool = false {
        didSet {
            guard isLockScreenActive, oldValue != isLockScreenActive else { return }
            mouseEventHandler.handleInputSuppressionBegan()
        }
    }

    let axManager = AXManager()
    let traceCaptureCoordinator: RuntimeTraceCaptureCoordinator
    let appInfoCache = AppInfoCache()
    let eventIntake = EventIntake()
    let factResolver = FactResolver()
    let intentLedger = IntentLedger()
    let deadlineWheel = DeadlineWheel()
    @ObservationIgnored
    private(set) lazy var eventInterpreter = EventInterpreter(controller: self)
    let focusPolicyEngine: FocusPolicyEngine
    private let restorePlanner = RestorePlanner()
    let windowRuleEngine = WindowRuleEngine()

    var niriEngine: NiriLayoutEngine? {
        get { workspaceManager.niriEngine }
        set { workspaceManager.niriEngine = newValue }
    }

    var dwindleEngine: DwindleLayoutEngine? {
        get { workspaceManager.dwindleEngine }
        set { workspaceManager.dwindleEngine = newValue }
    }

    let tabbedOverlayManager = TabbedColumnOverlayManager()
    @ObservationIgnored
    lazy var nativeFullscreenPlaceholderManager: NativeFullscreenPlaceholderManager = {
        let manager = NativeFullscreenPlaceholderManager()
        manager.onActivate = { [weak self] token in
            self?.activateNativeFullscreenPlaceholder(token)
        }
        return manager
    }()

    @ObservationIgnored
    private(set) lazy var surfaceReconciler = SurfaceReconciler(controller: self)
    @ObservationIgnored
    private(set) lazy var workspaceBarManager: WorkspaceBarManager = .init(motionPolicy: motionPolicy)
    @ObservationIgnored
    private var runtimeFrameJobCancellationSuppressionDepth: Int = 0
    @ObservationIgnored
    private var floatDemotionFirstSamplesByToken: [WindowToken: ContinuousClock.Instant] = [:]
    private static let floatDemotionStabilityInterval: Duration = .milliseconds(300)
    @ObservationIgnored
    private var hiddenWorkspaceBarMonitorIds: Set<Monitor.ID> = []
    @ObservationIgnored
    private let hiddenBarController: HiddenBarController
    @ObservationIgnored
    private lazy var quakeTerminalController: QuakeTerminalController = .init(
        settings: settings,
        motionPolicy: motionPolicy,
        captureRestoreTarget: { [weak self] in
            guard let self else { return nil }
            return self.captureQuakeTerminalRestoreTarget()
        },
        restoreFocusTarget: { [weak self] target in
            self?.restoreQuakeTerminalFocus(to: target)
        },
        focusedWindowScreenProvider: { [weak self] in
            self?.focusedManagedWindowScreenForQuakeTerminal()
        }
    )
    @ObservationIgnored
    private lazy var commandPaletteController: CommandPaletteController = .init(motionPolicy: motionPolicy)
    @ObservationIgnored
    private lazy var sponsorsWindowController: SponsorsWindowController = .init(
        motionPolicy: motionPolicy,
        ownedWindowRegistry: ownedWindowRegistry
    )

    var isTransferringWindow: Bool = false
    var hiddenAppPIDs: Set<pid_t> = []

    @ObservationIgnored
    private(set) lazy var mouseEventHandler = MouseEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var mouseWarpHandler = MouseWarpHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var axEventHandler = AXEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var spaceTracker = SpaceTracker(controller: self)
    @ObservationIgnored
    private(set) lazy var commandHandler = CommandHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var workspaceNavigationHandler = WorkspaceNavigationHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var layoutRefreshController = LayoutRefreshController(controller: self)
    var niriLayoutHandler: NiriLayoutHandler {
        layoutRefreshController.niriHandler
    }

    var dwindleLayoutHandler: DwindleLayoutHandler {
        layoutRefreshController.dwindleHandler
    }

    @ObservationIgnored
    private(set) lazy var serviceLifecycleManager = ServiceLifecycleManager(controller: self)
    @ObservationIgnored
    private(set) lazy var windowActionHandler = WindowActionHandler(
        controller: self,
        orderWindow: windowFocusOperations.orderWindow
    )
    @ObservationIgnored
    private lazy var clipboardHistoryService = ClipboardHistoryService(configuration: clipboardHistoryConfiguration())
    @ObservationIgnored
    private(set) lazy var focusNotificationDispatcher = FocusNotificationDispatcher(controller: self)
    @ObservationIgnored
    var hasStartedServices = false
    @ObservationIgnored
    private(set) var isMouseWarpPolicyEnabled = false
    @ObservationIgnored
    let ownedWindowRegistry: OwnedWindowRegistry
    @ObservationIgnored
    var warpMouseCursorPosition: (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
    @ObservationIgnored
    weak var ipcApplicationBridge: IPCApplicationBridge?

    let animationClock = AnimationClock()
    let motionPolicy: MotionPolicy
    let diagnosticsDirectory: URL
    private let clipboardHistoryDirectory: URL
    private let windowFocusOperations: WindowFocusOperations
    weak var statusBarController: StatusBarController?

    init(
        settings: SettingsStore,
        hiddenBarController: HiddenBarController? = nil,
        clipboardHistoryDirectory: URL = OmniWMStoragePaths.live.stateDirectory,
        diagnosticsDirectory: URL = OmniWMStoragePaths.live.diagnosticsDirectory,
        windowFocusOperations: WindowFocusOperations = .live,
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        self.settings = settings
        motionPolicy = MotionPolicy(animationsEnabled: settings.animationsEnabled)
        self.hiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.clipboardHistoryDirectory = clipboardHistoryDirectory
        self.diagnosticsDirectory = diagnosticsDirectory
        traceCaptureCoordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: diagnosticsDirectory)
        self.windowFocusOperations = windowFocusOperations
        self.ownedWindowRegistry = ownedWindowRegistry
        workspaceManager = WorkspaceManager(settings: settings)
        focusPolicyEngine = FocusPolicyEngine()
        intentLedger.seqProvider = { [eventIntake] in eventIntake.lastSeq }
        intentLedger.deadlineWheel = deadlineWheel
        focusPolicyEngine.intentLedger = intentLedger
        focusPolicyEngine.deadlineWheel = deadlineWheel
        hotkeys.onCommand = { [weak self] command in
            guard let self else { return }
            if !eventIntake.enqueue(.hotkeyCommand(command)) {
                _ = commandHandler.handleHotkeyCommand(command)
            }
        }
        traceCaptureCoordinator.onStateChange = { [weak self] in
            self?.statusBarController?.handleTraceCaptureStateChange()
        }
        tabbedOverlayManager.onSelect = { [weak self] info, visualIndex, token in
            self?.layoutRefreshController.selectTabInNiri(
                info: info,
                visualIndex: visualIndex,
                expectedToken: token
            )
        }
        workspaceManager.onSessionStateChanged = { [weak self] in
            self?.handleSessionStateChanged()
        }
        workspaceManager.onRuntimeInvalidation = { [weak self] workspaceId, domains in
            self?.handleRuntimeInvalidation(workspaceId: workspaceId, domains: domains)
        }
        focusPolicyEngine.onLeaseChanged = { [weak self] lease in
            self?.workspaceManager.recordReconcileEvent(
                .focusLeaseChanged(
                    lease: lease,
                    source: .focusPolicy
                )
            )
        }
        MenuAnywhereController.shared.onMenuTrackingChanged = { [weak self] isTracking in
            guard let self else { return }
            if isTracking {
                self.focusPolicyEngine.beginLease(
                    owner: .nativeMenu,
                    reason: "menu_anywhere",
                    suppressesFocusFollowsMouse: true,
                    duration: nil
                )
            } else {
                self.focusPolicyEngine.endLease(owner: .nativeMenu)
            }
        }
    }

    func applyPersistedSettings(_ settings: SettingsStore, startServices: Bool = true) {
        setAnimationsEnabled(settings.animationsEnabled, persist: false)
        applyCurrentAppearanceMode()

        updateHotkeyBindings(settings.hotkeyBindings)
        setHotkeysEnabled(settings.hotkeysEnabled)

        setGapSize(settings.gapSize)
        setOuterGaps(
            left: settings.outerGapLeft,
            right: settings.outerGapRight,
            top: settings.outerGapTop,
            bottom: settings.outerGapBottom
        )

        if niriEngine == nil {
            enableNiriLayout(
                centerFocusedColumn: settings.niriCenterFocusedColumn,
                alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn
            )
        }
        updateNiriConfig(
            maxVisibleColumns: settings.niriMaxVisibleColumns,
            infiniteLoop: settings.niriInfiniteLoop,
            centerFocusedColumn: settings.niriCenterFocusedColumn,
            alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn,
            singleWindowFit: settings.niriSingleWindowFit,
            columnWidthPresets: settings.niriColumnWidthPresets,
            defaultColumnWidth: settings.niriDefaultColumnWidth
        )

        if dwindleEngine == nil {
            enableDwindleLayout()
        }
        updateDwindleConfig(
            smartSplit: settings.dwindleSmartSplit,
            defaultSplitRatio: settings.dwindleDefaultSplitRatio,
            splitWidthMultiplier: settings.dwindleSplitWidthMultiplier,
            singleWindowFit: settings.dwindleSingleWindowFit
        )

        updateWorkspaceConfig()
        updateMonitorOrientations()
        updateMonitorNiriSettings()
        updateMonitorDwindleSettings()
        updateMonitorGapSettings()
        updateAppRules()

        borderSettingsChanged()

        setFocusFollowsMouse(settings.focusFollowsMouse)
        setMoveMouseToFocusedWindow(settings.moveMouseToFocusedWindow)

        setWorkspaceBarEnabled(settings.workspaceBarEnabled)
        setPreventSleepEnabled(settings.preventSleepEnabled)
        setQuakeTerminalEnabled(settings.quakeTerminalEnabled)
        syncClipboardHistoryService()

        // External edits to settings.toml otherwise stop here at refreshStatusBar
        // and skip subsystems that read settings only at trigger time. Push the
        // remaining live values explicitly so editor saves take effect without
        // an app relaunch.
        quakeTerminalController.applyGeometryToVisibleWindow()
        quakeTerminalController.reloadOpacityConfig()
        updateWorkspaceBarSettings()
        _ = syncMouseWarpPolicy()

        if startServices {
            setEnabled(true)
        }
        refreshStatusBar()
    }

    func setAnimationsEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist, settings.animationsEnabled != enabled {
            settings.animationsEnabled = enabled
        }

        guard motionPolicy.animationsEnabled != enabled else {
            statusBarController?.rebuildMenu()
            return
        }

        motionPolicy.animationsEnabled = enabled
        statusBarController?.rebuildMenu()
    }

    func applyCurrentAppearanceMode() {
        settings.appearanceMode.apply()
        workspaceBarManager.updateAppearance()
        surfaceReconciler.noteWorldChanged()
        statusBarController?.rebuildMenu()
    }

    func setEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        if enabled {
            serviceLifecycleManager.start()
        } else {
            serviceLifecycleManager.stop()
        }
        reconcileEnabledAndHotkeysState()
    }

    func setHotkeysEnabled(_ enabled: Bool) {
        desiredHotkeysEnabled = enabled
        reconcileEnabledAndHotkeysState()
    }

    func setHotkeyRecordingActive(_ active: Bool) {
        hotkeys.setCommandHotkeysSuspended(active)
        refreshHotkeyFailureSnapshots()
    }

    func updateAccessibilityPermissionGranted(_ granted: Bool) {
        accessibilityPermissionGranted = granted
        reconcileEnabledAndHotkeysState()
    }

    func updateDisplaySpacesMode(_ mode: DisplaySpacesMode) {
        guard displaySpacesMode != mode else { return }
        displaySpacesMode = mode
        statusBarController?.rebuildMenu()
        if mode == .disabled, !displaySpacesAlertShown {
            displaySpacesAlertShown = true
            presentSeparateSpacesAlert()
        }
    }

    private func presentSeparateSpacesAlert() {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Enable “Displays have separate Spaces”"
            alert.informativeText = "OmniWM requires the macOS setting “Displays have separate Spaces.” "
                + "Turn it on in System Settings > Desktop & Dock > Mission Control, then log out and back in. "
                + "Window management stays paused until it is enabled."
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        }
    }

    func reconcileEnabledAndHotkeysState() {
        isEnabled = desiredEnabled && accessibilityPermissionGranted

        let shouldEnableHotkeys = desiredHotkeysEnabled
            && isEnabled
            && hasStartedServices
            && !serviceLifecycleManager.isSecureInputActive
        hotkeysEnabled = shouldEnableHotkeys
        shouldEnableHotkeys ? hotkeys.start() : hotkeys.stop()
        refreshHotkeyFailureSnapshots()
    }

    func setGapSize(_ size: Double) {
        workspaceManager.setGaps(to: size)
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        workspaceManager.setOuterGaps(left: left, right: right, top: top, bottom: bottom)
    }

    func borderSettingsChanged() {
        surfaceReconciler.noteWorldChanged()
    }

    func setWorkspaceBarEnabled(_ enabled: Bool) {
        if settings.workspaceBarEnabled != enabled {
            settings.workspaceBarEnabled = enabled
        }
        pruneHiddenWorkspaceBarMonitorIds()
        workspaceBarManager.setup(controller: self, settings: settings)
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
    }

    func cleanupUIOnStop() {
        workspaceBarManager.cleanup()
    }

    func setPreventSleepEnabled(_ enabled: Bool) {
        if enabled {
            SleepPreventionManager.shared.preventSleep()
        } else {
            SleepPreventionManager.shared.allowSleep()
        }
    }

    func toggleHiddenBar() {
        hiddenBarController.toggle()
    }

    @discardableResult
    func toggleWorkspaceBarVisibility() -> Bool {
        pruneHiddenWorkspaceBarMonitorIds()

        guard let monitor = monitorForInteraction() else { return false }
        let resolved = settings.resolvedBarSettings(for: monitor)
        guard resolved.enabled else { return false }

        if hiddenWorkspaceBarMonitorIds.contains(monitor.id) {
            hiddenWorkspaceBarMonitorIds.remove(monitor.id)
        } else {
            hiddenWorkspaceBarMonitorIds.insert(monitor.id)
        }

        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
        return true
    }

    func setQuakeTerminalEnabled(_ enabled: Bool) {
        if enabled {
            quakeTerminalController.setup()
        } else {
            quakeTerminalController.cleanup()
        }
    }

    func toggleQuakeTerminal() {
        guard settings.quakeTerminalEnabled else { return }
        quakeTerminalController.toggle()
    }

    func reloadQuakeTerminalOpacity() {
        quakeTerminalController.reloadOpacityConfig()
    }

    func requestWorkspaceBarRefresh() {
        surfaceReconciler.noteWorldChanged()
    }

    func isManagedWindowDisplayable(_ token: WindowToken) -> Bool {
        guard workspaceManager.entry(for: token) != nil else { return false }
        if hiddenAppPIDs.contains(token.pid) {
            return false
        }
        if workspaceManager.layoutReason(for: token) != .standard {
            return false
        }
        return !workspaceManager.isHiddenInCorner(token)
    }

    func isManagedWindowSuspendedForNativeFullscreen(_ token: WindowToken) -> Bool {
        workspaceManager.isNativeFullscreenSuspended(token)
    }

    func refreshStatusBar() {
        statusBarController?.refreshWorkspaces()
    }

    func activeStatusBarWorkspaceSummary() -> StatusBarWorkspaceSummary? {
        guard let monitor = monitorForInteraction(),
              let workspace = workspaceManager.activeWorkspace(on: monitor.id)
        else {
            return nil
        }

        let focusedAppName: String? = if let focusedToken = workspaceManager.focusedToken,
                                         let entry = workspaceManager.entry(for: focusedToken),
                                         entry.workspaceId == workspace.id
        {
            resolvedAppInfo(for: entry.pid)?.name
        } else {
            nil
        }

        return StatusBarWorkspaceSummary(
            monitorId: monitor.id,
            workspaceLabel: settings.displayName(for: workspace.name),
            workspaceRawName: workspace.name,
            focusedAppName: focusedAppName
        )
    }

    func updateWorkspaceBarSettings() {
        pruneHiddenWorkspaceBarMonitorIds()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
    }

    func updateWorkspaceBarAppearance() {
        workspaceBarManager.updateAppearance()
    }

    func updateMonitorOrientations() {
        var orientations: [Monitor.ID: Monitor.Orientation] = [:]
        for monitor in workspaceManager.monitors {
            orientations[monitor.id] = settings.effectiveOrientation(for: monitor)
        }
        workspaceManager.withEngineMutationScope {
            niriEngine?.updateMonitorOrientations(orientations)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorNiriSettings() {
        guard niriEngine != nil else { return }
        niriLayoutHandler.refreshResolvedMonitorSettings()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorDwindleSettings() {
        guard let engine = dwindleEngine else { return }
        workspaceManager.withEngineMutationScope {
            for monitor in workspaceManager.monitors {
                let resolved = settings.resolvedDwindleSettings(for: monitor)
                engine.updateMonitorSettings(resolved, for: monitor.id)
            }
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorGapSettings() {
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func workspaceBarItems(
        for monitor: Monitor,
        projection options: WorkspaceBarProjectionOptions
    ) -> [WorkspaceBarItem] {
        WorkspaceBarDataSource.workspaceBarItems(
            for: monitor,
            options: options,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            focusedToken: workspaceManager.focusedToken,
            settings: settings
        )
    }

    func workspaceBarProjection(
        for monitor: Monitor,
        projection options: WorkspaceBarProjectionOptions
    ) -> WorkspaceBarProjection {
        WorkspaceBarDataSource.workspaceBarProjection(
            for: monitor,
            options: options,
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            focusedToken: workspaceManager.focusedToken,
            settings: settings
        )
    }

    func focusWorkspaceFromBar(named name: String) {
        windowActionHandler.focusWorkspaceFromBar(named: name)
    }

    func focusWindowFromBar(token: WindowToken) {
        windowActionHandler.focusWindowFromBar(token: token)
    }

    @discardableResult
    func activateScratchpadFromBar(on monitorId: Monitor.ID?) -> ExternalCommandResult {
        guard let scratchpadToken = workspaceManager.scratchpadToken() else {
            return .notFound
        }
        guard let entry = workspaceManager.entry(for: scratchpadToken) else {
            cleanupScratchpadWindowResources(for: scratchpadToken)
            return .notFound
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(scratchpadToken) else {
            return .notFound
        }

        if let monitorId {
            _ = workspaceManager.setInteractionMonitor(monitorId)
        }

        if let hiddenState = workspaceManager.hiddenState(for: scratchpadToken) {
            guard hiddenState.isScratchpad || hiddenState.workspaceInactive,
                  let target = scratchpadTarget(on: monitorId)
            else {
                return .notFound
            }
            let updatedEntry = workspaceManager.entry(for: scratchpadToken) ?? entry
            return showScratchpadWindow(updatedEntry, on: target.workspaceId, monitor: target.monitor)
                ? .executed
                : .notFound
        }

        if windowActionHandler.focusWindowFromBar(token: scratchpadToken) {
            return .executed
        }

        focusWindow(scratchpadToken)
        return .executed
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    func shouldUseMouseWarp(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        return effectiveMonitors.count > 1
    }

    @discardableResult
    func syncMouseWarpPolicy(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        let shouldEnable = shouldUseMouseWarp(for: effectiveMonitors)

        guard shouldEnable != isMouseWarpPolicyEnabled else {
            return shouldEnable
        }

        if shouldEnable {
            mouseWarpHandler.setup()
        } else {
            mouseWarpHandler.cleanup()
        }

        isMouseWarpPolicyEnabled = shouldEnable
        return shouldEnable
    }

    func resetMouseWarpPolicy() {
        mouseWarpHandler.cleanup()
        isMouseWarpPolicyEnabled = false
    }

    func resetMouseWarpTransientState() {
        mouseWarpHandler.resetTransientState()
    }

    func insetWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
        let reservedTopInset = workspaceBarReservedTopInset(for: monitor)
        let gaps = settings.resolvedGapSettings(for: monitor)
        let menuBarInset = max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)
        let struts = Struts(
            left: gaps.outerGapLeft,
            right: gaps.outerGapRight,
            top: normalizedTopStrut(
                top: gaps.outerGapTop,
                menuBarInset: menuBarInset,
                reservedTopInset: reservedTopInset
            ),
            bottom: gaps.outerGapBottom
        )
        return computeWorkingArea(parentArea: monitor.visibleFrame, scale: scale, struts: struts)
    }

    func fullscreenLayoutFrame(for monitor: Monitor) -> CGRect {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
        // Outer gaps still hold here: an external bar at a screen edge overlaps a
        // filled single window just as much as a tiled one.
        let gaps = settings.resolvedGapSettings(for: monitor)
        let struts = Struts(
            left: gaps.outerGapLeft,
            right: gaps.outerGapRight,
            top: workspaceBarReservedTopInset(for: monitor),
            bottom: gaps.outerGapBottom
        )
        return computeWorkingArea(parentArea: monitor.visibleFrame, scale: scale, struts: struts)
    }

    private func workspaceBarReservedTopInset(for monitor: Monitor) -> CGFloat {
        let resolved = settings.resolvedBarSettings(for: monitor)
        return WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: isWorkspaceBarVisible(on: monitor, resolved: resolved)
        ).reservedTopInset
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding], force: Bool = false) {
        hotkeys.updateBindings(
            bindings,
            systemHyperTrigger: settings.systemHyperTrigger,
            force: force
        )
        refreshHotkeyFailureSnapshots()
    }

    private func refreshHotkeyFailureSnapshots() {
        hotkeyRegistrationFailures = hotkeys.registrationFailures
        systemHyperTriggerFailure = hotkeys.systemHyperTriggerFailure
    }

    func updateWorkspaceConfig() {
        workspaceManager.applySettings()
        syncMonitorsToNiriEngine()
        layoutRefreshController.requestFullRescan(reason: .workspaceConfigChanged)
    }

    func rebuildAppRulesCache() {
        windowRuleEngine.rebuild(rules: settings.appRules)
    }

    func updateAppRules() {
        rebuildAppRulesCache()
        layoutRefreshController.requestFullRescan(reason: .appRulesChanged)
    }

    private var workspaceBarRefreshIsEnabled: Bool {
        settings.workspaceBarEnabled || settings.monitorBarSettings.contains(where: { $0.enabled == true })
    }

    private var statusBarRefreshIsEnabled: Bool {
        statusBarController != nil && settings.statusBarShowWorkspaceName
    }

    var hasWorkspaceBarDataConsumers: Bool {
        workspaceBarRefreshIsEnabled
            || statusBarRefreshIsEnabled
            || ipcApplicationBridge?.hasSubscribers(for: .workspaceBar) == true
            || ipcApplicationBridge?.hasSubscribers(for: .windowsChanged) == true
            || ipcApplicationBridge?.hasSubscribers(for: .layoutChanged) == true
    }

    func publishWorkspaceDataChanged() {
        if statusBarRefreshIsEnabled {
            refreshStatusBar()
        }
        if let ipcApplicationBridge {
            Task {
                await ipcApplicationBridge.publishEvent(.workspaceBar)
                await ipcApplicationBridge.publishEvent(.windowsChanged)
                await ipcApplicationBridge.publishEvent(.layoutChanged)
            }
        }
    }

    func isWorkspaceBarVisible(on monitor: Monitor, resolved: ResolvedBarSettings? = nil) -> Bool {
        let effective = resolved ?? settings.resolvedBarSettings(for: monitor)
        return effective.enabled && !hiddenWorkspaceBarMonitorIds.contains(monitor.id)
    }

    private func pruneHiddenWorkspaceBarMonitorIds() {
        hiddenWorkspaceBarMonitorIds = hiddenWorkspaceBarMonitorIds.filter { monitorId in
            guard let monitor = workspaceManager.monitor(byId: monitorId) else { return false }
            return settings.resolvedBarSettings(for: monitor).enabled
        }
    }

    func enableNiriLayout(
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        niriLayoutHandler.enableNiriLayout(
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
    }

    func syncMonitorsToNiriEngine() {
        niriLayoutHandler.syncMonitorsToNiriEngine()
    }

    func updateNiriConfig(
        maxVisibleColumns: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        columnWidthPresets: [Double]? = nil,
        defaultColumnWidth: Double?? = nil
    ) {
        niriLayoutHandler.updateNiriConfig(
            maxVisibleColumns: maxVisibleColumns,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowFit: singleWindowFit,
            columnWidthPresets: columnWidthPresets,
            defaultColumnWidth: defaultColumnWidth
        )
    }

    func balanceNiriSizesAllWorkspaces() {
        niriLayoutHandler.balanceSizesAllWorkspaces()
    }

    func enableDwindleLayout() {
        dwindleLayoutHandler.enableDwindleLayout()
    }

    func updateDwindleConfig(
        smartSplit: Bool? = nil,
        defaultSplitRatio: CGFloat? = nil,
        splitWidthMultiplier: CGFloat? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        innerGap: CGFloat? = nil
    ) {
        dwindleLayoutHandler.updateDwindleConfig(
            smartSplit: smartSplit,
            defaultSplitRatio: defaultSplitRatio,
            splitWidthMultiplier: splitWidthMultiplier,
            singleWindowFit: singleWindowFit,
            innerGap: innerGap
        )
    }

    func monitorForInteraction() -> Monitor? {
        if let interactionMonitorId = workspaceManager.interactionMonitorId,
           let monitor = workspaceManager.monitor(byId: interactionMonitorId)
        {
            return monitor
        }
        if let focusedToken = workspaceManager.focusedToken,
           let workspaceId = workspaceManager.workspace(for: focusedToken),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    private func handleSessionStateChanged() {
        surfaceReconciler.noteWorldChanged()
        let changeSet = focusNotificationDispatcher.notifyFocusChangesIfNeeded()
        if statusBarRefreshIsEnabled {
            refreshStatusBar()
        }
        if let ipcApplicationBridge {
            Task {
                if changeSet.focusChanged {
                    await ipcApplicationBridge.publishEvent(.focus)
                }
                if changeSet.workspaceChanged || changeSet.monitorChanged {
                    await ipcApplicationBridge.publishEvent(.activeWorkspace)
                }
                if changeSet.monitorChanged {
                    await ipcApplicationBridge.publishEvent(.focusedMonitor)
                    await ipcApplicationBridge.publishEvent(.displayChanged)
                }
            }
        }
    }

    private func handleRuntimeInvalidation(
        workspaceId: WorkspaceDescriptor.ID?,
        domains: InvalidationDomain
    ) {
        surfaceReconciler.noteWorldChanged()
        guard domains.contains(.workspace) || domains.contains(.fullscreen) else { return }
        guard runtimeFrameJobCancellationSuppressionDepth == 0 else { return }
        cancelPendingFrameJobsForInvalidation(workspaceId: workspaceId)
    }

    func withRuntimeFrameJobCancellationSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        runtimeFrameJobCancellationSuppressionDepth += 1
        defer { runtimeFrameJobCancellationSuppressionDepth -= 1 }
        return try body()
    }

    func cancelPendingFrameJobsForInvalidation(workspaceId: WorkspaceDescriptor.ID?) {
        let entries = workspaceId.map { workspaceManager.entries(in: $0) } ?? workspaceManager.allEntries()
        guard !entries.isEmpty else { return }
        axManager.cancelPendingFrameJobs(entries.map { ($0.pid, $0.windowId) })
    }

    func activeWorkspace() -> WorkspaceDescriptor? {
        guard let monitor = monitorForInteraction() else { return nil }
        return workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
    }

    func resolveWorkspaceForNewWindow(
        workspaceName: String? = nil,
        axRef: AXWindowRef,
        pid: pid_t,
        parentWindowId: UInt32? = nil,
        inheritTrackedParentWorkspace: Bool = false,
        preferSameAppSiblingWorkspace: Bool = false,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        restrictWorkspaceRuleToPlacementMonitor: Bool = true,
        createPlacementContext: WindowCreatePlacementContext? = nil,
        windowFrame: CGRect? = nil,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID {
        resolveWorkspacePlacement(
            workspaceName: workspaceName,
            axRef: axRef,
            pid: pid,
            parentWindowId: parentWindowId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            preferSameAppSiblingWorkspace: preferSameAppSiblingWorkspace,
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            restrictWorkspaceRuleToPlacementMonitor: restrictWorkspaceRuleToPlacementMonitor,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame,
            existingEntry: nil,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: .automatic
        )
    }

    private struct WorkspacePlacementTarget {
        let workspaceId: WorkspaceDescriptor.ID?
        let monitorId: Monitor.ID?
        let isAuthoritative: Bool
    }

    private func resolveWorkspacePlacement(
        workspaceName: String?,
        axRef: AXWindowRef,
        pid: pid_t?,
        parentWindowId: UInt32?,
        inheritTrackedParentWorkspace: Bool,
        preferSameAppSiblingWorkspace: Bool,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID?,
        restrictWorkspaceRuleToPlacementMonitor: Bool,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        existingEntry: WindowState?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        context: WindowRuleReevaluationContext
    ) -> WorkspaceDescriptor.ID {
        if context == .automatic, let existingEntry {
            return existingEntry.workspaceId
        }

        if existingEntry == nil,
           let structuralReplacementWorkspaceId,
           workspaceManager.descriptor(for: structuralReplacementWorkspaceId) != nil
        {
            return structuralReplacementWorkspaceId
        }

        if existingEntry == nil,
           inheritTrackedParentWorkspace,
           let parentWorkspaceId = workspaceForTrackedParentWindow(parentWindowId: parentWindowId, pid: pid)
        {
            return parentWorkspaceId
        }

        let placementTarget = createPlacementTarget(
            axRef: axRef,
            pid: pid,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame,
            fallbackWorkspaceId: fallbackWorkspaceId,
            preferManagedFocusPlacement: existingEntry == nil && restrictWorkspaceRuleToPlacementMonitor
        )

        if context == .automatic,
           existingEntry == nil,
           preferSameAppSiblingWorkspace,
           let pid,
           let siblingWorkspaceId = workspaceForNewSiblingWindow(
               pid: pid,
               fallbackWorkspaceId: fallbackWorkspaceId,
               targetMonitorId: placementTarget.isAuthoritative ? placementTarget.monitorId : nil
           )
        {
            return siblingWorkspaceId
        }

        if let workspaceName,
           let workspaceId = workspaceManager.workspaceId(for: workspaceName, createIfMissing: false),
           existingEntry != nil ||
           !restrictWorkspaceRuleToPlacementMonitor ||
           shouldApplyWorkspaceRule(workspaceId, placementTarget: placementTarget)
        {
            return workspaceId
        }

        if let existingEntry {
            return existingEntry.workspaceId
        }

        return defaultWorkspaceId(placementTarget: placementTarget)
    }

    private func workspaceForTrackedParentWindow(
        parentWindowId: UInt32?,
        pid _: pid_t?
    ) -> WorkspaceDescriptor.ID? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return workspaceManager.entry(forWindowId: Int(parentWindowId))?.workspaceId
    }

    private func workspaceForNewSiblingWindow(
        pid: pid_t,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        targetMonitorId: Monitor.ID?
    ) -> WorkspaceDescriptor.ID? {
        let entries = workspaceManager.entries(forPid: pid)
        guard let firstEntry = entries.first else { return nil }

        if let focusedToken = workspaceManager.focusedToken,
           let focusedEntry = entries.first(where: { $0.token == focusedToken }),
           workspace(focusedEntry.workspaceId, isOn: targetMonitorId)
        {
            return focusedEntry.workspaceId
        }

        if let fallbackWorkspaceId,
           entries.contains(where: { $0.workspaceId == fallbackWorkspaceId }),
           workspace(fallbackWorkspaceId, isOn: targetMonitorId)
        {
            return fallbackWorkspaceId
        }

        let workspaceId = firstEntry.workspaceId
        guard entries.dropFirst().allSatisfy({ $0.workspaceId == workspaceId }),
              workspace(workspaceId, isOn: targetMonitorId)
        else {
            return nil
        }
        return workspaceId
    }

    private func workspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        isOn targetMonitorId: Monitor.ID?
    ) -> Bool {
        guard let targetMonitorId else { return true }
        return workspaceManager.monitorId(for: workspaceId) == targetMonitorId
    }

    private func floatingSpawnMonitorId(pid: pid_t) -> Monitor.ID? {
        let tiled = workspaceManager.entries(forPid: pid).filter { $0.mode == .tiling }
        guard !tiled.isEmpty else { return nil }

        if let focused = workspaceManager.focusedToken,
           let entry = tiled.first(where: { $0.token == focused }),
           let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        {
            return monitorId
        }

        if let recent = workspaceManager.lastTiledFocusedToken,
           let entry = tiled.first(where: { $0.token == recent }),
           let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        {
            return monitorId
        }

        let monitors = Set(tiled.compactMap { workspaceManager.monitorId(for: $0.workspaceId) })
        return monitors.count == 1 ? monitors.first : nil
    }

    #if DEBUG
        func testFloatingSpawnMonitorId(pid: pid_t) -> Monitor.ID? {
            floatingSpawnMonitorId(pid: pid)
        }
    #endif

    private func shouldApplyWorkspaceRule(
        _ workspaceId: WorkspaceDescriptor.ID,
        placementTarget: WorkspacePlacementTarget
    ) -> Bool {
        guard placementTarget.isAuthoritative,
              let targetMonitorId = placementTarget.monitorId,
              let workspaceMonitorId = workspaceManager.monitorId(for: workspaceId)
        else {
            return true
        }
        return workspaceMonitorId == targetMonitorId
    }

    func shouldInheritTrackedParentWorkspace(for evaluation: WindowDecisionEvaluation) -> Bool {
        let facts = evaluation.facts
        guard let windowServer = facts.windowServer,
              windowServer.parentId != 0
        else {
            return false
        }

        let axFacts = facts.ax
        if axFacts.attributeFetchSucceeded {
            return AXWindowService.isSystemModalSurface(role: axFacts.role, subrole: axFacts.subrole)
        }

        if windowServer.hasDocumentTag {
            return false
        }

        return windowServer.hasModalTag || windowServer.hasTransientSurfaceEvidence
    }

    func shouldPreferSameAppSiblingWorkspace(
        for evaluation: WindowDecisionEvaluation,
        inheritTrackedParentWorkspace: Bool
    ) -> Bool {
        guard let workspaceName = evaluation.decision.workspaceName,
              workspaceManager.workspaceId(for: workspaceName, createIfMissing: false) != nil,
              evaluation.decision.disposition == .managed,
              !inheritTrackedParentWorkspace
        else {
            return false
        }

        let axFacts = evaluation.facts.ax
        guard axFacts.attributeFetchSucceeded,
              axFacts.role == kAXWindowRole as String
        else {
            return false
        }

        return axFacts.subrole == nil || axFacts.subrole == kAXStandardWindowSubrole as String
    }

    private func defaultWorkspaceId(placementTarget: WorkspacePlacementTarget) -> WorkspaceDescriptor.ID {
        if let workspaceId = placementTarget.workspaceId {
            return workspaceId
        }

        if let monitor = monitorForInteraction(),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return workspace.id
        }
        if let workspaceId = workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first?.id {
            return workspaceId
        }
        if let createdWorkspaceId = workspaceManager.workspaceId(for: "1", createIfMissing: false) {
            return createdWorkspaceId
        }
        fatal("resolveWorkspaceForNewWindow: no workspaces exist")
    }

    private func createPlacementTarget(
        axRef: AXWindowRef,
        pid: pid_t?,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        preferManagedFocusPlacement: Bool
    ) -> WorkspacePlacementTarget {
        if preferManagedFocusPlacement {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.pendingFocusedWorkspaceId,
                createPlacementContext?.pendingFocusedMonitorId
            ) {
                return target
            }

            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId
            ) {
                return target
            }
        }

        if let monitorId = createPlacementContext?.nativeSpaceMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true
            )
        }

        if !preferManagedFocusPlacement,
           let pid,
           let monitorId = floatingSpawnMonitorId(pid: pid),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true
            )
        }

        if let monitor = monitorForPlacementFrame(windowFrame),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitor.id,
                isAuthoritative: true
            )
        }

        if workspaceManager.monitors.count > 1,
           let monitor = monitorForPlacementFrame(AXWindowService.framePreferFast(axRef)),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitor.id,
                isAuthoritative: true
            )
        }

        if !preferManagedFocusPlacement {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.pendingFocusedWorkspaceId,
                createPlacementContext?.pendingFocusedMonitorId
            ) {
                return target
            }

            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId
            ) {
                return target
            }
        }

        if let monitorId = createPlacementContext?.interactionMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true
            )
        }

        if let fallbackWorkspaceId,
           workspaceManager.descriptor(for: fallbackWorkspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: fallbackWorkspaceId,
                monitorId: workspaceManager.monitorId(for: fallbackWorkspaceId),
                isAuthoritative: false
            )
        }

        return WorkspacePlacementTarget(
            workspaceId: nil,
            monitorId: nil,
            isAuthoritative: false
        )
    }

    private func managedFocusPlacementTarget(
        _ workspaceId: WorkspaceDescriptor.ID?,
        _ monitorId: Monitor.ID?
    ) -> WorkspacePlacementTarget? {
        if let workspaceId,
           workspaceManager.descriptor(for: workspaceId) != nil
        {
            let resolvedMonitorId = workspaceManager.monitorId(for: workspaceId) ?? monitorId
            return WorkspacePlacementTarget(
                workspaceId: workspaceId,
                monitorId: resolvedMonitorId,
                isAuthoritative: true
            )
        }

        if let monitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true
            )
        }

        return nil
    }

    private func monitorForPlacementFrame(_ frame: CGRect?) -> Monitor? {
        guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
        return frame.center.monitorApproximation(in: workspaceManager.monitors)
    }

    private func resolvedAppInfo(for pid: pid_t) -> AppInfoCache.AppInfo? {
        appInfoCache.info(for: pid) ?? NSRunningApplication(processIdentifier: pid).map {
            AppInfoCache.AppInfo(
                name: $0.localizedName,
                bundleId: $0.bundleIdentifier,
                icon: $0.icon,
                activationPolicy: $0.activationPolicy
            )
        }
    }

    func adoptObservedSizeAfterTerminalFrameRefusal(_ refusal: AXFrameTerminalRefusal) {
        let token = WindowToken(pid: refusal.pid, windowId: refusal.windowId)
        guard let entry = workspaceManager.entry(for: token),
              entry.mode == .tiling,
              workspaceManager.hiddenState(for: token) == nil
        else {
            return
        }

        let target = refusal.targetFrame.size
        let observed = refusal.observedFrame.size
        let observedMin = CGSize(
            width: observed.width > target.width + FrameTolerance.frameWrite ? observed.width : 1,
            height: observed.height > target.height + FrameTolerance.frameWrite ? observed.height : 1
        )
        guard observedMin.width > 1 || observedMin.height > 1 else { return }

        guard workspaceManager.setObservedMinSize(observedMin, for: token) else { return }
        layoutRefreshController.requestRelayout(
            reason: .observedConstraintsChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func evaluateSizeConstraints(
        for token: WindowToken,
        axRef: AXWindowRef
    ) -> WindowSizeConstraints {
        if let cached = workspaceManager.cachedConstraints(for: token) {
            return cached
        }

        let currentSize = AXWindowService.framePreferFast(axRef)?.size
            ?? axManager.lastAppliedFrame(for: token.windowId)?.size
        let resolved = AXWindowService.sizeConstraints(axRef, currentSize: currentSize)
        workspaceManager.setCachedConstraints(resolved, for: token)
        return resolved
    }

    private func liveFrame(for entry: WindowState) -> CGRect? {
        AXWindowService.framePreferFast(entry.axRef)
            ?? axManager.lastAppliedFrame(for: entry.windowId)
            ?? (try? AXWindowService.frame(entry.axRef))
    }

    private func floatingPlacementMonitor(
        for entry: WindowState,
        preferredMonitor: Monitor? = nil,
        frame: CGRect? = nil
    ) -> Monitor? {
        if let preferredMonitor {
            return preferredMonitor
        }
        if let interactionMonitor = monitorForInteraction() {
            return interactionMonitor
        }
        if let workspaceMonitor = workspaceManager.monitor(for: entry.workspaceId) {
            return workspaceMonitor
        }
        if let frame,
           let approximatedMonitor = frame.center.monitorApproximation(in: workspaceManager.monitors)
        {
            return approximatedMonitor
        }
        return workspaceManager.monitors.first
    }

    private func clampedFloatingFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGRect {
        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height
        let clampedX = min(max(frame.origin.x, visibleFrame.minX), max(maxX, visibleFrame.minX))
        let clampedY = min(max(frame.origin.y, visibleFrame.minY), max(maxY, visibleFrame.minY))
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: frame.size)
    }

    private func initialFloatingFrame(
        for entry: WindowState,
        preferredMonitor: Monitor?
    ) -> CGRect? {
        guard let frame = liveFrame(for: entry) else { return nil }
        let offsetFrame = frame.offsetBy(dx: 50, dy: 50)
        guard let monitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        ) else {
            return offsetFrame
        }
        return clampedFloatingFrame(offsetFrame, in: monitor.visibleFrame)
    }

    private func shouldApplyFloatingFrameImmediately(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let monitor = workspaceManager.monitor(for: workspaceId) else { return false }
        return workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
    }

    func seedFloatingGeometryIfNeeded(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) {
        guard workspaceManager.floatingState(for: token) == nil,
              let entry = workspaceManager.entry(for: token),
              let frame = liveFrame(for: entry)
        else {
            return
        }

        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
    }

    func focusedOrFrontmostWindowTokenForAutomation(
        preferFrontmostWhenNonManagedFocusActive: Bool = false
    ) -> WindowToken? {
        let focusedToken = workspaceManager.focusedToken
        let frontmostPid = commandHandler.frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
        if preferFrontmostWhenNonManagedFocusActive, workspaceManager.isNonManagedFocusActive {
            return frontmostToken ?? focusedToken
        }
        return focusedToken ?? frontmostToken
    }

    func captureQuakeTerminalRestoreTarget() -> QuakeTerminalRestoreTarget? {
        guard let token = workspaceManager.renderableFocusToken
            ?? focusedOrFrontmostWindowTokenForAutomation(preferFrontmostWhenNonManagedFocusActive: true)
        else {
            return nil
        }

        if workspaceManager.entry(for: token) != nil {
            return .managed(token)
        }

        guard let axRef = AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
        else {
            return nil
        }

        return .external(
            KeyboardFocusTarget(
                token: token,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            )
        )
    }

    func focusedManagedWindowScreenForQuakeTerminal() -> NSScreen? {
        guard let token = focusedOrFrontmostWindowTokenForAutomation(
            preferFrontmostWhenNonManagedFocusActive: true
        ),
            let entry = workspaceManager.entry(for: token)
        else {
            return nil
        }

        if let monitorId = entry.observedState.monitorId
            ?? entry.desiredState.monitorId
            ?? workspaceManager.monitorId(for: entry.workspaceId),
            let screen = screen(for: monitorId)
        {
            return screen
        }

        if let frame = entry.observedState.frame
            ?? entry.desiredState.floatingFrame
            ?? entry.floatingState?.lastFrame,
            let monitor = frame.center.monitorApproximation(in: workspaceManager.monitors)
        {
            return screen(for: monitor.id)
        }

        return nil
    }

    private func screen(for monitorId: Monitor.ID) -> NSScreen? {
        guard let monitor = workspaceManager.monitor(byId: monitorId) else { return nil }
        return NSScreen.screens.first(where: { $0.displayId == monitor.displayId })
    }

    private func focusedManagedTokenForCommand() -> WindowToken? {
        let token = focusedOrFrontmostWindowTokenForAutomation()
        guard let token, workspaceManager.entry(for: token) != nil else {
            return nil
        }
        return token
    }

    @discardableResult
    private func captureVisibleFloatingGeometry(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> CGRect? {
        guard !workspaceManager.isHiddenInCorner(token),
              let entry = workspaceManager.entry(for: token),
              let frame = liveFrame(for: entry)
        else {
            return nil
        }

        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
        return frame
    }

    @discardableResult
    private func prepareWindowForScratchpadAssignment(
        _ token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }

        if entry.mode == .floating {
            guard captureVisibleFloatingGeometry(for: token, preferredMonitor: preferredMonitor) != nil
                || workspaceManager.floatingState(for: token) != nil
            else {
                return false
            }
            if workspaceManager.manualLayoutOverride(for: token) != .forceFloat {
                workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
            }
            return true
        }

        guard let frame = liveFrame(for: entry) else { return false }
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        _ = workspaceManager.setWindowMode(.floating, for: token)
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
        if workspaceManager.manualLayoutOverride(for: token) != .forceFloat {
            workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        }
        return true
    }

    private func scratchpadTarget(
        on monitorId: Monitor.ID? = nil
    ) -> (workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)? {
        guard let monitor = monitorId.flatMap({ workspaceManager.monitor(byId: $0) }) ?? monitorForInteraction(),
              let workspaceId = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            return nil
        }
        return (workspaceId, monitor)
    }

    private func visibleFocusRecoveryToken(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedToken: WindowToken
    ) -> WindowToken? {
        let explicitCandidates = [
            workspaceManager.lastFocusedToken(in: workspaceId),
            workspaceManager.preferredFocusToken(in: workspaceId),
            workspaceManager.lastFloatingFocusedToken(in: workspaceId),
            workspaceManager.focusedToken
        ]

        for candidate in explicitCandidates {
            guard let candidate,
                  candidate != excludedToken,
                  let entry = workspaceManager.entry(for: candidate),
                  entry.workspaceId == workspaceId,
                  isManagedWindowDisplayable(entry.token)
            else {
                continue
            }
            return candidate
        }

        if let tiledEntry = workspaceManager.tiledEntries(in: workspaceId).first(where: {
            $0.token != excludedToken && isManagedWindowDisplayable($0.token)
        }) {
            return tiledEntry.token
        }

        return workspaceManager.floatingEntries(in: workspaceId).first(where: {
            $0.token != excludedToken && isManagedWindowDisplayable($0.token)
        })?.token
    }

    private func recoverFocusAfterScratchpadHide(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding token: WindowToken,
        on monitorId: Monitor.ID?
    ) {
        if let nextFocusToken = visibleFocusRecoveryToken(in: workspaceId, excluding: token) {
            focusWindow(nextFocusToken)
            return
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
    }

    func cleanupScratchpadWindowResources(for token: WindowToken) {
        layoutRefreshController.cancelPendingScratchpadReveal(for: token)
        let frameEntry = [(pid: token.pid, windowId: token.windowId)]
        axManager.cancelPendingFrameJobs(frameEntry)
        axManager.unsuppressFrameWrites(frameEntry)
        AXWindowService.unpinAXElement(for: UInt32(token.windowId))
        if workspaceManager.clearScratchpadIfMatches(token) {
            requestWorkspaceBarRefresh()
        }
    }

    func cleanupScratchpadWindowResourcesIfNeeded(for token: WindowToken) {
        guard workspaceManager.isScratchpadToken(token)
            || workspaceManager.hiddenState(for: token)?.isScratchpad == true
        else {
            return
        }
        cleanupScratchpadWindowResources(for: token)
    }

    func rekeyScratchpadWindowResources(from oldToken: WindowToken, to newToken: WindowToken, axRef: AXWindowRef) {
        guard workspaceManager.hiddenState(for: newToken)?.isScratchpad == true else { return }
        AXWindowService.unpinAXElement(for: UInt32(oldToken.windowId))
        AXWindowService.pinAXElement(axRef.element, for: UInt32(newToken.windowId))
    }

    private func hideScratchpadWindow(
        _ entry: WindowState,
        monitor: Monitor
    ) {
        // Hold an AX reference before hiding so reveal can still resolve windows
        // whose apps drop them from kAXWindowsAttribute while off-screen
        // (Calculator, some AppKit panels). axWindowRef enumeration would
        // otherwise return nil and the reveal frame write would silently skip.
        if let ref = AXWindowService.axWindowRef(for: UInt32(entry.windowId), pid: entry.pid) {
            AXWindowService.pinAXElement(ref.element, for: UInt32(entry.windowId))
        }

        let preferredSide = layoutRefreshController.preferredHideSide(for: monitor)
        layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: preferredSide,
            reason: .scratchpad
        )
        requestWorkspaceBarRefresh()
        recoverFocusAfterScratchpadHide(
            in: workspaceManager.workspace(for: entry.token) ?? entry.workspaceId,
            excluding: entry.token,
            on: monitor.id
        )
    }

    @discardableResult
    private func showScratchpadWindow(
        _ entry: WindowState,
        on workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> Bool {
        if entry.workspaceId != workspaceId {
            reassignManagedWindow(entry.token, to: workspaceId)
        }
        let entry = workspaceManager.entry(for: entry.token) ?? entry
        axManager.markWindowActive(entry.windowId)

        if let hiddenState = workspaceManager.hiddenState(for: entry.token) {
            let focusOnRevealSuccess: LayoutRefreshController.PostLayoutAction = { [weak self] in
                self?.focusWindow(entry.token)
            }
            if hiddenState.isScratchpad {
                return layoutRefreshController.restoreScratchpadWindow(
                    entry,
                    monitor: monitor,
                    onSuccess: focusOnRevealSuccess
                )
            } else {
                return layoutRefreshController.unhideWindow(
                    entry,
                    monitor: monitor,
                    onSuccess: focusOnRevealSuccess
                )
            }
        }

        if let frame = workspaceManager.resolvedFloatingFrame(
            for: entry.token,
            preferredMonitor: monitor
        ) {
            axManager.forceApplyNextFrame(for: entry.windowId)
            axManager.applyFramesParallel([(entry.pid, entry.windowId, frame)])
        }

        focusWindow(entry.token)
        return true
    }

    @discardableResult
    func transitionWindowMode(
        for token: WindowToken,
        to targetMode: TrackedWindowMode,
        preferredMonitor: Monitor? = nil,
        applyFloatingFrame: Bool? = nil
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        let currentMode = entry.mode
        guard currentMode != targetMode else { return false }

        let currentFrame = liveFrame(for: entry)
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: currentFrame
        )

        switch (currentMode, targetMode) {
        case (.tiling, .floating):
            let targetFrame = initialFloatingFrame(
                for: entry,
                preferredMonitor: referenceMonitor
            )
            _ = workspaceManager.setWindowMode(.floating, for: token)
            if let targetFrame {
                workspaceManager.updateFloatingGeometry(
                    frame: targetFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true
                )
                if applyFloatingFrame
                    ?? shouldApplyFloatingFrameImmediately(
                        for: workspaceManager.workspace(for: token) ?? entry.workspaceId
                    )
                {
                    axManager.forceApplyNextFrame(for: entry.windowId)
                    axManager.applyFramesParallel([(entry.pid, entry.windowId, targetFrame)])
                }
            }
            return true

        case (.floating, .tiling):
            if let currentFrame {
                workspaceManager.updateFloatingGeometry(
                    frame: currentFrame,
                    for: token,
                    referenceMonitor: referenceMonitor,
                    restoreToFloating: true
                )
            } else if var floatingState = workspaceManager.floatingState(for: token) {
                floatingState.restoreToFloating = true
                workspaceManager.setFloatingState(floatingState, for: token)
            }
            _ = workspaceManager.setWindowMode(.tiling, for: token)
            return true

        case (.tiling, .tiling),
             (.floating, .floating):
            return false
        }
    }

    func trackedModeForLifecycle(
        decision: WindowDecision,
        existingEntry: WindowState?
    ) -> TrackedWindowMode? {
        if let trackedMode = decision.trackedMode {
            return trackedMode
        }
        if decision.disposition == .undecided {
            return existingEntry?.mode
        }
        return nil
    }

    func trackedModePreservingAutomaticFallbackState(
        decision: WindowDecision,
        existingEntry: WindowState?,
        context: WindowRuleReevaluationContext
    ) -> TrackedWindowMode? {
        guard let trackedMode = trackedModeForLifecycle(
            decision: decision,
            existingEntry: existingEntry
        ) else {
            return nil
        }

        guard context == .automatic,
              let existingEntry,
              decision.layoutDecisionKind == .fallbackLayout
        else {
            return trackedMode
        }

        if existingEntry.mode == .floating,
           trackedMode == .tiling,
           existingEntry.managedReplacementMetadata?.transientWindowServerEvidence == true
        {
            return .floating
        }

        if existingEntry.mode == .tiling,
           trackedMode == .floating
        {
            return floatDemotionModeApplyingHysteresis(for: existingEntry.token, decision: decision)
        }

        floatDemotionFirstSamplesByToken.removeValue(forKey: existingEntry.token)
        return trackedMode
    }

    private func floatDemotionModeApplyingHysteresis(
        for token: WindowToken,
        decision: WindowDecision
    ) -> TrackedWindowMode {
        guard !decision.heuristicReasons.contains(.attributeFetchFailed),
              !decision.heuristicReasons.contains(.disabledFullscreenButton),
              !decision.heuristicReasons.contains(.missingFullscreenButton),
              !decision.heuristicReasons.contains(.nonStandardSubrole),
              !decision.heuristicReasons.contains(.noButtonsOnNonStandardSubrole)
        else {
            return .tiling
        }

        let now = ContinuousClock.now
        guard let firstSampledAt = floatDemotionFirstSamplesByToken[token] else {
            floatDemotionFirstSamplesByToken[token] = now
            return .tiling
        }
        guard firstSampledAt.duration(to: now) >= Self.floatDemotionStabilityInterval else {
            return .tiling
        }

        floatDemotionFirstSamplesByToken.removeValue(forKey: token)
        return .floating
    }

    func resolvedWorkspaceId(
        for evaluation: WindowDecisionEvaluation,
        axRef: AXWindowRef,
        existingEntry: WindowState?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        restrictWorkspaceRuleToPlacementMonitor: Bool = true,
        createPlacementContext: WindowCreatePlacementContext? = nil,
        context: WindowRuleReevaluationContext = .automatic
    ) -> WorkspaceDescriptor.ID {
        let inheritTrackedParentWorkspace = shouldInheritTrackedParentWorkspace(for: evaluation)
        return resolveWorkspacePlacement(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: evaluation.token.pid,
            parentWindowId: evaluation.facts.windowServer?.parentId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            preferSameAppSiblingWorkspace: shouldPreferSameAppSiblingWorkspace(
                for: evaluation,
                inheritTrackedParentWorkspace: inheritTrackedParentWorkspace
            ),
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            restrictWorkspaceRuleToPlacementMonitor: restrictWorkspaceRuleToPlacementMonitor,
            createPlacementContext: createPlacementContext,
            windowFrame: evaluation.facts.windowServer?.frame,
            existingEntry: existingEntry,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: context
        )
    }

    func evaluateWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil,
        applyingManualOverride: Bool = true,
        windowInfo: WindowServerInfo? = nil
    ) -> WindowDecisionEvaluation {
        let token = WindowToken(pid: pid, windowId: axRef.windowId)
        if pid == ProcessInfo.processInfo.processIdentifier || isOwnedWindow(windowNumber: axRef.windowId) {
            return Self.ownedWindowDispositionEvaluation(token: token)
        }
        let sizeConstraints = evaluateSizeConstraints(for: token, axRef: axRef)
        let appInfo = resolvedAppInfo(for: pid)
        let baseFacts = WindowRuleFacts(
            appName: appInfo?.name,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: appInfo?.activationPolicy,
                bundleId: appInfo?.bundleId,
                includeTitle: windowRuleEngine.requiresTitle(for: appInfo?.bundleId)
            ),
            sizeConstraints: sizeConstraints,
            windowServer: nil
        )
        let resolvedWindowInfo = baseFacts.windowServer ?? resolveWindowServerInfoForDisposition(
            token: token,
            bundleId: baseFacts.ax.bundleId ?? appInfo?.bundleId,
            preferredWindowInfo: windowInfo
        )
        let facts = WindowRuleFacts(
            appName: baseFacts.appName,
            ax: baseFacts.ax,
            sizeConstraints: baseFacts.sizeConstraints,
            windowServer: resolvedWindowInfo
        )
        let fullscreen = appFullscreen ?? AXWindowService.isFullscreen(axRef)
        let manualOverride = workspaceManager.manualLayoutOverride(for: token)
        let baseDecision = windowRuleEngine.decision(
            for: facts,
            token: token,
            appFullscreen: fullscreen
        )
        let decision = applyingManualOverride
            ? WindowRuleEngine.applyingManualOverride(baseDecision, manualOverride: manualOverride)
            : baseDecision
        return WindowDecisionEvaluation(
            token: token,
            facts: facts,
            decision: decision,
            appFullscreen: fullscreen,
            manualOverride: manualOverride
        )
    }

    private static func ownedWindowDispositionEvaluation(token: WindowToken) -> WindowDecisionEvaluation {
        WindowDecisionEvaluation(
            token: token,
            facts: WindowRuleFacts(
                appName: nil,
                ax: AXWindowFacts(
                    role: nil,
                    subrole: nil,
                    title: nil,
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: nil,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: nil,
                    bundleId: nil,
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: nil,
                windowServer: nil
            ),
            decision: WindowDecision(
                disposition: .unmanaged,
                source: .builtInRule(WindowRuleEngine.ownedWindowRuleName),
                layoutDecisionKind: .explicitLayout,
                workspaceName: nil,
                ruleEffects: .none,
                heuristicReasons: [],
                deferredReason: nil
            ),
            appFullscreen: false,
            manualOverride: nil
        )
    }

    private func resolveWindowServerInfoForDisposition(
        token: WindowToken,
        bundleId: String?,
        preferredWindowInfo: WindowServerInfo?
    ) -> WindowServerInfo? {
        if let preferredWindowInfo {
            return preferredWindowInfo
        }

        guard bundleId == WindowRuleEngine.cleanShotBundleId,
              let windowId = UInt32(exactly: token.windowId)
        else {
            return nil
        }

        return SkyLight.shared.queryWindowInfo(windowId)
    }

    func decideWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil
    ) -> WindowDecision {
        evaluateWindowDisposition(
            axRef: axRef,
            pid: pid,
            appFullscreen: appFullscreen
        ).decision
    }

    func makeWindowDecisionDebugSnapshot(
        from evaluation: WindowDecisionEvaluation
    ) -> WindowDecisionDebugSnapshot {
        WindowDecisionDebugSnapshot(
            token: evaluation.token,
            appName: evaluation.facts.appName,
            bundleId: evaluation.facts.ax.bundleId,
            title: evaluation.facts.ax.title,
            axRole: evaluation.facts.ax.role,
            axSubrole: evaluation.facts.ax.subrole,
            appFullscreen: evaluation.appFullscreen,
            manualOverride: evaluation.manualOverride,
            disposition: evaluation.decision.disposition,
            source: evaluation.decision.source,
            layoutDecisionKind: evaluation.decision.layoutDecisionKind,
            deferredReason: evaluation.decision.deferredReason,
            admissionOutcome: evaluation.decision.admissionOutcome,
            workspaceName: evaluation.decision.workspaceName,
            minWidth: evaluation.decision.ruleEffects.minWidth,
            minHeight: evaluation.decision.ruleEffects.minHeight,
            matchedRuleId: evaluation.decision.ruleEffects.matchedRuleId,
            heuristicReasons: evaluation.decision.heuristicReasons,
            attributeFetchSucceeded: evaluation.facts.ax.attributeFetchSucceeded
        )
    }

    func windowDecisionDebugSnapshot(for token: WindowToken) -> WindowDecisionDebugSnapshot? {
        let axRef = workspaceManager.entry(for: token)?.axRef
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
        guard let axRef else { return nil }
        let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)
        return makeWindowDecisionDebugSnapshot(from: evaluation)
    }

    func focusedWindowDecisionDebugSnapshot() -> WindowDecisionDebugSnapshot? {
        let token = focusedOrFrontmostWindowTokenForAutomation()
        guard let token else { return nil }
        return windowDecisionDebugSnapshot(for: token)
    }

    func copyDebugDump(_ snapshot: WindowDecisionDebugSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.formattedDump(), forType: .string)
    }

    func clearManualWindowOverride(for token: WindowToken) {
        workspaceManager.setManualLayoutOverride(nil, for: token)
    }

    private func resolveAXWindowRef(for token: WindowToken) -> AXWindowRef? {
        workspaceManager.entry(for: token)?.axRef
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
    }

    @discardableResult
    func reevaluateWindowRules(
        for targets: Set<WindowRuleReevaluationTarget>,
        context: WindowRuleReevaluationContext = .automatic
    ) async -> WindowRuleReevaluationOutcome {
        guard !targets.isEmpty else { return .none }

        let epochDomains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen]
        let epochSeq = workspaceManager.worldSeq
        var liveWindowsByToken: [WindowToken: AXWindowRef] = [:]
        var tokensToReevaluate: Set<WindowToken> = []
        var pidTargets: Set<pid_t> = []
        var resolvedAnyTarget = false
        func staleOutcome() -> WindowRuleReevaluationOutcome {
            WindowRuleReevaluationOutcome(
                resolvedAnyTarget: resolvedAnyTarget,
                evaluatedAnyWindow: false,
                relayoutNeeded: false,
                stale: true
            )
        }

        for target in targets {
            switch target {
            case let .window(token):
                let existingEntry = workspaceManager.entry(for: token)
                if let axRef = resolveAXWindowRef(for: token) {
                    resolvedAnyTarget = true
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                } else if existingEntry != nil {
                    resolvedAnyTarget = true
                    tokensToReevaluate.insert(token)
                }
            case let .pid(pid):
                pidTargets.insert(pid)
            }
        }

        for pid in pidTargets {
            let managedEntries = workspaceManager.entries(forPid: pid)
            if !managedEntries.isEmpty {
                resolvedAnyTarget = true
            }
            if let app = NSRunningApplication(processIdentifier: pid) {
                let windows = await axManager.windowsForApp(app)
                guard !Task.isCancelled,
                      workspaceManager.isSeqEpochCurrent(epochSeq, domains: epochDomains)
                else {
                    return staleOutcome()
                }
                if !windows.isEmpty {
                    resolvedAnyTarget = true
                }
                for (axRef, _, windowId) in windows {
                    let token = WindowToken(pid: pid, windowId: windowId)
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                }
            }

            for entry in managedEntries {
                tokensToReevaluate.insert(entry.token)
            }
        }

        guard !Task.isCancelled,
              workspaceManager.isSeqEpochCurrent(epochSeq, domains: epochDomains)
        else {
            return staleOutcome()
        }

        guard !tokensToReevaluate.isEmpty else {
            return WindowRuleReevaluationOutcome(
                resolvedAnyTarget: resolvedAnyTarget,
                evaluatedAnyWindow: false,
                relayoutNeeded: false
            )
        }

        var relayoutNeeded = false
        var evaluatedAnyWindow = false
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

        for token in tokensToReevaluate.sorted(by: {
            if $0.pid == $1.pid {
                return $0.windowId < $1.windowId
            }
            return $0.pid < $1.pid
        }) {
            let existingEntry = workspaceManager.entry(for: token)
            let axRef = liveWindowsByToken[token] ?? existingEntry?.axRef
            guard let axRef else { continue }
            let createPlacementContext = existingEntry == nil
                ? axEventHandler.pendingCreatePlacementContext(for: token.windowId)
                : nil

            evaluatedAnyWindow = true
            let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)

            guard let effectiveTrackedMode = trackedModePreservingAutomaticFallbackState(
                decision: evaluation.decision,
                existingEntry: existingEntry,
                context: context
            ) else {
                if let existingEntry {
                    affectedWorkspaceIds.insert(existingEntry.workspaceId)
                    cleanupScratchpadWindowResourcesIfNeeded(for: token)
                    _ = workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
                    relayoutNeeded = true
                } else if evaluation.decision.disposition != .undecided {
                    axEventHandler.discardCreatePlacementContext(for: token.windowId)
                }
                continue
            }

            let oldEffects = existingEntry?.ruleEffects ?? .none
            let oldMode = existingEntry?.mode
            let oldWorkspaceId = existingEntry?.workspaceId
            let structuralMatch = existingEntry == nil
                ? axEventHandler.structuralReplacementMatch(
                    token: token,
                    bundleId: evaluation.facts.ax.bundleId,
                    mode: effectiveTrackedMode,
                    facts: evaluation.facts
                )
                : nil
            let workspaceId = resolvedWorkspaceId(
                for: evaluation,
                axRef: axRef,
                existingEntry: existingEntry,
                fallbackWorkspaceId: activeWorkspace()?.id,
                structuralReplacementWorkspaceId: structuralMatch?.workspaceId,
                restrictWorkspaceRuleToPlacementMonitor: effectiveTrackedMode != .floating,
                createPlacementContext: createPlacementContext,
                context: context
            )

            if existingEntry == nil,
               let windowId = UInt32(exactly: token.windowId),
               let structuralMatch,
               axEventHandler.rekeyStructuralManagedReplacement(
                   match: structuralMatch,
                   token: token,
                   windowId: windowId,
                   axRef: axRef,
                   bundleId: evaluation.facts.ax.bundleId,
                   mode: effectiveTrackedMode,
                   facts: evaluation.facts
               )
            {
                affectedWorkspaceIds.insert(workspaceId)
                relayoutNeeded = true
                continue
            }

            let parentWindowId = evaluation.facts.windowServer.flatMap { $0.parentId == 0 ? nil : $0.parentId }
            let managedReplacementMetadata = ManagedReplacementMetadata(
                bundleId: evaluation.facts.ax.bundleId ?? existingEntry?.managedReplacementMetadata?.bundleId,
                workspaceId: workspaceId,
                mode: oldMode ?? effectiveTrackedMode,
                role: evaluation.facts.ax.role ?? existingEntry?.managedReplacementMetadata?.role,
                subrole: evaluation.facts.ax.subrole ?? existingEntry?.managedReplacementMetadata?.subrole,
                title: evaluation.facts.ax.title ?? existingEntry?.managedReplacementMetadata?.title,
                windowLevel: evaluation.facts.windowServer?.level ?? existingEntry?.managedReplacementMetadata?
                    .windowLevel,
                parentWindowId: parentWindowId ?? existingEntry?.managedReplacementMetadata?.parentWindowId,
                frame: evaluation.facts.windowServer?.frame ?? existingEntry?.managedReplacementMetadata?.frame,
                transientWindowServerEvidence: existingEntry?.managedReplacementMetadata?
                    .transientWindowServerEvidence == true
                    || evaluation.facts.windowServer?.hasTransientSurfaceEvidence == true,
                degradedWindowServerChildEvidence: existingEntry?.managedReplacementMetadata?
                    .degradedWindowServerChildEvidence == true
                    || evaluation.facts.degradedWindowServerChildEvidence
            )

            _ = workspaceManager.addWindow(
                axRef,
                pid: token.pid,
                windowId: token.windowId,
                to: workspaceId,
                mode: oldMode ?? effectiveTrackedMode,
                ruleEffects: evaluation.decision.ruleEffects,
                managedReplacementMetadata: managedReplacementMetadata
            )
            if existingEntry == nil {
                axEventHandler.discardCreatePlacementContext(for: token.windowId)
            }

            if let oldMode, oldMode != effectiveTrackedMode {
                _ = transitionWindowMode(
                    for: token,
                    to: effectiveTrackedMode,
                    preferredMonitor: workspaceManager.monitor(for: workspaceId)
                )
            } else if effectiveTrackedMode == .floating {
                seedFloatingGeometryIfNeeded(
                    for: token,
                    preferredMonitor: workspaceManager.monitor(for: workspaceId)
                )
            }

            if let updatedEntry = workspaceManager.entry(for: token) {
                let parentWindowId = if let windowServer = evaluation.facts.windowServer {
                    windowServer.parentId == 0 ? nil : windowServer.parentId
                } else {
                    updatedEntry.managedReplacementMetadata?.parentWindowId
                }
                _ = workspaceManager.setManagedReplacementMetadata(
                    ManagedReplacementMetadata(
                        bundleId: evaluation.facts.ax.bundleId ?? updatedEntry.managedReplacementMetadata?.bundleId,
                        workspaceId: updatedEntry.workspaceId,
                        mode: updatedEntry.mode,
                        role: evaluation.facts.ax.role ?? updatedEntry.managedReplacementMetadata?.role,
                        subrole: evaluation.facts.ax.subrole ?? updatedEntry.managedReplacementMetadata?.subrole,
                        title: evaluation.facts.ax.title ?? updatedEntry.managedReplacementMetadata?.title,
                        windowLevel: evaluation.facts.windowServer?.level ?? updatedEntry.managedReplacementMetadata?
                            .windowLevel,
                        parentWindowId: parentWindowId,
                        frame: evaluation.facts.windowServer?.frame ?? updatedEntry.managedReplacementMetadata?.frame,
                        transientWindowServerEvidence: updatedEntry.managedReplacementMetadata?
                            .transientWindowServerEvidence == true
                            || evaluation.facts.windowServer?.hasTransientSurfaceEvidence == true,
                        degradedWindowServerChildEvidence: updatedEntry.managedReplacementMetadata?
                            .degradedWindowServerChildEvidence == true
                            || evaluation.facts.degradedWindowServerChildEvidence
                    ),
                    for: token
                )
            }

            if existingEntry == nil
                || oldEffects != evaluation.decision.ruleEffects
                || oldWorkspaceId != workspaceId
                || oldMode != effectiveTrackedMode
            {
                if let oldWorkspaceId {
                    affectedWorkspaceIds.insert(oldWorkspaceId)
                }
                affectedWorkspaceIds.insert(workspaceId)
                relayoutNeeded = true
            }
        }

        if relayoutNeeded {
            layoutRefreshController.requestRelayout(
                reason: .windowRuleReevaluation,
                affectedWorkspaceIds: affectedWorkspaceIds
            )
        }

        return WindowRuleReevaluationOutcome(
            resolvedAnyTarget: resolvedAnyTarget,
            evaluatedAnyWindow: evaluatedAnyWindow,
            relayoutNeeded: relayoutNeeded
        )
    }

    func toggleFocusedWindowFloating() -> ExternalCommandResult {
        let token = focusedManagedTokenForCommand()
        guard let token,
              let entry = workspaceManager.entry(for: token)
        else {
            return .notFound
        }

        let nextOverride: ManualWindowOverride?
        if workspaceManager.manualLayoutOverride(for: token) != nil {
            nextOverride = nil
        } else {
            nextOverride = entry.mode == .tiling ? .forceFloat : .forceTile
        }

        applyManagedWindowOverride(nextOverride, for: token, entry: entry)
        return .executed
    }

    @discardableResult
    func assignFocusedWindowToScratchpad() -> ExternalCommandResult {
        guard let token = focusedManagedTokenForCommand(),
              let entry = workspaceManager.entry(for: token),
              !isManagedWindowSuspendedForNativeFullscreen(token)
        else {
            return .notFound
        }

        if workspaceManager.isScratchpadToken(token) {
            guard !workspaceManager.isHiddenInCorner(token) else {
                return .notFound
            }
            cleanupScratchpadWindowResources(for: token)
            applyManagedWindowOverride(.forceTile, for: token, entry: entry)
            return .executed
        }

        if let existingScratchpadToken = workspaceManager.scratchpadToken() {
            if workspaceManager.entry(for: existingScratchpadToken) == nil {
                cleanupScratchpadWindowResources(for: existingScratchpadToken)
            } else {
                return .notFound
            }
        }

        let preferredMonitor = monitorForInteraction() ?? workspaceManager.monitor(for: entry.workspaceId)
        let transitionedFromTiling = entry.mode == .tiling
        guard prepareWindowForScratchpadAssignment(token, preferredMonitor: preferredMonitor) else {
            return .notFound
        }

        if workspaceManager.setScratchpadToken(token) {
            requestWorkspaceBarRefresh()
        }

        guard let updatedEntry = workspaceManager.entry(for: token),
              let hideMonitor = workspaceManager.monitor(for: updatedEntry.workspaceId) ?? preferredMonitor
        else {
            cleanupScratchpadWindowResources(for: token)
            return .notFound
        }

        hideScratchpadWindow(updatedEntry, monitor: hideMonitor)

        if transitionedFromTiling {
            layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [workspaceManager.workspace(for: token) ?? updatedEntry.workspaceId]
            )
        }

        return .executed
    }

    private func applyManagedWindowOverride(
        _ override: ManualWindowOverride?,
        for token: WindowToken,
        entry: WindowState
    ) {
        workspaceManager.setManualLayoutOverride(override, for: token)
        let entry = workspaceManager.entry(for: token) ?? entry
        let evaluation = evaluateWindowDisposition(
            axRef: entry.axRef,
            pid: token.pid
        )
        guard let trackedMode = trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: entry
        ) else {
            cleanupScratchpadWindowResourcesIfNeeded(for: token)
            _ = workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
            layoutRefreshController.requestRelayout(
                reason: .windowRuleReevaluation,
                affectedWorkspaceIds: [entry.workspaceId]
            )
            return
        }

        _ = transitionWindowMode(
            for: token,
            to: trackedMode,
            preferredMonitor: monitorForInteraction(),
            applyFloatingFrame: true
        )
        layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    @discardableResult
    func toggleScratchpadWindow() -> ExternalCommandResult {
        guard let scratchpadToken = workspaceManager.scratchpadToken() else {
            return .notFound
        }
        guard let entry = workspaceManager.entry(for: scratchpadToken) else {
            cleanupScratchpadWindowResources(for: scratchpadToken)
            return .notFound
        }
        guard !isManagedWindowSuspendedForNativeFullscreen(scratchpadToken) else {
            return .notFound
        }
        guard let target = scratchpadTarget() else {
            return .notFound
        }

        if let hiddenState = workspaceManager.hiddenState(for: scratchpadToken) {
            let updatedEntry = workspaceManager.entry(for: scratchpadToken) ?? entry
            if hiddenState.isScratchpad || hiddenState.workspaceInactive {
                let started = showScratchpadWindow(updatedEntry, on: target.workspaceId, monitor: target.monitor)
                return started ? .executed : .notFound
            }
            return .notFound
        }

        let hasCapturedGeometry = captureVisibleFloatingGeometry(
            for: scratchpadToken,
            preferredMonitor: target.monitor
        ) != nil || workspaceManager.floatingState(for: scratchpadToken) != nil
        guard hasCapturedGeometry else {
            return .notFound
        }

        let liveEntry = workspaceManager.entry(for: scratchpadToken) ?? entry
        if liveEntry.workspaceId == target.workspaceId,
           isManagedWindowDisplayable(liveEntry.token)
        {
            hideScratchpadWindow(liveEntry, monitor: target.monitor)
            return .executed
        }

        let started = showScratchpadWindow(liveEntry, on: target.workspaceId, monitor: target.monitor)
        return started ? .executed : .notFound
    }

    func workspaceAssignment(pid: pid_t, windowId: Int) -> WorkspaceDescriptor.ID? {
        workspaceManager.entry(forPid: pid, windowId: windowId)?.workspaceId
    }

    func openCommandPalette() {
        commandPaletteController.toggle(wmController: self)
    }

    func clipboardPaletteItems() -> [ClipboardPaletteItem] {
        clipboardHistoryService.paletteItems
    }

    func setClipboardHistoryEnabled(_ enabled: Bool) {
        settings.clipboardHistoryEnabled = enabled
        syncClipboardHistoryService()
    }

    func copyClipboardItem(id: UUID) async -> Bool {
        await clipboardHistoryService.copyItemToPasteboard(id: id)
    }

    func deleteClipboardItem(id: UUID) async -> [ClipboardPaletteItem] {
        await clipboardHistoryService.deleteItem(id: id)
    }

    func clearClipboardHistory() async -> [ClipboardPaletteItem] {
        await clipboardHistoryService.clearHistory()
    }

    private func syncClipboardHistoryService() {
        clipboardHistoryService.updateConfiguration(clipboardHistoryConfiguration())
    }

    func clipboardHistoryConfiguration() -> ClipboardHistoryConfiguration {
        ClipboardHistoryConfiguration(
            isEnabled: settings.clipboardHistoryEnabled,
            maxItems: settings.clipboardMaxItems,
            maxItemBytes: settings.clipboardMaxItemBytes,
            maxTotalBytes: settings.clipboardMaxTotalBytes,
            storageDirectory: clipboardHistoryDirectory
        )
    }

    func openSponsorsWindow() {
        sponsorsWindowController.show()
    }

    func openMenuAnywhere() {
        windowActionHandler.openMenuAnywhere()
    }

    func navigateToCommandPaletteWindow(_ handle: WindowHandle) {
        windowActionHandler.navigateToWindow(handle: handle)
    }

    func summonCommandPaletteWindowRight(
        _ handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) {
        windowActionHandler.summonWindowRight(
            handle: handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }

    func toggleOverview() {
        windowActionHandler.toggleOverview()
    }

    func navigateOverviewSelection(_ direction: Direction) -> Bool {
        windowActionHandler.navigateOverviewSelection(direction)
    }

    func raiseAllFloatingWindows() {
        windowActionHandler.raiseAllFloatingWindows()
    }

    @discardableResult
    func restoreVisibleWorkspaceInactiveFloatingWindows() -> Int {
        layoutRefreshController.restoreWorkspaceInactiveFloatingWindows(
            activeWorkspaceIds: workspaceManager.visibleWorkspaceIds()
        )
    }

    func hasVisibleWorkspaceInactiveFloatingWindows() -> Bool {
        layoutRefreshController.hasWorkspaceInactiveFloatingWindows(
            activeWorkspaceIds: workspaceManager.visibleWorkspaceIds()
        )
    }

    @discardableResult
    func rescueOffscreenWindows() -> Int {
        guard !isLockScreenActive else { return 0 }

        var candidates: [RestorePlanner.FloatingRescueCandidate] = []
        let visibleWorkspaceIds = workspaceManager.visibleWorkspaceIds()

        for entry in workspaceManager.allFloatingEntries() {
            guard entry.layoutReason == .standard else { continue }
            guard visibleWorkspaceIds.contains(entry.workspaceId) else { continue }
            guard let targetMonitor = workspaceManager.monitor(for: entry.workspaceId)
                ?? monitorForInteraction()
                ?? workspaceManager.monitors.first
            else {
                continue
            }

            guard let targetFrame = workspaceManager.resolvedFloatingFrame(
                for: entry.token,
                preferredMonitor: targetMonitor
            ) else {
                continue
            }

            candidates.append(
                .init(
                    token: entry.token,
                    pid: entry.pid,
                    windowId: entry.windowId,
                    workspaceId: entry.workspaceId,
                    targetMonitor: targetMonitor,
                    currentFrame: liveFrame(for: entry),
                    targetFrame: targetFrame,
                    isScratchpadHidden: workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true,
                    isWorkspaceInactiveHidden: workspaceManager.hiddenState(for: entry.token)?.workspaceInactive == true
                )
            )
        }

        let rescuePlan = restorePlanner.planFloatingRescue(candidates)
        var frameUpdates: [(pid: pid_t, windowId: Int, frame: CGRect)] = []
        var visibleJobs: [(pid: pid_t, windowId: Int)] = []
        var rescuedEntries: [WindowState] = []

        for operation in rescuePlan.operations {
            guard let entry = workspaceManager.entry(for: operation.token) else { continue }
            let wasWorkspaceInactiveHidden = workspaceManager.hiddenState(for: operation.token)?
                .workspaceInactive == true
            if !wasWorkspaceInactiveHidden {
                workspaceManager.updateFloatingGeometry(
                    frame: operation.targetFrame,
                    for: operation.token,
                    referenceMonitor: operation.targetMonitor,
                    restoreToFloating: true
                )
            }
            if wasWorkspaceInactiveHidden {
                workspaceManager.setHiddenState(nil, for: operation.token)
                visibleJobs.append((operation.pid, operation.windowId))
                axManager.markWindowActive(operation.windowId)
            }
            axManager.forceApplyNextFrame(for: operation.windowId)
            frameUpdates.append((operation.pid, operation.windowId, operation.targetFrame))
            rescuedEntries.append(entry)
        }

        if !frameUpdates.isEmpty {
            if !visibleJobs.isEmpty {
                axManager.unsuppressFrameWrites(visibleJobs)
            }
            axManager.applyFramesParallel(frameUpdates)
            for entry in rescuedEntries {
                windowFocusOperations.raiseWindow(entry.axRef.element)
            }
        }

        return rescuePlan.rescuedCount
    }

    func isOverviewOpen() -> Bool {
        windowActionHandler.isOverviewOpen()
    }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(for workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        )
    }

    func reassignManagedWindow(
        _ token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID
    ) {
        workspaceManager.setWorkspace(for: token, to: workspaceId)
    }

    func recoverSourceFocusAfterMove(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredNodeId: NodeId?
    ) {
        let monitorId = workspaceManager.monitorId(for: workspaceId)

        if let engine = niriEngine,
           let preferredNodeId,
           let node = engine.findNode(by: preferredNodeId) as? NiriWindow
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: node.token,
                in: workspaceId,
                onMonitor: monitorId
            )
            return
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
    }

    private func commitWorkspaceFocusCandidate(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        if let engine = niriEngine,
           let node = engine.findNode(for: token)
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: token,
                in: workspaceId,
                onMonitor: workspaceManager.monitorId(for: workspaceId)
            )
        } else {
            _ = workspaceManager.applySessionPatch(
                .init(
                    workspaceId: workspaceId,
                    viewportState: nil,
                    rememberedFocusToken: token,
                    plannedSeq: workspaceManager.worldSeq
                )
            )
        }
    }

    func ensureFocusedTokenValid(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredRecoveryToken: WindowToken? = nil
    ) {
        guard !shouldSuppressManagedFocusRecovery else { return }
        guard !workspaceManager.hasPendingNativeFullscreenTransition else { return }

        if let pendingFocusedToken = workspaceManager.pendingFocusedToken,
           workspaceManager.pendingFocusedWorkspaceId == workspaceId
        {
            commitWorkspaceFocusCandidate(pendingFocusedToken, in: workspaceId)
            return
        }

        if let preferredRecoveryToken {
            if let entry = workspaceManager.entry(for: preferredRecoveryToken),
               entry.workspaceId == workspaceId
            {
                commitWorkspaceFocusCandidate(preferredRecoveryToken, in: workspaceId)
                focusWindow(preferredRecoveryToken)
                return
            }
        }

        if let focusedToken = workspaceManager.focusedToken,
           workspaceManager.entry(for: focusedToken)?.workspaceId == workspaceId
        {
            commitWorkspaceFocusCandidate(focusedToken, in: workspaceId)
            return
        }

        guard let nextFocusToken = workspaceManager.resolveAndSetWorkspaceFocusToken(
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId)
        ) else {
            return
        }

        if let engine = niriEngine,
           let node = engine.findNode(for: nextFocusToken)
        {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: nextFocusToken,
                in: workspaceId
            )
        }
        focusWindow(nextFocusToken)
    }

    func moveMouseToWindow(_ handle: WindowHandle, preferredFrame: CGRect? = nil) {
        moveMouseToWindow(handle.id, preferredFrame: preferredFrame)
    }

    func moveMouseToWindow(_ token: WindowToken, preferredFrame: CGRect? = nil) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard let frame = preferredFrame ?? AXWindowService.framePreferFast(entry.axRef) else { return }

        let center = frame.center

        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else {
            MouseTrace.record("focus-warp suppressed (off-screen) token=\(token) center=\(TraceFormat.point(center))")
            return
        }

        MouseTrace.record("focus-warp token=\(token) center=\(TraceFormat.point(center))")
        warpMouseCursorPosition(ScreenCoordinateSpace.toWindowServer(point: center))
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        windowActionHandler.runningAppsWithWindows()
    }
}

extension WMController {
    func isFrontmostAppLockScreen() -> Bool {
        lockScreenObserver.isFrontmostAppLockScreen()
    }

    func isPointInQuakeTerminal(_ point: CGPoint) -> Bool {
        guard settings.quakeTerminalEnabled,
              quakeTerminalController.visible,
              let window = quakeTerminalController.window
        else {
            return false
        }
        return window.frame.contains(point)
    }

    func isPointInOwnWindow(_ point: CGPoint) -> Bool {
        ownedWindowRegistry.contains(point: point)
    }

    var hasFrontmostOwnedWindow: Bool {
        ownedWindowRegistry.hasFrontmostWindow
    }

    var hasVisibleOwnedWindow: Bool {
        ownedWindowRegistry.hasVisibleWindow
    }

    func isOwnedWindow(windowNumber: Int) -> Bool {
        ownedWindowRegistry.contains(windowNumber: windowNumber)
    }

    var shouldSuppressManagedFocusRecovery: Bool {
        workspaceManager.isNonManagedFocusActive && hasFrontmostOwnedWindow
    }

    func performWindowFronting(
        pid: pid_t,
        windowId: Int,
        axRef: AXWindowRef
    ) {
        windowFocusOperations.activateApp(pid)
        windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)
        windowFocusOperations.raiseWindow(axRef.element)
    }

    func retryManagedFocusFronting(_ request: ManagedFocusRequest) {
        guard let entry = workspaceManager.entry(for: request.token),
              entry.workspaceId == request.workspaceId
        else {
            return
        }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
    }

    func activateNativeFullscreenPlaceholder(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard workspaceManager.layoutReason(for: token) == .nativeFullscreen else { return }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        selectNativeFullscreenPlaceholder(entry)
        performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
    }

    @discardableResult
    private func selectNativeFullscreenPlaceholder(_ entry: WindowState) -> Bool {
        let token = entry.token
        let changed = workspaceManager.selectNativeFullscreenPlaceholder(
            token,
            in: entry.workspaceId,
            onMonitor: workspaceManager.monitorId(for: entry.workspaceId)
        )
        let workspaceId = workspaceManager.workspace(for: token) ?? entry.workspaceId
        let canceledRequest = intentLedger.cancelManagedRequest(matching: token, workspaceId: workspaceId)
        if let canceledRequest {
            _ = workspaceManager.cancelManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId,
                requestId: canceledRequest.requestId
            )
        } else {
            _ = workspaceManager.cancelCurrentManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId
            )
        }
        intentLedger.discardPendingFocus(token)
        if changed {
            layoutRefreshController.requestImmediateRelayout(
                reason: .appActivationTransition,
                affectedWorkspaceIds: [workspaceId]
            )
        }
        return changed
    }

    func restoreQuakeTerminalFocus(to target: QuakeTerminalRestoreTarget) {
        switch target {
        case let .managed(token):
            guard workspaceManager.entry(for: token) != nil else { return }
            focusWindow(token)

        case let .external(target):
            if workspaceManager.entry(for: target.token) != nil {
                focusWindow(target.token)
                return
            }
            guard !isLockScreenActive else { return }
            if hasStartedServices {
                guard !isFrontmostAppLockScreen() else { return }
            }

            let pid = target.pid
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated
            else {
                return
            }

            let intent = intentLedger.registerActivateApp(pid: pid)
            deadlineWheel.schedule(intentId: intent.id, after: .seconds(1))
            if let axRef = AXWindowService.axWindowRef(for: UInt32(target.windowId), pid: pid) {
                performWindowFronting(
                    pid: pid,
                    windowId: target.windowId,
                    axRef: axRef
                )
            } else {
                windowFocusOperations.activateApp(pid)
            }
        }
    }

    func focusWindow(
        _ token: WindowToken,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) {
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard !isLockScreenActive else { return }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return }
        }
        if isManagedWindowSuspendedForNativeFullscreen(token) {
            selectNativeFullscreenPlaceholder(entry)
            return
        }

        let workspaceId = entry.workspaceId
        let request = intentLedger.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: origin
        )
        _ = workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            onMonitor: workspaceManager.monitorId(for: workspaceId),
            requestId: request.requestId
        )
        recordNiriCreateFocusTrace(
            .pendingFocusStarted(
                requestId: request.requestId,
                token: token,
                workspaceId: workspaceId
            )
        )

        performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
        axEventHandler.probeFocusedWindowAfterFronting(
            expectedToken: token,
            workspaceId: workspaceId
        )
    }

    func focusWindow(_ handle: WindowHandle) {
        focusWindow(handle.id)
    }

    func preferredKeyboardFocusFrame(for token: WindowToken) -> CGRect? {
        if let node = niriEngine?.findNode(for: token) {
            return node.renderedFrame ?? node.frame
        }
        if let node = dwindleEngine?.findNode(for: token) {
            return node.cachedFrame
        }
        if let floatingState = workspaceManager.floatingState(for: token) {
            return floatingState.lastFrame
        }
        return nil
    }

    func recordNiriCreateFocusTrace(_ kind: NiriCreateFocusTraceEvent.Kind) {
        axEventHandler.recordNiriCreateFocusTrace(.init(kind: kind))
    }

    var isDiscoveryInProgress: Bool {
        layoutRefreshController.isDiscoveryInProgress
    }

    var isInteractiveGestureActive: Bool {
        mouseEventHandler.isInteractiveGestureActive
    }
}
