// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct WindowFocusOperations {
    let activateApp: (pid_t) -> Void
    let focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let deactivateSameAppWindow: (pid_t, UInt32) -> Bool
    let activateAndFocusSameAppWindow: (pid_t, UInt32, AXUIElement) -> Bool
    let raiseWindow: (AXUIElement) -> Void
    let orderWindow: (UInt32) -> Void

    init(
        activateApp: @escaping (pid_t) -> Void,
        focusSpecificWindow: @escaping (pid_t, UInt32, AXUIElement) -> Void,
        deactivateSameAppWindow: @escaping (pid_t, UInt32) -> Bool = { _, _ in false },
        activateAndFocusSameAppWindow: @escaping (pid_t, UInt32, AXUIElement) -> Bool = { _, _, _ in false },
        raiseWindow: @escaping (AXUIElement) -> Void,
        orderWindow: @escaping (UInt32) -> Void = { _ in }
    ) {
        self.activateApp = activateApp
        self.focusSpecificWindow = focusSpecificWindow
        self.deactivateSameAppWindow = deactivateSameAppWindow
        self.activateAndFocusSameAppWindow = activateAndFocusSameAppWindow
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
        deactivateSameAppWindow: { pid, windowId in
            OmniWM.deactivateSameAppWindow(pid: pid, windowId: windowId)
        },
        activateAndFocusSameAppWindow: { pid, windowId, element in
            OmniWM.activateAndFocusSameAppWindow(
                pid: pid,
                windowId: windowId,
                windowRef: element
            )
        },
        raiseWindow: { element in
            performAXAction(element, kAXRaiseAction as CFString, noteKey: "performRaiseFailed")
        },
        orderWindow: { windowId in
            SkyLight.shared.orderWindow(windowId, relativeTo: 0, order: .above)
        }
    )
}

private struct ScratchpadStackingPlan {
    let id: UInt64
    let index: ScratchpadIndex
    let workspaceId: WorkspaceDescriptor.ID
    let handles: [WindowHandle]
    var nextHandleIndex: Int
    var pendingHandle: WindowHandle?
    var pendingRequestId: IntentID?
    var pendingActivationSettled: Bool
    var continuationScheduled: Bool
}

private struct DeferredScratchpadStacking {
    let id: UInt64
    let index: ScratchpadIndex
    let workspaceId: WorkspaceDescriptor.ID
    let tokens: [WindowToken]
}

@MainActor @Observable
final class WMController {
    private struct BorderLayoutConfig: Equatable {
        let enabled: Bool
        let width: CGFloat

