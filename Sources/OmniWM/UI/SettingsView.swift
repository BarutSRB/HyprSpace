// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    let updateCoordinator: (any AppUpdateCoordinating)?
    let navigation: SettingsNavigationModel
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                selection: $selectedSection,
                diagnosticsIssueCount: controller.diagnosticsIssues.count
            )
        } detail: {
            SettingsDetailView(
                section: selectedSection,
                settings: settings,
                controller: controller,
                windowCornerPreferences: windowCornerPreferences,
                updateCoordinator: updateCoordinator,
                navigation: navigation
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            selectedSection = navigation.section
        }
        .onChange(of: navigation.section) { _, newValue in
            selectedSection = newValue
        }
        .task(id: selectedSection) {
            controller.refreshDiagnosticsIssues()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshDiagnosticsIssues()
        }
    }
}

struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    let updateCoordinator: (any AppUpdateCoordinating)?

    @State private var selectedGapMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()
    @State private var loginItems = LoginItemManager()

    var body: some View {
        let animationsEnabled = Binding(
            get: { controller.motionPolicy.animationsEnabled },
            set: { controller.setAnimationsEnabled($0) }
        )
        let startAtLogin = Binding(
            get: { loginItems.isEnabled },
            set: { loginItems.setEnabled($0) }
        )

        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.appearanceMode) { _, _ in
                    controller.applyCurrentAppearanceMode()
                }

                SettingsCaption("Controls the appearance of menus and workspace bar")

                Toggle("Enable Animations", isOn: animationsEnabled)
                SettingsCaption("Turns OmniWM-authored animations on or off live without relaunching.")

                AppWindowCornerSettings(preferences: windowCornerPreferences)
            }

            Section("Status Bar") {
                Toggle("Show Workspace", isOn: $settings.statusBarShowWorkspaceName)
                    .onChange(of: settings.statusBarShowWorkspaceName) { _, _ in
                        controller.refreshStatusBar()
                    }
                Toggle("Use Workspace Number", isOn: $settings.statusBarUseWorkspaceId)
                    .onChange(of: settings.statusBarUseWorkspaceId) { _, _ in
                        controller.refreshStatusBar()
                    }
                    .disabled(!settings.statusBarShowWorkspaceName)
                Toggle("Show Focused App", isOn: $settings.statusBarShowAppNames)
                    .onChange(of: settings.statusBarShowAppNames) { _, _ in
                        controller.refreshStatusBar()
                    }
                    .disabled(!settings.statusBarShowWorkspaceName)
                SettingsCaption("Shows the active workspace and focused app beside the menu bar icon")
            }

            Section("Startup") {
                Toggle("Start at Login", isOn: startAtLogin)
                    .onAppear { loginItems.refresh() }
                    .onReceive(
                        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                    ) { _ in
                        loginItems.refresh()
                    }
                if loginItems.requiresApproval {
                    Button("Open Login Items Settings...") {
                        LoginItemManager.openLoginItemsSettings()
                    }
                    SettingsCaption(
                        "macOS needs your approval before OmniWM can start at login. "
                            + "Approve it under System Settings > General > Login Items."
                    )
                }
                if let loginItemError = loginItems.lastErrorDescription {
                    SettingsCaption("Could not update the login item: \(loginItemError)")
                }
                SettingsCaption("Launches OmniWM automatically when you log in.")
            }

            Section("Updates") {
                Toggle("Check for Updates Automatically", isOn: $settings.updateChecksEnabled)

                Button("Check for Updates...") {
                    updateCoordinator?.checkForUpdatesManually()
                }
                .disabled(updateCoordinator == nil)

                SettingsCaption(
                    "OmniWM checks the latest GitHub release once per day on launch. Updates stay manual and the popup includes both the GitHub page and the Homebrew command."
                )
            }

            MonitorScopeSection(
                selectedMonitor: $selectedGapMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.gapSettings(for: $0) != nil },
                reset: { monitor in
                    settings.removeGapSettings(for: monitor)
                    controller.updateMonitorGapSettings()
                }
            )

            Section("Layout") {
                if let monitorId = selectedGapMonitor,
                   let monitor = connectedMonitors.first(where: { $0.id == monitorId })
                {
                    OverridableSlider(
                        label: "Inner Gaps",
                        value: settings.gapSettings(for: monitor)?.innerGap,
                        globalValue: settings.gapSize,
                        range: 0 ... 32,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { value in updateGapSetting(for: monitor) { $0.innerGap = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.innerGap = nil } }
                    )
                    SettingsCaption("Overrides the global inner gap for \(monitor.name).")
                } else {
                    SettingsSliderRow(
                        label: "Inner Gaps",
                        value: $settings.gapSize,
                        range: 0 ... 32,
                        step: 1,
                        valueText: "\(Int(settings.gapSize)) px",
                        valueWidth: 64
                    )
                    .onChange(of: settings.gapSize) { _, newValue in
                        controller.setGapSize(newValue)
                    }
                }
            }

            Section("Outer Margins") {
                if let monitorId = selectedGapMonitor,
                   let monitor = connectedMonitors.first(where: { $0.id == monitorId })
                {
                    OverridableSlider(
                        label: "Left",
                        value: settings.gapSettings(for: monitor)?.outerGapLeft,
                        globalValue: settings.outerGapLeft,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { v in updateGapSetting(for: monitor) { $0.outerGapLeft = v } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapLeft = nil } }
                    )
                    OverridableSlider(
                        label: "Right",
                        value: settings.gapSettings(for: monitor)?.outerGapRight,
                        globalValue: settings.outerGapRight,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { v in updateGapSetting(for: monitor) { $0.outerGapRight = v } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapRight = nil } }
                    )
                    OverridableSlider(
                        label: "Top",
                        value: settings.gapSettings(for: monitor)?.outerGapTop,
                        globalValue: settings.outerGapTop,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { v in updateGapSetting(for: monitor) { $0.outerGapTop = v } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapTop = nil } }
                    )
                    OverridableSlider(
                        label: "Bottom",
                        value: settings.gapSettings(for: monitor)?.outerGapBottom,
                        globalValue: settings.outerGapBottom,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { "\(Int($0)) px" },
                        onChange: { v in updateGapSetting(for: monitor) { $0.outerGapBottom = v } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapBottom = nil } }
                    )
                    OverridableToggle(
                        label: "Keep Outer Margins in Full Screen",
                        value: settings.gapSettings(for: monitor)?.fullscreenUsesOuterGaps,
                        globalValue: settings.fullscreenUsesOuterGaps,
                        onChange: { value in
                            updateGapSetting(for: monitor) { $0.fullscreenUsesOuterGaps = value }
                        },
                        onReset: { updateGapSetting(for: monitor) { $0.fullscreenUsesOuterGaps = nil } }
                    )
                    SettingsCaption(
                        "Overrides selected global outer-margin values for \(monitor.name). "
                            + topGapCaption(
                                settings.gapSettings(for: monitor)?.outerGapTop ?? settings.outerGapTop,
                                on: monitor
                            )
                    )
                    SettingsCaption(
                        "Keeps these margins for OmniWM Full Screen and the Single Window ‘Full Screen’ fit. Any active Workspace Bar reservation is also kept; native macOS Full Screen is unchanged."
                    )
                } else {
                    SettingsSliderRow(
                        label: "Left",
                        value: $settings.outerGapLeft,
                        range: 0 ... 64,
                        step: 1,
                        valueText: "\(Int(settings.outerGapLeft)) px",
                        valueWidth: 64
                    )
                    .onChange(of: settings.outerGapLeft) { _, _ in syncOuterGaps() }

                    SettingsSliderRow(
                        label: "Right",
                        value: $settings.outerGapRight,
                        range: 0 ... 64,
                        step: 1,
                        valueText: "\(Int(settings.outerGapRight)) px",
                        valueWidth: 64
                    )
                    .onChange(of: settings.outerGapRight) { _, _ in syncOuterGaps() }

                    SettingsSliderRow(
                        label: "Top",
                        value: $settings.outerGapTop,
                        range: 0 ... 64,
                        step: 1,
                        valueText: "\(Int(settings.outerGapTop)) px",
                        valueWidth: 64
                    )
                    .onChange(of: settings.outerGapTop) { _, _ in syncOuterGaps() }
                    if let mainMonitor = connectedMonitors.first(where: \.isMain) {
                        SettingsCaption(topGapCaption(settings.outerGapTop, on: mainMonitor))
                    }

                    SettingsSliderRow(
                        label: "Bottom",
                        value: $settings.outerGapBottom,
                        range: 0 ... 64,
                        step: 1,
                        valueText: "\(Int(settings.outerGapBottom)) px",
                        valueWidth: 64
                    )
                    .onChange(of: settings.outerGapBottom) { _, _ in syncOuterGaps() }

                    Toggle(
                        "Keep Outer Margins in Full Screen",
                        isOn: $settings.fullscreenUsesOuterGaps
                    )
                    .onChange(of: settings.fullscreenUsesOuterGaps) { _, _ in
                        controller.updateMonitorGapSettings()
                    }

                    SettingsCaption(
                        "Keeps these margins for OmniWM Full Screen and the Single Window ‘Full Screen’ fit. Any active Workspace Bar reservation is also kept; native macOS Full Screen is unchanged."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }

    private func topGapCaption(_ top: Double, on monitor: Monitor) -> String {
        let menuBarInset = Int(max(0, monitor.frame.maxY - monitor.visibleFrame.maxY))
        let belowMenuBar = max(0, Int(top) - menuBarInset)
        return "Top is measured from the screen's physical top edge: "
            + "\(Int(top)) px → \(belowMenuBar) px below the menu bar on \(monitor.name)."
    }

    private func syncOuterGaps() {
        controller.updateMonitorGapSettings()
    }

    private func updateGapSetting(for monitor: Monitor, _ update: (inout MonitorGapSettings) -> Void) {
        var ms = settings.gapSettings(for: monitor) ?? MonitorGapSettings(
            monitorName: monitor.name
        )
        update(&ms)
        settings.updateGapSettings(ms, for: monitor)
        controller.updateMonitorGapSettings()
    }
}

