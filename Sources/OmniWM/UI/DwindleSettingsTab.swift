// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct DwindleSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.dwindleSettings(for: $0) != nil },
                reset: { monitor in
                    settings.removeDwindleSettings(for: monitor)
                    controller.updateMonitorDwindleSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorDwindleSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalDwindleSettingsSection(
                    settings: settings,
                    controller: controller
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }
}

private struct GlobalDwindleSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Section("Dwindle Layout") {
            Toggle("Smart Split", isOn: $settings.dwindleSmartSplit)
                .onChange(of: settings.dwindleSmartSplit) { _, newValue in
                    controller.updateDwindleConfig(smartSplit: newValue)
                }
            SettingsCaption("Automatically choose split direction based on cursor position")

            Toggle("Move to Root: Stable", isOn: $settings.dwindleMoveToRootStable)
            SettingsCaption("Keep window on same screen side when moving to root")

            SettingsSliderRow(
                label: "Default Split Ratio",
                value: $settings.dwindleDefaultSplitRatio,
                range: 0.1 ... 1.9,
                step: 0.1,
                valueText: String(format: "%.1f", settings.dwindleDefaultSplitRatio),
                valueWidth: 40
            )
            .onChange(of: settings.dwindleDefaultSplitRatio) { _, newValue in
                controller.updateDwindleConfig(defaultSplitRatio: CGFloat(newValue))
            }
            SettingsCaption("1.0 = equal split, <1.0 = first smaller, >1.0 = first larger")

            SettingsSliderRow(
                label: "Split Width Multiplier",
                value: $settings.dwindleSplitWidthMultiplier,
                range: 0.5 ... 2.0,
                step: 0.1,
                valueText: String(format: "%.1f", settings.dwindleSplitWidthMultiplier),
                valueWidth: 40
            )
            .onChange(of: settings.dwindleSplitWidthMultiplier) { _, newValue in
                controller.updateDwindleConfig(splitWidthMultiplier: CGFloat(newValue))
            }
            SettingsCaption("Affects when to prefer vertical vs horizontal splits")

            SingleWindowFitControls(
                label: "Single Window",
                fit: settings.dwindleSingleWindowFit,
                modes: SingleWindowFit.dwindleModes,
                onChange: { newValue in
                    settings.dwindleSingleWindowFit = newValue
                    controller.updateDwindleConfig(singleWindowFit: newValue)
                }
            )
            SettingsCaption(
                "How a lone window is sized: Full Screen fills the work area; Custom uses a fixed width × height"
            )

            Toggle("Use Global Gap Settings", isOn: $settings.dwindleUseGlobalGaps)
                .onChange(of: settings.dwindleUseGlobalGaps) { _, _ in
                    controller.updateDwindleConfig()
                }
            SettingsCaption("When enabled, uses the gap values from General settings")
        }
    }
}

private struct MonitorDwindleSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorDwindleSettings {
        settings.dwindleSettings(for: monitor) ?? MonitorDwindleSettings(
            monitorName: monitor.name
        )
    }

    private func updateSetting(_ update: (inout MonitorDwindleSettings) -> Void) {
        var ms = monitorSettings
        update(&ms)
        settings.updateDwindleSettings(ms, for: monitor)
        controller.updateMonitorDwindleSettings()
    }

    var body: some View {
        let ms = monitorSettings
        let usesGlobalGaps = ms.useGlobalGaps ?? settings.dwindleUseGlobalGaps

        Section("Dwindle Layout") {
            OverridableToggle(
                label: "Smart Split",
                value: ms.smartSplit,
                globalValue: settings.dwindleSmartSplit,
                onChange: { newValue in updateSetting { $0.smartSplit = newValue } },
                onReset: { updateSetting { $0.smartSplit = nil } }
            )
            SettingsCaption("Automatically choose split direction based on cursor position")

            OverridableSlider(
                label: "Default Split Ratio",
                value: ms.defaultSplitRatio,
                globalValue: settings.dwindleDefaultSplitRatio,
                range: 0.1 ... 1.9,
                step: 0.1,
                formatter: { String(format: "%.1f", $0) },
                onChange: { newValue in updateSetting { $0.defaultSplitRatio = newValue } },
                onReset: { updateSetting { $0.defaultSplitRatio = nil } }
            )
            SettingsCaption("1.0 = equal split, <1.0 = first smaller, >1.0 = first larger")

            OverridableSlider(
                label: "Split Width Multiplier",
                value: ms.splitWidthMultiplier,
                globalValue: settings.dwindleSplitWidthMultiplier,
                range: 0.5 ... 2.0,
                step: 0.1,
                formatter: { String(format: "%.1f", $0) },
                onChange: { newValue in updateSetting { $0.splitWidthMultiplier = newValue } },
                onReset: { updateSetting { $0.splitWidthMultiplier = nil } }
            )
            SettingsCaption("Affects when to prefer vertical vs horizontal splits")

            SingleWindowFitControls(
                label: "Single Window",
                fit: ms.singleWindowFit ?? settings.dwindleSingleWindowFit,
                modes: SingleWindowFit.dwindleModes,
                isOverridden: ms.singleWindowFit != nil,
                onChange: { newValue in updateSetting { $0.singleWindowFit = newValue } },
                onReset: { updateSetting { $0.singleWindowFit = nil } }
            )

            OverridableToggle(
                label: "Use Global Gap Settings",
                value: ms.useGlobalGaps,
                globalValue: settings.dwindleUseGlobalGaps,
                onChange: { newValue in updateSetting { $0.useGlobalGaps = newValue } },
                onReset: { updateSetting { $0.useGlobalGaps = nil } }
            )
            SettingsCaption("When enabled, uses the gap values from General settings")
        }

        if !usesGlobalGaps {
            Section("Dwindle Gaps") {
                OverridableSlider(
                    label: "Inner Gap",
                    value: ms.innerGap,
                    globalValue: settings.gapSize,
                    range: 0 ... 32,
                    step: 1,
                    formatter: { "\(Int($0)) px" },
                    onChange: { newValue in updateSetting { $0.innerGap = newValue } },
                    onReset: { updateSetting { $0.innerGap = nil } }
                )
            }
        }
    }
}
