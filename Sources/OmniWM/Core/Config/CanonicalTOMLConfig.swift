// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct CanonicalTOMLConfig: Codable, Equatable {
    var general: General
    var focus: Focus
    var mouseWarp: MouseWarp
    var routing: Routing
    var gaps: Gaps
    var niri: Niri
    var dwindle: Dwindle
    var borders: Borders
    var overview: Overview
    var workspaceBar: WorkspaceBar
    var gestures: Gestures
    var statusBar: StatusBar
    var hiddenBar: HiddenBar
    var clipboard: Clipboard
    var quakeTerminal: QuakeTerminal
    var scratchpads: Scratchpads
    var appearance: Appearance
    var hotkeys: [HotkeyBinding]
    var workspaces: [WorkspaceConfiguration]
    var appRules: [AppRule]
    var monitorBarOverrides: [MonitorBarSettings]
    var monitorOrientationOverrides: [MonitorOrientationSettings]
    var monitorNiriOverrides: [MonitorNiriSettings]
    var monitorDwindleOverrides: [MonitorDwindleSettings]
    var monitorGapOverrides: [MonitorGapSettings]
    var monitorRoutingOverrides: [MonitorRoutingSettings]

    struct General: Codable, Equatable {
        var hotkeysEnabled: Bool
        var systemHyperTrigger: SystemHyperTrigger
        var hyperKeyModifiers: HyperKeyModifiers
        var defaultLayoutType: String
        var preventSleepEnabled: Bool
        var updateChecksEnabled: Bool
        var ipcEnabled: Bool
        var animationsEnabled: Bool
    }

    struct Focus: Codable, Equatable {
        var followsMouse: Bool
        var raiseOnMouseFocus: Bool
        var lockModifier: String
        var moveMouseToFocusedWindow: Bool
        var followsWindowToMonitor: Bool
        var crossesMonitorAtEdge: Bool
        var moveCrossesMonitorAtEdge: Bool
    }

    struct Scratchpads: Codable, Equatable {
        var labels: [String: String]
    }

    struct MouseWarp: Codable, Equatable {
        var margin: Int
        var enabled: Bool
        var constrainToArrangement: Bool
    }

    struct Routing: Codable, Equatable {
        var mode: String
    }

    struct Gaps: Codable, Equatable {
        var size: Double
        var fullscreenUsesOuterGaps: Bool
        var outer: Outer

        struct Outer: Codable, Equatable {
            var left: Double
            var right: Double
            var top: Double
            var bottom: Double
        }
    }

    struct Niri: Codable, Equatable {
        var visibleContainerCount: Int
        var infiniteLoop: Bool
        var centerFocusedColumn: String
        var alwaysCenterSingleColumn: Bool
        var singleWindowFit: String
        var containerPrimarySpanPresets: [Double]?
        var defaultContainerPrimarySpan: Double?
    }

    struct Dwindle: Codable, Equatable {
        var smartSplit: Bool
        var defaultSplitRatio: Double
        var splitWidthMultiplier: Double
        var singleWindowFit: String
        var useGlobalGaps: Bool
        var moveToRootStable: Bool
    }

    struct Borders: Codable, Equatable {
        var enabled: Bool
        var width: Double
        var color: Color

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double
        }
    }

    struct Overview: Codable, Equatable {
        var zoom: Double
        var backdrop: Color
        var windowBorders: WindowBorders

        struct WindowBorders: Codable, Equatable {
            var normal: Color
            var hovered: Color
            var selected: Color
        }

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double

            init(red: Double, green: Double, blue: Double, alpha: Double) {
                self.red = red
                self.green = green
                self.blue = blue
                self.alpha = alpha
            }

            init(_ color: SettingsColor) {
                self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
            }

            var settingsColor: SettingsColor {
                SettingsColor(red: red, green: green, blue: blue, alpha: alpha)
            }
        }
    }

    struct WorkspaceBar: Codable, Equatable {
        var enabled: Bool
        var showLabels: Bool
        var showFloatingWindows: Bool
        var windowLevel: String
        var position: String
        var notchMode: String
        var notchActiveZoneWidth: Double
        var systemStatsButton: Bool
        var deduplicateAppIcons: Bool
        var hideEmptyWorkspaces: Bool
        var excludedBundleIDs: [String]
        var iconOverrides: [String: String]
        var reserveLayoutSpace: Bool
        var revealModifier: String
        var revealHoldMilliseconds: Double
        var hideInNativeFullscreen: Bool
        var height: Double
        var backgroundOpacity: Double
        var xOffset: Double
        var yOffset: Double
        var accentColor: Color?
        var textColor: Color?

        struct Color: Codable, Equatable {
            var red: Double
            var green: Double
            var blue: Double
            var alpha: Double

            init(red: Double, green: Double, blue: Double, alpha: Double) {
                self.red = red
                self.green = green
                self.blue = blue
                self.alpha = alpha
            }

            init(_ color: SettingsColor) {
                red = color.red
                green = color.green
                blue = color.blue
                alpha = color.alpha
            }

            var settingsColor: SettingsColor {
                SettingsColor(red: red, green: green, blue: blue, alpha: alpha)
            }
        }
    }

    struct Gestures: Codable, Equatable {
        var scrollEnabled: Bool
        var scrollSensitivity: Double
        var scrollModifierKey: String
        var mouseMoveModifierKey: String
        var mouseResizeModifierKey: String
        var fingerCount: Int
        var invertDirection: Bool
        var trackpadScrollStyle: String
        var workspaceSwipeEnabled: Bool
        var workspaceSwipeFingerCount: Int
        var workspaceSwipeAxis: String
    }

    struct StatusBar: Codable, Equatable {
        var showWorkspaceName: Bool
        var showAppNames: Bool
        var useWorkspaceId: Bool
    }

    struct HiddenBar: Codable, Equatable {
        var enabled: Bool
        var hiddenBundleIDs: [String]
        var rehideIntervalSeconds: Double
    }

    struct Clipboard: Codable, Equatable {
        var historyEnabled: Bool
        var maxItems: Int
        var maxItemBytes: Int
        var maxTotalBytes: Int
    }

    struct QuakeTerminal: Codable, Equatable {
        var enabled: Bool
        var position: String
        var widthPercent: Double
        var heightPercent: Double
        var animationDuration: Double
        var autoHide: Bool
        var opacity: Double?
        var backgroundEffect: String
        var backgroundBlurRadius: Int?
        var monitorMode: String?
    }

    struct Appearance: Codable, Equatable {
        var mode: String
    }
}

