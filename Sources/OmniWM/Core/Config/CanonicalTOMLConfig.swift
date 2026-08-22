// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension CodingUserInfoKey {
    static let settingsTOMLRecoverMissingKeys = CodingUserInfoKey(rawValue: "settingsTOMLRecoverMissingKeys")!
}

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
        var lockModifier: String
        var moveMouseToFocusedWindow: Bool
        var followsWindowToMonitor: Bool
        var crossesMonitorAtEdge: Bool
        var moveCrossesMonitorAtEdge: Bool
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

private extension Decoder {
    var recoversMissingSettingsTOMLKeys: Bool {
        userInfo[.settingsTOMLRecoverMissingKeys] as? Bool == true
    }
}

private extension KeyedDecodingContainer {
    func decode<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T,
        recovering: Bool
    ) throws -> T {
        if recovering {
            return try decodeIfPresent(type, forKey: key) ?? defaultValue
        }
        return try decode(type, forKey: key)
    }

    func decode<T>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T,
        recovering: Bool,
        using decode: (Decoder, T, Bool) throws -> T
    ) throws -> T {
        if recovering, !contains(key) {
            return defaultValue
        }
        return try decode(superDecoder(forKey: key), defaultValue, recovering)
    }

    func decodeRecoveringInvalidValue<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T,
        recovering: Bool
    ) throws -> T {
        do {
            return try decode(type, forKey: key)
        } catch DecodingError.dataCorrupted {
            return defaultValue
        } catch DecodingError.keyNotFound(_, _) where recovering {
            return defaultValue
        } catch DecodingError.valueNotFound(_, _) where recovering {
            return defaultValue
        }
    }
}

private extension CanonicalTOMLConfig {
    static func recoveryDefaults() -> CanonicalTOMLConfig {
        CanonicalTOMLConfig(export: SettingsExport.defaults())
    }
}