        func clearance(scale: CGFloat) -> CGFloat {
            BorderConfig.layoutClearance(enabled: enabled, width: width, scale: scale)
        }
    }

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
        let admissionGeometry: WindowAdmissionGeometryEvidence?
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
    @ObservationIgnored
    private var appliedBorderLayoutConfig: BorderLayoutConfig
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
            guard oldValue != isLockScreenActive else { return }
            if isLockScreenActive {
                layoutRefreshController.suspendForLockScreen()
                resetWorkspaceBarReveal()
                mouseEventHandler.handleInputSuppressionBegan()
            } else {
                layoutRefreshController.awaitPostUnlockTopologySample()
            }
        }
    }

    let axManager = AXManager()
    let traceCaptureCoordinator: RuntimeTraceCaptureCoordinator
    let appInfoCache = AppInfoCache()
    @ObservationIgnored
    let workspaceBarIconResolver: WorkspaceBarIconResolver
    private(set) var workspaceBarIconResolutionRevision: UInt64 = 0
    let eventIntake = EventIntake()
    let factResolver = FactResolver()
    let intentLedger = IntentLedger()
    let deadlineWheel = DeadlineWheel()
    @ObservationIgnored
    var scheduleScratchpadStackingContinuation: (@escaping @MainActor () -> Void) -> Void = { continuation in
        Task { @MainActor in
            await Task.yield()
            continuation()
        }
    }

    @ObservationIgnored
    private var scratchpadStackingPlan: ScratchpadStackingPlan?
    @ObservationIgnored
    private var deferredScratchpadStacking: DeferredScratchpadStacking?
    @ObservationIgnored
    private var scratchpadStackingGeneration: UInt64 = 0
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
        set {
            if let current = workspaceManager.dwindleEngine, current !== newValue {
                layoutRefreshController.stopAllDwindleAnimations()
            }
            workspaceManager.dwindleEngine = newValue
        }
    }

    let tabRailManager = TabRailManager()
    @ObservationIgnored
    lazy var nativeFullscreenPlaceholderManager: NativeFullscreenPlaceholderManager = {
        let manager = NativeFullscreenPlaceholderManager()
        manager.appInfoCache = appInfoCache
        manager.onActivate = { [weak self] originalToken in
            self?.activateNativeFullscreenPlaceholder(originalToken)
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
    private static let finderBundleId = "com.apple.finder"
    private static let finderQuickLookSubrole = "Quick Look"
    @ObservationIgnored
    private var hiddenWorkspaceBarMonitorIds: Set<Monitor.ID> = []
    @ObservationIgnored
    private var isWorkspaceBarRevealHeld = false
    @ObservationIgnored
    private lazy var workspaceBarRevealMonitor: WorkspaceBarRevealMonitor = {
        let monitor = WorkspaceBarRevealMonitor()
        monitor.onRevealChanged = { [weak self] revealed in
            self?.setWorkspaceBarRevealHeld(revealed)
        }
        return monitor
    }()

    @ObservationIgnored
    let hiddenBarController: HiddenBarController
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
    private lazy var systemStatsPopupController: SystemStatsPopupController = {
        let controller = SystemStatsPopupController()
        controller.isToggleSourceWindow = { [weak self] window in
            self?.workspaceBarManager.isWorkspaceBarWindow(window) ?? false
        }
        return controller
    }()

    @ObservationIgnored
    private lazy var sponsorsWindowController: SponsorsWindowController = .init(
        motionPolicy: motionPolicy,
        ownedWindowRegistry: ownedWindowRegistry
    )

    var isTransferringWindow: Bool = false

    @ObservationIgnored
    private(set) lazy var mouseEventHandler = MouseEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var mouseWarpHandler = MouseWarpHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var axEventHandler = AXEventHandler(controller: self)
    @ObservationIgnored
    private lazy var placementResolver = PlacementResolver(workspaceManager: workspaceManager)
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
    private var windowActionHandlerStorage: WindowActionHandler?
    var windowActionHandler: WindowActionHandler {
        if let windowActionHandlerStorage {
            return windowActionHandlerStorage
        }
        let handler = WindowActionHandler(controller: self)
        windowActionHandlerStorage = handler
        return handler
    }

    @ObservationIgnored
    lazy var clipboardHistoryService = ClipboardHistoryService(configuration: clipboardHistoryConfiguration())
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
    var currentMouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    @ObservationIgnored
    weak var ipcApplicationBridge: IPCApplicationBridge?

    let animationClock = AnimationClock()
    let motionPolicy: MotionPolicy
    let diagnosticsDirectory: URL
    private let clipboardHistoryDirectory: URL
    let windowFocusOperations: WindowFocusOperations
    weak var statusBarController: StatusBarController?

    init(
        settings: SettingsStore,
        hiddenBarController: HiddenBarController? = nil,
        clipboardHistoryDirectory: URL = OmniWMStoragePaths.live.stateDirectory,
        diagnosticsDirectory: URL = OmniWMStoragePaths.live.diagnosticsDirectory,
        windowFocusOperations: WindowFocusOperations = .live,
        ownedWindowRegistry: OwnedWindowRegistry = .shared,
        workspaceBarIconResolver: WorkspaceBarIconResolver? = nil
    ) {
        self.settings = settings
        appliedBorderLayoutConfig = BorderLayoutConfig(
            enabled: settings.bordersEnabled,
            width: CGFloat(settings.borderWidth)
        )
        self.workspaceBarIconResolver = workspaceBarIconResolver
            ?? WorkspaceBarIconResolver(settingsFileURL: settings.settingsFileURL)
        motionPolicy = MotionPolicy(animationsEnabled: settings.animationsEnabled)
        self.hiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.clipboardHistoryDirectory = clipboardHistoryDirectory
        self.diagnosticsDirectory = diagnosticsDirectory
        traceCaptureCoordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: diagnosticsDirectory)
        self.windowFocusOperations = windowFocusOperations
        self.ownedWindowRegistry = ownedWindowRegistry
        workspaceManager = WorkspaceManager(settings: settings)
        focusPolicyEngine = FocusPolicyEngine()
        if self.workspaceBarIconResolver.synchronize(
            overrides: settings.workspaceBarIconOverrides
        ) {
            workspaceBarIconResolutionRevision = 1
        }
        axManager.isWindowParked = { [workspaceManager] windowId in
            workspaceManager.entry(forWindowId: windowId)?.hiddenState != nil
        }
        intentLedger.seqProvider = { [eventIntake] in eventIntake.lastSeq }
        intentLedger.deadlineWheel = deadlineWheel
        focusPolicyEngine.intentLedger = intentLedger
        focusPolicyEngine.deadlineWheel = deadlineWheel
        hotkeys.onCommand = { [weak self] invocation in
            guard let self else { return }
            if !eventIntake.enqueue(.hotkeyInvocation(invocation)) {
                _ = commandHandler.handleHotkeyInvocation(invocation)
            }
        }
        traceCaptureCoordinator.onStateChange = { [weak self] in
            self?.statusBarController?.handleTraceCaptureStateChange()
        }
        tabRailManager.onSelect = { [weak self] info, visualIndex, token in
            guard let self else { return }
            switch info.owner {
            case .niriColumn:
                layoutRefreshController.selectTabInNiri(
                    info: info,
                    visualIndex: visualIndex,
                    expectedToken: token
                )
            case .dwindleTile:
                dwindleLayoutHandler.selectGroupMember(
                    info: info,
                    visualIndex: visualIndex,
                    expectedToken: token
                )
            }
        }
        workspaceManager.onSessionStateChanged = { [weak self] surfaceScope in
            self?.handleSessionStateChanged(surfaceScope: surfaceScope)
        }
        workspaceManager.onRuntimeInvalidation = { [weak self] workspaceId, domains, surfaceScope in
            self?.handleRuntimeInvalidation(
                workspaceId: workspaceId,
                domains: domains,
                surfaceScope: surfaceScope
            )
        }
        workspaceManager.onWindowPresenceObserved = { [weak self] handle in
            self?.layoutRefreshController.recordWindowPresence(handle)
        }
        workspaceManager.onWindowRemoved = { [weak self] entry in
            self?.windowActionHandlerStorage?.handleOverviewWindowRemoved(entry)
        }
        workspaceManager.onDeferredWorkspaceMonitorMove = { [weak self] outcome in
            self?.layoutRefreshController.commitWorkspaceMonitorTransition(outcome)
        }
        workspaceManager.onAnimationMotionsWillBeRemoved = { [weak self] workspaceIds in
            guard let self else { return }
            for workspaceId in workspaceIds {
                self.niriLayoutHandler.terminateViewportGesture(
                    for: workspaceId,
                    disposition: .settleLiveOffset
                )
                let displayIds = self.niriLayoutHandler.scrollAnimationByDisplay.compactMap { displayId, registered in
                    registered == workspaceId ? displayId : nil
                }
                for displayId in displayIds {
                    self.layoutRefreshController.stopScrollAnimation(for: displayId)
                }
                for displayId in self.dwindleLayoutHandler.animationDisplayIds(for: workspaceId) {
                    self.layoutRefreshController.stopDwindleAnimation(for: displayId)
                }
            }
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
        self.hiddenBarController.onCursorWarp = { [weak self] point in
            self?.mouseWarpHandler.noteProgrammaticCursorMove(to: point)
        }
        self.hiddenBarController.fallbackPlacementsProvider = { [weak self] in
            self?.hiddenBarFallbackIconPlacements() ?? []
        }
    }

    func applyPersistedSettings(_ settings: SettingsStore, startServices: Bool = true) {
        setAnimationsEnabled(settings.animationsEnabled, persist: false)
        applyCurrentAppearanceMode()

        updateHotkeyBindings(settings.hotkeyBindings)
        setHotkeysEnabled(settings.hotkeysEnabled)

        setGapSize(settings.gapSize, publishChange: false)
        setOuterGaps(
            left: settings.outerGapLeft,
            right: settings.outerGapRight,
            top: settings.outerGapTop,
            bottom: settings.outerGapBottom,
            publishChange: false
        )

        if niriEngine == nil {
            enableNiriLayout(
                centerFocusedColumn: settings.niriCenterFocusedColumn,
                alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn
            )
        }
        updateNiriConfig(
            visibleContainerCount: settings.niriVisibleContainerCount,
            infiniteLoop: settings.niriInfiniteLoop,
            centerFocusedColumn: settings.niriCenterFocusedColumn,
            alwaysCenterSingleColumn: settings.niriAlwaysCenterSingleColumn,
            singleWindowFit: settings.niriSingleWindowFit,
            containerPrimarySpanPresets: settings.niriContainerPrimarySpanPresets,
            defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan
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
        updateOverviewSettings()

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
        quakeTerminalController.reloadBackgroundBlur()
        updateWorkspaceBarSettings()
        updateHiddenBarSettings()
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

        guard motionPolicy.animationsEnabled != enabled else { return }

        motionPolicy.animationsEnabled = enabled
    }

    func applyCurrentAppearanceMode() {
        settings.appearanceMode.apply()
        workspaceBarManager.updateAppearance()
        surfaceReconciler.noteWorldChanged()
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

    func setGapSize(_ size: Double, publishChange: Bool = true) {
        workspaceManager.setGaps(to: size)
        if publishChange {
            publishDisplayChanged()
        }
    }

    func setOuterGaps(
        left: Double,
        right: Double,
        top: Double,
        bottom: Double,
        publishChange: Bool = true
    ) {
        workspaceManager.setOuterGaps(left: left, right: right, top: top, bottom: bottom)
        if publishChange {
            publishDisplayChanged()
        }
    }

    func borderSettingsChanged() {
        let current = BorderLayoutConfig(
            enabled: settings.bordersEnabled,
            width: CGFloat(settings.borderWidth)
        )
        let previous = appliedBorderLayoutConfig
        appliedBorderLayoutConfig = current
        let clearanceChanged = workspaceManager.monitors.contains { monitor in
            let scale = backingScaleFactor(for: monitor)
            return previous.clearance(scale: scale) != current.clearance(scale: scale)
        }
        if clearanceChanged {
            workspaceManager.invalidateAllLayouts()
            layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
            surfaceReconciler.noteWorldChanged()
        } else {
            surfaceReconciler.noteBorderChanged()
        }
    }

    func setWorkspaceBarEnabled(_ enabled: Bool) {
        if settings.workspaceBarEnabled != enabled {
            settings.workspaceBarEnabled = enabled
        }
        pruneHiddenWorkspaceBarMonitorIds()
        workspaceBarManager.setup(controller: self, settings: settings)
        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
        syncWorkspaceBarRevealMonitor()
        hiddenBarController.dismissPanel()
    }

    func cleanupUIOnStop() {
        workspaceBarRevealMonitor.stop()
        workspaceBarManager.cleanup()
    }

    func invalidateOverviewDeferredActionsForServiceStop() {
        windowActionHandlerStorage?.invalidateOverviewDeferredActionsForServiceStop()
    }

    func setPreventSleepEnabled(_ enabled: Bool) {
        if enabled {
            SleepPreventionManager.shared.preventSleep()
        } else {
            SleepPreventionManager.shared.allowSleep()
        }
    }

    func toggleHiddenBarPanel() {
        hiddenBarController.togglePanel(placement: hiddenBarPanelPlacement())
    }

    private func hiddenBarPanelPlacement() -> HiddenBarPanelPlacement? {
        let monitors = workspaceManager.monitors
        guard let monitor = currentMouseLocation().monitorApproximation(in: monitors)
            ?? monitors.first(where: \.isMain) ?? monitors.first
        else { return nil }
        let resolved = settings.resolvedBarSettings(for: monitor)
        return HiddenBarPanelPlacement(
            anchor: HiddenBarPanelController.panelAnchor(
                monitor: monitor,
                resolved: resolved,
                barVisible: isWorkspaceBarVisible(on: monitor, resolved: resolved)
            ),
            visibleFrame: monitor.visibleFrame
        )
    }

    private func hiddenBarFallbackIconPlacements() -> [HiddenBarFallbackIconPlacement] {
        workspaceManager.monitors.map { monitor in
            let resolved = settings.resolvedBarSettings(for: monitor)
            return HiddenBarFallbackIconPlacement(
                monitorId: monitor.id,
                frame: HiddenBarFallbackIconController.iconFrame(
                    monitor: monitor,
                    barVisible: isWorkspaceBarVisible(on: monitor, resolved: resolved),
                    barFrame: workspaceBarManager.primaryBarFrame(on: monitor.id)
                )
            )
        }
    }

    func setHiddenBarEnabled(_ enabled: Bool) {
        hiddenBarController.setEnabled(enabled)
    }

    func updateHiddenBarSettings() {
        hiddenBarController.applySettings()
    }

    var isHiddenBarHidingAvailable: Bool {
        hiddenBarController.isHidingAvailable
    }

    func detectMenuBarApps() async -> [DetectedMenuBarApp] {
        await hiddenBarController.detectMenuBarApps()
    }

    func hiddenBarDisplayName(for bundleID: String) -> String {
        hiddenBarController.displayName(for: bundleID)
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

        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
        hiddenBarController.dismissPanel()
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

    func reapplyQuakeTerminalGeometryForMonitorChange() {
        guard settings.quakeTerminalEnabled else { return }
        quakeTerminalController.applyGeometryToVisibleWindow()
    }

    func reloadQuakeTerminalOpacity() {
        quakeTerminalController.reloadOpacityConfig()
    }

    func reloadQuakeTerminalBackgroundEffect() {
        quakeTerminalController.reloadOpacityConfig()
    }

    func reloadQuakeTerminalBackgroundBlur() {
        quakeTerminalController.reloadBackgroundBlur()
    }

    func requestWorkspaceBarRefresh() {
        surfaceReconciler.noteWorldChanged()
    }

    func isManagedWindowDisplayable(_ token: WindowToken) -> Bool {
        guard workspaceManager.entry(for: token) != nil else { return false }
        if isManagedWindowSuppressedByMacOSHide(token) {
            return false
        }
        if workspaceManager.layoutReason(for: token) != .standard {
            return false
        }
        return !workspaceManager.isHiddenInCorner(token)
    }

    func isManagedWindowSuppressedByMacOSHide(_ token: WindowToken) -> Bool {
        workspaceManager.isAppHidden(token)
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

        let focusedAppName: String? = if let focusedToken = workspaceManager.selectedManagedToken,
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

    func updateWorkspaceBarSettings(forceIconReload: Bool = false) {
        synchronizeWorkspaceBarIconOverrides(
            forceReload: forceIconReload
        )
        pruneHiddenWorkspaceBarMonitorIds()
        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
        syncWorkspaceBarRevealMonitor()
        hiddenBarController.dismissPanel()
    }

    func updateWorkspaceBarIconOverride(bundleId: String, forceReload: Bool) {
        guard synchronizeWorkspaceBarIconOverrides(
            forceReloadBundleId: forceReload ? bundleId : nil
        ) else {
            return
        }
        surfaceReconciler.noteWorldChanged()
    }

    func refreshUnavailableWorkspaceBarIconOverride(bundleId: String?) {
        guard let bundleId,
              let resolution = workspaceBarIconResolver.overrideResolution(for: bundleId),
              resolution.image == nil,
              case .bundleResource = resolution.source
        else {
            return
        }

        guard synchronizeWorkspaceBarIconOverrides(
            forceReloadBundleId: bundleId
        ) else {
            return
        }
        surfaceReconciler.noteWorldChanged()
    }

    func updateWorkspaceBarAppearance() {
        workspaceBarManager.updateAppearance()
    }

    @discardableResult
    private func synchronizeWorkspaceBarIconOverrides(
        forceReload: Bool = false,
        forceReloadBundleId: String? = nil
    ) -> Bool {
        guard workspaceBarIconResolver.synchronize(
            overrides: settings.workspaceBarIconOverrides,
            forceReload: forceReload,
            forceReloadBundleId: forceReloadBundleId
        ) else {
            return false
        }
        workspaceBarIconResolutionRevision += 1
        return true
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
        guard dwindleEngine != nil else { return }
        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorGapSettings() {
        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        publishDisplayChanged()
    }

    private func publishDisplayChanged() {
        guard let ipcApplicationBridge else { return }
        Task {
            await ipcApplicationBridge.publishEvent(.displayChanged)
        }
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
            iconResolver: workspaceBarIconResolver,
            focusedToken: workspaceManager.selectedManagedToken,
            settings: settings
        )
    }

    func focusWorkspaceFromBar(id workspaceId: WorkspaceDescriptor.ID) {
        windowActionHandler.focusWorkspaceFromBar(id: workspaceId)
    }

    func focusWindowFromBar(token: WindowToken) {
        windowActionHandler.focusWindowFromBar(token: token)
    }

    func focusWindowFromBar(handle: WindowHandle) {
        windowActionHandler.focusWindowFromBar(handle: handle)
    }

    func toggleSystemStats() {
        let monitors = workspaceManager.monitors
        let target = SystemStatsPopupController.targetMonitor(
            pointer: NSEvent.mouseLocation.monitorApproximation(in: monitors),
            main: monitors.first(where: \.isMain),
            monitors: monitors
        ) { workspaceBarManager.statsAnchor(on: $0) != nil }
        guard let target else { return }
        toggleSystemStatsFromBar(on: target.id)
    }

    func toggleSystemStatsFromBar(on monitorId: Monitor.ID) {
        guard let monitor = workspaceManager.monitors.first(where: { $0.id == monitorId }),
              let anchor = workspaceBarManager.statsAnchor(on: monitorId)
        else {
            return
        }
        systemStatsPopupController.toggle(
            anchor: anchor,
            monitorId: monitorId,
            screenVisibleFrame: monitor.visibleFrame
        )
    }

    func dismissSystemStatsPopup(anchoredTo monitorId: Monitor.ID) {
        systemStatsPopupController.dismissIfAnchored(to: monitorId)
    }

    @discardableResult
    func activateScratchpadFromBar(index: ScratchpadIndex, on monitorId: Monitor.ID?) -> ExternalCommandResult {
        if workspaceManager.revealedScratchpadIndex() != index {
            let hiddenAppHandles = workspaceManager.scratchpadMembers(in: index).compactMap { token in
                workspaceManager.entry(for: token).flatMap {
                    workspaceManager.isAppHidden(pid: $0.pid) ? workspaceManager.handle(for: token) : nil
                }
            }
            if let handle = hiddenAppHandles.first,
               windowActionHandler.revealScratchpadFromBar(
                   handle: handle,
                   index: index,
                   monitorId: monitorId
               )
            {
                return .executed
            }
        }

        if let monitorId {
            _ = workspaceManager.setInteractionMonitor(monitorId)
        }
        return toggleScratchpad(index, on: monitorId)
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
        guard !enabled,
              let request = intentLedger.activeManagedRequest,
              request.origin == .focusFollowsMouse
        else {
            return
        }
        cancelManagedFocusRequestAndRestoreSource(request)
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

    func syncWorkspaceBarRevealMonitor() {
        guard hasStartedServices,
              settings.workspaceBarRevealModifier != .off,
              workspaceBarRefreshIsEnabled
        else {
            workspaceBarRevealMonitor.stop()
            return
        }

        workspaceBarRevealMonitor.start(
            modifier: settings.workspaceBarRevealModifier,
            holdMilliseconds: settings.workspaceBarRevealHoldMilliseconds
        )
    }

    func setWorkspaceBarRevealHeld(_ revealed: Bool) {
        guard isWorkspaceBarRevealHeld != revealed else { return }
        isWorkspaceBarRevealHeld = revealed
        surfaceReconciler.noteWorldChanged()
    }

    func resetWorkspaceBarReveal() {
        workspaceBarRevealMonitor.resetReveal()
    }

    func resetMouseWarpPolicy() {
        mouseWarpHandler.cleanup()
        isMouseWarpPolicyEnabled = false
    }

    func resetMouseWarpTransientState() {
        mouseWarpHandler.resetTransientState()
    }

    func innerGap(for monitor: Monitor) -> CGFloat {
        innerGap(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func innerGap(for monitor: Monitor, scale: CGFloat) -> CGFloat {
        let rawGap = settings.gapSettings(for: monitor)?.innerGap == nil
            ? CGFloat(workspaceManager.gaps)
            : settings.resolvedGapSettings(for: monitor).innerGap
        return max(rawGap, borderClearance(scale: scale))
    }

    func innerGap(for workspaceId: WorkspaceDescriptor.ID) -> CGFloat {
        guard let monitor = workspaceManager.monitor(for: workspaceId) else {
            return CGFloat(workspaceManager.gaps)
        }
        return innerGap(for: monitor)
    }

    func resolvedDwindleSettings(for monitor: Monitor) -> ResolvedDwindleSettings {
        resolvedDwindleSettings(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func resolvedDwindleSettings(for monitor: Monitor, scale: CGFloat) -> ResolvedDwindleSettings {
        let resolved = settings.resolvedDwindleSettings(for: monitor)
        return ResolvedDwindleSettings(
            smartSplit: resolved.smartSplit,
            defaultSplitRatio: resolved.defaultSplitRatio,
            splitWidthMultiplier: resolved.splitWidthMultiplier,
            singleWindowFit: resolved.singleWindowFit,
            useGlobalGaps: resolved.useGlobalGaps,
            innerGap: max(resolved.innerGap, borderClearance(scale: scale))
        )
    }

    func layoutFrames(
        for monitor: Monitor,
        scale: CGFloat
    ) -> (workingFrame: CGRect, borderSafeFillFrame: CGRect, fullscreenLayoutFrame: CGRect) {
        let reservedTopInset = workspaceBarReservedTopInset(for: monitor)
        let gaps = settings.resolvedGapSettings(for: monitor)
        let menuBarInset = max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)
        let normalizedTop = normalizedTopStrut(
            top: gaps.outerGapTop,
            menuBarInset: menuBarInset,
            reservedTopInset: reservedTopInset
        )
        let rawStruts = Struts(
            left: gaps.outerGapLeft,
            right: gaps.outerGapRight,
            top: normalizedTop,
            bottom: gaps.outerGapBottom
        )
        let clearance = borderClearance(scale: scale)
        let effectiveStruts = Struts(
            left: max(rawStruts.left, clearance),
            right: max(rawStruts.right, clearance),
            top: max(rawStruts.top, clearance),
            bottom: max(rawStruts.bottom, clearance)
        )
        let rawWorkingFrame = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: scale,
            struts: rawStruts
        )
        let workingFrame = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: scale,
            struts: effectiveStruts
        )
        let fullscreenLayoutFrame: CGRect
        let borderSafeFillFrame: CGRect
        if gaps.fullscreenUsesOuterGaps {
            fullscreenLayoutFrame = rawWorkingFrame
            borderSafeFillFrame = workingFrame
        } else {
            fullscreenLayoutFrame = computeWorkingArea(
                parentArea: monitor.visibleFrame,
                scale: scale,
                struts: Struts(top: reservedTopInset)
            )
            borderSafeFillFrame = computeWorkingArea(
                parentArea: monitor.visibleFrame,
                scale: scale,
                struts: Struts(
                    left: clearance,
                    right: clearance,
                    top: max(reservedTopInset, clearance),
                    bottom: clearance
                )
            )
        }
        return (workingFrame, borderSafeFillFrame, fullscreenLayoutFrame)
    }

    func niriInteractionGeometry(
        for monitor: Monitor
    ) -> (workingFrame: CGRect, innerGap: CGFloat, scale: CGFloat) {
        niriInteractionGeometry(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func niriInteractionGeometry(
        for monitor: Monitor,
        scale: CGFloat
    ) -> (workingFrame: CGRect, innerGap: CGFloat, scale: CGFloat) {
        let workingFrame = layoutFrames(for: monitor, scale: scale).workingFrame
        return (workingFrame, innerGap(for: monitor, scale: scale), scale)
    }

    func insetWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).workingFrame
    }

    func fullscreenLayoutFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).fullscreenLayoutFrame
    }

    func borderSafeFillFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).borderSafeFillFrame
    }

    func backingScaleFactor(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
    }

    private func borderClearance(scale: CGFloat) -> CGFloat {
        BorderConfig.layoutClearance(
            enabled: settings.bordersEnabled,
            width: CGFloat(settings.borderWidth),
            scale: scale
        )
    }

    private func workspaceBarReservedTopInset(for monitor: Monitor) -> CGFloat {
        guard settings.workspaceBarRevealModifier == .off else { return 0 }
        let resolved = settings.resolvedBarSettings(for: monitor)
        return WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: isWorkspaceBarConfiguredVisible(on: monitor, resolved: resolved)
        ).reservedTopInset
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding], force: Bool = false) {
        hotkeys.updateBindings(
            bindings,
            systemHyperTrigger: settings.systemHyperTrigger,
            force: force
        )
        refreshHotkeyFailureSnapshots()
        refreshDiagnosticsIssues()
    }

    private func refreshHotkeyFailureSnapshots() {
        hotkeyRegistrationFailures = hotkeys.registrationFailures
        systemHyperTriggerFailure = hotkeys.systemHyperTriggerFailure
    }

    func updateWorkspaceConfig() {
        workspaceManager.applySettings()
        syncMonitorsToNiriEngine()
        layoutRefreshController.requestRelayout(reason: .workspaceConfigChanged)
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
        guard isWorkspaceBarConfiguredVisible(on: monitor, resolved: effective) else { return false }
        return !isWorkspaceBarSuppressedByNativeFullscreen(on: monitor)
    }

    private func isWorkspaceBarConfiguredVisible(on monitor: Monitor, resolved: ResolvedBarSettings) -> Bool {
        guard resolved.enabled, !hiddenWorkspaceBarMonitorIds.contains(monitor.id) else { return false }
        return settings.workspaceBarRevealModifier == .off || isWorkspaceBarRevealHeld
    }

    private func isWorkspaceBarSuppressedByNativeFullscreen(on monitor: Monitor) -> Bool {
        guard settings.workspaceBarHideInNativeFullscreen else { return false }
        let topology = workspaceManager.spaceTopology
        guard topology.isPopulated else { return false }
        return topology.isDisplayShowingFullscreenSpace(on: monitor) == true
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
        visibleContainerCount: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        containerPrimarySpanPresets: [Double]? = nil,
        defaultContainerPrimarySpan: Double?? = nil
    ) {
        niriLayoutHandler.updateNiriConfig(
            visibleContainerCount: visibleContainerCount,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowFit: singleWindowFit,
            containerPrimarySpanPresets: containerPrimarySpanPresets,
            defaultContainerPrimarySpan: defaultContainerPrimarySpan
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
        placementResolver.monitorForInteraction()
    }

    private func handleSessionStateChanged(surfaceScope: SessionSurfaceInvalidationScope) {
        switch surfaceScope {
        case .full:
            surfaceReconciler.noteWorldChanged()
        case .border:
            surfaceReconciler.noteBorderChanged()
        }
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
        domains: InvalidationDomain,
        surfaceScope: SessionSurfaceInvalidationScope
    ) {
        switch surfaceScope {
        case .full:
            surfaceReconciler.noteWorldChanged()
        case .border:
            surfaceReconciler.noteBorderChanged()
        }
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
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        placementMode: TrackedWindowMode,
        allowsFloatingSpawnPlacement: Bool = false,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        createPlacementContext: WindowCreatePlacementContext? = nil,
        windowFrame: CGRect? = nil,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspacePlacementResolution {
        placementResolver.resolveWorkspacePlacement(
            workspaceName: workspaceName,
            axRef: axRef,
            pid: pid,
            parentWindowId: parentWindowId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            placementMode: placementMode,
            allowsFloatingSpawnPlacement: allowsFloatingSpawnPlacement,
            origin: placementOrigin,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame,
            existingEntry: nil,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: .automatic
        )
    }

    #if DEBUG
        func testFloatingSpawnMonitorId(pid: pid_t) -> Monitor.ID? {
            placementResolver.floatingSpawnMonitorId(pid: pid)
        }
    #endif

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

    func allowsFloatingSpawnPlacement(
        for evaluation: WindowDecisionEvaluation,
        mode: TrackedWindowMode
    ) -> Bool {
        let ax = evaluation.facts.ax
        return mode == .floating
            && ax.attributeFetchSucceeded
            && ax.bundleId == Self.finderBundleId
            && ax.role == kAXWindowRole as String
            && ax.subrole == Self.finderQuickLookSubrole
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

    func adoptObservedMinimumAfterTerminalSizeWriteFailure(_ refusal: AXFrameTerminalRefusal) {
        guard case .sizeWriteFailed = refusal.failureReason,
              let entry = workspaceManager.entry(forWindowId: refusal.windowId),
              entry.mode == .tiling,
              workspaceManager.hiddenState(for: entry.token) == nil
        else {
            return
        }
        let token = entry.token

        let target = refusal.targetFrame.size
        let observed = refusal.observedFrame.size
        let existing = workspaceManager.observedMinSize(for: token) ?? CGSize(width: 1, height: 1)
        let observedMin = CGSize(
            width: Self.updatedObservedMinimumAxis(
                existing: existing.width,
                target: target.width,
                observed: observed.width
            ),
            height: Self.updatedObservedMinimumAxis(
                existing: existing.height,
                target: target.height,
                observed: observed.height
            )
        )
        guard observedMin.width > 1 || observedMin.height > 1 else { return }

        guard workspaceManager.setObservedMinSize(observedMin, for: token) else { return }
        workspaceManager.invalidateLayout(for: [entry.workspaceId])
        layoutRefreshController.requestRelayout(
            reason: .observedConstraintsChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private static func updatedObservedMinimumAxis(
        existing: CGFloat,
        target: CGFloat,
        observed: CGFloat
    ) -> CGFloat {
        if observed > target + FrameTolerance.frameWrite { return observed }
        if target < existing - FrameTolerance.frameWrite { return 1 }
        return existing
    }

    private func evaluateSizeConstraints(
        for token: WindowToken,
        axRef: AXWindowRef,
        admissionGeometry: WindowAdmissionGeometryEvidence? = nil
    ) -> WindowSizeConstraints {
        if let cached = workspaceManager.cachedConstraints(for: token) {
            return cached
        }

        let currentSize = admissionGeometry?.frame?.size
            ?? AXWindowService.framePreferFast(axRef)?.size
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

    private func initialFloatingFrame(
        for entry: WindowState,
        preferredMonitor: Monitor?,
        sourceFrame: CGRect? = nil,
        allowLiveFrameFallback: Bool = true
    ) -> CGRect? {
        guard let frame = sourceFrame ?? (allowLiveFrameFallback ? liveFrame(for: entry) : nil) else { return nil }
        let offsetFrame = frame.offsetBy(dx: 50, dy: 50)
        guard let monitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        ) else {
            return offsetFrame
        }
        return FloatingFrameGeometry.clamped(offsetFrame, in: monitor.visibleFrame)
    }

    private func shouldApplyFloatingFrameImmediately(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let monitor = workspaceManager.monitor(for: workspaceId) else { return false }
        return workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
    }

    func seedFloatingGeometryIfNeeded(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil,
        observedFrame: CGRect? = nil,
        allowLiveFrameFallback: Bool = true
    ) {
        guard workspaceManager.floatingState(for: token) == nil,
              let entry = workspaceManager.entry(for: token),
              let frame = observedFrame ?? (allowLiveFrameFallback ? liveFrame(for: entry) : nil)
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
        preferFrontmostWhenExternalOrOwnedFocusActive: Bool = false
    ) -> WindowToken? {
        let selectedManagedToken = workspaceManager.selectedManagedToken
        let frontmostPid = commandHandler.frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
        if preferFrontmostWhenExternalOrOwnedFocusActive {
            switch workspaceManager.nativeFocusOwner {
            case .external,
                 .ownedSurface:
                return frontmostToken ?? selectedManagedToken
            case .managed,
                 .none:
                break
            }
        }
        return selectedManagedToken ?? frontmostToken
    }

    func captureQuakeTerminalRestoreTarget() -> QuakeTerminalRestoreTarget? {
        guard let token = workspaceManager.renderableFocusToken
            ?? focusedOrFrontmostWindowTokenForAutomation(preferFrontmostWhenExternalOrOwnedFocusActive: true)
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
            preferFrontmostWhenExternalOrOwnedFocusActive: true
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
        guard let token,
              workspaceManager.entry(for: token) != nil,
              !workspaceManager.isAppHidden(token)
        else {
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
        guard let entry = workspaceManager.entry(for: token) else {
            return false
        }

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
        excluding excludedTokens: Set<WindowToken>
    ) -> WindowToken? {
        let explicitCandidates = [
            workspaceManager.lastFocusedToken(in: workspaceId),
            workspaceManager.preferredFocusToken(in: workspaceId),
            workspaceManager.lastFloatingFocusedToken(in: workspaceId),
            workspaceManager.selectedManagedToken
        ]

        for candidate in explicitCandidates {
            guard let candidate,
                  !excludedTokens.contains(candidate),
                  let entry = workspaceManager.entry(for: candidate),
                  entry.workspaceId == workspaceId,
                  isManagedWindowDisplayable(entry.token)
            else {
                continue
            }
            return candidate
        }

        if let tiledEntry = workspaceManager.tiledEntries(in: workspaceId).first(where: {
            !excludedTokens.contains($0.token) && isManagedWindowDisplayable($0.token)
        }) {
            return tiledEntry.token
        }

        return workspaceManager.floatingEntries(in: workspaceId).first(where: {
            !excludedTokens.contains($0.token) && isManagedWindowDisplayable($0.token)
        })?.token
    }

    private func recoverFocusAfterScratchpadHide(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding tokens: Set<WindowToken>,
        on monitorId: Monitor.ID?
    ) {
        if let nextFocusToken = visibleFocusRecoveryToken(in: workspaceId, excluding: tokens) {
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

    func rekeyScratchpadWindowResources(from oldToken: WindowToken, to newToken: WindowToken, axRef: AXWindowRef) {
        guard workspaceManager.hiddenState(for: newToken)?.isScratchpad == true else { return }
        AXWindowService.unpinAXElement(for: UInt32(oldToken.windowId))
        AXWindowService.pinAXElement(axRef.element, for: UInt32(newToken.windowId))
    }

    private func logicalScratchpadHiddenState(
        for entry: WindowState,
        monitor: Monitor
    ) -> HiddenState? {
        guard let floatingState = workspaceManager.floatingState(for: entry.token) else { return nil }
        let referenceMonitor = floatingState.referenceMonitorId.flatMap { workspaceManager.monitor(byId: $0) }
            ?? monitor
        return HiddenState(
            proportionalPosition: layoutRefreshController.proportionalPosition(
                topLeft: floatingState.lastFrame.topLeftCorner,
                in: referenceMonitor.frame
            ),
            referenceMonitorId: referenceMonitor.id,
            reason: .scratchpad
        )
    }

    @discardableResult
    private func parkScratchpadWindow(
        _ entry: WindowState,
        monitor: Monitor,
        captureGeometry: Bool = true
    ) -> Bool {
        let logicalOnly = workspaceManager.isAppHidden(pid: entry.pid)
            || isManagedWindowSuspendedForNativeFullscreen(entry.token)
        if logicalOnly {
            guard let hiddenState = logicalScratchpadHiddenState(for: entry, monitor: monitor) else {
                return false
            }
            let frameEntry = [(entry.pid, entry.windowId)]
            axManager.cancelPendingFrameJobs(frameEntry)
            axManager.suppressFrameWrites(frameEntry)
            workspaceManager.setHiddenState(hiddenState, for: entry.token)
            return true
        }

        if captureGeometry {
            _ = captureVisibleFloatingGeometry(for: entry.token, preferredMonitor: monitor)
        }
        if let ref = AXWindowService.axWindowRef(for: UInt32(entry.windowId), pid: entry.pid) {
            AXWindowService.pinAXElement(ref.element, for: UInt32(entry.windowId))
        }

        let parked = layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: layoutRefreshController.preferredHideSide(for: monitor),
            reason: .scratchpad
        )
        if !parked,
           workspaceManager.hiddenState(for: entry.token) == nil,
           !workspaceManager.isAppHidden(pid: entry.pid),
           !isManagedWindowSuspendedForNativeFullscreen(entry.token)
        {
            axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
        }
        return parked
    }

    private func hideScratchpadMembers(
        _ entries: [WindowState],
        fallbackMonitor: Monitor,
        captureGeometry: Bool = true
    ) {
        let focusedEntry = workspaceManager.selectedManagedToken.flatMap { focusedToken in
            entries.first { $0.token == focusedToken }
        }
        for entry in entries {
            _ = parkScratchpadWindow(
                entry,
                monitor: workspaceManager.monitor(for: entry.workspaceId) ?? fallbackMonitor,
                captureGeometry: captureGeometry
            )
        }
        requestWorkspaceBarRefresh()
        if let focusedEntry {
            recoverFocusAfterScratchpadHide(
                in: workspaceManager.workspace(for: focusedEntry.token) ?? focusedEntry.workspaceId,
                excluding: Set(entries.map(\.token)),
                on: (workspaceManager.monitor(for: focusedEntry.workspaceId) ?? fallbackMonitor).id
            )
        }
    }

    @discardableResult
    private func showScratchpadWindow(
        _ entry: WindowState,
        on workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        onRevealed: LayoutRefreshController.PostLayoutAction? = nil,
        revealGroupId: UInt64? = nil
    ) -> Bool {
        let entry = workspaceManager.entry(for: entry.token) ?? entry
        axManager.markWindowActive(entry.windowId)

        if let hiddenState = workspaceManager.hiddenState(for: entry.token) {
            if hiddenState.isScratchpad {
                return layoutRefreshController.restoreScratchpadWindow(
                    entry,
                    monitor: monitor,
                    onSuccess: onRevealed,
                    revealGroupId: revealGroupId
                )
            }
            return layoutRefreshController.unhideWindow(
                entry,
                monitor: monitor,
                onSuccess: onRevealed,
                revealGroupId: revealGroupId
            )
        }

        if let frame = workspaceManager.resolvedFloatingFrame(
            for: entry.token,
            preferredMonitor: monitor
        ) {
            axManager.forceApplyNextFrame(for: entry.windowId)
            axManager.applyFramesParallel([
                .init(pid: entry.pid, window: entry.axRef, frame: frame)
            ])
        }

        if let revealGroupId {
            layoutRefreshController.recordScratchpadRevealSuccess(entry.token, groupId: revealGroupId)
        } else {
            onRevealed?()
        }
        return true
    }

    private func scratchpadEntries(in index: ScratchpadIndex) -> [WindowState] {
        workspaceManager.scratchpadMembers(in: index).compactMap { token in
            guard let entry = workspaceManager.entry(for: token) else {
                cleanupScratchpadWindowResources(for: token)
                return nil
            }
            return entry
        }
    }

    private func revealableScratchpadEntries(in index: ScratchpadIndex) -> [WindowState] {
        scratchpadEntries(in: index).filter { entry in
            !isManagedWindowSuspendedForNativeFullscreen(entry.token)
                && !workspaceManager.isAppHidden(pid: entry.pid)
        }
    }

    private func stackScratchpadMembers(
        _ tokens: [WindowToken],
        in index: ScratchpadIndex,
        on workspaceId: WorkspaceDescriptor.ID
    ) {
        let planId = reserveScratchpadStackingGeneration()
        startScratchpadStacking(
            tokens,
            in: index,
            on: workspaceId,
            planId: planId
        )
    }

    private func reserveScratchpadStackingGeneration() -> UInt64 {
        scratchpadStackingGeneration &+= 1
        scratchpadStackingPlan = nil
        deferredScratchpadStacking = nil
        return scratchpadStackingGeneration
    }

    private func startScratchpadStacking(
        _ tokens: [WindowToken],
        in index: ScratchpadIndex,
        on workspaceId: WorkspaceDescriptor.ID,
        planId: UInt64,
        waitingFor barrierRequest: ManagedFocusRequest? = nil
    ) {
        guard scratchpadStackingGeneration == planId else { return }
        let handles = tokens.compactMap { workspaceManager.handle(for: $0) }
        guard !handles.isEmpty else {
            scratchpadStackingPlan = nil
            return
        }
        var plan = ScratchpadStackingPlan(
            id: planId,
            index: index,
            workspaceId: workspaceId,
            handles: handles,
            nextHandleIndex: 0,
            pendingHandle: nil,
            pendingRequestId: nil,
            pendingActivationSettled: false,
            continuationScheduled: false
        )
        if let barrierRequest {
            guard barrierRequest.workspaceId == workspaceId,
                  let barrierHandle = workspaceManager.handle(for: barrierRequest.token),
                  intentLedger.activeManagedRequest(requestId: barrierRequest.requestId) != nil,
                  workspaceManager.pendingManagedFocusMatches(
                      token: barrierRequest.token,
                      workspaceId: barrierRequest.workspaceId,
                      requestId: barrierRequest.requestId
                  )
            else {
                scratchpadStackingPlan = nil
                return
            }
            plan.pendingHandle = barrierHandle
            plan.pendingRequestId = barrierRequest.requestId
            plan.pendingActivationSettled = axEventHandler.frontmostApplicationPIDProvider()
                == barrierRequest.token.pid
            scratchpadStackingPlan = plan
            return
        }
        scratchpadStackingPlan = plan
        advanceScratchpadStacking(planId: planId)
    }

    func resumeRehomedScratchpadStackingAfterFocusHandoff() {
        guard let deferred = deferredScratchpadStacking,
              deferred.id == scratchpadStackingGeneration
        else {
            return
        }
        deferredScratchpadStacking = nil
        startScratchpadStacking(
            deferred.tokens,
            in: deferred.index,
            on: deferred.workspaceId,
            planId: deferred.id,
            waitingFor: intentLedger.activeManagedRequest
        )
    }

    private func advanceScratchpadStacking(planId: UInt64) {
        guard var plan = scratchpadStackingPlan, plan.id == planId else { return }
        guard workspaceManager.revealedScratchpadIndex() == plan.index,
              workspaceManager.visibleWorkspaceIds().contains(plan.workspaceId)
        else {
            scratchpadStackingPlan = nil
            return
        }

        while plan.nextHandleIndex < plan.handles.count {
            let handle = plan.handles[plan.nextHandleIndex]
            plan.nextHandleIndex += 1
            guard let entry = scratchpadStackingEntry(for: handle, in: plan) else {
                continue
            }

            plan.pendingHandle = handle
            plan.pendingRequestId = nil
            plan.pendingActivationSettled = axEventHandler.frontmostApplicationPIDProvider() == entry.pid
            plan.continuationScheduled = false
            scratchpadStackingPlan = plan
            let origin: ManagedFocusOrigin = plan.handles[plan.nextHandleIndex...].contains { candidate in
                scratchpadStackingEntry(for: candidate, in: plan) != nil
            } ? .pointerHover : .keyboardOrProgrammatic
            guard let request = focusWindow(handle.id, origin: origin) else {
                plan.pendingHandle = nil
                scratchpadStackingPlan = plan
                continue
            }
            guard intentLedger.activeManagedRequest(requestId: request.requestId) != nil,
                  workspaceManager.pendingManagedFocusMatches(
                      token: request.token,
                      workspaceId: request.workspaceId,
                      requestId: request.requestId
                  )
            else {
                plan.pendingHandle = nil
                scratchpadStackingPlan = plan
                continue
            }
            plan.pendingRequestId = request.requestId
            scratchpadStackingPlan = plan
            return
        }

        scratchpadStackingPlan = nil
    }

    private func scratchpadStackingEntry(
        for handle: WindowHandle,
        in plan: ScratchpadStackingPlan
    ) -> WindowState? {
        guard workspaceManager.scratchpadIndex(for: handle.id) == plan.index,
              let entry = workspaceManager.entry(for: handle),
              entry.workspaceId == plan.workspaceId,
              workspaceManager.hiddenState(for: handle.id) == nil,
              !workspaceManager.isAppHidden(pid: entry.pid),
              !isManagedWindowSuspendedForNativeFullscreen(handle.id)
        else {
            return nil
        }
        return entry
    }

    func continueScratchpadStacking(after request: ManagedFocusRequest) {
        guard let plan = scratchpadStackingPlan,
              plan.pendingRequestId == request.requestId,
              plan.pendingHandle?.id == request.token
        else {
            return
        }
        scheduleScratchpadStackingIfReady(planId: plan.id)
    }

    func advanceScratchpadStackingAfterFocusRetryExhaustion(_ request: ManagedFocusRequest) {
        guard var plan = scratchpadStackingPlan,
              plan.pendingRequestId == request.requestId,
              plan.pendingHandle?.id == request.token
        else {
            return
        }
        plan.pendingHandle = nil
        plan.pendingRequestId = nil
        plan.pendingActivationSettled = false
        plan.continuationScheduled = false
        scratchpadStackingPlan = plan
        advanceScratchpadStacking(planId: plan.id)
    }

    func abortScratchpadStacking(matching requestId: IntentID) {
        guard scratchpadStackingPlan?.pendingRequestId == requestId else { return }
        _ = reserveScratchpadStackingGeneration()
    }

    func noteScratchpadStackingAppActivation(pid: pid_t, source: ActivationEventSource) {
        guard source == .workspaceDidActivateApplication,
              var plan = scratchpadStackingPlan,
              let pendingHandle = plan.pendingHandle,
              pendingHandle.id.pid == pid,
              axEventHandler.frontmostApplicationPIDProvider() == pid
        else {
            return
        }
        plan.pendingActivationSettled = true
        scratchpadStackingPlan = plan
        scheduleScratchpadStackingIfReady(planId: plan.id)
    }

    private func scheduleScratchpadStackingIfReady(planId: UInt64) {
        guard var plan = scratchpadStackingPlan,
              plan.id == planId,
              !plan.continuationScheduled,
              plan.pendingActivationSettled,
              let pendingPID = plan.pendingHandle?.id.pid,
              let requestId = plan.pendingRequestId,
              intentLedger.intent(id: requestId)?.phase == .confirmed,
              intentLedger.newestFocusIntentId() == requestId
        else {
            return
        }
        plan.continuationScheduled = true
        scratchpadStackingPlan = plan
        scheduleScratchpadStackingContinuation { [weak self] in
            guard let self,
                  var currentPlan = scratchpadStackingPlan,
                  currentPlan.id == planId,
                  currentPlan.pendingRequestId == requestId
            else {
                return
            }
            guard intentLedger.intent(id: requestId)?.phase == .confirmed,
                  intentLedger.newestFocusIntentId() == requestId,
                  axEventHandler.frontmostApplicationPIDProvider() == pendingPID,
                  workspaceManager.selectedManagedToken == currentPlan.pendingHandle?.id,
                  workspaceManager.revealedScratchpadIndex() == currentPlan.index,
                  workspaceManager.visibleWorkspaceIds().contains(currentPlan.workspaceId)
            else {
                scratchpadStackingPlan = nil
                return
            }
            currentPlan.pendingHandle = nil
            currentPlan.pendingRequestId = nil
            currentPlan.pendingActivationSettled = false
            currentPlan.continuationScheduled = false
            scratchpadStackingPlan = currentPlan
            advanceScratchpadStacking(planId: planId)
        }
    }

    private func revealScratchpadMembers(
        _ entries: [WindowState],
        in index: ScratchpadIndex,
        on workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        preferring preferredToken: WindowToken? = nil
    ) -> Bool {
        for entry in scratchpadEntries(in: index) where entry.workspaceId != workspaceId {
            reassignManagedWindow(entry.token, to: workspaceId)
        }
        let resolvedEntries = entries.compactMap { workspaceManager.entry(for: $0.token) }
        let preferredToken = preferredToken ?? workspaceManager.lastFocusedToken(in: workspaceId)
        let ordered = resolvedEntries.filter { $0.token != preferredToken }
            + resolvedEntries.filter { $0.token == preferredToken }
        let orderedHandles = ordered.compactMap { workspaceManager.handle(for: $0.token) }
        var revealed = false
        let groupId = layoutRefreshController.beginScratchpadRevealGroup(index: index) { [weak self] outcome in
            guard let self else { return }
            let revealedHandleIds = Set(outcome.revealedHandles.map(ObjectIdentifier.init))
            let survivors = orderedHandles.compactMap { handle -> WindowToken? in
                guard revealedHandleIds.contains(ObjectIdentifier(handle)),
                      self.workspaceManager.scratchpadIndex(for: handle.id) == index,
                      self.workspaceManager.entry(for: handle) != nil,
                      self.workspaceManager.hiddenState(for: handle.id) == nil
                else {
                    return nil
                }
                return handle.id
            }
            guard !survivors.isEmpty else {
                if self.workspaceManager.revealedScratchpadIndex() == index {
                    self.workspaceManager.setRevealedScratchpad(nil)
                    self.requestWorkspaceBarRefresh()
                }
                return
            }
            self.stackScratchpadMembers(survivors, in: index, on: workspaceId)
        }

        for entry in ordered {
            if showScratchpadWindow(
                entry,
                on: workspaceId,
                monitor: monitor,
                revealGroupId: groupId
            ) {
                revealed = true
            }
        }

        guard revealed else {
            layoutRefreshController.discardScratchpadRevealGroup(groupId)
            return false
        }
        layoutRefreshController.sealScratchpadRevealGroup(groupId)
        requestWorkspaceBarRefresh()
        return true
    }

    func rehomeRevealedScratchpad(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let index = workspaceManager.revealedScratchpadIndex() else { return }
        let members = workspaceManager.scratchpadMembers(in: index)
        let focusedMember = workspaceManager.selectedManagedToken.flatMap { members.contains($0) ? $0 : nil }
        var targetWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for token in members {
            guard let entry = workspaceManager.entry(for: token),
                  !activeWorkspaceIds.contains(entry.workspaceId),
                  let monitor = workspaceManager.monitor(for: entry.workspaceId),
                  let target = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
                  target != entry.workspaceId
            else {
                continue
            }
            reassignManagedWindow(token, to: target)
            targetWorkspaceIds.insert(target)
        }
        guard !targetWorkspaceIds.isEmpty else { return }
        let planId = reserveScratchpadStackingGeneration()
        guard targetWorkspaceIds.count == 1,
              let targetWorkspaceId = targetWorkspaceIds.first
        else {
            return
        }
        let survivors = members.filter { token in
            workspaceManager.entry(for: token)?.workspaceId == targetWorkspaceId
                && workspaceManager.hiddenState(for: token) == nil
        }
        let preferred = focusedMember.flatMap { survivors.contains($0) ? $0 : nil } ?? survivors.last
        let ordered = survivors.filter { $0 != preferred } + survivors.filter { $0 == preferred }
        guard !ordered.isEmpty else { return }
        deferredScratchpadStacking = DeferredScratchpadStacking(
            id: planId,
            index: index,
            workspaceId: targetWorkspaceId,
            tokens: ordered
        )
    }

    private func hideRevealedScratchpad(_ index: ScratchpadIndex, fallbackMonitor: Monitor) {
        let entries = scratchpadEntries(in: index).filter { entry in
            workspaceManager.hiddenState(for: entry.token) == nil
                || workspaceManager.isAppHidden(pid: entry.pid)
                || isManagedWindowSuspendedForNativeFullscreen(entry.token)
        }
        hideScratchpadMembers(entries, fallbackMonitor: fallbackMonitor)
        workspaceManager.setRevealedScratchpad(nil)
    }

    @discardableResult
    func transitionWindowMode(
        for token: WindowToken,
        to targetMode: TrackedWindowMode,
        preferredMonitor: Monitor? = nil,
        applyFloatingFrame: Bool? = nil,
        observedFrame: CGRect? = nil,
        allowLiveFrameFallback: Bool = true
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        let currentMode = entry.mode
        guard currentMode != targetMode else { return false }

        let currentFrame = observedFrame ?? (allowLiveFrameFallback ? liveFrame(for: entry) : nil)
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: currentFrame
        )

        switch (currentMode, targetMode) {
        case (.tiling, .floating):
            let targetFrame = initialFloatingFrame(
                for: entry,
                preferredMonitor: referenceMonitor,
                sourceFrame: currentFrame,
                allowLiveFrameFallback: allowLiveFrameFallback
            )
            _ = workspaceManager.setWindowMode(.floating, for: token)
            mouseEventHandler.discardNativeTitleBarDrag(for: token)
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
                    axManager.applyFramesParallel([
                        .init(pid: entry.pid, window: entry.axRef, frame: targetFrame)
                    ])
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

    func shouldDeferAdmission(
        evaluation: WindowDecisionEvaluation,
        axRef: AXWindowRef,
        mode: TrackedWindowMode,
        windowInfo: WindowServerInfo?
    ) -> Bool {
        if let admissionGeometry = evaluation.admissionGeometry {
            if mode == .tiling,
               !admissionGeometry.isSizeSettable
            {
                return true
            }
            guard let frame = evaluation.facts.windowServer?.frame
                ?? windowInfo?.frame
                ?? admissionGeometry.frame
            else {
                return true
            }
            return !Self.isMeaningfulAdmissionFrame(frame)
        }
        if mode == .tiling,
           !AXWindowService.isSizeSettable(axRef)
        {
            return true
        }
        if let frame = evaluation.facts.windowServer?.frame ?? windowInfo?.frame,
           Self.isMeaningfulAdmissionFrame(frame)
        {
            return false
        }
        guard let axFrame = AXWindowService.framePreferFast(axRef)
            ?? (try? AXWindowService.frame(axRef))
        else {
            return true
        }
        return !Self.isMeaningfulAdmissionFrame(axFrame)
    }

    static func isMeaningfulAdmissionFrame(_ frame: CGRect) -> Bool {
        !frame.isNull
            && !frame.isInfinite
            && frame.width > 1
            && frame.height > 1
    }

    func trackedModePreservingAutomaticFallbackState(
        decision: WindowDecision,
        existingEntry: WindowState?,
        context: WindowRuleReevaluationContext
    ) -> TrackedWindowMode? {
        if context == .automatic,
           let existingEntry,
           decision.isUnprovenIndependentRootDecision
        {
            floatDemotionFirstSamplesByToken.removeValue(forKey: existingEntry.token)
            return existingEntry.mode
        }

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
        axRef: AXWindowRef?,
        existingEntry: WindowState?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        placementMode: TrackedWindowMode,
        placementOrigin: WorkspacePlacementOrigin,
        createPlacementContext: WindowCreatePlacementContext? = nil,
        windowFrame: CGRect? = nil,
        context: WindowRuleReevaluationContext = .automatic
    ) -> WorkspaceDescriptor.ID {
        let inheritTrackedParentWorkspace = shouldInheritTrackedParentWorkspace(for: evaluation)
        return placementResolver.resolveWorkspacePlacement(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: evaluation.token.pid,
            parentWindowId: evaluation.facts.windowServer?.parentId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            placementMode: placementMode,
            allowsFloatingSpawnPlacement: allowsFloatingSpawnPlacement(
                for: evaluation,
                mode: placementMode
            ),
            origin: placementOrigin,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame ?? evaluation.facts.windowServer?.frame,
            existingEntry: existingEntry,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: context
        ).workspaceId
    }

    func evaluateWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil,
        applyingManualOverride: Bool = true,
        windowInfo: WindowServerInfo? = nil,
        windowServerLookupAttempted: Bool = false,
        admissionGeometry: WindowAdmissionGeometryEvidence? = nil
    ) -> WindowDecisionEvaluation {
        let token = WindowToken(pid: pid, windowId: axRef.windowId)
        if pid == ProcessInfo.processInfo.processIdentifier || isOwnedWindow(windowNumber: axRef.windowId) {
            return Self.ownedWindowDispositionEvaluation(token: token)
        }
        let sizeConstraints = evaluateSizeConstraints(
            for: token,
            axRef: axRef,
            admissionGeometry: admissionGeometry
        )
        let appInfo = resolvedAppInfo(for: pid)
        let baseFacts = WindowRuleFacts(
            appName: appInfo?.name,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: appInfo?.activationPolicy,
                bundleId: appInfo?.bundleId,
                includeTitle: windowRuleEngine.requiresTitle(
                    for: appInfo?.bundleId,
                    appName: appInfo?.name
                )
            ),
            sizeConstraints: sizeConstraints,
            windowServer: nil
        )
        let fullscreen = appFullscreen ?? AXWindowService.isFullscreen(axRef)
        let lookupAttempted = windowServerLookupAttempted || windowInfo != nil
        var resolvedWindowInfo = Self.exactWindowServerInfo(windowInfo, for: token)

        func evaluate(with windowServer: WindowServerInfo?) -> WindowDecisionEvaluation {
            makeWindowDispositionEvaluation(
                token: token,
                facts: WindowRuleFacts(
                    appName: baseFacts.appName,
                    ax: baseFacts.ax,
                    sizeConstraints: baseFacts.sizeConstraints,
                    windowServer: windowServer
                ),
                appFullscreen: fullscreen,
                applyingManualOverride: applyingManualOverride,
                admissionGeometry: admissionGeometry
            )
        }

        var evaluation = evaluate(with: resolvedWindowInfo)
        if evaluation.decision.deferredReason == .windowServerEvidenceMissing,
           !lookupAttempted
        {
            resolvedWindowInfo = resolveWindowServerInfoForDisposition(
                token: token,
                axFacts: baseFacts.ax,
                preferredWindowInfo: nil
            )
            evaluation = evaluate(with: resolvedWindowInfo)
        }
        return evaluation
    }

    func evaluateWindowDisposition(
        token: WindowToken,
        evidence: AXWindowDecisionEvidence,
        appFullscreen: Bool,
        applyingManualOverride: Bool = true,
        windowInfo: WindowServerInfo?,
        admissionGeometry: WindowAdmissionGeometryEvidence
    ) -> WindowDecisionEvaluation {
        if token.pid == ProcessInfo.processInfo.processIdentifier || isOwnedWindow(windowNumber: token.windowId) {
            return Self.ownedWindowDispositionEvaluation(token: token)
        }
        let appInfo = resolvedAppInfo(for: token.pid)
        let captured = evidence.facts
        let axFacts = AXWindowFacts(
            role: captured.role,
            subrole: captured.subrole,
            title: captured.title,
            hasCloseButton: captured.hasCloseButton,
            hasFullscreenButton: captured.hasFullscreenButton,
            fullscreenButtonEnabled: captured.fullscreenButtonEnabled,
            hasZoomButton: captured.hasZoomButton,
            hasMinimizeButton: captured.hasMinimizeButton,
            appPolicy: captured.appPolicy ?? appInfo?.activationPolicy,
            bundleId: captured.bundleId ?? appInfo?.bundleId,
            attributeFetchSucceeded: captured.attributeFetchSucceeded,
            isMain: captured.isMain,
            isModal: captured.isModal
        )
        return makeWindowDispositionEvaluation(
            token: token,
            facts: WindowRuleFacts(
                appName: appInfo?.name,
                ax: axFacts,
                sizeConstraints: evidence.sizeConstraints,
                windowServer: Self.exactWindowServerInfo(windowInfo, for: token)
            ),
            appFullscreen: appFullscreen,
            applyingManualOverride: applyingManualOverride,
            admissionGeometry: admissionGeometry
        )
    }

    private func makeWindowDispositionEvaluation(
        token: WindowToken,
        facts: WindowRuleFacts,
        appFullscreen: Bool,
        applyingManualOverride: Bool,
        admissionGeometry: WindowAdmissionGeometryEvidence?
    ) -> WindowDecisionEvaluation {
        let manualOverride = workspaceManager.manualLayoutOverride(for: token)
        let baseDecision = windowRuleEngine.decision(
            for: facts,
            token: token,
            appFullscreen: appFullscreen
        )
        let decision = applyingManualOverride
            ? WindowRuleEngine.applyingManualOverride(baseDecision, manualOverride: manualOverride)
            : baseDecision
        return WindowDecisionEvaluation(
            token: token,
            facts: facts,
            decision: decision,
            appFullscreen: appFullscreen,
            manualOverride: manualOverride,
            admissionGeometry: admissionGeometry
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
                admissionHints: .none,
                heuristicReasons: [],
                deferredReason: nil
            ),
            appFullscreen: false,
            manualOverride: nil,
            admissionGeometry: nil
        )
    }

    private func batchedWindowServerInfo(
        for tokens: Set<WindowToken>
    ) -> [WindowToken: WindowServerInfo] {
        let windowIds = Set(tokens.compactMap { UInt32(exactly: $0.windowId) })
        guard windowIds.count > 1 else { return [:] }
        let infoByWindowId = axEventHandler.resolveWindowInfo(windowIds)
        return tokens.reduce(into: [:]) { result, token in
            guard let windowId = UInt32(exactly: token.windowId),
                  let info = Self.exactWindowServerInfo(infoByWindowId[windowId], for: token)
            else {
                return
            }
            result[token] = info
        }
    }

    static func exactWindowServerInfo(
        _ windowInfo: WindowServerInfo?,
        for token: WindowToken
    ) -> WindowServerInfo? {
        guard let windowInfo,
              let windowId = UInt32(exactly: token.windowId),
              windowInfo.id == windowId,
              pid_t(windowInfo.pid) == token.pid
        else {
            return nil
        }
        return windowInfo
    }

    func resolveWindowServerInfoForDisposition(
        token: WindowToken,
        axFacts: AXWindowFacts,
        preferredWindowInfo: WindowServerInfo?
    ) -> WindowServerInfo? {
        if preferredWindowInfo != nil {
            return Self.exactWindowServerInfo(preferredWindowInfo, for: token)
        }

        guard axFacts.role != (kAXHelpTagRole as String),
              let windowId = UInt32(exactly: token.windowId)
        else {
            return nil
        }

        return Self.exactWindowServerInfo(
            axEventHandler.resolveWindowInfo(windowId),
            for: token
        )
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
            initialNiriContainerPrimarySpan: evaluation.decision.admissionHints.initialNiriContainerPrimarySpan,
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

    static func ruleReevaluationLifetimeAuthority(
        existing: ManagedWindowLifetimeAuthority?,
        observedInTopLevelInventory: Bool
    ) -> ManagedWindowLifetimeAuthority {
        if observedInTopLevelInventory {
            return .axTopLevelInventory
        }
        return existing ?? .directLifecycle
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
        var topLevelInventoryTokens: Set<WindowToken> = []
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
                    topLevelInventoryTokens.insert(token)
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

        let batchedWindowInfoByToken = batchedWindowServerInfo(for: tokensToReevaluate)

        var relayoutNeeded = false
        var ruleRelayoutNeeded = false
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
            let placementOrigin: WorkspacePlacementOrigin = createPlacementContext == nil
                ? .discovery
                : .liveCreate

            evaluatedAnyWindow = true
            let evaluation = evaluateWindowDisposition(
                axRef: axRef,
                pid: token.pid,
                windowInfo: batchedWindowInfoByToken[token]
            )
            let ruleEffects = evaluation.decision.disposition == .undecided
                ? existingEntry?.ruleEffects ?? evaluation.decision.ruleEffects
                : evaluation.decision.ruleEffects
            let admissionHints = evaluation.decision.disposition == .undecided
                ? existingEntry?.admissionHints ?? evaluation.decision.admissionHints
                : evaluation.decision.admissionHints

            guard let effectiveTrackedMode = trackedModePreservingAutomaticFallbackState(
                decision: evaluation.decision,
                existingEntry: existingEntry,
                context: context
            ) else {
                axEventHandler.cancelTrackedTilingPromotionRetry(windowId: token.windowId)
                if let existingEntry {
                    affectedWorkspaceIds.insert(existingEntry.workspaceId)
                    axEventHandler.retireManagedWindowAfterDecisionRejection(existingEntry)
                    relayoutNeeded = true
                } else if evaluation.decision.disposition != .undecided {
                    axEventHandler.discardCreatePlacementContext(for: token.windowId)
                }
                continue
            }
            if effectiveTrackedMode != .tiling {
                axEventHandler.cancelTrackedTilingPromotionRetry(windowId: token.windowId)
            }

            if axEventHandler.deferAdmissionIfNeeded(
                evaluation: evaluation,
                axRef: axRef,
                token: token,
                mode: effectiveTrackedMode,
                existingEntry: existingEntry,
                placementOrigin: placementOrigin
            ) {
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
                placementMode: effectiveTrackedMode,
                placementOrigin: placementOrigin,
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
                   facts: evaluation.facts,
                   admissionHints: admissionHints
               )
            {
                affectedWorkspaceIds.insert(workspaceId)
                relayoutNeeded = true
                ruleRelayoutNeeded = true
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

            let shouldAdmit = existingEntry.map {
                LayoutRefreshController.shouldReadmitTrackedWindow(
                    entry: $0,
                    workspaceId: workspaceId,
                    mode: oldMode ?? effectiveTrackedMode,
                    ruleEffects: ruleEffects,
                    shouldPreservePreFullscreenState: false,
                    appFullscreen: false
                )
            } ?? true
            if shouldAdmit {
                _ = workspaceManager.addWindow(
                    axRef,
                    pid: token.pid,
                    windowId: token.windowId,
                    to: workspaceId,
                    mode: oldMode ?? effectiveTrackedMode,
                    ruleEffects: ruleEffects,
                    admissionHints: admissionHints,
                    lifetimeAuthority: Self.ruleReevaluationLifetimeAuthority(
                        existing: existingEntry?.lifetimeAuthority,
                        observedInTopLevelInventory: topLevelInventoryTokens.contains(token)
                    ),
                    allowsNativeFocusAdoption: !evaluation.appFullscreen,
                    managedReplacementMetadata: managedReplacementMetadata
                )
            }
            if existingEntry != nil {
                _ = workspaceManager.updateAdmissionHints(
                    admissionHints,
                    for: token
                )
            }
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
                || oldEffects != ruleEffects
                || oldWorkspaceId != workspaceId
                || oldMode != effectiveTrackedMode
            {
                if let oldWorkspaceId {
                    affectedWorkspaceIds.insert(oldWorkspaceId)
                }
                affectedWorkspaceIds.insert(workspaceId)
                relayoutNeeded = true
                ruleRelayoutNeeded = true
            }
            if workspaceManager.entry(for: token) != nil,
               let windowId = UInt32(exactly: token.windowId)
            {
                axEventHandler.finishRuleReevaluationAfterTracking(
                    windowId: windowId,
                    wasNewlyManaged: existingEntry == nil
                )
            }
        }

        workspaceManager.promoteLifetimeAuthorityForObservedTopLevelWindows(
            topLevelInventoryTokens
        )

        let evaluatedPIDs = Set(tokensToReevaluate.map(\.pid))
        axManager.bindManagedWindows(
            workspaceManager.allEntries().filter { evaluatedPIDs.contains($0.pid) }
        )

        if ruleRelayoutNeeded {
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
    func assignFocusedWindowToScratchpad(_ index: ScratchpadIndex) -> ExternalCommandResult {
        guard let token = focusedManagedTokenForCommand(),
              let entry = workspaceManager.entry(for: token),
              !isManagedWindowSuspendedForNativeFullscreen(token)
        else {
            return .notFound
        }

        if workspaceManager.scratchpadIndex(for: token) == index {
            guard !workspaceManager.isHiddenInCorner(token) else {
                return .notFound
            }
            cleanupScratchpadWindowResources(for: token)
            applyManagedWindowOverride(.forceTile, for: token, entry: entry)
            return .executed
        }

        let preferredMonitor = monitorForInteraction() ?? workspaceManager.monitor(for: entry.workspaceId)
        let transitionedFromTiling = entry.mode == .tiling
        guard prepareWindowForScratchpadAssignment(token, preferredMonitor: preferredMonitor) else {
            return .notFound
        }

        if workspaceManager.setScratchpadMembership(token, to: index) {
            requestWorkspaceBarRefresh()
        }

        guard let updatedEntry = workspaceManager.entry(for: token),
              let hideMonitor = workspaceManager.monitor(for: updatedEntry.workspaceId) ?? preferredMonitor
        else {
            cleanupScratchpadWindowResources(for: token)
            return .notFound
        }

        if workspaceManager.revealedScratchpadIndex() != index {
            hideScratchpadMembers(
                [updatedEntry],
                fallbackMonitor: hideMonitor,
                captureGeometry: false
            )
        }

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
            axEventHandler.cancelTrackedTilingPromotionRetry(windowId: token.windowId)
            axEventHandler.retireManagedWindowAfterDecisionRejection(entry)
            return
        }
        if trackedMode != .tiling {
            axEventHandler.cancelTrackedTilingPromotionRetry(windowId: token.windowId)
        }

        if axEventHandler.deferAdmissionIfNeeded(
            evaluation: evaluation,
            axRef: entry.axRef,
            token: token,
            mode: trackedMode,
            existingEntry: entry
        ) {
            return
        }

        _ = transitionWindowMode(
            for: token,
            to: trackedMode,
            preferredMonitor: monitorForInteraction(),
            applyFloatingFrame: true
        )
        if let windowId = UInt32(exactly: token.windowId) {
            axEventHandler.finishAdmissionRetryAfterTracking(windowId: windowId)
        }
        layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    @discardableResult
    func toggleScratchpad(_ index: ScratchpadIndex, on monitorId: Monitor.ID? = nil) -> ExternalCommandResult {
        guard let target = scratchpadTarget(on: monitorId) else {
            return .notFound
        }
        let members = scratchpadEntries(in: index)
        guard !members.isEmpty else { return .notFound }

        let regroupsRevealedScratchpad = workspaceManager.revealedScratchpadIndex() == index
        if regroupsRevealedScratchpad {
            if members.allSatisfy({ $0.workspaceId == target.workspaceId }) {
                layoutRefreshController.discardScratchpadRevealGroupCompletions()
                for entry in members {
                    layoutRefreshController.cancelPendingScratchpadReveal(for: entry.token)
                }
                hideScratchpadMembers(members, fallbackMonitor: target.monitor)
                workspaceManager.setRevealedScratchpad(nil)
                return .executed
            }
        }

        let entries = members.filter { entry in
            !isManagedWindowSuspendedForNativeFullscreen(entry.token)
                && !workspaceManager.isAppHidden(pid: entry.pid)
        }
        guard !entries.isEmpty else { return .notFound }

        if regroupsRevealedScratchpad {
            layoutRefreshController.discardScratchpadRevealGroupCompletions()
            for entry in members {
                layoutRefreshController.cancelPendingScratchpadReveal(for: entry.token)
            }
        }

        if let revealed = workspaceManager.revealedScratchpadIndex(), revealed != index {
            layoutRefreshController.discardScratchpadRevealGroupCompletions()
            hideRevealedScratchpad(revealed, fallbackMonitor: target.monitor)
        }

        let revealedBeforeAttempt = workspaceManager.revealedScratchpadIndex()
        workspaceManager.setRevealedScratchpad(index)
        guard revealScratchpadMembers(
            entries,
            in: index,
            on: target.workspaceId,
            monitor: target.monitor
        ) else {
            if workspaceManager.revealedScratchpadIndex() == index {
                workspaceManager.setRevealedScratchpad(revealedBeforeAttempt)
            }
            return .notFound
        }
        return .executed
    }

    @discardableResult
    func revealScratchpadWindow(
        _ token: WindowToken,
        index: ScratchpadIndex,
        on monitorId: Monitor.ID?
    ) -> ExternalCommandResult {
        guard workspaceManager.scratchpadIndex(for: token) == index,
              workspaceManager.entry(for: token) != nil,
              let target = scratchpadTarget(on: monitorId)
        else {
            return .notFound
        }

        if workspaceManager.revealedScratchpadIndex() == index,
           workspaceManager.hiddenState(for: token) == nil
        {
            if let entry = workspaceManager.entry(for: token) {
                performWindowOrdering(windowId: entry.windowId)
                focusWindow(token)
                return .executed
            }
            return .notFound
        }

        let entries = revealableScratchpadEntries(in: index)
        guard entries.contains(where: { $0.token == token }) else { return .notFound }
        if workspaceManager.revealedScratchpadIndex() == index {
            layoutRefreshController.discardScratchpadRevealGroupCompletions()
            if entries.contains(where: { $0.workspaceId != target.workspaceId }) {
                for entry in scratchpadEntries(in: index) {
                    layoutRefreshController.cancelPendingScratchpadReveal(for: entry.token)
                }
            }
        }
        if let revealed = workspaceManager.revealedScratchpadIndex(), revealed != index {
            layoutRefreshController.discardScratchpadRevealGroupCompletions()
            hideRevealedScratchpad(revealed, fallbackMonitor: target.monitor)
        }
        let revealedBeforeAttempt = workspaceManager.revealedScratchpadIndex()
        workspaceManager.setRevealedScratchpad(index)
        guard revealScratchpadMembers(
            entries,
            in: index,
            on: target.workspaceId,
            monitor: target.monitor,
            preferring: token
        ) else {
            if workspaceManager.revealedScratchpadIndex() == index {
                workspaceManager.setRevealedScratchpad(revealedBeforeAttempt)
            }
            return .notFound
        }
        return .executed
    }

    func reconcileScratchpadMembersAfterAppUnhide(pid: pid_t) {
        for entry in workspaceManager.entries(forPid: pid) {
            guard let index = workspaceManager.scratchpadIndex(for: entry.token),
                  workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true,
                  !isManagedWindowSuspendedForNativeFullscreen(entry.token),
                  let monitor = workspaceManager.monitor(for: entry.workspaceId) ?? monitorForInteraction()
            else {
                continue
            }
            if workspaceManager.revealedScratchpadIndex() == index {
                _ = showScratchpadWindow(entry, on: entry.workspaceId, monitor: monitor)
            } else {
                _ = parkScratchpadWindow(entry, monitor: monitor)
            }
        }
    }

    @discardableResult
    func reconcileScratchpadMemberAfterNativeFullscreenExit(_ token: WindowToken) -> Bool {
        guard let entry = workspaceManager.entry(for: token),
              entry.layoutReason == .standard,
              let index = workspaceManager.scratchpadIndex(for: token),
              workspaceManager.hiddenState(for: token)?.isScratchpad == true,
              let monitor = workspaceManager.monitor(for: entry.workspaceId) ?? monitorForInteraction()
        else {
            return false
        }
        if workspaceManager.revealedScratchpadIndex() == index {
            _ = showScratchpadWindow(entry, on: entry.workspaceId, monitor: monitor)
            return false
        }
        _ = parkScratchpadWindow(entry, monitor: monitor)
        return true
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
        windowActionHandler.navigateToExplicitlySelectedWindow(handle: handle)
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

    func handleOverviewHotkey(_ invocation: HotkeyInvocation) -> OverviewHotkeyDisposition {
        windowActionHandlerStorage?.handleOverviewHotkey(invocation) ?? .inactive
    }

    func updateOverviewSettings() {
        windowActionHandlerStorage?.updateOverviewSettings()
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
            guard !workspaceManager.isAppHidden(pid: entry.pid) else { continue }
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
        var frameUpdates: [AXFrameApplicationTarget] = []
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
            frameUpdates.append(
                .init(pid: entry.pid, window: entry.axRef, frame: operation.targetFrame)
            )
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
        preferredNodeId: NodeId? = nil,
        preferredToken: WindowToken? = nil
    ) {
        let monitorId = workspaceManager.monitorId(for: workspaceId)

        switch workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            if let engine = niriEngine {
                let preferredTokenNode: NiriWindow? = preferredToken.flatMap { token in
                    guard !isManagedWindowSuppressedByMacOSHide(token) else { return nil }
                    return engine.findNode(for: token, in: workspaceId)
                }
                let preferredNode = preferredNodeId
                    .flatMap { engine.findNode(by: $0, in: workspaceId) as? NiriWindow }
                    .flatMap { node in
                        isManagedWindowSuppressedByMacOSHide(node.token) ? nil : node
                    }
                if let node = preferredTokenNode ?? preferredNode {
                    _ = workspaceManager.commitWorkspaceSelection(
                        nodeId: node.id,
                        focusedToken: node.token,
                        in: workspaceId,
                        onMonitor: monitorId
                    )
                    return
                }
            }
        case .dwindle:
            if let token = dwindleEngine?.selectedNode(in: workspaceId)?.windowToken,
               !isManagedWindowSuppressedByMacOSHide(token)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: nil,
                    focusedToken: token,
                    in: workspaceId,
                    onMonitor: monitorId
                )
                return
            }
            if let preferredToken,
               !isManagedWindowSuppressedByMacOSHide(preferredToken),
               dwindleEngine?.findNode(for: preferredToken, in: workspaceId) != nil
            {
                commitWorkspaceFocusCandidate(preferredToken, in: workspaceId)
                return
            }
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
    }

    @discardableResult
    private func commitWorkspaceFocusCandidate(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        focusDwindleCandidate: Bool = false
    ) -> Bool {
        let monitorId = workspaceManager.monitorId(for: workspaceId)

        switch workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            if let engine = niriEngine,
               let node = engine.findNode(for: token, in: workspaceId)
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: node.id,
                    focusedToken: token,
                    in: workspaceId,
                    onMonitor: monitorId
                )
                return false
            }
        case .dwindle:
            if let engine = dwindleEngine,
               engine.findNode(for: token, in: workspaceId) != nil
            {
                _ = workspaceManager.commitWorkspaceSelection(
                    nodeId: nil,
                    focusedToken: token,
                    in: workspaceId,
                    onMonitor: monitorId
                )
                let activation = dwindleLayoutHandler.activateWindow(
                    token,
                    in: workspaceId,
                    focusAfterLayout: focusDwindleCandidate
                )
                return focusDwindleCandidate && activation != .missing
            }
        }

        _ = workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: token,
                plannedSeq: workspaceManager.worldSeq
            )
        )
        return false
    }

    func ensureFocusedTokenValid(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredRecoveryToken: WindowToken? = nil
    ) {
        guard !shouldSuppressManagedFocusRecovery else { return }
        guard !workspaceManager.hasPendingNativeFullscreenTransition(in: workspaceId) else { return }

        if let pendingFocusedToken = workspaceManager.pendingFocusedToken,
           workspaceManager.pendingFocusedWorkspaceId == workspaceId,
           !isManagedWindowSuppressedByMacOSHide(pendingFocusedToken)
        {
            commitWorkspaceFocusCandidate(pendingFocusedToken, in: workspaceId)
            return
        }

        if let preferredRecoveryToken {
            if let entry = workspaceManager.entry(for: preferredRecoveryToken),
               entry.workspaceId == workspaceId,
               !isManagedWindowSuppressedByMacOSHide(preferredRecoveryToken)
            {
                let routedDwindleFocus = commitWorkspaceFocusCandidate(
                    preferredRecoveryToken,
                    in: workspaceId,
                    focusDwindleCandidate: true
                )
                if !routedDwindleFocus {
                    focusWindow(preferredRecoveryToken)
                }
                return
            }
        }

        if let focusedToken = workspaceManager.selectedManagedToken,
           workspaceManager.entry(for: focusedToken)?.workspaceId == workspaceId,
           !isManagedWindowSuppressedByMacOSHide(focusedToken)
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

        let routedDwindleFocus = commitWorkspaceFocusCandidate(
            nextFocusToken,
            in: workspaceId,
            focusDwindleCandidate: true
        )
        if !routedDwindleFocus {
            focusWindow(nextFocusToken)
        }
    }

    func moveMouseToWindow(_ handle: WindowHandle, preferredFrame: CGRect? = nil) {
        moveMouseToWindow(handle.id, preferredFrame: preferredFrame)
    }

    func moveMouseToWindow(_ token: WindowToken, preferredFrame: CGRect? = nil) {
        guard !axEventHandler.hasRecentMouseFocusIntent(for: token) else {
            MouseTrace.record("focus-warp suppressed (mouse-click-intent) token=\(token)")
            return
        }
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard let frame = preferredFrame ?? AXWindowService.framePreferFast(entry.axRef) else { return }

        let center = frame.center

        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else {
            MouseTrace.record("focus-warp suppressed (off-screen) token=\(token) center=\(TraceFormat.point(center))")
            return
        }

        let mouse = currentMouseLocation()
        guard !frame.contains(mouse) else {
            MouseTrace.record(
                "focus-warp suppressed (cursor-inside) token=\(token) mouse=\(TraceFormat.point(mouse))"
            )
            return
        }

        MouseTrace.record("focus-warp token=\(token) center=\(TraceFormat.point(center))")
        warpMouseCursorPosition(ScreenCoordinateSpace.toWindowServer(point: center))
        mouseWarpHandler.noteProgrammaticCursorMove(to: center)
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        windowActionHandler.runningAppsWithWindows()
    }

    func runningAppsForRulePicker() -> [RunningAppInfo] {
        RunningAppInventory.rulePickerCandidates(trackedApplications: runningAppsWithWindows())
    }
}