struct NiriSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.niriSettings(for: $0) != nil },
                reset: { monitor in
                    settings.removeNiriSettings(for: monitor)
                    controller.updateMonitorNiriSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorNiriSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalNiriSettingsSection(
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

private struct GlobalNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        let useAutoDefaultContainerPrimarySpan = Binding(
            get: { settings.niriDefaultContainerPrimarySpan == nil },
            set: { useAuto in
                settings
                    .niriDefaultContainerPrimarySpan = useAuto ? nil : (settings.niriDefaultContainerPrimarySpan ?? 0.5)
                controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan)
                controller.balanceNiriSizesAllWorkspaces()
            }
        )
        let defaultContainerPrimarySpanPercent = Binding(
            get: { Int((settings.niriDefaultContainerPrimarySpan ?? 0.5) * 100) },
            set: { newPercent in
                settings.niriDefaultContainerPrimarySpan = Double(min(100, max(5, newPercent))) / 100.0
                controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan)
                controller.balanceNiriSizesAllWorkspaces()
            }
        )
        let presets = settings.niriContainerPrimarySpanPresets

        Section("Niri Layout") {
            SettingsSliderRow(
                label: "Visible Containers",
                value: Binding(
                    get: { Double(settings.niriVisibleContainerCount) },
                    set: { settings.niriVisibleContainerCount = Int($0) }
                ),
                range: 1 ... 5,
                step: 1,
                valueText: "\(settings.niriVisibleContainerCount)",
                valueWidth: 32
            )
            .onChange(of: settings.niriVisibleContainerCount) { _, newValue in
                settings.niriDefaultContainerPrimarySpan = nil
                controller.updateNiriConfig(
                    visibleContainerCount: newValue,
                    defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan
                )
                controller.balanceNiriSizesAllWorkspaces()
            }

            Toggle("Infinite Loop Navigation", isOn: $settings.niriInfiniteLoop)
                .onChange(of: settings.niriInfiniteLoop) { _, newValue in
                    controller.updateNiriConfig(infiniteLoop: newValue)
                }

            Picker("Center Focused Column", selection: $settings.niriCenterFocusedColumn) {
                ForEach(CenterFocusedColumn.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: settings.niriCenterFocusedColumn) { _, newValue in
                controller.updateNiriConfig(centerFocusedColumn: newValue)
            }

            Toggle("Always Center Single Column", isOn: $settings.niriAlwaysCenterSingleColumn)
                .onChange(of: settings.niriAlwaysCenterSingleColumn) { _, newValue in
                    controller.updateNiriConfig(alwaysCenterSingleColumn: newValue)
                }

            SingleWindowFitControls(
                label: "Single Window",
                fit: settings.niriSingleWindowFit,
                modes: SingleWindowFit.niriModes,
                onChange: { newValue in
                    settings.niriSingleWindowFit = newValue
                    controller.updateNiriConfig(singleWindowFit: newValue)
                }
            )
            SettingsCaption(
                "How a lone window is sized: Full Screen fills the work area; "
                    + "Custom uses a fixed width × height; Container Primary Span keeps the configured primary span."
            )
        }

        Section("Default New Container Primary Span") {
            Picker("Span Mode", selection: useAutoDefaultContainerPrimarySpan) {
                Text("Auto").tag(true)
                Text("Custom").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            if settings.niriDefaultContainerPrimarySpan != nil {
                LabeledContent("Custom Span") {
                    HStack {
                        TextField("Custom Span", value: defaultContainerPrimarySpanPercent, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCaption(
                settings.niriDefaultContainerPrimarySpan == nil
                    ? "Auto divides the primary axis by the Visible Containers setting."
                    : "New or claimed containers start at this primary span until you resize them."
            )
        }

        Section("Container Primary Span Presets") {
            ForEach(presets.indices, id: \.self) { index in
                LabeledContent("Preset \(index + 1)") {
                    HStack {
                        TextField("Preset \(index + 1)", value: Binding(
                            get: { Int(presets[index] * 100) },
                            set: { newPercent in
                                var current = settings.niriContainerPrimarySpanPresets
                                current[index] = Double(min(100, max(5, newPercent))) / 100.0
                                settings.niriContainerPrimarySpanPresets = current
                                controller
                                    .updateNiriConfig(containerPrimarySpanPresets: settings
                                        .niriContainerPrimarySpanPresets)
                            }
                        ), format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Preset \(index + 1) primary span")
                        Text("%")
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            var presets = settings.niriContainerPrimarySpanPresets
                            presets.remove(at: index)
                            settings.niriContainerPrimarySpanPresets = presets
                            controller
                                .updateNiriConfig(containerPrimarySpanPresets: settings.niriContainerPrimarySpanPresets)
                        } label: {
                            Label("Remove preset \(index + 1)", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove preset \(index + 1)")
                        .disabled(settings.niriContainerPrimarySpanPresets.count <= 2)
                    }
                }
            }

            HStack {
                Button("Add Preset") {
                    var presets = settings.niriContainerPrimarySpanPresets
                    presets.append(0.5)
                    settings.niriContainerPrimarySpanPresets = presets
                    controller.updateNiriConfig(containerPrimarySpanPresets: settings.niriContainerPrimarySpanPresets)
                }
                Button("Reset Cycle Presets") {
                    settings.niriContainerPrimarySpanPresets = SettingsStore.defaultContainerPrimarySpanPresets
                    controller.updateNiriConfig(containerPrimarySpanPresets: settings.niriContainerPrimarySpanPresets)
                }
            }
            SettingsCaption("Resize commands cycle through these presets in order. Duplicates are allowed.")
        }
        .id(settings.niriContainerPrimarySpanPresets.count)
    }
}

private struct MonitorNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorNiriSettings {
        settings.niriSettings(for: monitor) ?? MonitorNiriSettings(
            monitorName: monitor.name
        )
    }

    private func updateSetting(_ update: (inout MonitorNiriSettings) -> Void) {
        var ms = monitorSettings
        update(&ms)
        settings.updateNiriSettings(ms, for: monitor)
        controller.updateMonitorNiriSettings()
    }

    var body: some View {
        let ms = monitorSettings

        Section("Niri Layout") {
            OverridableSlider(
                label: "Visible Containers",
                value: ms.visibleContainerCount.map { Double($0) },
                globalValue: Double(settings.niriVisibleContainerCount),
                range: 1 ... 5,
                step: 1,
                formatter: { "\(Int($0))" },
                onChange: { newValue in
                    updateSetting { $0.visibleContainerCount = Int(newValue) }
                    settings.niriDefaultContainerPrimarySpan = nil
                    controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niriDefaultContainerPrimarySpan)
                    controller.balanceNiriSizesAllWorkspaces()
                },
                onReset: { updateSetting { $0.visibleContainerCount = nil } }
            )

            OverridableToggle(
                label: "Infinite Loop Navigation",
                value: ms.infiniteLoop,
                globalValue: settings.niriInfiniteLoop,
                onChange: { newValue in updateSetting { $0.infiniteLoop = newValue } },
                onReset: { updateSetting { $0.infiniteLoop = nil } }
            )

            OverridablePicker(
                label: "Center Focused Column",
                value: ms.centerFocusedColumn,
                globalValue: settings.niriCenterFocusedColumn,
                options: CenterFocusedColumn.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.centerFocusedColumn = newValue } },
                onReset: { updateSetting { $0.centerFocusedColumn = nil } }
            )

            OverridableToggle(
                label: "Always Center Single Column",
                value: ms.alwaysCenterSingleColumn,
                globalValue: settings.niriAlwaysCenterSingleColumn,
                onChange: { newValue in updateSetting { $0.alwaysCenterSingleColumn = newValue } },
                onReset: { updateSetting { $0.alwaysCenterSingleColumn = nil } }
            )

            SingleWindowFitControls(
                label: "Single Window",
                fit: ms.singleWindowFit ?? settings.niriSingleWindowFit,
                modes: SingleWindowFit.niriModes,
                isOverridden: ms.singleWindowFit != nil,
                onChange: { newValue in updateSetting { $0.singleWindowFit = newValue } },
                onReset: { updateSetting { $0.singleWindowFit = nil } }
            )
        }
    }
}