extension CanonicalTOMLConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = Self.recoveryDefaults()

        general = try container.decode(
            General.self,
            forKey: .general,
            default: defaults.general,
            recovering: recovering
        )
        KeySymbolMapper.setHyperKeyModifiers(general.hyperKeyModifiers)
        focus = try container.decode(Focus.self, forKey: .focus, default: defaults.focus, recovering: recovering)
        mouseWarp = try container.decode(
            MouseWarp.self,
            forKey: .mouseWarp,
            default: defaults.mouseWarp,
            recovering: recovering
        )
        routing = try container.decode(
            Routing.self,
            forKey: .routing,
            default: defaults.routing,
            recovering: recovering
        )
        gaps = try container.decode(Gaps.self, forKey: .gaps, default: defaults.gaps, recovering: recovering)
        niri = try container.decode(Niri.self, forKey: .niri, default: defaults.niri, recovering: recovering)
        dwindle = try container.decode(
            Dwindle.self,
            forKey: .dwindle,
            default: defaults.dwindle,
            recovering: recovering
        )
        borders = try container.decode(
            Borders.self,
            forKey: .borders,
            default: defaults.borders,
            recovering: recovering
        )
        overview = try container.decode(
            Overview.self,
            forKey: .overview,
            default: defaults.overview,
            recovering: recovering
        )
        workspaceBar = try container.decode(
            WorkspaceBar.self,
            forKey: .workspaceBar,
            default: defaults.workspaceBar,
            recovering: recovering
        )
        gestures = try container.decode(
            Gestures.self,
            forKey: .gestures,
            default: defaults.gestures,
            recovering: recovering
        )
        statusBar = try container.decode(
            StatusBar.self,
            forKey: .statusBar,
            default: defaults.statusBar,
            recovering: recovering
        )
        hiddenBar = try container.decode(
            HiddenBar.self,
            forKey: .hiddenBar,
            default: defaults.hiddenBar,
            recovering: recovering
        )
        clipboard = try container.decode(
            Clipboard.self,
            forKey: .clipboard,
            default: defaults.clipboard,
            recovering: recovering
        )
        quakeTerminal = try container.decode(
            QuakeTerminal.self,
            forKey: .quakeTerminal,
            default: defaults.quakeTerminal,
            recovering: recovering
        )
        appearance = try container.decode(
            Appearance.self,
            forKey: .appearance,
            default: defaults.appearance,
            recovering: recovering
        )
        let persistedHotkeys = try container.decode(
            [PersistedHotkeyBinding].self,
            forKey: .hotkeys,
            default: [],
            recovering: recovering
        )
        hotkeys = HotkeyBindingRegistry.canonicalize(persistedHotkeys)
        workspaces = try container.decode(
            [WorkspaceConfiguration].self,
            forKey: .workspaces,
            default: defaults.workspaces,
            recovering: recovering
        )
        appRules = try container.decode(
            [AppRule].self,
            forKey: .appRules,
            default: defaults.appRules,
            recovering: recovering
        )
        monitorBarOverrides = try container.decode(
            [MonitorBarSettings].self,
            forKey: .monitorBarOverrides,
            default: defaults.monitorBarOverrides,
            recovering: recovering
        )
        monitorOrientationOverrides = try container.decode(
            [MonitorOrientationSettings].self,
            forKey: .monitorOrientationOverrides,
            default: defaults.monitorOrientationOverrides,
            recovering: recovering
        )
        monitorNiriOverrides = try container.decode(
            [MonitorNiriSettings].self,
            forKey: .monitorNiriOverrides,
            default: defaults.monitorNiriOverrides,
            recovering: recovering
        )
        monitorDwindleOverrides = try container.decode(
            [MonitorDwindleSettings].self,
            forKey: .monitorDwindleOverrides,
            default: defaults.monitorDwindleOverrides,
            recovering: recovering
        )
        monitorGapOverrides = try container.decode(
            [MonitorGapSettings].self,
            forKey: .monitorGapOverrides,
            default: defaults.monitorGapOverrides,
            recovering: recovering
        )
        monitorRoutingOverrides = try container.decode(
            [MonitorRoutingSettings].self,
            forKey: .monitorRoutingOverrides,
            default: defaults.monitorRoutingOverrides,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.General {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().general

        hotkeysEnabled = try container.decode(
            Bool.self,
            forKey: .hotkeysEnabled,
            default: defaults.hotkeysEnabled,
            recovering: recovering
        )
        systemHyperTrigger = try container.decodeRecoveringInvalidValue(
            SystemHyperTrigger.self,
            forKey: .systemHyperTrigger,
            default: defaults.systemHyperTrigger,
            recovering: recovering
        )
        hyperKeyModifiers = try container.decodeRecoveringInvalidValue(
            HyperKeyModifiers.self,
            forKey: .hyperKeyModifiers,
            default: defaults.hyperKeyModifiers,
            recovering: recovering
        )
        defaultLayoutType = try container.decode(
            String.self,
            forKey: .defaultLayoutType,
            default: defaults.defaultLayoutType,
            recovering: recovering
        )
        preventSleepEnabled = try container.decode(
            Bool.self,
            forKey: .preventSleepEnabled,
            default: defaults.preventSleepEnabled,
            recovering: recovering
        )
        updateChecksEnabled = try container.decode(
            Bool.self,
            forKey: .updateChecksEnabled,
            default: defaults.updateChecksEnabled,
            recovering: recovering
        )
        ipcEnabled = try container.decode(
            Bool.self,
            forKey: .ipcEnabled,
            default: defaults.ipcEnabled,
            recovering: recovering
        )
        animationsEnabled = try container.decode(
            Bool.self,
            forKey: .animationsEnabled,
            default: defaults.animationsEnabled,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.Focus {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().focus

        followsMouse = try container.decode(
            Bool.self,
            forKey: .followsMouse,
            default: defaults.followsMouse,
            recovering: recovering
        )
        lockModifier = try container.decode(
            String.self,
            forKey: .lockModifier,
            default: defaults.lockModifier,
            recovering: recovering
        )
        moveMouseToFocusedWindow = try container.decode(
            Bool.self,
            forKey: .moveMouseToFocusedWindow,
            default: defaults.moveMouseToFocusedWindow,
            recovering: recovering
        )
        followsWindowToMonitor = try container.decode(
            Bool.self,
            forKey: .followsWindowToMonitor,
            default: defaults.followsWindowToMonitor,
            recovering: recovering
        )
        crossesMonitorAtEdge = try container.decode(
            Bool.self,
            forKey: .crossesMonitorAtEdge,
            default: defaults.crossesMonitorAtEdge,
            recovering: recovering
        )
        moveCrossesMonitorAtEdge = try container.decode(
            Bool.self,
            forKey: .moveCrossesMonitorAtEdge,
            default: defaults.moveCrossesMonitorAtEdge,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.MouseWarp {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().mouseWarp

        margin = try container.decode(Int.self, forKey: .margin, default: defaults.margin, recovering: recovering)
        enabled = try container.decode(
            Bool.self,
            forKey: .enabled,
            default: defaults.enabled,
            recovering: recovering
        )
        constrainToArrangement = try container.decode(
            Bool.self,
            forKey: .constrainToArrangement,
            default: defaults.constrainToArrangement,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.Routing {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().routing

        mode = try container.decode(String.self, forKey: .mode, default: defaults.mode, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Gaps {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().gaps

        size = try container.decode(Double.self, forKey: .size, default: defaults.size, recovering: recovering)
        outer = try container.decode(Outer.self, forKey: .outer, default: defaults.outer, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Gaps.Outer {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().gaps.outer

        left = try container.decode(Double.self, forKey: .left, default: defaults.left, recovering: recovering)
        right = try container.decode(Double.self, forKey: .right, default: defaults.right, recovering: recovering)
        top = try container.decode(Double.self, forKey: .top, default: defaults.top, recovering: recovering)
        bottom = try container.decode(Double.self, forKey: .bottom, default: defaults.bottom, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Niri {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().niri

        visibleContainerCount = try container.decode(
            Int.self,
            forKey: .visibleContainerCount,
            default: defaults.visibleContainerCount,
            recovering: recovering
        )
        infiniteLoop = try container.decode(
            Bool.self,
            forKey: .infiniteLoop,
            default: defaults.infiniteLoop,
            recovering: recovering
        )
        centerFocusedColumn = try container.decode(
            String.self,
            forKey: .centerFocusedColumn,
            default: defaults.centerFocusedColumn,
            recovering: recovering
        )
        alwaysCenterSingleColumn = try container.decode(
            Bool.self,
            forKey: .alwaysCenterSingleColumn,
            default: defaults.alwaysCenterSingleColumn,
            recovering: recovering
        )
        singleWindowFit = try container.decode(
            String.self,
            forKey: .singleWindowFit,
            default: defaults.singleWindowFit,
            recovering: recovering
        )
        containerPrimarySpanPresets = try container.decodeIfPresent([Double].self, forKey: .containerPrimarySpanPresets)
        defaultContainerPrimarySpan = try container.decodeIfPresent(Double.self, forKey: .defaultContainerPrimarySpan)
    }
}

extension CanonicalTOMLConfig.Dwindle {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().dwindle

        smartSplit = try container.decode(
            Bool.self,
            forKey: .smartSplit,
            default: defaults.smartSplit,
            recovering: recovering
        )
        defaultSplitRatio = try container.decode(
            Double.self,
            forKey: .defaultSplitRatio,
            default: defaults.defaultSplitRatio,
            recovering: recovering
        )
        splitWidthMultiplier = try container.decode(
            Double.self,
            forKey: .splitWidthMultiplier,
            default: defaults.splitWidthMultiplier,
            recovering: recovering
        )
        singleWindowFit = try container.decode(
            String.self,
            forKey: .singleWindowFit,
            default: defaults.singleWindowFit,
            recovering: recovering
        )
        useGlobalGaps = try container.decode(
            Bool.self,
            forKey: .useGlobalGaps,
            default: defaults.useGlobalGaps,
            recovering: recovering
        )
        moveToRootStable = try container.decode(
            Bool.self,
            forKey: .moveToRootStable,
            default: defaults.moveToRootStable,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.Borders {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().borders

        enabled = try container.decode(Bool.self, forKey: .enabled, default: defaults.enabled, recovering: recovering)
        width = try container.decode(Double.self, forKey: .width, default: defaults.width, recovering: recovering)
        color = try container.decode(Color.self, forKey: .color, default: defaults.color, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Borders.Color {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().borders.color

        red = try container.decode(Double.self, forKey: .red, default: defaults.red, recovering: recovering)
        green = try container.decode(Double.self, forKey: .green, default: defaults.green, recovering: recovering)
        blue = try container.decode(Double.self, forKey: .blue, default: defaults.blue, recovering: recovering)
        alpha = try container.decode(Double.self, forKey: .alpha, default: defaults.alpha, recovering: recovering)
    }
}

extension CanonicalTOMLConfig.Overview {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().overview

        zoom = try container.decode(Double.self, forKey: .zoom, default: defaults.zoom, recovering: recovering)
        backdrop = try container.decode(
            Color.self,
            forKey: .backdrop,
            default: defaults.backdrop,
            recovering: recovering,
            using: Color.decode
        )
        windowBorders = try container.decode(
            WindowBorders.self,
            forKey: .windowBorders,
            default: defaults.windowBorders,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.Overview.WindowBorders {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().overview.windowBorders

        normal = try container.decode(
            CanonicalTOMLConfig.Overview.Color.self,
            forKey: .normal,
            default: defaults.normal,
            recovering: recovering,
            using: CanonicalTOMLConfig.Overview.Color.decode
        )
        hovered = try container.decode(
            CanonicalTOMLConfig.Overview.Color.self,
            forKey: .hovered,
            default: defaults.hovered,
            recovering: recovering,
            using: CanonicalTOMLConfig.Overview.Color.decode
        )
        selected = try container.decode(
            CanonicalTOMLConfig.Overview.Color.self,
            forKey: .selected,
            default: defaults.selected,
            recovering: recovering,
            using: CanonicalTOMLConfig.Overview.Color.decode
        )
    }
}

private extension CanonicalTOMLConfig.Overview.Color {
    static func decode(_ decoder: Decoder, _ defaultValue: Self, _ recovering: Bool) throws -> Self {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        return Self(
            red: try container.decode(
                Double.self,
                forKey: .red,
                default: defaultValue.red,
                recovering: recovering
            ),
            green: try container.decode(
                Double.self,
                forKey: .green,
                default: defaultValue.green,
                recovering: recovering
            ),
            blue: try container.decode(
                Double.self,
                forKey: .blue,
                default: defaultValue.blue,
                recovering: recovering
            ),
            alpha: try container.decode(
                Double.self,
                forKey: .alpha,
                default: defaultValue.alpha,
                recovering: recovering
            )
        )
    }
}

extension CanonicalTOMLConfig.WorkspaceBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().workspaceBar

        enabled = try container.decode(Bool.self, forKey: .enabled, default: defaults.enabled, recovering: recovering)
        showLabels = try container.decode(
            Bool.self,
            forKey: .showLabels,
            default: defaults.showLabels,
            recovering: recovering
        )
        showFloatingWindows = try container.decode(
            Bool.self,
            forKey: .showFloatingWindows,
            default: defaults.showFloatingWindows,
            recovering: recovering
        )
        windowLevel = try container.decode(
            String.self,
            forKey: .windowLevel,
            default: defaults.windowLevel,
            recovering: recovering
        )
        position = try container.decode(
            String.self,
            forKey: .position,
            default: defaults.position,
            recovering: recovering
        )
        notchMode = try container.decode(
            String.self,
            forKey: .notchMode,
            default: defaults.notchMode,
            recovering: recovering
        )
        notchActiveZoneWidth = try container.decode(
            Double.self,
            forKey: .notchActiveZoneWidth,
            default: defaults.notchActiveZoneWidth,
            recovering: recovering
        )
        systemStatsButton = try container.decode(
            Bool.self,
            forKey: .systemStatsButton,
            default: defaults.systemStatsButton,
            recovering: recovering
        )
        deduplicateAppIcons = try container.decode(
            Bool.self,
            forKey: .deduplicateAppIcons,
            default: defaults.deduplicateAppIcons,
            recovering: recovering
        )
        hideEmptyWorkspaces = try container.decode(
            Bool.self,
            forKey: .hideEmptyWorkspaces,
            default: defaults.hideEmptyWorkspaces,
            recovering: recovering
        )
        excludedBundleIDs = try container.decode(
            [String].self,
            forKey: .excludedBundleIDs,
            default: defaults.excludedBundleIDs,
            recovering: recovering
        )
        iconOverrides = try container.decode(
            [String: String].self,
            forKey: .iconOverrides,
            default: defaults.iconOverrides,
            recovering: recovering
        )
        reserveLayoutSpace = try container.decode(
            Bool.self,
            forKey: .reserveLayoutSpace,
            default: defaults.reserveLayoutSpace,
            recovering: recovering
        )
        revealModifier = try container.decode(
            String.self,
            forKey: .revealModifier,
            default: defaults.revealModifier,
            recovering: recovering
        )
        revealHoldMilliseconds = try container.decode(
            Double.self,
            forKey: .revealHoldMilliseconds,
            default: defaults.revealHoldMilliseconds,
            recovering: recovering
        )
        hideInNativeFullscreen = try container.decode(
            Bool.self,
            forKey: .hideInNativeFullscreen,
            default: defaults.hideInNativeFullscreen,
            recovering: recovering
        )
        height = try container.decode(Double.self, forKey: .height, default: defaults.height, recovering: recovering)
        backgroundOpacity = try container.decode(
            Double.self,
            forKey: .backgroundOpacity,
            default: defaults.backgroundOpacity,
            recovering: recovering
        )
        xOffset = try container.decode(Double.self, forKey: .xOffset, default: defaults.xOffset, recovering: recovering)
        yOffset = try container.decode(Double.self, forKey: .yOffset, default: defaults.yOffset, recovering: recovering)
        do {
            accentColor = try container.decodeIfPresent(Color.self, forKey: .accentColor)
        } catch {
            if recovering {
                accentColor = nil
            } else {
                throw error
            }
        }
        do {
            textColor = try container.decodeIfPresent(Color.self, forKey: .textColor)
        } catch {
            if recovering {
                textColor = nil
            } else {
                throw error
            }
        }
    }
}

extension CanonicalTOMLConfig.Gestures {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().gestures

        scrollEnabled = try container.decode(
            Bool.self,
            forKey: .scrollEnabled,
            default: defaults.scrollEnabled,
            recovering: recovering
        )
        scrollSensitivity = try container.decode(
            Double.self,
            forKey: .scrollSensitivity,
            default: defaults.scrollSensitivity,
            recovering: recovering
        )
        scrollModifierKey = try container.decode(
            String.self,
            forKey: .scrollModifierKey,
            default: defaults.scrollModifierKey,
            recovering: recovering
        )
        mouseMoveModifierKey = try container.decode(
            String.self,
            forKey: .mouseMoveModifierKey,
            default: defaults.mouseMoveModifierKey,
            recovering: recovering
        )
        mouseResizeModifierKey = try container.decode(
            String.self,
            forKey: .mouseResizeModifierKey,
            default: defaults.mouseResizeModifierKey,
            recovering: recovering
        )
        fingerCount = try container.decode(
            Int.self,
            forKey: .fingerCount,
            default: defaults.fingerCount,
            recovering: recovering
        )
        invertDirection = try container.decode(
            Bool.self,
            forKey: .invertDirection,
            default: defaults.invertDirection,
            recovering: recovering
        )
        trackpadScrollStyle = try container.decode(
            String.self,
            forKey: .trackpadScrollStyle,
            default: defaults.trackpadScrollStyle,
            recovering: recovering
        )
        workspaceSwipeEnabled = try container.decode(
            Bool.self,
            forKey: .workspaceSwipeEnabled,
            default: defaults.workspaceSwipeEnabled,
            recovering: recovering
        )
        workspaceSwipeFingerCount = try container.decode(
            Int.self,
            forKey: .workspaceSwipeFingerCount,
            default: defaults.workspaceSwipeFingerCount,
            recovering: recovering
        )
        workspaceSwipeAxis = try container.decode(
            String.self,
            forKey: .workspaceSwipeAxis,
            default: defaults.workspaceSwipeAxis,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.StatusBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().statusBar

        showWorkspaceName = try container.decode(
            Bool.self,
            forKey: .showWorkspaceName,
            default: defaults.showWorkspaceName,
            recovering: recovering
        )
        showAppNames = try container.decode(
            Bool.self,
            forKey: .showAppNames,
            default: defaults.showAppNames,
            recovering: recovering
        )
        useWorkspaceId = try container.decode(
            Bool.self,
            forKey: .useWorkspaceId,
            default: defaults.useWorkspaceId,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.HiddenBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().hiddenBar

        enabled = try container.decode(
            Bool.self,
            forKey: .enabled,
            default: defaults.enabled,
            recovering: recovering
        )
        hiddenBundleIDs = try container.decode(
            [String].self,
            forKey: .hiddenBundleIDs,
            default: defaults.hiddenBundleIDs,
            recovering: recovering
        )
        rehideIntervalSeconds = try container.decode(
            Double.self,
            forKey: .rehideIntervalSeconds,
            default: defaults.rehideIntervalSeconds,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.Clipboard {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().clipboard

        historyEnabled = try container.decode(
            Bool.self,
            forKey: .historyEnabled,
            default: defaults.historyEnabled,
            recovering: recovering
        )
        maxItems = try container.decode(Int.self, forKey: .maxItems, default: defaults.maxItems, recovering: recovering)
        maxItemBytes = try container.decode(
            Int.self,
            forKey: .maxItemBytes,
            default: defaults.maxItemBytes,
            recovering: recovering
        )
        maxTotalBytes = try container.decode(
            Int.self,
            forKey: .maxTotalBytes,
            default: defaults.maxTotalBytes,
            recovering: recovering
        )
    }
}

extension CanonicalTOMLConfig.QuakeTerminal {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().quakeTerminal

        enabled = try container.decode(Bool.self, forKey: .enabled, default: defaults.enabled, recovering: recovering)
        position = try container.decode(
            String.self,
            forKey: .position,
            default: defaults.position,
            recovering: recovering
        )
        widthPercent = try container.decode(
            Double.self,
            forKey: .widthPercent,
            default: defaults.widthPercent,
            recovering: recovering
        )
        heightPercent = try container.decode(
            Double.self,
            forKey: .heightPercent,
            default: defaults.heightPercent,
            recovering: recovering
        )
        animationDuration = try container.decode(
            Double.self,
            forKey: .animationDuration,
            default: defaults.animationDuration,
            recovering: recovering
        )
        autoHide = try container.decode(
            Bool.self,
            forKey: .autoHide,
            default: defaults.autoHide,
            recovering: recovering
        )
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        backgroundEffect = try container.decode(
            String.self,
            forKey: .backgroundEffect,
            default: defaults.backgroundEffect,
            recovering: recovering
        )
        backgroundBlurRadius = try container.decodeIfPresent(Int.self, forKey: .backgroundBlurRadius)
        monitorMode = try container.decodeIfPresent(String.self, forKey: .monitorMode)
    }
}

extension CanonicalTOMLConfig.Appearance {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovering = decoder.recoversMissingSettingsTOMLKeys
        let defaults = CanonicalTOMLConfig.recoveryDefaults().appearance

        mode = try container.decode(String.self, forKey: .mode, default: defaults.mode, recovering: recovering)
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
