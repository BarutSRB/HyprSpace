// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
enum DiagnosticsIssueAggregator {
    static func applicableIssues(
        controller: WMController,
        systemHotkeyQuery: HotkeyAdvisoryDetector.SystemHotkeyQuery = HotkeyAdvisoryDetector.liveSystemHotkeyQuery
    ) -> [DiagnosticsIssue] {
        var issues: [DiagnosticsIssue] = []

        if !controller.accessibilityPermissionGranted {
            issues.append(DiagnosticsIssue(kind: .accessibilityNotGranted))
        }

        let hotkeyIssues = controller.hotkeyRegistrationFailures
            .sorted { $0.key.displayName < $1.key.displayName }
            .map { failure in
                DiagnosticsIssue(kind: .hotkeyRegistration(command: failure.key.displayName, reason: failure.value))
            }
        issues.append(contentsOf: hotkeyIssues)

        issues.append(contentsOf: HotkeyAdvisoryDetector.issues(
            currentBindings: controller.settings.hotkeyBindings,
            defaults: HotkeyBindingRegistry.defaults(),
            systemHotkeyQuery: systemHotkeyQuery
        ))

        issues.append(contentsOf: SidedHyperBindingDetector.issues(
            currentBindings: controller.settings.hotkeyBindings
        ))

        issues.append(contentsOf: DisplayEnvironmentDiagnostics.issues(
            monitors: Monitor.current(),
            spacesMode: controller.displaySpacesMode
        ))

        issues.append(contentsOf: SettingsConfigDiagnostics.issues(
            directoryURL: controller.settings.settingsFileURL.deletingLastPathComponent(),
            notice: controller.settings.configNotice
        ))

        return issues
    }
}
