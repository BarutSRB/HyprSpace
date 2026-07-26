// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Observation

@MainActor
@Observable
final class SettingsNavigationModel {
    var section: SettingsSection = .general
    private(set) var hasPendingMonitorSetupPresentation = false

    func requestMonitorSetupPresentation() {
        section = .monitors
        hasPendingMonitorSetupPresentation = true
    }

    func consumeMonitorSetupPresentationRequest() -> Bool {
        guard hasPendingMonitorSetupPresentation else { return false }
        hasPendingMonitorSetupPresentation = false
        return true
    }
}