extension CanonicalTOMLConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        general = try container.decode(General.self, forKey: .general)
        KeySymbolMapper.setHyperKeyModifiers(general.hyperKeyModifiers)
        focus = try container.decode(Focus.self, forKey: .focus)
        mouseWarp = try container.decode(MouseWarp.self, forKey: .mouseWarp)
        routing = try container.decode(Routing.self, forKey: .routing)
        gaps = try container.decode(Gaps.self, forKey: .gaps)
        niri = try container.decode(Niri.self, forKey: .niri)
        dwindle = try container.decode(Dwindle.self, forKey: .dwindle)
        borders = try container.decode(Borders.self, forKey: .borders)
        overview = try container.decode(Overview.self, forKey: .overview)
        workspaceBar = try container.decode(WorkspaceBar.self, forKey: .workspaceBar)
        gestures = try container.decode(Gestures.self, forKey: .gestures)
        statusBar = try container.decode(StatusBar.self, forKey: .statusBar)
        hiddenBar = try container.decode(HiddenBar.self, forKey: .hiddenBar)
        clipboard = try container.decode(Clipboard.self, forKey: .clipboard)
        quakeTerminal = try container.decode(QuakeTerminal.self, forKey: .quakeTerminal)
        scratchpads = try container.decode(Scratchpads.self, forKey: .scratchpads)
        appearance = try container.decode(Appearance.self, forKey: .appearance)
        let persistedHotkeys = try container.decode([PersistedHotkeyBinding].self, forKey: .hotkeys)
        hotkeys = try HotkeyBindingRegistry.resolve(persistedHotkeys)
        workspaces = try container.decode([WorkspaceConfiguration].self, forKey: .workspaces)
        appRules = try container.decode([AppRule].self, forKey: .appRules)
        monitorBarOverrides = try container.decode([MonitorBarSettings].self, forKey: .monitorBarOverrides)
        monitorOrientationOverrides = try container.decode(
            [MonitorOrientationSettings].self,
            forKey: .monitorOrientationOverrides
        )
        monitorNiriOverrides = try container.decode([MonitorNiriSettings].self, forKey: .monitorNiriOverrides)
        monitorDwindleOverrides = try container.decode([MonitorDwindleSettings].self, forKey: .monitorDwindleOverrides)
        monitorGapOverrides = try container.decode([MonitorGapSettings].self, forKey: .monitorGapOverrides)
        monitorRoutingOverrides = try container.decode([MonitorRoutingSettings].self, forKey: .monitorRoutingOverrides)
    }
}

