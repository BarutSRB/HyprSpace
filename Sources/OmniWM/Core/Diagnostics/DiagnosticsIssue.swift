// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum DiagnosticsIssueSeverity: Equatable {
    case warning
    case critical
}

enum DockEdge: String, Equatable {
    case left
    case right
    case bottom

    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .bottom: "Bottom"
        }
    }
}

struct DiagnosticsIssue: Identifiable, Equatable {
    enum Kind: Equatable {
        case accessibilityNotGranted
        case hotkeyRegistration(command: String, reason: HotkeyRegistrationFailureReason)
        case hotkeyCoFireAdvisory(actionID: String, command: String, chord: String, advisory: String)
        case hotkeySidedHyper(actionID: String, command: String, chord: String, side: String)
        case fixedDock(monitorName: String, edge: DockEdge, inset: CGFloat, displayId: CGDirectDisplayID)
        case horizontalDisplayArrangement(
            firstName: String,
            secondName: String,
            firstDisplayId: CGDirectDisplayID,
            secondDisplayId: CGDirectDisplayID
        )
        case unknownConfigKeys(keyPaths: [String])
        case settingsFileCorrupt
        case settingsMigrated(report: SettingsMigrationReport, backupURL: URL)
        case settingsRecovered(reason: String, backupURL: URL)
        case settingsPersistenceBlocked(reason: String, backupURL: URL?)
        case settingsInvalidRejected(reason: String)
    }

    let kind: Kind
    let configFileURL: URL?

    init(kind: Kind, configFileURL: URL? = nil) {
        self.kind = kind
        self.configFileURL = configFileURL
    }

    var id: String {
        switch kind {
        case .accessibilityNotGranted: "accessibility"
        case let .hotkeyRegistration(command, _): "hotkey:\(command)"
        case let .hotkeyCoFireAdvisory(actionID, _, _, _): "hotkey-advisory:\(actionID)"
        case let .hotkeySidedHyper(actionID, _, _, _): "hotkey-sided-hyper:\(actionID)"
        case let .fixedDock(_, edge, _, displayId): "fixedDock:\(displayId):\(edge.rawValue)"
        case let .horizontalDisplayArrangement(_, _, first, second): "displayArrangement:\(first):\(second)"
        case .unknownConfigKeys: "unknown-config-keys"
        case .settingsFileCorrupt: "settings-corrupt"
        case .settingsMigrated: "settings-migrated"
        case .settingsRecovered: "settings-recovered"
        case .settingsPersistenceBlocked: "settings-persistence-blocked"
        case .settingsInvalidRejected: "settings-invalid-rejected"
        }
    }

    var severity: DiagnosticsIssueSeverity {
        switch kind {
        case .accessibilityNotGranted,
             .settingsPersistenceBlocked:
            .critical
        case .hotkeyRegistration,
             .hotkeyCoFireAdvisory,
             .hotkeySidedHyper,
             .fixedDock,
             .horizontalDisplayArrangement,
             .unknownConfigKeys,
             .settingsFileCorrupt,
             .settingsMigrated,
             .settingsRecovered,
             .settingsInvalidRejected:
            .warning
        }
    }

    var title: String {
        switch kind {
        case .accessibilityNotGranted: "Accessibility access required"
        case let .hotkeyRegistration(command, _): "Hotkey unavailable: \(command)"
        case let .hotkeyCoFireAdvisory(_, command, _, _): "Hotkey may conflict: \(command)"
        case let .hotkeySidedHyper(_, command, _, _): "Hyper shortcut may not fire: \(command)"
        case let .fixedDock(monitorName, _, _, _): "Fixed Dock detected on \(monitorName)"
        case .horizontalDisplayArrangement: "Unsupported vertical display overlap detected"
        case .unknownConfigKeys: "Unrecognized settings keys"
        case .settingsFileCorrupt: "Settings recovery file available"
        case .settingsMigrated: "Settings upgraded"
        case .settingsRecovered: "Invalid settings recovered"
        case .settingsPersistenceBlocked: "Settings writes blocked"
        case .settingsInvalidRejected: "Invalid settings left untouched"
        }
    }

