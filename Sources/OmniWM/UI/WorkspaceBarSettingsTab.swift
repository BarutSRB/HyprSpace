// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct WorkspaceBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.barSettings(for: $0) != nil },
                reset: { monitor in
                    settings.removeBarSettings(for: monitor)
                    controller.updateWorkspaceBarSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorBarSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalBarSettingsSection(
                    settings: settings,
                    controller: controller
                )
            }

            WorkspaceBarExcludedAppsSection(
                settings: settings,
                controller: controller
            )

            WorkspaceBarIconOverridesSection(
                settings: settings,
                controller: controller
            )
        }
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }
}

private struct GlobalBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var pendingAppearanceSync: Task<Void, Never>?

    var body: some View {
        Section("Workspace Bar") {
            Toggle("Enable Workspace Bar", isOn: $settings.workspaceBarEnabled)
                .onChange(of: settings.workspaceBarEnabled) { _, newValue in
                    controller.setWorkspaceBarEnabled(newValue)
                }

            if settings.workspaceBarEnabled {
                Toggle("Show Workspace Labels", isOn: $settings.workspaceBarShowLabels)
                    .onChange(of: settings.workspaceBarShowLabels) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Show Floating Windows", isOn: $settings.workspaceBarShowFloatingWindows)
                    .onChange(of: settings.workspaceBarShowFloatingWindows) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Deduplicate App Icons", isOn: $settings.workspaceBarDeduplicateAppIcons)
                    .onChange(of: settings.workspaceBarDeduplicateAppIcons) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help("Group windows by app with badge count")

                Toggle("Hide Empty Workspaces", isOn: $settings.workspaceBarHideEmptyWorkspaces)
                    .onChange(of: settings.workspaceBarHideEmptyWorkspaces) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Reserve Space for Workspace Bar", isOn: $settings.workspaceBarReserveLayoutSpace)
                    .onChange(of: settings.workspaceBarReserveLayoutSpace) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help(
                        "Reserve tiled layout space using the configured workspace bar height."
                    )

                Picker("Reveal on Modifier Hold", selection: $settings.workspaceBarRevealModifier) {
                    ForEach(WorkspaceBarRevealModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .onChange(of: settings.workspaceBarRevealModifier) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
                .help("Show the workspace bar as an overlay only while the selected modifiers are held")

                if settings.workspaceBarRevealModifier != .off {
                    SettingsSliderRow(
                        label: "Reveal Hold Delay",
                        value: $settings.workspaceBarRevealHoldMilliseconds,
                        range: 0 ... 1000,
                        step: 50,
                        valueText: "\(Int(settings.workspaceBarRevealHoldMilliseconds)) ms"
                    )
                    .onChange(of: settings.workspaceBarRevealHoldMilliseconds) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                }

                Toggle("Hide in Native Fullscreen", isOn: $settings.workspaceBarHideInNativeFullscreen)
                    .onChange(of: settings.workspaceBarHideInNativeFullscreen) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help(
                        "Hide the bar on a monitor while it shows a native fullscreen window"
                    )

                Toggle("System Stats Button", isOn: $settings.workspaceBarSystemStatsButton)
                    .onChange(of: settings.workspaceBarSystemStatsButton) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help("Show a small workspace bar button that opens a system stats popup")

                Picker("Notch Mode", selection: $settings.workspaceBarNotchMode) {
                    ForEach(WorkspaceBarNotchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.workspaceBarNotchMode) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
                .help("Move the bar below the notch, or split it into islands on both sides of the notch")

                if settings.workspaceBarNotchMode.isSplit {
                    SettingsSliderRow(
                        label: "Active Zone Width",
                        value: $settings.workspaceBarNotchActiveZoneWidth,
                        range: 100 ... 400,
                        step: 10,
                        valueText: "\(Int(settings.workspaceBarNotchActiveZoneWidth)) px"
                    )
                    .onChange(of: settings.workspaceBarNotchActiveZoneWidth) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help("Width of the zone next to the notch that the focused workspace stays centered in")
                }
            }
        }

        if settings.workspaceBarEnabled {
            Section("Position & Level") {
                Picker("Position", selection: $settings.workspaceBarPosition) {
                    ForEach(WorkspaceBarPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .onChange(of: settings.workspaceBarPosition) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                Picker("Window Level", selection: $settings.workspaceBarWindowLevel) {
                    ForEach(WorkspaceBarWindowLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .onChange(of: settings.workspaceBarWindowLevel) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
            }

            Section("Position Offset") {
                SettingsNumberStepperRow(
                    label: "X Offset",
                    value: $settings.workspaceBarXOffset,
                    step: 10,
                    valueText: "\(Int(settings.workspaceBarXOffset)) px"
                )
                .help("Horizontal offset (negative = left, positive = right)")
                .onChange(of: settings.workspaceBarXOffset) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                SettingsNumberStepperRow(
                    label: "Y Offset",
                    value: $settings.workspaceBarYOffset,
                    step: 10,
                    valueText: "\(Int(settings.workspaceBarYOffset)) px"
                )
                .help("Vertical offset (negative = down, positive = up)")
                .onChange(of: settings.workspaceBarYOffset) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
            }

            Section("Appearance") {
                SettingsSliderRow(
                    label: "Bar Height",
                    value: $settings.workspaceBarHeight,
                    range: 20 ... 40,
                    step: 2,
                    valueText: "\(Int(settings.workspaceBarHeight)) px"
                )
                .onChange(of: settings.workspaceBarHeight) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                SettingsSliderRow(
                    label: "Background Opacity",
                    value: $settings.workspaceBarBackgroundOpacity,
                    range: 0 ... 0.5,
                    step: 0.05,
                    valueText: "\(Int(settings.workspaceBarBackgroundOpacity * 100))%"
                )
                .onChange(of: settings.workspaceBarBackgroundOpacity) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                Toggle("Custom Accent Color", isOn: customAccentColorBinding)

                if settings.workspaceBarAccentColor != nil {
                    ColorPicker("Accent Color", selection: accentColorBinding, supportsOpacity: false)
                }

                Toggle("Custom Text Color", isOn: customTextColorBinding)

                if settings.workspaceBarTextColor != nil {
                    ColorPicker("Text Color", selection: textColorBinding, supportsOpacity: false)
                }
            }
        }
    }

    private var customAccentColorBinding: Binding<Bool> {
        Binding(
            get: { settings.workspaceBarAccentColor != nil },
            set: { enabled in
                settings.workspaceBarAccentColor = enabled ? settings
                    .workspaceBarAccentColor ?? defaultAccentColor : nil
                debouncedAppearanceSync()
            }
        )
    }

    private var customTextColorBinding: Binding<Bool> {
        Binding(
            get: { settings.workspaceBarTextColor != nil },
            set: { enabled in
                settings.workspaceBarTextColor = enabled ? settings.workspaceBarTextColor ?? defaultTextColor : nil
                debouncedAppearanceSync()
            }
        )
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { (settings.workspaceBarAccentColor ?? defaultAccentColor).swiftUIColor },
            set: { newColor in
                if let color = SettingsColor(color: newColor, preservesAlpha: false) {
                    settings.workspaceBarAccentColor = color
                    debouncedAppearanceSync()
                }
            }
        )
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { (settings.workspaceBarTextColor ?? defaultTextColor).swiftUIColor },
            set: { newColor in
                if let color = SettingsColor(color: newColor, preservesAlpha: false) {
                    settings.workspaceBarTextColor = color
                    debouncedAppearanceSync()
                }
            }
        )
    }

    private var defaultAccentColor: SettingsColor {
        SettingsColor(nsColor: .controlAccentColor, preservesAlpha: false)
            ?? SettingsColor(red: 0, green: 0.4784313725, blue: 1, alpha: 1)
    }

    private var defaultTextColor: SettingsColor {
        SettingsColor(nsColor: .labelColor, preservesAlpha: false)
            ?? SettingsColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    private func debouncedAppearanceSync() {
        pendingAppearanceSync?.cancel()
        pendingAppearanceSync = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            controller.updateWorkspaceBarAppearance()
        }
    }
}

private struct MonitorBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorBarSettings {
        settings.barSettings(for: monitor) ?? MonitorBarSettings(
            monitorName: monitor.name
        )
    }

    private func updateSetting(_ update: (inout MonitorBarSettings) -> Void) {
        var ms = monitorSettings
        update(&ms)
        settings.updateBarSettings(ms, for: monitor)
        controller.updateWorkspaceBarSettings()
    }

    var body: some View {
        let ms = monitorSettings

        Section("Workspace Bar") {
            OverridableToggle(
                label: "Enable Workspace Bar",
                value: ms.enabled,
                globalValue: settings.workspaceBarEnabled,
                onChange: { newValue in updateSetting { $0.enabled = newValue } },
                onReset: { updateSetting { $0.enabled = nil } }
            )

            OverridableToggle(
                label: "Show Workspace Labels",
                value: ms.showLabels,
                globalValue: settings.workspaceBarShowLabels,
                onChange: { newValue in updateSetting { $0.showLabels = newValue } },
                onReset: { updateSetting { $0.showLabels = nil } }
            )

            OverridableToggle(
                label: "Show Floating Windows",
                value: ms.showFloatingWindows,
                globalValue: settings.workspaceBarShowFloatingWindows,
                onChange: { newValue in updateSetting { $0.showFloatingWindows = newValue } },
                onReset: { updateSetting { $0.showFloatingWindows = nil } }
            )

            OverridableToggle(
                label: "Deduplicate App Icons",
                value: ms.deduplicateAppIcons,
                globalValue: settings.workspaceBarDeduplicateAppIcons,
                onChange: { newValue in updateSetting { $0.deduplicateAppIcons = newValue } },
                onReset: { updateSetting { $0.deduplicateAppIcons = nil } }
            )
            .help("Group windows by app with badge count")

            OverridableToggle(
                label: "Hide Empty Workspaces",
                value: ms.hideEmptyWorkspaces,
                globalValue: settings.workspaceBarHideEmptyWorkspaces,
                onChange: { newValue in updateSetting { $0.hideEmptyWorkspaces = newValue } },
                onReset: { updateSetting { $0.hideEmptyWorkspaces = nil } }
            )

            OverridableToggle(
                label: "Reserve Space for Workspace Bar",
                value: ms.reserveLayoutSpace,
                globalValue: settings.workspaceBarReserveLayoutSpace,
                onChange: { newValue in updateSetting { $0.reserveLayoutSpace = newValue } },
                onReset: { updateSetting { $0.reserveLayoutSpace = nil } }
            )
            .help(
                "Reserve tiled layout space using the configured workspace bar height."
            )

            OverridablePicker(
                label: "Notch Mode",
                value: ms.notchMode,
                globalValue: settings.workspaceBarNotchMode,
                options: WorkspaceBarNotchMode.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.notchMode = newValue } },
                onReset: { updateSetting { $0.notchMode = nil } }
            )
            .help("Move the bar below the notch, or split it into islands on both sides of the notch")

            OverridableSlider(
                label: "Active Zone Width",
                value: ms.notchActiveZoneWidth,
                globalValue: settings.workspaceBarNotchActiveZoneWidth,
                range: 100 ... 400,
                step: 10,
                formatter: { "\(Int($0)) px" },
                onChange: { newValue in updateSetting { $0.notchActiveZoneWidth = newValue } },
                onReset: { updateSetting { $0.notchActiveZoneWidth = nil } }
            )
            .help("Width of the zone next to the notch that the focused workspace stays centered in")
        }

        Section("Position & Level") {
            OverridablePicker(
                label: "Position",
                value: ms.position,
                globalValue: settings.workspaceBarPosition,
                options: WorkspaceBarPosition.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.position = newValue } },
                onReset: { updateSetting { $0.position = nil } }
            )

            OverridablePicker(
                label: "Window Level",
                value: ms.windowLevel,
                globalValue: settings.workspaceBarWindowLevel,
                options: WorkspaceBarWindowLevel.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.windowLevel = newValue } },
                onReset: { updateSetting { $0.windowLevel = nil } }
            )
        }

        Section("Position Offset") {
            OverridableStepper(
                label: "X Offset",
                value: ms.xOffset,
                globalValue: settings.workspaceBarXOffset,
                step: 10,
                formatter: { "\(Int($0)) px" },
                onChange: { newValue in updateSetting { $0.xOffset = newValue } },
                onReset: { updateSetting { $0.xOffset = nil } }
            )
            .help("Horizontal offset (negative = left, positive = right)")

            OverridableStepper(
                label: "Y Offset",
                value: ms.yOffset,
                globalValue: settings.workspaceBarYOffset,
                step: 10,
                formatter: { "\(Int($0)) px" },
                onChange: { newValue in updateSetting { $0.yOffset = newValue } },
                onReset: { updateSetting { $0.yOffset = nil } }
            )
            .help("Vertical offset (negative = down, positive = up)")
        }

        Section("Appearance") {
            OverridableSlider(
                label: "Bar Height",
                value: ms.height,
                globalValue: settings.workspaceBarHeight,
                range: 20 ... 40,
                step: 2,
                formatter: { "\(Int($0)) px" },
                onChange: { newValue in updateSetting { $0.height = newValue } },
                onReset: { updateSetting { $0.height = nil } }
            )

            OverridableSlider(
                label: "Background Opacity",
                value: ms.backgroundOpacity,
                globalValue: settings.workspaceBarBackgroundOpacity,
                range: 0 ... 0.5,
                step: 0.05,
                formatter: { "\(Int($0 * 100))%" },
                onChange: { newValue in updateSetting { $0.backgroundOpacity = newValue } },
                onReset: { updateSetting { $0.backgroundOpacity = nil } }
            )
        }
    }
}
