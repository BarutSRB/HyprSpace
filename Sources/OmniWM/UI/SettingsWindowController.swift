// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private let presenter = HostedWindowPresenter()
    private let navigation = SettingsNavigationModel()
    private let windowCornerPreferences = GlobalWindowCornerPreferences()

    func show(
        settings: SettingsStore,
        controller: WMController,
        updateCoordinator: (any AppUpdateCoordinating)? = nil,
        section: SettingsSection? = nil,
        presentMonitorSetup: Bool = false
    ) {
        windowCornerPreferences.refresh()
        if presentMonitorSetup {
            navigation.requestMonitorSetupPresentation()
        } else if let section {
            navigation.section = section
        }

        presenter.present(
            title: "OmniWM Settings",
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            contentSize: NSSize(width: 900, height: 680),
            minSize: NSSize(width: 760, height: 560)
        ) {
            SettingsView(
                settings: settings,
                controller: controller,
                windowCornerPreferences: windowCornerPreferences,
                updateCoordinator: updateCoordinator,
                navigation: navigation
            )
        }
    }
}