    var message: String {
        switch kind {
        case .accessibilityNotGranted:
            "OmniWM needs Accessibility access to observe and manage windows."
        case let .hotkeyRegistration(_, reason):
            switch reason {
            case .duplicateBinding: "Two OmniWM commands are bound to this shortcut."
            case .systemReserved: "macOS or another app already uses this shortcut."
            case .requiresInputMonitoring: "This shortcut needs Input Monitoring permission."
            }
        case let .hotkeyCoFireAdvisory(_, _, _, advisory):
            advisory
        case let .hotkeySidedHyper(_, command, chord, side):
            "\(command) is restricted to \(side)-side modifiers (\(chord)). The Hyper key sends generic modifiers, "
                + "not specific left/right keys, so this shortcut won't trigger from Hyper "
                + "(only from physically holding all four \(side) modifier keys at once)."
        case let .fixedDock(_, edge, inset, _):
            "The Dock appears to reserve \(Int(inset.rounded())) px on the \(edge.displayName.lowercased()) edge. "
                + "Parked windows can be clamped to the Dock boundary and leave a visible strip."
        case let .horizontalDisplayArrangement(firstName, secondName, _, _):
            "\(firstName) and \(secondName) overlap vertically in the display arrangement. "
                + "Horizontally parked windows can bleed onto the neighboring display."
        case let .unknownConfigKeys(keyPaths):
            "settings.toml contains keys OmniWM does not recognize: \(keyPaths.joined(separator: ", ")). "
                + "They are ignored."
        case .settingsFileCorrupt:
            "OmniWM preserved settings data it could not parse as settings.toml.corrupt "
                + "or settings.toml.corrupt.1."
        case let .settingsMigrated(report, backupURL):
            "OmniWM upgraded \(configPath) from schema version \(report.fromVersion) to \(report.toVersion). "
                + "The exact original bytes were preserved at \(backupURL.path). "
                + report.messages.joined(separator: " ")
        case let .settingsRecovered(reason, backupURL):
            "OmniWM could not decode \(configPath): \(reason) The exact rejected bytes were preserved at \(backupURL.path)."
        case let .settingsPersistenceBlocked(reason, backupURL):
            "OmniWM left \(configPath) untouched and blocked configuration writes: \(reason)"
                + (backupURL.map { " The exact original bytes are at \($0.path)." } ?? "")
        case let .settingsInvalidRejected(reason):
            "OmniWM could not decode \(configPath) and left the file untouched: \(reason) The active settings were not changed."
        }
    }

    var remediation: String {
        switch kind {
        case .accessibilityNotGranted:
            "Open System Settings → Privacy & Security → Accessibility and enable OmniWM."
        case let .hotkeyRegistration(_, reason):
            switch reason {
            case .duplicateBinding: "Assign a unique chord to one of the commands in Hotkeys."
            case .systemReserved: "Reassign this command to a free chord in Hotkeys."
            case .requiresInputMonitoring: "Grant Input Monitoring in System Settings, or reassign the chord."
            }
        case .hotkeyCoFireAdvisory:
            "Reassign this command in Hotkeys, or clear the conflicting shortcut in System Settings → Keyboard."
        case .hotkeySidedHyper:
            "In Hotkeys, set this shortcut's modifier side to “Either”, or re-record it without a side restriction. "
                + "A single Hyper key emits generic modifier flags, so a left- or right-restricted binding cannot match it."
        case .fixedDock:
            "Enable Dock auto-hide in System Settings → Desktop & Dock, or move the Dock off the parking edge."
        case .horizontalDisplayArrangement:
            "Arrange displays vertically or diagonally in System Settings → Displays so frames do not overlap."
        case .unknownConfigKeys:
            "Remove or fix the keys in \(configPath)."
        case .settingsFileCorrupt:
            "Inspect \(configDirectoryPath)/settings.toml.corrupt and "
                + "\(configDirectoryPath)/settings.toml.corrupt.1 if present, "
                + "then delete the recovery files to dismiss this notice."
        case let .settingsMigrated(_, backupURL):
            "Verify the upgraded settings, then keep the backup or delete \(backupURL.path) to dismiss this notice."
        case let .settingsRecovered(_, backupURL):
            "Compare \(backupURL.path) with \(configPath), restore valid values, and then remove the recovery file."
        case .settingsPersistenceBlocked:
            "Resolve the reported schema or backup problem at \(configPath), then reload or restart OmniWM."
        case .settingsInvalidRejected:
            "Correct the reported value at \(configPath); OmniWM applies the file once it decodes. Saving from the Settings window first secures the rejected bytes as a recovery file."
        }
    }

    var systemSettingsURLString: String? {
        switch kind {
        case .accessibilityNotGranted:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .fixedDock:
            "x-apple.systempreferences:com.apple.preference.dock"
        case .horizontalDisplayArrangement:
            "x-apple.systempreferences:com.apple.preference.displays"
        case .hotkeyRegistration,
             .hotkeyCoFireAdvisory:
            "x-apple.systempreferences:com.apple.preference.keyboard"
        case .hotkeySidedHyper,
             .unknownConfigKeys,
             .settingsFileCorrupt,
             .settingsMigrated,
             .settingsRecovered,
             .settingsPersistenceBlocked,
             .settingsInvalidRejected:
            nil
        }
    }

    var revealsConfigFolder: Bool {
        switch kind {
        case .unknownConfigKeys,
             .settingsFileCorrupt,
             .settingsMigrated,
             .settingsRecovered,
             .settingsPersistenceBlocked,
             .settingsInvalidRejected:
            true
        default:
            false
        }
    }

    private var configPath: String {
        (configFileURL ?? SettingsFilePersistence.fileURL).path
    }

    private var configDirectoryPath: String {
        (configFileURL ?? SettingsFilePersistence.fileURL).deletingLastPathComponent().path
    }
}
