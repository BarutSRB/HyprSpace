// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class SettingsStore {
    private nonisolated static let defaultExport = SettingsExport.defaults()

    private struct NormalizedWorkspaceBarIconOverride {
        let foldedBundleID: String
        let bundleID: String
        let value: String
    }

    private let persistence: SettingsFilePersistence
    private let runtimeState: RuntimeStateStore
    private let autosaveEnabled: Bool
    private var isApplyingExport = false
    private var isApplyingRuntimeState = false

    var onIPCEnabledChanged: (@MainActor (Bool) -> Void)?
    var onExternalSettingsReloaded: (@MainActor () -> Void)?

    var hotkeysEnabled = SettingsStore.defaultExport.hotkeysEnabled {
        didSet { scheduleSave() }
    }

    var focusFollowsMouse = SettingsStore.defaultExport.focusFollowsMouse {
        didSet { scheduleSave() }
    }

    var focusLockModifier = FocusLockModifier(
        rawValue: SettingsStore.defaultExport.focusLockModifier
    ) ?? .off {
        didSet { scheduleSave() }
    }

    var moveMouseToFocusedWindow = SettingsStore.defaultExport.moveMouseToFocusedWindow {
        didSet { scheduleSave() }
    }

    var focusFollowsWindowToMonitor = SettingsStore.defaultExport.focusFollowsWindowToMonitor {
        didSet { scheduleSave() }
    }

    var focusCrossesMonitorAtEdge = SettingsStore.defaultExport.focusCrossesMonitorAtEdge {
        didSet { scheduleSave() }
    }

    var moveCrossesMonitorAtEdge = SettingsStore.defaultExport.moveCrossesMonitorAtEdge {
        didSet { scheduleSave() }
    }

    var niriContainerPrimarySpanPresets = SettingsStore.validatedContainerPrimarySpanPresets(
        SettingsStore.defaultExport.niriContainerPrimarySpanPresets ?? BuiltInSettingsDefaults
            .niriContainerPrimarySpanPresets
    ) {
        didSet { scheduleSave() }
    }

    var niriDefaultContainerPrimarySpan = SettingsStore.validatedDefaultContainerPrimarySpan(
        SettingsStore.defaultExport.niriDefaultContainerPrimarySpan
    ) {
        didSet {
            let validated = SettingsStore.validatedDefaultContainerPrimarySpan(niriDefaultContainerPrimarySpan)
            if validated != niriDefaultContainerPrimarySpan {
                niriDefaultContainerPrimarySpan = validated
                return
            }
            scheduleSave()
        }
    }

    var mouseWarpMargin = SettingsStore.defaultExport.mouseWarpMargin {
        didSet { scheduleSave() }
    }

    var mouseWarpEnabled = SettingsStore.defaultExport.mouseWarpEnabled {
        didSet { scheduleSave() }
    }

    var cursorContainmentEnabled = SettingsStore.defaultExport.cursorContainmentEnabled {
        didSet { scheduleSave() }
    }

    var monitorRoutingMode = MonitorRoutingMode(rawValue: SettingsStore.defaultExport.monitorRoutingMode) ?? .macOS {
        didSet { scheduleSave() }
    }

    var monitorRoutingSettings = SettingsStore.defaultExport.monitorRoutingSettings {
        didSet { scheduleSave() }
    }

    func applyMonitorSetup(
        routingSettings: [MonitorRoutingSettings],
        mouseWarpEnabled: Bool
    ) {
        monitorRoutingSettings = routingSettings
        monitorRoutingMode = .custom
        self.mouseWarpEnabled = mouseWarpEnabled
    }

    var gapSize = SettingsStore.defaultExport.gapSize {
        didSet { scheduleSave() }
    }

    var outerGapLeft = SettingsStore.defaultExport.outerGapLeft {
        didSet { scheduleSave() }
    }

    var outerGapRight = SettingsStore.defaultExport.outerGapRight {
        didSet { scheduleSave() }
    }

    var outerGapTop = SettingsStore.defaultExport.outerGapTop {
        didSet { scheduleSave() }
    }

    var outerGapBottom = SettingsStore.defaultExport.outerGapBottom {
        didSet { scheduleSave() }
    }

    var niriVisibleContainerCount = SettingsStore.defaultExport.niriVisibleContainerCount {
        didSet { scheduleSave() }
    }

    var niriInfiniteLoop = SettingsStore.defaultExport.niriInfiniteLoop {
        didSet { scheduleSave() }
    }

    var niriCenterFocusedColumn = CenterFocusedColumn(
        rawValue: SettingsStore.defaultExport.niriCenterFocusedColumn
    ) ?? .never {
        didSet { scheduleSave() }
    }

    var niriAlwaysCenterSingleColumn = SettingsStore.defaultExport.niriAlwaysCenterSingleColumn {
        didSet { scheduleSave() }
    }

    var niriSingleWindowFit = SingleWindowFit(
        serialized: SettingsStore.defaultExport.niriSingleWindowFit
    ) {
        didSet { scheduleSave() }
    }

    var workspaceConfigurations = SettingsStore.defaultExport.workspaceConfigurations {
        didSet { scheduleSave() }
    }

    var defaultLayoutType = LayoutType(
        rawValue: SettingsStore.defaultExport.defaultLayoutType
    ) ?? .niri {
        didSet { scheduleSave() }
    }

    var bordersEnabled = SettingsStore.defaultExport.bordersEnabled {
        didSet { scheduleSave() }
    }

    var borderWidth = SettingsStore.defaultExport.borderWidth {
        didSet { scheduleSave() }
    }

    var borderColorRed = SettingsStore.defaultExport.borderColorRed {
        didSet { scheduleSave() }
    }

    var borderColorGreen = SettingsStore.defaultExport.borderColorGreen {
        didSet { scheduleSave() }
    }

    var borderColorBlue = SettingsStore.defaultExport.borderColorBlue {
        didSet { scheduleSave() }
    }

    var borderColorAlpha = SettingsStore.defaultExport.borderColorAlpha {
        didSet { scheduleSave() }
    }

    var overviewZoom = SettingsStore.defaultExport.overviewZoom {
        didSet { scheduleSave() }
    }

    var overviewBackdropColor = SettingsStore.defaultExport.overviewBackdropColor {
        didSet { scheduleSave() }
    }

    var overviewNormalBorderColor = SettingsStore.defaultExport.overviewNormalBorderColor {
        didSet { scheduleSave() }
    }

    var overviewHoveredBorderColor = SettingsStore.defaultExport.overviewHoveredBorderColor {
        didSet { scheduleSave() }
    }

    var overviewSelectedBorderColor = SettingsStore.defaultExport.overviewSelectedBorderColor {
        didSet { scheduleSave() }
    }

    var hotkeyBindings = SettingsStore.defaultExport.hotkeyBindings {
        didSet { scheduleSave() }
    }

    var systemHyperTrigger = SettingsStore.defaultExport.systemHyperTrigger {
        didSet { scheduleSave() }
    }

    private var hyperKeyModifiersStorage = SettingsStore.defaultExport.hyperKeyModifiers

    var hyperKeyModifiers: HyperKeyModifiers {
        get { hyperKeyModifiersStorage }
        set { applyHyperKeyModifiers(newValue) }
    }

    private func applyHyperKeyModifiers(_ newValue: HyperKeyModifiers) {
        guard newValue != hyperKeyModifiersStorage else { return }
        let retargeted = HotkeyBindingRegistry.retargetingHyperChords(hotkeyBindings, to: newValue)
        hyperKeyModifiersStorage = newValue
        hotkeyBindings = retargeted
        scheduleSave()
    }

    var workspaceBarEnabled = SettingsStore.defaultExport.workspaceBarEnabled {
        didSet { scheduleSave() }
    }

    var workspaceBarShowLabels = SettingsStore.defaultExport.workspaceBarShowLabels {
        didSet { scheduleSave() }
    }

    var workspaceBarShowFloatingWindows = SettingsStore.defaultExport.workspaceBarShowFloatingWindows {
        didSet { scheduleSave() }
    }

    var workspaceBarWindowLevel = WorkspaceBarWindowLevel(
        rawValue: SettingsStore.defaultExport.workspaceBarWindowLevel
    ) ?? .popup {
        didSet { scheduleSave() }
    }

    var workspaceBarPosition = WorkspaceBarPosition(
        rawValue: SettingsStore.defaultExport.workspaceBarPosition
    ) ?? .overlappingMenuBar {
        didSet { scheduleSave() }
    }

    var workspaceBarNotchMode = WorkspaceBarNotchMode(
        rawValue: SettingsStore.defaultExport.workspaceBarNotchMode
    ) ?? .moveBelowMenuBar {
        didSet { scheduleSave() }
    }

    var workspaceBarNotchActiveZoneWidth = SettingsStore.defaultExport.workspaceBarNotchActiveZoneWidth {
        didSet { scheduleSave() }
    }

    var workspaceBarSystemStatsButton = SettingsStore.defaultExport.workspaceBarSystemStatsButton {
        didSet { scheduleSave() }
    }

    var workspaceBarDeduplicateAppIcons = SettingsStore.defaultExport.workspaceBarDeduplicateAppIcons {
        didSet { scheduleSave() }
    }

    var workspaceBarHideEmptyWorkspaces = SettingsStore.defaultExport.workspaceBarHideEmptyWorkspaces {
        didSet { scheduleSave() }
    }

    private(set) var workspaceBarExcludedBundleIDs = SettingsStore.normalizedWorkspaceBarExcludedBundleIDs(
        SettingsStore.defaultExport.workspaceBarExcludedBundleIDs
    ) {
        didSet { scheduleSave() }
    }

    private(set) var workspaceBarIconOverrides = SettingsStore.normalizedWorkspaceBarIconOverrides(
        SettingsStore.defaultExport.workspaceBarIconOverrides
    ) {
        didSet { scheduleSave() }
    }

    var workspaceBarReserveLayoutSpace = SettingsStore.defaultExport.workspaceBarReserveLayoutSpace {
        didSet { scheduleSave() }
    }

    var workspaceBarRevealModifier = WorkspaceBarRevealModifier(
        rawValue: SettingsStore.defaultExport.workspaceBarRevealModifier
    ) ?? .off {
        didSet { scheduleSave() }
    }

    var workspaceBarRevealHoldMilliseconds = SettingsStore.defaultExport.workspaceBarRevealHoldMilliseconds {
        didSet { scheduleSave() }
    }

    var workspaceBarHideInNativeFullscreen = SettingsStore.defaultExport.workspaceBarHideInNativeFullscreen {
        didSet { scheduleSave() }
    }

    var workspaceBarHeight = SettingsStore.defaultExport.workspaceBarHeight {
        didSet { scheduleSave() }
    }

    var workspaceBarBackgroundOpacity = SettingsStore.defaultExport.workspaceBarBackgroundOpacity {
        didSet { scheduleSave() }
    }

    var workspaceBarXOffset = SettingsStore.defaultExport.workspaceBarXOffset {
        didSet { scheduleSave() }
    }

    var workspaceBarYOffset = SettingsStore.defaultExport.workspaceBarYOffset {
        didSet { scheduleSave() }
    }

    var workspaceBarAccentColor = SettingsStore.defaultExport.workspaceBarAccentColor {
        didSet { scheduleSave() }
    }

    var workspaceBarTextColor = SettingsStore.defaultExport.workspaceBarTextColor {
        didSet { scheduleSave() }
    }

    var monitorBarSettings = SettingsStore.defaultExport.monitorBarSettings {
        didSet { scheduleSave() }
    }

    private(set) var appRulesRevision: UInt64 = 0
    private(set) var appRulesDiagnosticSnapshot = WindowClassificationRulesSnapshot(
        revision: 0,
        rules: SettingsStore.defaultExport.appRules
    )

    var appRules = SettingsStore.defaultExport.appRules {
        didSet {
            if appRules != oldValue {
                appRulesRevision &+= 1
                appRulesDiagnosticSnapshot = WindowClassificationRulesSnapshot(
                    revision: appRulesRevision,
                    rules: appRules
                )
            }
            scheduleSave()
        }
    }

    var monitorOrientationSettings = SettingsStore.defaultExport.monitorOrientationSettings {
        didSet { scheduleSave() }
    }

    var monitorNiriSettings = SettingsStore.defaultExport.monitorNiriSettings {
        didSet { scheduleSave() }
    }

    var dwindleSmartSplit = SettingsStore.defaultExport.dwindleSmartSplit {
        didSet { scheduleSave() }
    }

    var dwindleDefaultSplitRatio = SettingsStore.defaultExport.dwindleDefaultSplitRatio {
        didSet { scheduleSave() }
    }

    var dwindleSplitWidthMultiplier = SettingsStore.defaultExport.dwindleSplitWidthMultiplier {
        didSet { scheduleSave() }
    }

    var dwindleSingleWindowFit = SingleWindowFit(
        serialized: SettingsStore.defaultExport.dwindleSingleWindowFit
    ) {
        didSet { scheduleSave() }
    }

    var dwindleUseGlobalGaps = SettingsStore.defaultExport.dwindleUseGlobalGaps {
        didSet { scheduleSave() }
    }

    var dwindleMoveToRootStable = SettingsStore.defaultExport.dwindleMoveToRootStable {
        didSet { scheduleSave() }
    }

    var monitorDwindleSettings = SettingsStore.defaultExport.monitorDwindleSettings {
        didSet { scheduleSave() }
    }

    var monitorGapSettings = SettingsStore.defaultExport.monitorGapSettings {
        didSet { scheduleSave() }
    }

    var preventSleepEnabled = SettingsStore.defaultExport.preventSleepEnabled {
        didSet { scheduleSave() }
    }

    var updateChecksEnabled = SettingsStore.defaultExport.updateChecksEnabled {
        didSet { scheduleSave() }
    }

    var ipcEnabled = SettingsStore.defaultExport.ipcEnabled {
        didSet {
            guard oldValue != ipcEnabled else { return }
            onIPCEnabledChanged?(ipcEnabled)
            scheduleSave()
        }
    }

    var scrollGestureEnabled = SettingsStore.defaultExport.scrollGestureEnabled {
        didSet { scheduleSave() }
    }

    var scrollSensitivity = SettingsStore.defaultExport.scrollSensitivity {
        didSet { scheduleSave() }
    }

    var scrollModifierKey = ScrollModifierKey(
        rawValue: SettingsStore.defaultExport.scrollModifierKey
    ) ?? .optionShift {
        didSet { scheduleSave() }
    }

    var mouseMoveModifierKey = MouseMoveModifierKey(
        rawValue: SettingsStore.defaultExport.mouseMoveModifierKey
    ) ?? .option {
        didSet { scheduleSave() }
    }

    var mouseResizeModifierKey = MouseResizeModifierKey(
        rawValue: SettingsStore.defaultExport.mouseResizeModifierKey
    ) ?? .option {
        didSet { scheduleSave() }
    }

    var gestureFingerCount = GestureFingerCount(
        rawValue: SettingsStore.defaultExport.gestureFingerCount
    ) ?? .three {
        didSet { scheduleSave() }
    }

    var gestureInvertDirection = SettingsStore.defaultExport.gestureInvertDirection {
        didSet { scheduleSave() }
    }

    var trackpadScrollStyle = TrackpadScrollStyle(
        rawValue: SettingsStore.defaultExport.trackpadScrollStyle
    ) ?? .snap {
        didSet { scheduleSave() }
    }

    var workspaceSwipeEnabled = SettingsStore.defaultExport.workspaceSwipeEnabled {
        didSet { scheduleSave() }
    }

    var workspaceSwipeFingerCount = GestureFingerCount(
        rawValue: SettingsStore.defaultExport.workspaceSwipeFingerCount
    ) ?? .three {
        didSet { scheduleSave() }
    }

    var workspaceSwipeAxis = WorkspaceSwipeAxis(
        rawValue: SettingsStore.defaultExport.workspaceSwipeAxis
    ) ?? .vertical {
        didSet { scheduleSave() }
    }

    var workspaceSwipeAxisLockedToVertical: Bool {
        scrollGestureEnabled && workspaceSwipeFingerCount == gestureFingerCount
    }

    var effectiveWorkspaceSwipeAxis: WorkspaceSwipeAxis {
        workspaceSwipeAxisLockedToVertical ? .vertical : workspaceSwipeAxis
    }

    var statusBarShowWorkspaceName = SettingsStore.defaultExport.statusBarShowWorkspaceName {
        didSet { scheduleSave() }
    }

    var statusBarShowAppNames = SettingsStore.defaultExport.statusBarShowAppNames {
        didSet { scheduleSave() }
    }

    var statusBarUseWorkspaceId = SettingsStore.defaultExport.statusBarUseWorkspaceId {
        didSet { scheduleSave() }
    }

    var hiddenBarEnabled = SettingsStore.defaultExport.hiddenBarEnabled {
        didSet { scheduleSave() }
    }

    var hiddenBarHiddenBundleIDs = SettingsStore.defaultExport.hiddenBarHiddenBundleIDs {
        didSet { scheduleSave() }
    }

    var hiddenBarRehideIntervalSeconds = SettingsStore.defaultExport.hiddenBarRehideIntervalSeconds {
        didSet { scheduleSave() }
    }

    var commandPaletteLastMode = RuntimeStateStore.defaultCommandPaletteLastMode {
        didSet { runtimeState.commandPaletteLastMode = commandPaletteLastMode }
    }

    var animationsEnabled = SettingsStore.defaultExport.animationsEnabled {
        didSet { scheduleSave() }
    }

    var clipboardHistoryEnabled = SettingsStore.defaultExport.clipboardHistoryEnabled {
        didSet { scheduleSave() }
    }

    var clipboardMaxItems = SettingsStore.defaultExport.clipboardMaxItems {
        didSet { scheduleSave() }
    }

    var clipboardMaxItemBytes = SettingsStore.defaultExport.clipboardMaxItemBytes {
        didSet { scheduleSave() }
    }

    var clipboardMaxTotalBytes = SettingsStore.defaultExport.clipboardMaxTotalBytes {
        didSet { scheduleSave() }
    }

    var quakeTerminalEnabled = SettingsStore.defaultExport.quakeTerminalEnabled {
        didSet { scheduleSave() }
    }

    var quakeTerminalPosition = QuakeTerminalPosition(
        rawValue: SettingsStore.defaultExport.quakeTerminalPosition
    ) ?? .center {
        didSet { scheduleSave() }
    }

    var quakeTerminalWidthPercent = SettingsStore.defaultExport.quakeTerminalWidthPercent {
        didSet {
            let normalized = QuakeTerminalGeometryPolicy.normalizedDimensionPercent(quakeTerminalWidthPercent)
            if normalized != quakeTerminalWidthPercent {
                quakeTerminalWidthPercent = normalized
                return
            }
            scheduleSave()
        }
    }

    var quakeTerminalHeightPercent = SettingsStore.defaultExport.quakeTerminalHeightPercent {
        didSet {
            let normalized = QuakeTerminalGeometryPolicy.normalizedDimensionPercent(quakeTerminalHeightPercent)
            if normalized != quakeTerminalHeightPercent {
                quakeTerminalHeightPercent = normalized
                return
            }
            scheduleSave()
        }
    }

    var quakeTerminalAnimationDuration = SettingsStore.defaultExport.quakeTerminalAnimationDuration {
        didSet { scheduleSave() }
    }

    var quakeTerminalAutoHide = SettingsStore.defaultExport.quakeTerminalAutoHide {
        didSet { scheduleSave() }
    }

    var quakeTerminalOpacity = SettingsStore.defaultExport.quakeTerminalOpacity ?? 1.0 {
        didSet { scheduleSave() }
    }

    var quakeTerminalBackgroundEffect = QuakeTerminalBackgroundEffect(
        rawValue: SettingsStore.defaultExport.quakeTerminalBackgroundEffect
    ) ?? .standardBlur {
        didSet { scheduleSave() }
    }

    var quakeTerminalBackgroundBlurRadius = SettingsStore.defaultExport.quakeTerminalBackgroundBlurRadius
        ?? QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
    {
        didSet {
            let normalized = QuakeTerminalAppearancePolicy
                .normalizedBackgroundBlurRadius(quakeTerminalBackgroundBlurRadius)
            if normalized != quakeTerminalBackgroundBlurRadius {
                quakeTerminalBackgroundBlurRadius = normalized
                return
            }
            scheduleSave()
        }
    }

    var quakeTerminalMonitorMode = QuakeTerminalMonitorMode(
        rawValue: SettingsStore.defaultExport.quakeTerminalMonitorMode ?? ""
    ) ?? .focusedWindow {
        didSet { scheduleSave() }
    }

    var quakeTerminalUseCustomFrame = RuntimeStateStore.defaultQuakeTerminalUseCustomFrame {
        didSet {
            if !quakeTerminalUseCustomFrame, quakeTerminalCustomFrameStorage != nil {
                quakeTerminalCustomFrameStorage = nil
            }
            syncQuakeTerminalCustomFrameToRuntimeState()
        }
    }

    private var quakeTerminalCustomFrameStorage: NSRect? = nil {
        didSet { syncQuakeTerminalCustomFrameToRuntimeState() }
    }

    var quakeTerminalCustomFrame: NSRect? {
        get { quakeTerminalCustomFrameStorage }
        set {
            if let frame = QuakeTerminalGeometryPolicy.normalizedCustomFrame(newValue) {
                quakeTerminalCustomFrameStorage = frame
            } else {
                quakeTerminalCustomFrameStorage = nil
                quakeTerminalUseCustomFrame = false
            }
        }
    }

    func resetQuakeTerminalCustomFrame() {
        quakeTerminalUseCustomFrame = false
        quakeTerminalCustomFrame = nil
    }

    var appearanceMode = AppearanceMode(
        rawValue: SettingsStore.defaultExport.appearanceMode
    ) ?? .dark {
        didSet { scheduleSave() }
    }

    func loadPersistedWindowRestoreCatalog() -> PersistedWindowRestoreCatalog {
        runtimeState.windowRestoreCatalog ?? .empty
    }

    func savePersistedWindowRestoreCatalog(_ catalog: PersistedWindowRestoreCatalog) {
        runtimeState.windowRestoreCatalog = catalog.entries.isEmpty ? nil : catalog
    }

    var issueDraft: IssueDraft? {
        get { runtimeState.issueDraft }
        set { runtimeState.issueDraft = newValue }
    }

    var hasSeenIssueWalkthrough: Bool {
        get { runtimeState.hasSeenIssueWalkthrough }
        set { runtimeState.hasSeenIssueWalkthrough = newValue }
    }

    var monitorSetupStatus = RuntimeStateStore.defaultMonitorSetupStatus {
        didSet { runtimeState.monitorSetupStatus = monitorSetupStatus }
    }

    init(
        persistence: SettingsFilePersistence = SettingsFilePersistence(),
        runtimeState: RuntimeStateStore = RuntimeStateStore(),
        autosaveEnabled: Bool = true
    ) {
        self.persistence = persistence
        self.runtimeState = runtimeState
        self.autosaveEnabled = autosaveEnabled
        commandPaletteLastMode = runtimeState.commandPaletteLastMode
        monitorSetupStatus = runtimeState.monitorSetupStatus
        isApplyingRuntimeState = true
        quakeTerminalCustomFrameStorage = QuakeTerminalGeometryPolicy.normalizedCustomFrame(
            runtimeState.quakeTerminalCustomFrame
        )
        quakeTerminalUseCustomFrame = runtimeState.quakeTerminalUseCustomFrame && quakeTerminalCustomFrameStorage != nil
        isApplyingRuntimeState = false
        syncQuakeTerminalCustomFrameToRuntimeState()

        applyExport(persistence.load())
        persistence.setExternalChangeHandler { [weak self] export in
            self?.handleExternalReload(export)
        }
    }

    var settingsFileURL: URL {
        persistence.fileURL
    }

    func ensureSettingsFileAvailable() throws {
        guard !FileManager.default.fileExists(atPath: settingsFileURL.path) else { return }
        try persistence.saveImmediately(toExport())
    }

    func flushNow() {
        if autosaveEnabled {
            persistence.flushNow()
        } else {
            persistence.save(toExport())
        }
        runtimeState.flushNow()
    }

    func toExport() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: hotkeysEnabled,
            focusFollowsMouse: focusFollowsMouse,
            focusLockModifier: focusLockModifier.rawValue,
            moveMouseToFocusedWindow: moveMouseToFocusedWindow,
            focusFollowsWindowToMonitor: focusFollowsWindowToMonitor,
            focusCrossesMonitorAtEdge: focusCrossesMonitorAtEdge,
            moveCrossesMonitorAtEdge: moveCrossesMonitorAtEdge,
            mouseWarpMargin: mouseWarpMargin,
            mouseWarpEnabled: mouseWarpEnabled,
            cursorContainmentEnabled: cursorContainmentEnabled,
            monitorRoutingMode: monitorRoutingMode.rawValue,
            monitorRoutingSettings: monitorRoutingSettings,
            gapSize: gapSize,
            outerGapLeft: outerGapLeft,
            outerGapRight: outerGapRight,
            outerGapTop: outerGapTop,
            outerGapBottom: outerGapBottom,
            niriVisibleContainerCount: niriVisibleContainerCount,
            niriInfiniteLoop: niriInfiniteLoop,
            niriCenterFocusedColumn: niriCenterFocusedColumn.rawValue,
            niriAlwaysCenterSingleColumn: niriAlwaysCenterSingleColumn,
            niriSingleWindowFit: niriSingleWindowFit.serialized,
            niriContainerPrimarySpanPresets: niriContainerPrimarySpanPresets,
            niriDefaultContainerPrimarySpan: niriDefaultContainerPrimarySpan,
            workspaceConfigurations: workspaceConfigurations,
            defaultLayoutType: defaultLayoutType.rawValue,
            bordersEnabled: bordersEnabled,
            borderWidth: borderWidth,
            borderColorRed: borderColorRed,
            borderColorGreen: borderColorGreen,
            borderColorBlue: borderColorBlue,
            borderColorAlpha: borderColorAlpha,
            overviewZoom: overviewZoom,
            overviewBackdropColor: overviewBackdropColor,
            overviewNormalBorderColor: overviewNormalBorderColor,
            overviewHoveredBorderColor: overviewHoveredBorderColor,
            overviewSelectedBorderColor: overviewSelectedBorderColor,
            hotkeyBindings: hotkeyBindings,
            systemHyperTrigger: systemHyperTrigger,
            hyperKeyModifiers: hyperKeyModifiersStorage,
            workspaceBarEnabled: workspaceBarEnabled,
            workspaceBarShowLabels: workspaceBarShowLabels,
            workspaceBarShowFloatingWindows: workspaceBarShowFloatingWindows,
            workspaceBarWindowLevel: workspaceBarWindowLevel.rawValue,
            workspaceBarPosition: workspaceBarPosition.rawValue,
            workspaceBarNotchMode: workspaceBarNotchMode.rawValue,
            workspaceBarNotchActiveZoneWidth: workspaceBarNotchActiveZoneWidth,
            workspaceBarSystemStatsButton: workspaceBarSystemStatsButton,
            workspaceBarDeduplicateAppIcons: workspaceBarDeduplicateAppIcons,
            workspaceBarHideEmptyWorkspaces: workspaceBarHideEmptyWorkspaces,
            workspaceBarExcludedBundleIDs: SettingsStore.sortedWorkspaceBarExcludedBundleIDs(
                workspaceBarExcludedBundleIDs
            ),
            workspaceBarIconOverrides: workspaceBarIconOverrides,
            workspaceBarReserveLayoutSpace: workspaceBarReserveLayoutSpace,
            workspaceBarRevealModifier: workspaceBarRevealModifier.rawValue,
            workspaceBarRevealHoldMilliseconds: workspaceBarRevealHoldMilliseconds,
            workspaceBarHideInNativeFullscreen: workspaceBarHideInNativeFullscreen,
            workspaceBarHeight: workspaceBarHeight,
            workspaceBarBackgroundOpacity: workspaceBarBackgroundOpacity,
            workspaceBarXOffset: workspaceBarXOffset,
            workspaceBarYOffset: workspaceBarYOffset,
            workspaceBarAccentColor: workspaceBarAccentColor,
            workspaceBarTextColor: workspaceBarTextColor,
            monitorBarSettings: monitorBarSettings,
            appRules: appRules,
            monitorOrientationSettings: monitorOrientationSettings,
            monitorNiriSettings: monitorNiriSettings,
            dwindleSmartSplit: dwindleSmartSplit,
            dwindleDefaultSplitRatio: dwindleDefaultSplitRatio,
            dwindleSplitWidthMultiplier: dwindleSplitWidthMultiplier,
            dwindleSingleWindowFit: dwindleSingleWindowFit.serialized,
            dwindleUseGlobalGaps: dwindleUseGlobalGaps,
            dwindleMoveToRootStable: dwindleMoveToRootStable,
            monitorDwindleSettings: monitorDwindleSettings,
            monitorGapSettings: monitorGapSettings.filter(\.hasOverrides),
            preventSleepEnabled: preventSleepEnabled,
            updateChecksEnabled: updateChecksEnabled,
            ipcEnabled: ipcEnabled,
            scrollGestureEnabled: scrollGestureEnabled,
            scrollSensitivity: scrollSensitivity,
            scrollModifierKey: scrollModifierKey.rawValue,
            mouseMoveModifierKey: mouseMoveModifierKey.rawValue,
            mouseResizeModifierKey: mouseResizeModifierKey.rawValue,
            gestureFingerCount: gestureFingerCount.rawValue,
            gestureInvertDirection: gestureInvertDirection,
            trackpadScrollStyle: trackpadScrollStyle.rawValue,
            workspaceSwipeEnabled: workspaceSwipeEnabled,
            workspaceSwipeFingerCount: workspaceSwipeFingerCount.rawValue,
            workspaceSwipeAxis: workspaceSwipeAxis.rawValue,
            statusBarShowWorkspaceName: statusBarShowWorkspaceName,
            statusBarShowAppNames: statusBarShowAppNames,
            statusBarUseWorkspaceId: statusBarUseWorkspaceId,
            hiddenBarEnabled: hiddenBarEnabled,
            hiddenBarHiddenBundleIDs: hiddenBarHiddenBundleIDs,
            hiddenBarRehideIntervalSeconds: hiddenBarRehideIntervalSeconds,
            animationsEnabled: animationsEnabled,
            clipboardHistoryEnabled: clipboardHistoryEnabled,
            clipboardMaxItems: clipboardMaxItems,
            clipboardMaxItemBytes: clipboardMaxItemBytes,
            clipboardMaxTotalBytes: clipboardMaxTotalBytes,
            quakeTerminalEnabled: quakeTerminalEnabled,
            quakeTerminalPosition: quakeTerminalPosition.rawValue,
            quakeTerminalWidthPercent: quakeTerminalWidthPercent,
            quakeTerminalHeightPercent: quakeTerminalHeightPercent,
            quakeTerminalAnimationDuration: quakeTerminalAnimationDuration,
            quakeTerminalAutoHide: quakeTerminalAutoHide,
            quakeTerminalOpacity: quakeTerminalOpacity,
            quakeTerminalBackgroundEffect: quakeTerminalBackgroundEffect.rawValue,
            quakeTerminalBackgroundBlurRadius: quakeTerminalBackgroundBlurRadius,
            quakeTerminalMonitorMode: quakeTerminalMonitorMode.rawValue,
            appearanceMode: appearanceMode.rawValue
        )
    }

    func applyExport(_ export: SettingsExport) {
        let baseline = SettingsStore.defaultExport
        isApplyingExport = true
        defer { isApplyingExport = false }

        hotkeysEnabled = export.hotkeysEnabled
        focusFollowsMouse = export.focusFollowsMouse
        focusLockModifier = FocusLockModifier(rawValue: export.focusLockModifier) ?? .off
        moveMouseToFocusedWindow = export.moveMouseToFocusedWindow
        focusFollowsWindowToMonitor = export.focusFollowsWindowToMonitor
        focusCrossesMonitorAtEdge = export.focusCrossesMonitorAtEdge
        moveCrossesMonitorAtEdge = export.moveCrossesMonitorAtEdge
        mouseWarpMargin = export.mouseWarpMargin
        mouseWarpEnabled = export.mouseWarpEnabled
        cursorContainmentEnabled = export.cursorContainmentEnabled
        monitorRoutingMode = MonitorRoutingMode(rawValue: export.monitorRoutingMode) ?? .macOS
        monitorRoutingSettings = export.monitorRoutingSettings
        gapSize = export.gapSize
        outerGapLeft = export.outerGapLeft
        outerGapRight = export.outerGapRight
        outerGapTop = export.outerGapTop
        outerGapBottom = export.outerGapBottom

        niriVisibleContainerCount = export.niriVisibleContainerCount
        niriInfiniteLoop = export.niriInfiniteLoop
        niriCenterFocusedColumn = CenterFocusedColumn(rawValue: export.niriCenterFocusedColumn) ?? .never
        niriAlwaysCenterSingleColumn = export.niriAlwaysCenterSingleColumn
        niriSingleWindowFit = SingleWindowFit(serialized: export.niriSingleWindowFit)
        niriContainerPrimarySpanPresets = SettingsStore.validatedContainerPrimarySpanPresets(
            export.niriContainerPrimarySpanPresets ?? baseline.niriContainerPrimarySpanPresets ?? SettingsStore
                .defaultContainerPrimarySpanPresets
        )
        niriDefaultContainerPrimarySpan = SettingsStore
            .validatedDefaultContainerPrimarySpan(export.niriDefaultContainerPrimarySpan)

        workspaceConfigurations = SettingsStore.normalizedWorkspaceConfigurations(export.workspaceConfigurations)
        defaultLayoutType = LayoutType(rawValue: export.defaultLayoutType) ?? .niri

        bordersEnabled = export.bordersEnabled
        borderWidth = SettingsStore.validatedBorderWidth(export.borderWidth)
        borderColorRed = SettingsStore.validatedColorComponent(export.borderColorRed)
        borderColorGreen = SettingsStore.validatedColorComponent(export.borderColorGreen)
        borderColorBlue = SettingsStore.validatedColorComponent(export.borderColorBlue)
        borderColorAlpha = SettingsStore.validatedColorComponent(export.borderColorAlpha)

        overviewZoom = SettingsStore.validatedOverviewZoom(export.overviewZoom)
        overviewBackdropColor = SettingsStore.validatedOverviewColor(
            export.overviewBackdropColor,
            default: baseline.overviewBackdropColor
        )
        overviewNormalBorderColor = SettingsStore.validatedOverviewColor(
            export.overviewNormalBorderColor,
            default: baseline.overviewNormalBorderColor
        )
        overviewHoveredBorderColor = SettingsStore.validatedOverviewColor(
            export.overviewHoveredBorderColor,
            default: baseline.overviewHoveredBorderColor
        )
        overviewSelectedBorderColor = SettingsStore.validatedOverviewColor(
            export.overviewSelectedBorderColor,
            default: baseline.overviewSelectedBorderColor
        )

        hyperKeyModifiersStorage = export.hyperKeyModifiers
        KeySymbolMapper.setHyperKeyModifiers(export.hyperKeyModifiers)
        hotkeyBindings = export.hotkeyBindings
        systemHyperTrigger = export.systemHyperTrigger

        workspaceBarEnabled = export.workspaceBarEnabled
        workspaceBarShowLabels = export.workspaceBarShowLabels
        workspaceBarShowFloatingWindows = export.workspaceBarShowFloatingWindows
        workspaceBarWindowLevel = WorkspaceBarWindowLevel(rawValue: export.workspaceBarWindowLevel) ?? .popup
        workspaceBarPosition = WorkspaceBarPosition(rawValue: export.workspaceBarPosition) ?? .overlappingMenuBar
        workspaceBarNotchMode = WorkspaceBarNotchMode(rawValue: export.workspaceBarNotchMode) ?? .moveBelowMenuBar
        workspaceBarNotchActiveZoneWidth = min(max(export.workspaceBarNotchActiveZoneWidth, 100), 400)
        workspaceBarSystemStatsButton = export.workspaceBarSystemStatsButton
        workspaceBarDeduplicateAppIcons = export.workspaceBarDeduplicateAppIcons
        workspaceBarHideEmptyWorkspaces = export.workspaceBarHideEmptyWorkspaces
        workspaceBarExcludedBundleIDs = SettingsStore.normalizedWorkspaceBarExcludedBundleIDs(
            export.workspaceBarExcludedBundleIDs
        )
        workspaceBarIconOverrides = SettingsStore.normalizedWorkspaceBarIconOverrides(
            export.workspaceBarIconOverrides
        )
        workspaceBarReserveLayoutSpace = export.workspaceBarReserveLayoutSpace
        workspaceBarRevealModifier = WorkspaceBarRevealModifier(rawValue: export.workspaceBarRevealModifier) ?? .off
        workspaceBarRevealHoldMilliseconds = SettingsStore.validatedWorkspaceBarRevealHoldMilliseconds(
            export.workspaceBarRevealHoldMilliseconds
        )
        workspaceBarHideInNativeFullscreen = export.workspaceBarHideInNativeFullscreen
        workspaceBarHeight = export.workspaceBarHeight
        workspaceBarBackgroundOpacity = export.workspaceBarBackgroundOpacity
        workspaceBarXOffset = export.workspaceBarXOffset
        workspaceBarYOffset = export.workspaceBarYOffset
        workspaceBarAccentColor = export.workspaceBarAccentColor
        workspaceBarTextColor = export.workspaceBarTextColor
        monitorBarSettings = export.monitorBarSettings

        appRules = export.appRules
        monitorOrientationSettings = export.monitorOrientationSettings
        monitorNiriSettings = export.monitorNiriSettings

        dwindleSmartSplit = export.dwindleSmartSplit
        dwindleDefaultSplitRatio = export.dwindleDefaultSplitRatio
        dwindleSplitWidthMultiplier = export.dwindleSplitWidthMultiplier
        dwindleSingleWindowFit = SingleWindowFit(serialized: export.dwindleSingleWindowFit)
        dwindleUseGlobalGaps = export.dwindleUseGlobalGaps
        dwindleMoveToRootStable = export.dwindleMoveToRootStable
        monitorDwindleSettings = export.monitorDwindleSettings
        monitorGapSettings = export.monitorGapSettings.filter(\.hasOverrides)

        preventSleepEnabled = export.preventSleepEnabled
        updateChecksEnabled = export.updateChecksEnabled
        ipcEnabled = export.ipcEnabled
        scrollGestureEnabled = export.scrollGestureEnabled
        scrollSensitivity = export.scrollSensitivity
        scrollModifierKey = ScrollModifierKey(rawValue: export.scrollModifierKey) ?? .optionShift
        mouseMoveModifierKey = MouseMoveModifierKey(rawValue: export.mouseMoveModifierKey) ?? .option
        mouseResizeModifierKey = MouseResizeModifierKey(rawValue: export.mouseResizeModifierKey) ?? .option
        gestureFingerCount = GestureFingerCount(rawValue: export.gestureFingerCount) ?? .three
        gestureInvertDirection = export.gestureInvertDirection
        trackpadScrollStyle = TrackpadScrollStyle(rawValue: export.trackpadScrollStyle) ?? .snap
        workspaceSwipeEnabled = export.workspaceSwipeEnabled
        workspaceSwipeFingerCount = GestureFingerCount(rawValue: export.workspaceSwipeFingerCount) ?? .three
        workspaceSwipeAxis = WorkspaceSwipeAxis(rawValue: export.workspaceSwipeAxis) ?? .vertical
        statusBarShowWorkspaceName = export.statusBarShowWorkspaceName
        statusBarShowAppNames = export.statusBarShowAppNames
        statusBarUseWorkspaceId = export.statusBarUseWorkspaceId
        hiddenBarEnabled = export.hiddenBarEnabled
        hiddenBarHiddenBundleIDs = HiddenBarSettingsPolicy.normalizedBundleIDs(export.hiddenBarHiddenBundleIDs)
        hiddenBarRehideIntervalSeconds = SettingsStore.validatedHiddenBarRehideIntervalSeconds(
            export.hiddenBarRehideIntervalSeconds
        )
        animationsEnabled = export.animationsEnabled
        clipboardHistoryEnabled = export.clipboardHistoryEnabled
        clipboardMaxItems = export.clipboardMaxItems
        clipboardMaxItemBytes = export.clipboardMaxItemBytes
        clipboardMaxTotalBytes = export.clipboardMaxTotalBytes

        quakeTerminalEnabled = export.quakeTerminalEnabled
        quakeTerminalPosition = QuakeTerminalPosition(rawValue: export.quakeTerminalPosition) ?? .center
        quakeTerminalWidthPercent = QuakeTerminalGeometryPolicy
            .normalizedDimensionPercent(export.quakeTerminalWidthPercent)
        quakeTerminalHeightPercent = QuakeTerminalGeometryPolicy
            .normalizedDimensionPercent(export.quakeTerminalHeightPercent)
        quakeTerminalAnimationDuration = export.quakeTerminalAnimationDuration
        quakeTerminalAutoHide = export.quakeTerminalAutoHide
        quakeTerminalOpacity = export.quakeTerminalOpacity ?? baseline.quakeTerminalOpacity ?? 1.0
        quakeTerminalBackgroundEffect = QuakeTerminalBackgroundEffect(
            rawValue: export.quakeTerminalBackgroundEffect
        ) ?? .standardBlur
        quakeTerminalBackgroundBlurRadius = QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(
            export.quakeTerminalBackgroundBlurRadius
                ?? baseline.quakeTerminalBackgroundBlurRadius
                ?? QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        )
        quakeTerminalMonitorMode = QuakeTerminalMonitorMode(
            rawValue: export.quakeTerminalMonitorMode ?? baseline.quakeTerminalMonitorMode ?? ""
        ) ?? .focusedWindow

        appearanceMode = AppearanceMode(rawValue: export.appearanceMode) ?? .dark
    }

    private func syncQuakeTerminalCustomFrameToRuntimeState() {
        guard !isApplyingRuntimeState else { return }
        if let quakeTerminalCustomFrameStorage, quakeTerminalUseCustomFrame {
            runtimeState.quakeTerminalCustomFrame = quakeTerminalCustomFrameStorage
            runtimeState.quakeTerminalUseCustomFrame = true
        } else {
            runtimeState.quakeTerminalUseCustomFrame = false
            runtimeState.quakeTerminalCustomFrame = nil
        }
    }

    private func handleExternalReload(_ export: SettingsExport) {
        applyExport(export)
        onExternalSettingsReloaded?()
    }

    private func scheduleSave() {
        guard autosaveEnabled, !isApplyingExport else { return }
        persistence.scheduleSave(toExport())
    }

    func resetHotkeysToDefaults() {
        hyperKeyModifiers = SettingsStore.defaultExport.hyperKeyModifiers
        hotkeyBindings = HotkeyBindingRegistry.defaults()
        systemHyperTrigger = SettingsStore.defaultExport.systemHyperTrigger
    }

    func hotkeyBindings(applyingPreset mappings: [(id: String, trigger: HotkeyTrigger)]) -> [HotkeyBinding] {
        var proposed = hotkeyBindings
        for mapping in mappings {
            for index in proposed.indices where proposed[index].id != mapping.id &&
                proposed[index].binding.conflicts(with: mapping.trigger)
            {
                proposed[index] = HotkeyBinding(
                    id: proposed[index].id,
                    command: proposed[index].command,
                    trigger: .unassigned
                )
            }
            guard let index = proposed.firstIndex(where: { $0.id == mapping.id }) else { continue }
            proposed[index] = HotkeyBinding(
                id: proposed[index].id,
                command: proposed[index].command,
                trigger: mapping.trigger
            )
        }
        return proposed
    }

    func updateBinding(for commandId: String, newBinding: KeyBinding) {
        updateTrigger(for: commandId, newTrigger: newBinding.isUnassigned ? .unassigned : .chord(newBinding))
    }

    func updateTrigger(for commandId: String, newTrigger: HotkeyTrigger) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == commandId }) else { return }
        hotkeyBindings[index] = HotkeyBinding(
            id: hotkeyBindings[index].id,
            command: hotkeyBindings[index].command,
            trigger: newTrigger
        )
    }

    func clearBinding(for commandId: String) {
        updateBinding(for: commandId, newBinding: .unassigned)
    }

    func resetBindings(for commandId: String) {
        guard let defaultBinding = HotkeyBindingRegistry.defaults().first(where: { $0.id == commandId }),
              let index = hotkeyBindings.firstIndex(where: { $0.id == commandId })
        else { return }
        hotkeyBindings[index] = defaultBinding
    }

    func findConflicts(for binding: KeyBinding, excluding commandId: String) -> [HotkeyBinding] {
        findConflicts(for: binding.isUnassigned ? .unassigned : .chord(binding), excluding: commandId)
    }

    func findConflicts(for trigger: HotkeyTrigger, excluding commandId: String) -> [HotkeyBinding] {
        hotkeyBindings.filter { hotkeyBinding in
            hotkeyBinding.id != commandId &&
                hotkeyBinding.binding.conflicts(with: trigger)
        }
    }

    func configuredWorkspaceNames() -> [String] {
        workspaceConfigurations.map(\.name)
    }

    func layoutType(for workspaceName: String) -> LayoutType {
        if let config = workspaceConfigurations.first(where: { $0.name == workspaceName }) {
            if config.layoutType == .defaultLayout {
                return defaultLayoutType
            }
            return config.layoutType
        }
        return defaultLayoutType
    }

    func displayName(for workspaceName: String) -> String {
        workspaceConfigurations.first(where: { $0.name == workspaceName })?.effectiveDisplayName ?? workspaceName
    }

    static func normalizedWorkspaceConfigurations(_ configs: [WorkspaceConfiguration]) -> [WorkspaceConfiguration] {
        var seen: Set<String> = []
        let normalized = configs
            .filter { WorkspaceIDPolicy.normalizeRawID($0.name) != nil }
            .filter { seen.insert($0.name).inserted }
            .sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }

        if normalized.isEmpty {
            return BuiltInSettingsDefaults.workspaceConfigurations
        }

        return normalized
    }

    func barSettings(for monitor: Monitor) -> MonitorBarSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorBarSettings)
    }

    func updateBarSettings(_ settings: MonitorBarSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &monitorBarSettings)
    }

    func removeBarSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorBarSettings)
    }

    func resolvedBarSettings(for monitor: Monitor) -> ResolvedBarSettings {
        resolvedBarSettings(override: barSettings(for: monitor))
    }

    private func resolvedBarSettings(override: MonitorBarSettings?) -> ResolvedBarSettings {
        return ResolvedBarSettings(
            enabled: override?.enabled ?? workspaceBarEnabled,
            showLabels: override?.showLabels ?? workspaceBarShowLabels,
            showFloatingWindows: override?.showFloatingWindows ?? workspaceBarShowFloatingWindows,
            deduplicateAppIcons: override?.deduplicateAppIcons ?? workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: override?.hideEmptyWorkspaces ?? workspaceBarHideEmptyWorkspaces,
            excludedBundleIDs: workspaceBarExcludedBundleIDs,
            reserveLayoutSpace: override?.reserveLayoutSpace ?? workspaceBarReserveLayoutSpace,
            notchMode: override?.notchMode ?? workspaceBarNotchMode,
            notchActiveZoneWidth: override?.notchActiveZoneWidth ?? workspaceBarNotchActiveZoneWidth,
            systemStatsButton: workspaceBarSystemStatsButton,
            position: override?.position ?? workspaceBarPosition,
            windowLevel: override?.windowLevel ?? workspaceBarWindowLevel,
            height: override?.height ?? workspaceBarHeight,
            backgroundOpacity: override?.backgroundOpacity ?? workspaceBarBackgroundOpacity,
            xOffset: override?.xOffset ?? workspaceBarXOffset,
            yOffset: override?.yOffset ?? workspaceBarYOffset,
            accentColor: workspaceBarAccentColor,
            textColor: workspaceBarTextColor
        )
    }

    @discardableResult
    func addWorkspaceBarExcludedBundleID(_ rawBundleID: String) -> Bool {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty,
              !workspaceBarExcludedBundleIDs.contains(where: {
                  $0.caseInsensitiveCompare(bundleID) == .orderedSame
              })
        else {
            return false
        }
        workspaceBarExcludedBundleIDs.insert(bundleID)
        return true
    }

    @discardableResult
    func removeWorkspaceBarExcludedBundleID(_ rawBundleID: String) -> Bool {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return false }
        guard let storedBundleID = workspaceBarExcludedBundleIDs.first(where: {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }) else {
            return false
        }
        workspaceBarExcludedBundleIDs.remove(storedBundleID)
        return true
    }

    func workspaceBarIconOverrideValue(for rawBundleID: String) -> String? {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return nil }
        return workspaceBarIconOverrides.first { storedBundleID, _ in
            storedBundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        }?.value
    }

    @discardableResult
    func setWorkspaceBarIconOverride(_ rawValue: String, for rawBundleID: String) -> Bool {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !value.isEmpty else { return false }

        if let storedBundleID = workspaceBarIconOverrides.keys.first(where: {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }) {
            guard workspaceBarIconOverrides[storedBundleID] != value else { return false }
            workspaceBarIconOverrides[storedBundleID] = value
            return true
        }

        workspaceBarIconOverrides[bundleID] = value
        return true
    }

    @discardableResult
    func removeWorkspaceBarIconOverride(for rawBundleID: String) -> Bool {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return false }
        guard let storedBundleID = workspaceBarIconOverrides.keys.first(where: {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }) else {
            return false
        }
        workspaceBarIconOverrides.removeValue(forKey: storedBundleID)
        return true
    }

    func appRule(for bundleId: String) -> AppRule? {
        appRules.first { $0.bundleId == bundleId }
    }

    func orientationSettings(for monitor: Monitor) -> MonitorOrientationSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorOrientationSettings)
    }

    func effectiveOrientation(for monitor: Monitor) -> Monitor.Orientation {
        if let override = orientationSettings(for: monitor),
           let orientation = override.orientation
        {
            return orientation
        }
        return monitor.autoOrientation
    }

    func updateOrientationSettings(_ settings: MonitorOrientationSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &monitorOrientationSettings)
    }

    func removeOrientationSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorOrientationSettings)
    }

    func routingSettings(for monitor: Monitor) -> MonitorRoutingSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorRoutingSettings)
    }

    func updateRoutingSettings(_ settings: MonitorRoutingSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &monitorRoutingSettings)
    }

    func removeRoutingSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorRoutingSettings)
    }

    func niriSettings(for monitor: Monitor) -> MonitorNiriSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorNiriSettings)
    }

    func updateNiriSettings(_ settings: MonitorNiriSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &monitorNiriSettings)
    }

    func removeNiriSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorNiriSettings)
    }

    func resolvedNiriSettings(for monitor: Monitor) -> ResolvedNiriSettings {
        resolvedNiriSettings(override: niriSettings(for: monitor))
    }

    private func resolvedNiriSettings(override: MonitorNiriSettings?) -> ResolvedNiriSettings {
        return ResolvedNiriSettings(
            visibleContainerCount: override?.visibleContainerCount ?? niriVisibleContainerCount,
            centerFocusedColumn: override?.centerFocusedColumn ?? niriCenterFocusedColumn,
            alwaysCenterSingleColumn: override?.alwaysCenterSingleColumn ?? niriAlwaysCenterSingleColumn,
            singleWindowFit: override?.singleWindowFit ?? niriSingleWindowFit,
            infiniteLoop: override?.infiniteLoop ?? niriInfiniteLoop
        )
    }

    func dwindleSettings(for monitor: Monitor) -> MonitorDwindleSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorDwindleSettings)
    }

    func updateDwindleSettings(_ settings: MonitorDwindleSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &monitorDwindleSettings)
    }

    func removeDwindleSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorDwindleSettings)
    }

    func resolvedDwindleSettings(for monitor: Monitor) -> ResolvedDwindleSettings {
        resolvedDwindleSettings(
            override: dwindleSettings(for: monitor),
            sharedInnerGap: resolvedGapSettings(for: monitor).innerGap
        )
    }

    private func resolvedDwindleSettings(
        override: MonitorDwindleSettings?,
        sharedInnerGap: CGFloat
    ) -> ResolvedDwindleSettings {
        let useGlobalGaps = override?.useGlobalGaps ?? dwindleUseGlobalGaps
        return ResolvedDwindleSettings(
            smartSplit: override?.smartSplit ?? dwindleSmartSplit,
            defaultSplitRatio: CGFloat(override?.defaultSplitRatio ?? dwindleDefaultSplitRatio),
            splitWidthMultiplier: CGFloat(override?.splitWidthMultiplier ?? dwindleSplitWidthMultiplier),
            singleWindowFit: override?.singleWindowFit ?? dwindleSingleWindowFit,
            useGlobalGaps: useGlobalGaps,
            innerGap: useGlobalGaps ? sharedInnerGap : CGFloat(override?.innerGap ?? gapSize)
        )
    }

    func gapSettings(for monitor: Monitor) -> MonitorGapSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorGapSettings)
    }

    func updateGapSettings(_ settings: MonitorGapSettings, for monitor: Monitor) {
        if settings.hasOverrides {
            MonitorSettingsStore.update(settings, for: monitor, in: &monitorGapSettings)
        } else {
            MonitorSettingsStore.remove(for: monitor, from: &monitorGapSettings)
        }
    }

    func removeGapSettings(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorGapSettings)
    }

    func resolvedGapSettings(for monitor: Monitor) -> ResolvedGapSettings {
        let override = gapSettings(for: monitor)
        return ResolvedGapSettings(
            innerGap: resolvedInnerGap(override?.innerGap),
            outerGapLeft: CGFloat(override?.outerGapLeft ?? outerGapLeft),
            outerGapRight: CGFloat(override?.outerGapRight ?? outerGapRight),
            outerGapTop: CGFloat(override?.outerGapTop ?? outerGapTop),
            outerGapBottom: CGFloat(override?.outerGapBottom ?? outerGapBottom)
        )
    }

    private func resolvedInnerGap(_ override: Double?) -> CGFloat {
        CGFloat(min(64, max(0, override ?? gapSize)))
    }

    nonisolated static let defaultContainerPrimarySpanPresets: [Double] = BuiltInSettingsDefaults
        .niriContainerPrimarySpanPresets

    static func validatedContainerPrimarySpanPresets(_ presets: [Double]) -> [Double] {
        let result = presets.map { min(1.0, max(0.05, $0)) }
        if result.count < 2 {
            return defaultContainerPrimarySpanPresets
        }
        return result
    }

    static func validatedDefaultContainerPrimarySpan(_ width: Double?) -> Double? {
        guard let width else { return nil }
        return min(1.0, max(0.05, width))
    }

    static func validatedBorderWidth(_ width: Double) -> Double {
        min(12.0, max(1.0, width))
    }

    static func validatedColorComponent(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    static func validatedOverviewZoom(_ value: Double) -> Double {
        guard value.isFinite else { return defaultExport.overviewZoom }
        return min(1.5, max(0.5, value))
    }

    static func validatedOverviewColor(_ color: SettingsColor, default defaultColor: SettingsColor) -> SettingsColor {
        SettingsColor(
            red: validatedOverviewColorComponent(color.red, default: defaultColor.red),
            green: validatedOverviewColorComponent(color.green, default: defaultColor.green),
            blue: validatedOverviewColorComponent(color.blue, default: defaultColor.blue),
            alpha: validatedOverviewColorComponent(color.alpha, default: defaultColor.alpha)
        )
    }

    private static func validatedOverviewColorComponent(_ value: Double, default defaultValue: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(1.0, max(0.0, value))
    }

    static func validatedWorkspaceBarRevealHoldMilliseconds(_ value: Double) -> Double {
        guard value.isFinite else { return defaultExport.workspaceBarRevealHoldMilliseconds }
        return min(max(value, 0), 1000)
    }

    static func normalizedWorkspaceBarExcludedBundleIDs(_ bundleIDs: [String]) -> Set<String> {
        var normalized: Set<String> = []
        normalized.reserveCapacity(bundleIDs.count)
        for rawBundleID in bundleIDs {
            let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty,
                  !normalized.contains(where: {
                      $0.caseInsensitiveCompare(bundleID) == .orderedSame
                  })
            else {
                continue
            }
            normalized.insert(bundleID)
        }
        return normalized
    }

    static func sortedWorkspaceBarExcludedBundleIDs(_ bundleIDs: Set<String>) -> [String] {
        bundleIDs.sorted { lhs, rhs in
            let order = lhs.caseInsensitiveCompare(rhs)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    static func normalizedWorkspaceBarIconOverrides(_ overrides: [String: String]) -> [String: String] {
        let candidates = overrides.compactMap { rawBundleID, rawValue -> NormalizedWorkspaceBarIconOverride? in
            let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !value.isEmpty else { return nil }
            return NormalizedWorkspaceBarIconOverride(
                foldedBundleID: bundleID.lowercased(),
                bundleID: bundleID,
                value: value
            )
        }.sorted { lhs, rhs in
            if lhs.foldedBundleID != rhs.foldedBundleID {
                return lhs.foldedBundleID < rhs.foldedBundleID
            }
            if lhs.bundleID != rhs.bundleID {
                return lhs.bundleID < rhs.bundleID
            }
            return lhs.value < rhs.value
        }

        var normalized: [String: String] = [:]
        normalized.reserveCapacity(candidates.count)
        var seenBundleIDs: Set<String> = []
        seenBundleIDs.reserveCapacity(candidates.count)
        for candidate in candidates where seenBundleIDs.insert(candidate.foldedBundleID).inserted {
            normalized[candidate.bundleID] = candidate.value
        }
        return normalized
    }

    static func validatedHiddenBarRehideIntervalSeconds(_ value: Double) -> Double {
        guard value.isFinite else { return defaultExport.hiddenBarRehideIntervalSeconds }
        return min(max(value, 2), 30)
    }
}
