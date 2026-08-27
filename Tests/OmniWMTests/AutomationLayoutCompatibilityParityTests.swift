// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

final class AutomationLayoutCompatibilityParityTests: XCTestCase {
    func testManifestLayoutCompatibilityMatchesActionCatalog() {
        var compatibilitiesByCommand: [IPCCommandName: Set<IPCAutomationLayoutCompatibility>] = [:]
        for spec in ActionCatalog.allSpecs() {
            guard let name = spec.ipcCommandName else { continue }
            compatibilitiesByCommand[name, default: []]
                .insert(Self.automationCompatibility(for: spec.layoutCompatibility))
        }
        let commandsWithOneEnforcedCompatibility = compatibilitiesByCommand
            .compactMapValues { $0.count == 1 ? $0.first : nil }

        let mismatches = commandsWithOneEnforcedCompatibility.compactMap { name, enforced -> String? in
            guard let descriptor = IPCAutomationManifest.commandDescriptor(for: name),
                  descriptor.layoutCompatibility != enforced
            else { return nil }
            return "\(descriptor.path): manifest=\(descriptor.layoutCompatibility.rawValue), enforced=\(enforced.rawValue)"
        }.sorted()

        XCTAssertEqual(
            mismatches,
            [],
            "IPCAutomationManifest advertises a layout compatibility that CommandHandler does not enforce. "
                + "ActionCatalog is the runtime authority, so update the manifest to match it. Commands whose "
                + "enforced compatibility varies by argument, such as move-column, are exempt because one "
                + "descriptor cannot express more than one value."
        )
    }

    func testMoveColumnCompatibilityStillVariesByDirection() {
        XCTAssertEqual(ActionCatalog.layoutCompatibility(for: .moveColumn(.left)), .shared)
        XCTAssertEqual(ActionCatalog.layoutCompatibility(for: .moveColumn(.right)), .shared)
        XCTAssertEqual(ActionCatalog.layoutCompatibility(for: .moveColumn(.up)), .dwindle)
        XCTAssertEqual(ActionCatalog.layoutCompatibility(for: .moveColumn(.down)), .dwindle)
        XCTAssertEqual(
            IPCAutomationManifest.commandDescriptor(for: .moveColumn)?.layoutCompatibility,
            .shared
        )
    }

    private static func automationCompatibility(
        for compatibility: LayoutCompatibility
    ) -> IPCAutomationLayoutCompatibility {
        switch compatibility {
        case .shared: .shared
        case .niri: .niri
        case .dwindle: .dwindle
        }
    }
}
