// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct SettingsDetailView: View {
    let section: SettingsSection
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    let updateCoordinator: (any AppUpdateCoordinating)?
    let navigation: SettingsNavigationModel

    var body: some View {
        contentView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(section.displayName)
            .backgroundExtensionEffect()
    }

    @ViewBuilder
    private var contentView: some View {
        switch section {
        case .general:
            GeneralSettingsTab(
                settings: settings,
                controller: controller,
                windowCornerPreferences: windowCornerPreferences,
                updateCoordinator: updateCoordinator
            )
        case .diagnostics:
            DiagnosticsSettingsTab(controller: controller, navigation: navigation)
        case .niri:
            NiriSettingsTab(settings: settings, controller: controller)
        case .dwindle:
            DwindleSettingsTab(settings: settings, controller: controller)
        case .monitors:
            MonitorSettingsTab(
                settings: settings,
                controller: controller,
                navigation: navigation
            )
        case .workspaces:
            WorkspacesSettingsTab(settings: settings, controller: controller)
        case .overview:
            OverviewSettingsTab(settings: settings, controller: controller)
        case .borders:
            BorderSettingsTab(settings: settings, controller: controller)
        case .bar:
            WorkspaceBarSettingsTab(settings: settings, controller: controller)
        case .hiddenBar:
            HiddenBarSettingsTab(settings: settings, controller: controller)
        case .hotkeys:
            HotkeySettingsView(settings: settings, controller: controller)
        case .mouseTrackpad:
            MouseTrackpadSettingsTab(settings: settings, controller: controller)
        case .quakeTerminal:
            QuakeTerminalSettingsTab(settings: settings, controller: controller)
        case .reportIssue:
            ReportIssueSettingsTab(controller: controller)
        }
    }
}