extension CanonicalTOMLConfig {
    init(export: SettingsExport) {
        general = General(
            hotkeysEnabled: export.hotkeysEnabled,
            systemHyperTrigger: export.systemHyperTrigger,
            hyperKeyModifiers: export.hyperKeyModifiers,
            defaultLayoutType: export.defaultLayoutType,
            preventSleepEnabled: export.preventSleepEnabled,
            updateChecksEnabled: export.updateChecksEnabled,
            ipcEnabled: export.ipcEnabled,
            animationsEnabled: export.animationsEnabled
        )
        focus = Focus(
            followsMouse: export.focusFollowsMouse,
            raiseOnMouseFocus: export.raiseOnMouseFocus,
            lockModifier: export.focusLockModifier,
            moveMouseToFocusedWindow: export.moveMouseToFocusedWindow,
            followsWindowToMonitor: export.focusFollowsWindowToMonitor,
            crossesMonitorAtEdge: export.focusCrossesMonitorAtEdge,
            moveCrossesMonitorAtEdge: export.moveCrossesMonitorAtEdge
        )
        mouseWarp = MouseWarp(
            margin: export.mouseWarpMargin,
            enabled: export.mouseWarpEnabled,
            constrainToArrangement: export.cursorContainmentEnabled
        )
        routing = Routing(mode: export.monitorRoutingMode)
        gaps = Gaps(
            size: export.gapSize,
            fullscreenUsesOuterGaps: export.fullscreenUsesOuterGaps,
            outer: Gaps.Outer(
                left: export.outerGapLeft,
                right: export.outerGapRight,
                top: export.outerGapTop,
                bottom: export.outerGapBottom
            )
        )
        niri = Niri(
            visibleContainerCount: export.niriVisibleContainerCount,
            infiniteLoop: export.niriInfiniteLoop,
            centerFocusedColumn: export.niriCenterFocusedColumn,
            alwaysCenterSingleColumn: export.niriAlwaysCenterSingleColumn,
            singleWindowFit: export.niriSingleWindowFit,
            containerPrimarySpanPresets: export.niriContainerPrimarySpanPresets,
            defaultContainerPrimarySpan: export.niriDefaultContainerPrimarySpan
        )
        dwindle = Dwindle(
            smartSplit: export.dwindleSmartSplit,
            defaultSplitRatio: export.dwindleDefaultSplitRatio,
            splitWidthMultiplier: export.dwindleSplitWidthMultiplier,
            singleWindowFit: export.dwindleSingleWindowFit,
            useGlobalGaps: export.dwindleUseGlobalGaps,
            moveToRootStable: export.dwindleMoveToRootStable
        )
        borders = Borders(
            enabled: export.bordersEnabled,
            width: export.borderWidth,
            color: Borders.Color(
                red: export.borderColorRed,
                green: export.borderColorGreen,
                blue: export.borderColorBlue,
                alpha: export.borderColorAlpha
            )
        )
        overview = Overview(
            zoom: export.overviewZoom,
            backdrop: Overview.Color(export.overviewBackdropColor),
            windowBorders: Overview.WindowBorders(
                normal: Overview.Color(export.overviewNormalBorderColor),
                hovered: Overview.Color(export.overviewHoveredBorderColor),
                selected: Overview.Color(export.overviewSelectedBorderColor)
            )
        )
        workspaceBar = WorkspaceBar(
            enabled: export.workspaceBarEnabled,
            showLabels: export.workspaceBarShowLabels,
            showFloatingWindows: export.workspaceBarShowFloatingWindows,
            windowLevel: export.workspaceBarWindowLevel,
            position: export.workspaceBarPosition,
            notchMode: export.workspaceBarNotchMode,
            notchActiveZoneWidth: export.workspaceBarNotchActiveZoneWidth,
            systemStatsButton: export.workspaceBarSystemStatsButton,
            deduplicateAppIcons: export.workspaceBarDeduplicateAppIcons,
            hideEmptyWorkspaces: export.workspaceBarHideEmptyWorkspaces,
            excludedBundleIDs: export.workspaceBarExcludedBundleIDs,
            iconOverrides: export.workspaceBarIconOverrides,
            reserveLayoutSpace: export.workspaceBarReserveLayoutSpace,
            revealModifier: export.workspaceBarRevealModifier,
            revealHoldMilliseconds: export.workspaceBarRevealHoldMilliseconds,
            hideInNativeFullscreen: export.workspaceBarHideInNativeFullscreen,
            height: export.workspaceBarHeight,
            backgroundOpacity: export.workspaceBarBackgroundOpacity,
            xOffset: export.workspaceBarXOffset,
            yOffset: export.workspaceBarYOffset,
            accentColor: export.workspaceBarAccentColor.map(WorkspaceBar.Color.init),
            textColor: export.workspaceBarTextColor.map(WorkspaceBar.Color.init)
        )
        gestures = Gestures(
            scrollEnabled: export.scrollGestureEnabled,
            scrollSensitivity: export.scrollSensitivity,
            scrollModifierKey: export.scrollModifierKey,
            mouseMoveModifierKey: export.mouseMoveModifierKey,
            mouseResizeModifierKey: export.mouseResizeModifierKey,
            fingerCount: export.gestureFingerCount,
            invertDirection: export.gestureInvertDirection,
            trackpadScrollStyle: export.trackpadScrollStyle,
            workspaceSwipeEnabled: export.workspaceSwipeEnabled,
            workspaceSwipeFingerCount: export.workspaceSwipeFingerCount,
            workspaceSwipeAxis: export.workspaceSwipeAxis
        )
        statusBar = StatusBar(
            showWorkspaceName: export.statusBarShowWorkspaceName,
            showAppNames: export.statusBarShowAppNames,
            useWorkspaceId: export.statusBarUseWorkspaceId
        )
        hiddenBar = HiddenBar(
            enabled: export.hiddenBarEnabled,
            hiddenBundleIDs: export.hiddenBarHiddenBundleIDs,
            rehideIntervalSeconds: export.hiddenBarRehideIntervalSeconds
        )
        clipboard = Clipboard(
            historyEnabled: export.clipboardHistoryEnabled,
            maxItems: export.clipboardMaxItems,
            maxItemBytes: export.clipboardMaxItemBytes,
            maxTotalBytes: export.clipboardMaxTotalBytes
        )
        quakeTerminal = QuakeTerminal(
            enabled: export.quakeTerminalEnabled,
            position: export.quakeTerminalPosition,
            widthPercent: export.quakeTerminalWidthPercent,
            heightPercent: export.quakeTerminalHeightPercent,
            animationDuration: export.quakeTerminalAnimationDuration,
            autoHide: export.quakeTerminalAutoHide,
            opacity: export.quakeTerminalOpacity,
            backgroundEffect: export.quakeTerminalBackgroundEffect,
            backgroundBlurRadius: export.quakeTerminalBackgroundBlurRadius,
            monitorMode: export.quakeTerminalMonitorMode
        )
        scratchpads = Scratchpads(labels: export.scratchpadLabels)
        appearance = Appearance(mode: export.appearanceMode)
        hotkeys = export.hotkeyBindings
        workspaces = export.workspaceConfigurations
        appRules = export.appRules
        monitorBarOverrides = export.monitorBarSettings
        monitorOrientationOverrides = export.monitorOrientationSettings
        monitorNiriOverrides = export.monitorNiriSettings
        monitorDwindleOverrides = export.monitorDwindleSettings
        monitorGapOverrides = export.monitorGapSettings
        monitorRoutingOverrides = export.monitorRoutingSettings
    }

