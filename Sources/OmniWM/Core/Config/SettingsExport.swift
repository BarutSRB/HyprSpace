// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

// MARK: - SettingsExport

struct SettingsColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

struct SettingsExport: Equatable {
    var hotkeysEnabled: Bool
    var focusFollowsMouse: Bool
    var focusLockModifier: String
    var moveMouseToFocusedWindow: Bool
    var focusFollowsWindowToMonitor: Bool
    var focusCrossesMonitorAtEdge: Bool
    var moveCrossesMonitorAtEdge: Bool
    var mouseWarpMargin: Int
    var mouseWarpEnabled: Bool
    var cursorContainmentEnabled: Bool
    var monitorRoutingMode: String
    var monitorRoutingSettings: [MonitorRoutingSettings]
    var gapSize: Double
    var outerGapLeft: Double
    var outerGapRight: Double
    var outerGapTop: Double
    var outerGapBottom: Double

    var niriVisibleContainerCount: Int
    var niriInfiniteLoop: Bool
    var niriCenterFocusedColumn: String
    var niriAlwaysCenterSingleColumn: Bool
    var niriSingleWindowFit: String
    var niriContainerPrimarySpanPresets: [Double]?
    var niriDefaultContainerPrimarySpan: Double?

    var workspaceConfigurations: [WorkspaceConfiguration]
    var defaultLayoutType: String

    var bordersEnabled: Bool
    var borderWidth: Double
    var borderColorRed: Double
    var borderColorGreen: Double
    var borderColorBlue: Double
    var borderColorAlpha: Double

    var overviewZoom: Double
    var overviewBackdropColor: SettingsColor
    var overviewNormalBorderColor: SettingsColor
    var overviewHoveredBorderColor: SettingsColor
    var overviewSelectedBorderColor: SettingsColor

    var hotkeyBindings: [HotkeyBinding]
    var systemHyperTrigger: SystemHyperTrigger
    var hyperKeyModifiers: HyperKeyModifiers

    var workspaceBarEnabled: Bool
    var workspaceBarShowLabels: Bool
    var workspaceBarShowFloatingWindows: Bool
    var workspaceBarWindowLevel: String
    var workspaceBarPosition: String
    var workspaceBarNotchMode: String
    var workspaceBarNotchActiveZoneWidth: Double
    var workspaceBarSystemStatsButton: Bool
    var workspaceBarDeduplicateAppIcons: Bool
    var workspaceBarHideEmptyWorkspaces: Bool
    var workspaceBarExcludedBundleIDs: [String]
    var workspaceBarIconOverrides: [String: String]
    var workspaceBarReserveLayoutSpace: Bool
    var workspaceBarRevealModifier: String
    var workspaceBarRevealHoldMilliseconds: Double
    var workspaceBarHideInNativeFullscreen: Bool
    var workspaceBarHeight: Double
    var workspaceBarBackgroundOpacity: Double
    var workspaceBarXOffset: Double
    var workspaceBarYOffset: Double
    var workspaceBarAccentColor: SettingsColor?
    var workspaceBarTextColor: SettingsColor?
    var monitorBarSettings: [MonitorBarSettings]

    var appRules: [AppRule]
    var monitorOrientationSettings: [MonitorOrientationSettings]
    var monitorNiriSettings: [MonitorNiriSettings]

    var dwindleSmartSplit: Bool
    var dwindleDefaultSplitRatio: Double
    var dwindleSplitWidthMultiplier: Double
    var dwindleSingleWindowFit: String
    var dwindleUseGlobalGaps: Bool
    var dwindleMoveToRootStable: Bool
    var monitorDwindleSettings: [MonitorDwindleSettings]

    var monitorGapSettings: [MonitorGapSettings]

    var preventSleepEnabled: Bool
    var updateChecksEnabled: Bool
    var ipcEnabled: Bool
    var scrollGestureEnabled: Bool
    var scrollSensitivity: Double
    var scrollModifierKey: String
    var mouseMoveModifierKey: String
    var mouseResizeModifierKey: String
    var gestureFingerCount: Int
    var gestureInvertDirection: Bool
    var trackpadScrollStyle: String
    var workspaceSwipeEnabled: Bool
    var workspaceSwipeFingerCount: Int
    var workspaceSwipeAxis: String
    var statusBarShowWorkspaceName: Bool
    var statusBarShowAppNames: Bool
    var statusBarUseWorkspaceId: Bool
    var hiddenBarEnabled: Bool
    var hiddenBarHiddenBundleIDs: [String]
    var hiddenBarRehideIntervalSeconds: Double
    var animationsEnabled: Bool

    var clipboardHistoryEnabled: Bool
    var clipboardMaxItems: Int
    var clipboardMaxItemBytes: Int
    var clipboardMaxTotalBytes: Int

    var quakeTerminalEnabled: Bool
    var quakeTerminalPosition: String
    var quakeTerminalWidthPercent: Double
    var quakeTerminalHeightPercent: Double
    var quakeTerminalAnimationDuration: Double
    var quakeTerminalAutoHide: Bool
    var quakeTerminalOpacity: Double?
    var quakeTerminalBackgroundEffect: String
    var quakeTerminalBackgroundBlurRadius: Int?
    var quakeTerminalMonitorMode: String?

    var appearanceMode: String
}

// MARK: - Defaults & Diffing

