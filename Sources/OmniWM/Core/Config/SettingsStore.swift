// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class SettingsStore {
    private nonisolated static let defaultExport = SettingsExport.defaults()
    private nonisolated static let scrollSensitivityRange = 0.1 ... 100.0

    private nonisolated static func normalizedScrollSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultExport.scrollSensitivity }
        return min(max(value, scrollSensitivityRange.lowerBound), scrollSensitivityRange.upperBound)
    }

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
    var onConfigNoticeChanged: (@MainActor () -> Void)?
    var onTrackpadGestureAvailabilityChanged: (@MainActor (Bool) -> Void)?
    private(set) var configNotice: SettingsConfigNotice?

    var hotkeysEnabled = SettingsStore.defaultExport.hotkeysEnabled {
        didSet { scheduleSave() }
    }

    var focusFollowsMouse = SettingsStore.defaultExport.focusFollowsMouse {
        didSet { scheduleSave() }
    }

    var raiseOnMouseFocus = SettingsStore.defaultExport.raiseOnMouseFocus {
        didSet { scheduleSave() }
    }

    var focusLockModifier = SettingsStore.defaultExport.focusLockModifier {
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

    var monitorRoutingMode = SettingsStore.defaultExport.monitorRoutingMode {
        didSet { scheduleSave() }
    }

    var monitorArrangements = SettingsStore.defaultExport.monitorArrangements {
        didSet { scheduleSave() }
    }

    func applyMonitorSetup(
        routingSettings: [MonitorRoutingSettings],
        monitors: [Monitor],
        mouseWarpEnabled: Bool,
        workspaceConfigurations: [WorkspaceConfiguration]
    ) {
        storeRoutingLayout(routingSettings, for: monitors)
        monitorRoutingMode = .custom
        self.mouseWarpEnabled = mouseWarpEnabled
        if self.workspaceConfigurations != workspaceConfigurations {
            self.workspaceConfigurations = workspaceConfigurations
        }
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

    var fullscreenUsesOuterGaps = SettingsStore.defaultExport.fullscreenUsesOuterGaps {
        didSet { scheduleSave() }
    }

    var niriVisibleContainerCount = SettingsStore.defaultExport.niriVisibleContainerCount {
        didSet { scheduleSave() }
    }

    var niriInfiniteLoop = SettingsStore.defaultExport.niriInfiniteLoop {
        didSet { scheduleSave() }
    }

    var niriCenterFocusedColumn = SettingsStore.defaultExport.niriCenterFocusedColumn {
        didSet { scheduleSave() }
    }

    var niriAlwaysCenterSingleColumn = SettingsStore.defaultExport.niriAlwaysCenterSingleColumn {
        didSet { scheduleSave() }
    }

    var niriSingleWindowFit = SettingsStore.defaultExport.niriSingleWindowFit {
        didSet { scheduleSave() }
    }

    var workspaceConfigurations = SettingsStore.defaultExport.workspaceConfigurations {
        didSet { scheduleSave() }
    }

    var defaultLayoutType = SettingsStore.defaultExport.defaultLayoutType {
        didSet { scheduleSave() }
    }

    var bordersEnabled = SettingsStore.defaultExport.bordersEnabled {
        didSet { scheduleSave() }
    }

    var borderWidth = SettingsStore.defaultExport.borderWidth {
        didSet { scheduleSave() }
    }

    var borderColor = SettingsColor(
        red: SettingsStore.defaultExport.borderColorRed,
        green: SettingsStore.defaultExport.borderColorGreen,
        blue: SettingsStore.defaultExport.borderColorBlue,
        alpha: SettingsStore.defaultExport.borderColorAlpha
    ) {
        didSet { scheduleSave() }
    }

    var borderColorRed: Double {
        get { borderColor.red }
        set {
            var color = borderColor
            color.red = newValue
            borderColor = color
        }
    }

    var borderColorGreen: Double {
        get { borderColor.green }
        set {
            var color = borderColor
            color.green = newValue
            borderColor = color
        }
    }

    var borderColorBlue: Double {
        get { borderColor.blue }
        set {
            var color = borderColor
            color.blue = newValue
            borderColor = color
        }
    }

    var borderColorAlpha: Double {
        get { borderColor.alpha }
        set {
            var color = borderColor
            color.alpha = newValue
            borderColor = color
        }
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

    var workspaceBarWindowLevel = SettingsStore.defaultExport.workspaceBarWindowLevel {
        didSet { scheduleSave() }
    }

    var workspaceBarPosition = SettingsStore.defaultExport.workspaceBarPosition {
        didSet { scheduleSave() }
    }

    var workspaceBarNotchMode = SettingsStore.defaultExport.workspaceBarNotchMode {
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

    private(set) var scratchpadLabels = SettingsStore.normalizedScratchpadLabels(
        SettingsStore.defaultExport.scratchpadLabels
    ) {
        didSet { scheduleSave() }
    }

    var workspaceBarReserveLayoutSpace = SettingsStore.defaultExport.workspaceBarReserveLayoutSpace {
        didSet { scheduleSave() }
    }

    var workspaceBarRevealModifier = SettingsStore.defaultExport.workspaceBarRevealModifier {
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

    var dwindleSingleWindowFit = SettingsStore.defaultExport.dwindleSingleWindowFit {
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
        didSet {
            guard oldValue != scrollGestureEnabled else { return }
            if !isApplyingExport,
               (oldValue || workspaceSwipeEnabled) != (scrollGestureEnabled || workspaceSwipeEnabled)
            {
                onTrackpadGestureAvailabilityChanged?(scrollGestureEnabled || workspaceSwipeEnabled)
            }
            scheduleSave()
        }
    }

    var scrollSensitivity = SettingsStore.defaultExport.scrollSensitivity {
        didSet {
            let normalized = SettingsStore.normalizedScrollSensitivity(scrollSensitivity)
            guard normalized == scrollSensitivity else {
                scrollSensitivity = normalized
                return
            }
            scheduleSave()
        }
    }

    var scrollModifierKey = SettingsStore.defaultExport.scrollModifierKey {
        didSet { scheduleSave() }
    }

    var mouseMoveModifierKey = SettingsStore.defaultExport.mouseMoveModifierKey {
        didSet { scheduleSave() }
    }

    var mouseResizeModifierKey = SettingsStore.defaultExport.mouseResizeModifierKey {
        didSet { scheduleSave() }
    }

    var gestureFingerCount = SettingsStore.defaultExport.gestureFingerCount {
        didSet { scheduleSave() }
    }

    var gestureInvertDirection = SettingsStore.defaultExport.gestureInvertDirection {
        didSet { scheduleSave() }
    }

    var trackpadScrollStyle = SettingsStore.defaultExport.trackpadScrollStyle {
        didSet { scheduleSave() }
    }

    var workspaceSwipeEnabled = SettingsStore.defaultExport.workspaceSwipeEnabled {
        didSet {
            guard oldValue != workspaceSwipeEnabled else { return }
            if !isApplyingExport,
               (scrollGestureEnabled || oldValue) != (scrollGestureEnabled || workspaceSwipeEnabled)
            {
                onTrackpadGestureAvailabilityChanged?(scrollGestureEnabled || workspaceSwipeEnabled)
            }
            scheduleSave()
        }
    }

    var workspaceSwipeFingerCount = SettingsStore.defaultExport.workspaceSwipeFingerCount {
        didSet { scheduleSave() }
    }

    var workspaceSwipeAxis = SettingsStore.defaultExport.workspaceSwipeAxis {
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

    var quakeTerminalPosition = SettingsStore.defaultExport.quakeTerminalPosition {
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

    var quakeTerminalBackgroundEffect = SettingsStore.defaultExport.quakeTerminalBackgroundEffect {
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

    var quakeTerminalMonitorMode = SettingsStore.defaultExport.quakeTerminalMonitorMode ?? .focusedWindow {
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

    var appearanceMode = SettingsStore.defaultExport.appearanceMode {
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

        let outcome = persistence.loadOutcome()
        transitionConfigNotice(to: outcome.notice)
        applyExport(outcome.export ?? SettingsExport.defaults())
        persistence.setExternalChangeHandler { [weak self] outcome in
            self?.handleExternalReload(outcome)
        }
        persistence.setSaveNoticeHandler { [weak self] notice in
            self?.transitionConfigNotice(to: notice)
        }
    }

    var settingsFileURL: URL {
        persistence.fileURL
    }

    var settingsWritesBlocked: Bool {
        persistence.settingsWritesBlocked
    }

    func ensureSettingsFileAvailable() throws {
        guard !FileManager.default.fileExists(atPath: settingsFileURL.path) else { return }
        if let notice = try persistence.saveImmediately(toExport()) {
            transitionConfigNotice(to: notice)
        }
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
            raiseOnMouseFocus: raiseOnMouseFocus,
            focusLockModifier: focusLockModifier,
            moveMouseToFocusedWindow: moveMouseToFocusedWindow,
            focusFollowsWindowToMonitor: focusFollowsWindowToMonitor,
            focusCrossesMonitorAtEdge: focusCrossesMonitorAtEdge,
            moveCrossesMonitorAtEdge: moveCrossesMonitorAtEdge,
            mouseWarpMargin: mouseWarpMargin,
            mouseWarpEnabled: mouseWarpEnabled,
            cursorContainmentEnabled: cursorContainmentEnabled,
            monitorRoutingMode: monitorRoutingMode,
            monitorArrangements: monitorArrangements,
            gapSize: gapSize,
            outerGapLeft: outerGapLeft,
            outerGapRight: outerGapRight,
            outerGapTop: outerGapTop,
            outerGapBottom: outerGapBottom,
            fullscreenUsesOuterGaps: fullscreenUsesOuterGaps,
            niriVisibleContainerCount: niriVisibleContainerCount,
            niriInfiniteLoop: niriInfiniteLoop,
            niriCenterFocusedColumn: niriCenterFocusedColumn,
            niriAlwaysCenterSingleColumn: niriAlwaysCenterSingleColumn,
            niriSingleWindowFit: niriSingleWindowFit,
            niriContainerPrimarySpanPresets: niriContainerPrimarySpanPresets,
            niriDefaultContainerPrimarySpan: niriDefaultContainerPrimarySpan,
            workspaceConfigurations: workspaceConfigurations,
            defaultLayoutType: defaultLayoutType,
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
            workspaceBarWindowLevel: workspaceBarWindowLevel,
            workspaceBarPosition: workspaceBarPosition,
            workspaceBarNotchMode: workspaceBarNotchMode,
            workspaceBarNotchActiveZoneWidth: workspaceBarNotchActiveZoneWidth,
            workspaceBarSystemStatsButton: workspaceBarSystemStatsButton,
            workspaceBarDeduplicateAppIcons: workspaceBarDeduplicateAppIcons,
            workspaceBarHideEmptyWorkspaces: workspaceBarHideEmptyWorkspaces,
            workspaceBarExcludedBundleIDs: SettingsStore.sortedWorkspaceBarExcludedBundleIDs(
                workspaceBarExcludedBundleIDs
            ),
            workspaceBarIconOverrides: workspaceBarIconOverrides,
            scratchpadLabels: scratchpadLabels,
            workspaceBarReserveLayoutSpace: workspaceBarReserveLayoutSpace,
            workspaceBarRevealModifier: workspaceBarRevealModifier,
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
            dwindleSingleWindowFit: dwindleSingleWindowFit,
            dwindleUseGlobalGaps: dwindleUseGlobalGaps,
            dwindleMoveToRootStable: dwindleMoveToRootStable,
            monitorDwindleSettings: monitorDwindleSettings,
            monitorGapSettings: monitorGapSettings.filter(\.hasOverrides),
            preventSleepEnabled: preventSleepEnabled,
            updateChecksEnabled: updateChecksEnabled,
            ipcEnabled: ipcEnabled,
            scrollGestureEnabled: scrollGestureEnabled,
            scrollSensitivity: scrollSensitivity,
            scrollModifierKey: scrollModifierKey,
            mouseMoveModifierKey: mouseMoveModifierKey,
            mouseResizeModifierKey: mouseResizeModifierKey,
            gestureFingerCount: gestureFingerCount,
            gestureInvertDirection: gestureInvertDirection,
            trackpadScrollStyle: trackpadScrollStyle,
            workspaceSwipeEnabled: workspaceSwipeEnabled,
            workspaceSwipeFingerCount: workspaceSwipeFingerCount,
            workspaceSwipeAxis: workspaceSwipeAxis,
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
            quakeTerminalPosition: quakeTerminalPosition,
            quakeTerminalWidthPercent: quakeTerminalWidthPercent,
            quakeTerminalHeightPercent: quakeTerminalHeightPercent,
            quakeTerminalAnimationDuration: quakeTerminalAnimationDuration,
            quakeTerminalAutoHide: quakeTerminalAutoHide,
            quakeTerminalOpacity: quakeTerminalOpacity,
            quakeTerminalBackgroundEffect: quakeTerminalBackgroundEffect,
            quakeTerminalBackgroundBlurRadius: quakeTerminalBackgroundBlurRadius,
            quakeTerminalMonitorMode: quakeTerminalMonitorMode,
            appearanceMode: appearanceMode
        )
    }

    func applyExport(_ export: SettingsExport) {
        let baseline = SettingsStore.defaultExport
        let trackpadGesturesWereAvailable = scrollGestureEnabled || workspaceSwipeEnabled
        isApplyingExport = true
        defer {
            isApplyingExport = false
            let trackpadGesturesAreAvailable = scrollGestureEnabled || workspaceSwipeEnabled
            if trackpadGesturesWereAvailable != trackpadGesturesAreAvailable {
                onTrackpadGestureAvailabilityChanged?(trackpadGesturesAreAvailable)
            }
        }

        hotkeysEnabled = export.hotkeysEnabled
        focusFollowsMouse = export.focusFollowsMouse
        raiseOnMouseFocus = export.raiseOnMouseFocus
        focusLockModifier = export.focusLockModifier
        moveMouseToFocusedWindow = export.moveMouseToFocusedWindow
        focusFollowsWindowToMonitor = export.focusFollowsWindowToMonitor
        focusCrossesMonitorAtEdge = export.focusCrossesMonitorAtEdge
        moveCrossesMonitorAtEdge = export.moveCrossesMonitorAtEdge
        mouseWarpMargin = export.mouseWarpMargin
        mouseWarpEnabled = export.mouseWarpEnabled
        cursorContainmentEnabled = export.cursorContainmentEnabled
        monitorRoutingMode = export.monitorRoutingMode
        monitorArrangements = export.monitorArrangements
        gapSize = export.gapSize
        outerGapLeft = export.outerGapLeft
        outerGapRight = export.outerGapRight
        outerGapTop = export.outerGapTop
        outerGapBottom = export.outerGapBottom
        fullscreenUsesOuterGaps = export.fullscreenUsesOuterGaps

        niriVisibleContainerCount = export.niriVisibleContainerCount
        niriInfiniteLoop = export.niriInfiniteLoop
        niriCenterFocusedColumn = export.niriCenterFocusedColumn
        niriAlwaysCenterSingleColumn = export.niriAlwaysCenterSingleColumn
        niriSingleWindowFit = export.niriSingleWindowFit
        niriContainerPrimarySpanPresets = SettingsStore.validatedContainerPrimarySpanPresets(
            export.niriContainerPrimarySpanPresets ?? baseline.niriContainerPrimarySpanPresets ?? SettingsStore
                .defaultContainerPrimarySpanPresets
        )
        niriDefaultContainerPrimarySpan = SettingsStore
            .validatedDefaultContainerPrimarySpan(export.niriDefaultContainerPrimarySpan)

        workspaceConfigurations = SettingsStore.normalizedWorkspaceConfigurations(export.workspaceConfigurations)
        defaultLayoutType = export.defaultLayoutType

        bordersEnabled = export.bordersEnabled
        borderWidth = SettingsStore.validatedBorderWidth(export.borderWidth)
        borderColor = SettingsColor(
            red: SettingsStore.validatedColorComponent(export.borderColorRed),
            green: SettingsStore.validatedColorComponent(export.borderColorGreen),
            blue: SettingsStore.validatedColorComponent(export.borderColorBlue),
            alpha: SettingsStore.validatedColorComponent(export.borderColorAlpha)
        )

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
        workspaceBarWindowLevel = export.workspaceBarWindowLevel
        workspaceBarPosition = export.workspaceBarPosition
        workspaceBarNotchMode = export.workspaceBarNotchMode
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
        scratchpadLabels = SettingsStore.normalizedScratchpadLabels(export.scratchpadLabels)
        workspaceBarReserveLayoutSpace = export.workspaceBarReserveLayoutSpace
        workspaceBarRevealModifier = export.workspaceBarRevealModifier
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
        dwindleSingleWindowFit = export.dwindleSingleWindowFit
        dwindleUseGlobalGaps = export.dwindleUseGlobalGaps
        dwindleMoveToRootStable = export.dwindleMoveToRootStable
        monitorDwindleSettings = export.monitorDwindleSettings
        monitorGapSettings = export.monitorGapSettings.filter(\.hasOverrides)

        preventSleepEnabled = export.preventSleepEnabled
        updateChecksEnabled = export.updateChecksEnabled
        ipcEnabled = export.ipcEnabled
        scrollGestureEnabled = export.scrollGestureEnabled
        scrollSensitivity = export.scrollSensitivity
        scrollModifierKey = export.scrollModifierKey
        mouseMoveModifierKey = export.mouseMoveModifierKey
        mouseResizeModifierKey = export.mouseResizeModifierKey
        gestureFingerCount = export.gestureFingerCount
        gestureInvertDirection = export.gestureInvertDirection
        trackpadScrollStyle = export.trackpadScrollStyle
        workspaceSwipeEnabled = export.workspaceSwipeEnabled
        workspaceSwipeFingerCount = export.workspaceSwipeFingerCount
        workspaceSwipeAxis = export.workspaceSwipeAxis
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
        quakeTerminalPosition = export.quakeTerminalPosition
        quakeTerminalWidthPercent = QuakeTerminalGeometryPolicy
            .normalizedDimensionPercent(export.quakeTerminalWidthPercent)
        quakeTerminalHeightPercent = QuakeTerminalGeometryPolicy
            .normalizedDimensionPercent(export.quakeTerminalHeightPercent)
        quakeTerminalAnimationDuration = export.quakeTerminalAnimationDuration
        quakeTerminalAutoHide = export.quakeTerminalAutoHide
        quakeTerminalOpacity = export.quakeTerminalOpacity ?? baseline.quakeTerminalOpacity ?? 1.0
        quakeTerminalBackgroundEffect = export.quakeTerminalBackgroundEffect
        quakeTerminalBackgroundBlurRadius = QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(
            export.quakeTerminalBackgroundBlurRadius
                ?? baseline.quakeTerminalBackgroundBlurRadius
                ?? QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        )
        quakeTerminalMonitorMode = export.quakeTerminalMonitorMode ?? baseline
            .quakeTerminalMonitorMode ?? .focusedWindow

        appearanceMode = export.appearanceMode
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

    private func handleExternalReload(_ outcome: SettingsFileLoadOutcome) {
        transitionConfigNotice(to: outcome.notice)
        guard let export = outcome.export else { return }
        applyExport(export)
        onExternalSettingsReloaded?()
    }

    private func transitionConfigNotice(to notice: SettingsConfigNotice?) {
        guard notice != configNotice else { return }
        configNotice = notice
        onConfigNoticeChanged?()
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

    func storeRoutingLayout(_ layout: [MonitorRoutingSettings], for monitors: [Monitor]) {
        MonitorRouting.store(layout, for: monitors, in: &monitorArrangements)
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
            innerGap: useGlobalGaps ? sharedInnerGap : resolvedInnerGap(override?.innerGap)
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
            outerGapBottom: CGFloat(override?.outerGapBottom ?? outerGapBottom),
            fullscreenUsesOuterGaps: override?.fullscreenUsesOuterGaps ?? fullscreenUsesOuterGaps
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

    static func normalizedScratchpadLabels(_ labels: [String: String]) -> [String: String] {
        labels.reduce(into: [:]) { normalized, entry in
            guard let index = Int(entry.key.trimmingCharacters(in: .whitespacesAndNewlines)),
                  IPCScratchpadSlots.range.contains(index)
            else {
                return
            }
            let label = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return }
            normalized[String(index)] = label
        }
    }

    func scratchpadLabel(for index: Int) -> String? {
        scratchpadLabels[String(index)]
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