    func toSettingsExport() -> SettingsExport {
        return SettingsExport(
            hotkeysEnabled: general.hotkeysEnabled,
            focusFollowsMouse: focus.followsMouse,
            raiseOnMouseFocus: focus.raiseOnMouseFocus,
            focusLockModifier: focus.lockModifier,
            moveMouseToFocusedWindow: focus.moveMouseToFocusedWindow,
            focusFollowsWindowToMonitor: focus.followsWindowToMonitor,
            focusCrossesMonitorAtEdge: focus.crossesMonitorAtEdge,
            moveCrossesMonitorAtEdge: focus.moveCrossesMonitorAtEdge,
            mouseWarpMargin: mouseWarp.margin,
            mouseWarpEnabled: mouseWarp.enabled,
            cursorContainmentEnabled: mouseWarp.constrainToArrangement,
            monitorRoutingMode: routing.mode,
            monitorRoutingSettings: monitorRoutingOverrides,
            gapSize: gaps.size,
            outerGapLeft: gaps.outer.left,
            outerGapRight: gaps.outer.right,
            outerGapTop: gaps.outer.top,
            outerGapBottom: gaps.outer.bottom,
            fullscreenUsesOuterGaps: gaps.fullscreenUsesOuterGaps,
            niriVisibleContainerCount: niri.visibleContainerCount,
            niriInfiniteLoop: niri.infiniteLoop,
            niriCenterFocusedColumn: niri.centerFocusedColumn,
            niriAlwaysCenterSingleColumn: niri.alwaysCenterSingleColumn,
            niriSingleWindowFit: niri.singleWindowFit,
            niriContainerPrimarySpanPresets: niri.containerPrimarySpanPresets,
            niriDefaultContainerPrimarySpan: niri.defaultContainerPrimarySpan,
            workspaceConfigurations: workspaces,
            defaultLayoutType: general.defaultLayoutType,
            bordersEnabled: borders.enabled,
            borderWidth: borders.width,
            borderColorRed: borders.color.red,
            borderColorGreen: borders.color.green,
            borderColorBlue: borders.color.blue,
            borderColorAlpha: borders.color.alpha,
            overviewZoom: overview.zoom,
            overviewBackdropColor: overview.backdrop.settingsColor,
            overviewNormalBorderColor: overview.windowBorders.normal.settingsColor,
            overviewHoveredBorderColor: overview.windowBorders.hovered.settingsColor,
            overviewSelectedBorderColor: overview.windowBorders.selected.settingsColor,
            hotkeyBindings: hotkeys,
            systemHyperTrigger: general.systemHyperTrigger,
            hyperKeyModifiers: general.hyperKeyModifiers,
            workspaceBarEnabled: workspaceBar.enabled,
            workspaceBarShowLabels: workspaceBar.showLabels,
            workspaceBarShowFloatingWindows: workspaceBar.showFloatingWindows,
            workspaceBarWindowLevel: workspaceBar.windowLevel,
            workspaceBarPosition: workspaceBar.position,
            workspaceBarNotchMode: workspaceBar.notchMode,
            workspaceBarNotchActiveZoneWidth: workspaceBar.notchActiveZoneWidth,
            workspaceBarSystemStatsButton: workspaceBar.systemStatsButton,
            workspaceBarDeduplicateAppIcons: workspaceBar.deduplicateAppIcons,
            workspaceBarHideEmptyWorkspaces: workspaceBar.hideEmptyWorkspaces,
            workspaceBarExcludedBundleIDs: workspaceBar.excludedBundleIDs,
            workspaceBarIconOverrides: workspaceBar.iconOverrides,
            scratchpadLabels: scratchpads.labels,
            workspaceBarReserveLayoutSpace: workspaceBar.reserveLayoutSpace,
            workspaceBarRevealModifier: workspaceBar.revealModifier,
            workspaceBarRevealHoldMilliseconds: workspaceBar.revealHoldMilliseconds,
            workspaceBarHideInNativeFullscreen: workspaceBar.hideInNativeFullscreen,
            workspaceBarHeight: workspaceBar.height,
            workspaceBarBackgroundOpacity: workspaceBar.backgroundOpacity,
            workspaceBarXOffset: workspaceBar.xOffset,
            workspaceBarYOffset: workspaceBar.yOffset,
            workspaceBarAccentColor: workspaceBar.accentColor?.settingsColor,
            workspaceBarTextColor: workspaceBar.textColor?.settingsColor,
            monitorBarSettings: monitorBarOverrides,
            appRules: appRules,
            monitorOrientationSettings: monitorOrientationOverrides,
            monitorNiriSettings: monitorNiriOverrides,
            dwindleSmartSplit: dwindle.smartSplit,
            dwindleDefaultSplitRatio: dwindle.defaultSplitRatio,
            dwindleSplitWidthMultiplier: dwindle.splitWidthMultiplier,
            dwindleSingleWindowFit: dwindle.singleWindowFit,
            dwindleUseGlobalGaps: dwindle.useGlobalGaps,
            dwindleMoveToRootStable: dwindle.moveToRootStable,
            monitorDwindleSettings: monitorDwindleOverrides,
            monitorGapSettings: monitorGapOverrides,
            preventSleepEnabled: general.preventSleepEnabled,
            updateChecksEnabled: general.updateChecksEnabled,
            ipcEnabled: general.ipcEnabled,
            scrollGestureEnabled: gestures.scrollEnabled,
            scrollSensitivity: gestures.scrollSensitivity,
            scrollModifierKey: gestures.scrollModifierKey,
            mouseMoveModifierKey: gestures.mouseMoveModifierKey,
            mouseResizeModifierKey: gestures.mouseResizeModifierKey,
            gestureFingerCount: gestures.fingerCount,
            gestureInvertDirection: gestures.invertDirection,
            trackpadScrollStyle: gestures.trackpadScrollStyle,
            workspaceSwipeEnabled: gestures.workspaceSwipeEnabled,
            workspaceSwipeFingerCount: gestures.workspaceSwipeFingerCount,
            workspaceSwipeAxis: gestures.workspaceSwipeAxis,
            statusBarShowWorkspaceName: statusBar.showWorkspaceName,
            statusBarShowAppNames: statusBar.showAppNames,
            statusBarUseWorkspaceId: statusBar.useWorkspaceId,
            hiddenBarEnabled: hiddenBar.enabled,
            hiddenBarHiddenBundleIDs: hiddenBar.hiddenBundleIDs,
            hiddenBarRehideIntervalSeconds: hiddenBar.rehideIntervalSeconds,
            animationsEnabled: general.animationsEnabled,
            clipboardHistoryEnabled: clipboard.historyEnabled,
            clipboardMaxItems: clipboard.maxItems,
            clipboardMaxItemBytes: clipboard.maxItemBytes,
            clipboardMaxTotalBytes: clipboard.maxTotalBytes,
            quakeTerminalEnabled: quakeTerminal.enabled,
            quakeTerminalPosition: quakeTerminal.position,
            quakeTerminalWidthPercent: quakeTerminal.widthPercent,
            quakeTerminalHeightPercent: quakeTerminal.heightPercent,
            quakeTerminalAnimationDuration: quakeTerminal.animationDuration,
            quakeTerminalAutoHide: quakeTerminal.autoHide,
            quakeTerminalOpacity: quakeTerminal.opacity,
            quakeTerminalBackgroundEffect: quakeTerminal.backgroundEffect,
            quakeTerminalBackgroundBlurRadius: quakeTerminal.backgroundBlurRadius,
            quakeTerminalMonitorMode: quakeTerminal.monitorMode,
            appearanceMode: appearance.mode
        )
    }
}