extension SettingsExport {
    static func defaults() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: true,
            focusFollowsMouse: false,
            focusLockModifier: FocusLockModifier.off.rawValue,
            moveMouseToFocusedWindow: false,
            focusFollowsWindowToMonitor: false,
            focusCrossesMonitorAtEdge: false,
            moveCrossesMonitorAtEdge: false,
            mouseWarpMargin: 1,
            mouseWarpEnabled: true,
            cursorContainmentEnabled: false,
            monitorRoutingMode: MonitorRoutingMode.macOS.rawValue,
            monitorRoutingSettings: [],
            gapSize: 16,
            outerGapLeft: 0,
            outerGapRight: 0,
            outerGapTop: 0,
            outerGapBottom: 0,
            niriVisibleContainerCount: 2,
            niriInfiniteLoop: false,
            niriCenterFocusedColumn: CenterFocusedColumn.never.rawValue,
            niriAlwaysCenterSingleColumn: false,
            niriSingleWindowFit: SingleWindowFit.fullScreen.serialized,
            niriContainerPrimarySpanPresets: BuiltInSettingsDefaults.niriContainerPrimarySpanPresets,
            niriDefaultContainerPrimarySpan: 0.5,
            workspaceConfigurations: BuiltInSettingsDefaults.workspaceConfigurations,
            defaultLayoutType: LayoutType.niri.rawValue,
            bordersEnabled: true,
            borderWidth: 5.0,
            borderColorRed: 0.084585202284378935,
            borderColorGreen: 1.0,
            borderColorBlue: 0.97930003794467602,
            borderColorAlpha: 1.0,
            overviewZoom: 1.0,
            overviewBackdropColor: SettingsColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0),
            overviewNormalBorderColor: SettingsColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 0.5),
            overviewHoveredBorderColor: SettingsColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0),
            overviewSelectedBorderColor: SettingsColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1.0),
            hotkeyBindings: HotkeyBindingRegistry.defaults(),
            systemHyperTrigger: .default,
            hyperKeyModifiers: .default,
            workspaceBarEnabled: true,
            workspaceBarShowLabels: true,
            workspaceBarShowFloatingWindows: false,
            workspaceBarWindowLevel: WorkspaceBarWindowLevel.popup.rawValue,
            workspaceBarPosition: WorkspaceBarPosition.overlappingMenuBar.rawValue,
            workspaceBarNotchMode: WorkspaceBarNotchMode.moveBelowMenuBar.rawValue,
            workspaceBarNotchActiveZoneWidth: 180,
            workspaceBarSystemStatsButton: false,
            workspaceBarDeduplicateAppIcons: false,
            workspaceBarHideEmptyWorkspaces: false,
            workspaceBarExcludedBundleIDs: [],
            workspaceBarIconOverrides: [:],
            workspaceBarReserveLayoutSpace: false,
            workspaceBarRevealModifier: WorkspaceBarRevealModifier.off.rawValue,
            workspaceBarRevealHoldMilliseconds: 200,
            workspaceBarHideInNativeFullscreen: false,
            workspaceBarHeight: 24.0,
            workspaceBarBackgroundOpacity: 0.1,
            workspaceBarXOffset: 0.0,
            workspaceBarYOffset: 0.0,
            workspaceBarAccentColor: nil,
            workspaceBarTextColor: nil,
            monitorBarSettings: [],
            appRules: BuiltInSettingsDefaults.appRules,
            monitorOrientationSettings: [],
            monitorNiriSettings: [],
            dwindleSmartSplit: false,
            dwindleDefaultSplitRatio: 1.0,
            dwindleSplitWidthMultiplier: 1.0,
            dwindleSingleWindowFit: SingleWindowFit.fullScreen.serialized,
            dwindleUseGlobalGaps: true,
            dwindleMoveToRootStable: true,
            monitorDwindleSettings: [],
            monitorGapSettings: [],
            preventSleepEnabled: false,
            updateChecksEnabled: true,
            ipcEnabled: false,
            scrollGestureEnabled: true,
            scrollSensitivity: 5.0,
            scrollModifierKey: ScrollModifierKey.optionShift.rawValue,
            mouseMoveModifierKey: MouseMoveModifierKey.option.rawValue,
            mouseResizeModifierKey: MouseResizeModifierKey.option.rawValue,
            gestureFingerCount: GestureFingerCount.three.rawValue,
            gestureInvertDirection: true,
            trackpadScrollStyle: TrackpadScrollStyle.snap.rawValue,
            workspaceSwipeEnabled: false,
            workspaceSwipeFingerCount: GestureFingerCount.three.rawValue,
            workspaceSwipeAxis: WorkspaceSwipeAxis.vertical.rawValue,
            statusBarShowWorkspaceName: false,
            statusBarShowAppNames: false,
            statusBarUseWorkspaceId: false,
            hiddenBarEnabled: true,
            hiddenBarHiddenBundleIDs: [],
            hiddenBarRehideIntervalSeconds: 5,
            animationsEnabled: true,
            clipboardHistoryEnabled: false,
            clipboardMaxItems: 200,
            clipboardMaxItemBytes: 8_388_608,
            clipboardMaxTotalBytes: 67_108_864,
            quakeTerminalEnabled: true,
            quakeTerminalPosition: QuakeTerminalPosition.center.rawValue,
            quakeTerminalWidthPercent: 50.0,
            quakeTerminalHeightPercent: 50.0,
            quakeTerminalAnimationDuration: 0.2,
            quakeTerminalAutoHide: false,
            quakeTerminalOpacity: 1.0,
            quakeTerminalBackgroundEffect: QuakeTerminalBackgroundEffect.standardBlur.rawValue,
            quakeTerminalBackgroundBlurRadius: QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius,
            quakeTerminalMonitorMode: QuakeTerminalMonitorMode.focusedWindow.rawValue,
            appearanceMode: AppearanceMode.dark.rawValue
        )
    }
}
