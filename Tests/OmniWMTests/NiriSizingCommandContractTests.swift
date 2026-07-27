// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class NiriSizingCommandContractTests: XCTestCase {
    func testNewSizingActionsExposeAxisRelativeContracts() throws {
        let cycle = try XCTUnwrap(ActionCatalog.spec(for: .cycleSizeForward))
        XCTAssertEqual(cycle.id, "cycleSizeForward")
        XCTAssertEqual(cycle.layoutCompatibility, .shared)
        XCTAssertEqual(cycle.category, .layout)
        XCTAssertEqual(cycle.ipcCommandName, .cycleSizeForward)

        let primary = try XCTUnwrap(
            ActionCatalog.spec(for: .setContainerPrimarySpan(.adjustProportion(10)))
        )
        XCTAssertEqual(primary.id, "setContainerPrimarySpan.increase10Percent")
        XCTAssertEqual(primary.layoutCompatibility, .niri)
        XCTAssertEqual(primary.ipcCommandName, .setContainerPrimarySpan)

        let secondary = try XCTUnwrap(ActionCatalog.spec(for: .resetWindowSecondarySpan))
        XCTAssertEqual(secondary.id, "resetWindowSecondarySpan")
        XCTAssertEqual(secondary.layoutCompatibility, .niri)
        XCTAssertEqual(secondary.ipcCommandName, .resetWindowSecondarySpan)
    }

    func testRemovedSizingActionIDsAreAbsent() {
        let removedIDs = [
            "cycleColumnWidthForward",
            "cycleColumnWidthBackward",
            "cycleWindowWidthForward",
            "cycleWindowWidthBackward",
            "cycleWindowHeightForward",
            "cycleWindowHeightBackward",
            "toggleColumnFullWidth",
            "expandColumnToAvailableWidth",
            "resetWindowHeight",
            "setColumnWidth.decrease10Percent",
            "setColumnWidth.increase10Percent",
            "setWindowWidth.decrease10Percent",
            "setWindowWidth.increase10Percent",
            "setWindowHeight.decrease10Percent",
            "setWindowHeight.increase10Percent"
        ]

        for id in removedIDs {
            XCTAssertNil(ActionCatalog.spec(for: id))
        }
    }

    func testSizingManifestUsesNewPathsAndCompatibility() throws {
        let cycle = try XCTUnwrap(
            IPCAutomationManifest.commandDescriptors(matching: ["cycle-size", "forward"]).first
        )
        XCTAssertEqual(cycle.name, .cycleSizeForward)
        XCTAssertEqual(cycle.path, "command cycle-size forward")
        XCTAssertEqual(cycle.layoutCompatibility, .shared)

        let setPrimary = try XCTUnwrap(
            IPCAutomationManifest.commandDescriptor(for: .setContainerPrimarySpan)
        )
        XCTAssertEqual(setPrimary.commandWords, ["set-container-primary-span"])
        XCTAssertEqual(setPrimary.arguments.map(\.kind), [.sizeChange])
        XCTAssertEqual(setPrimary.layoutCompatibility, .niri)
    }

    func testSizingRequestsRoundTripWithNewWireNames() throws {
        let requests: [(IPCCommandRequest, String)] = [
            (.cycleSizeForward, "cycle-size-forward"),
            (.cycleWindowPrimarySpanBackward, "cycle-window-primary-span-backward"),
            (.cycleWindowSecondarySpanForward, "cycle-window-secondary-span-forward"),
            (.toggleContainerFullPrimarySpan, "toggle-container-full-primary-span"),
            (.expandContainerToAvailablePrimarySpan, "expand-container-to-available-primary-span"),
            (.resetWindowSecondarySpan, "reset-window-secondary-span"),
            (.setContainerPrimarySpan(change: .setProportion(50)), "set-container-primary-span"),
            (.setWindowPrimarySpan(change: .adjustFixed(10)), "set-window-primary-span"),
            (.setWindowSecondarySpan(change: .adjustProportion(-10)), "set-window-secondary-span")
        ]

        for (request, expectedName) in requests {
            let data = try JSONEncoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["name"] as? String, expectedName)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request)
        }
    }

    func testRemovedSizingWireNamesDoNotDecode() {
        let removedNames = [
            "cycle-column-width-forward",
            "cycle-column-width-backward",
            "cycle-window-width-forward",
            "cycle-window-width-backward",
            "cycle-window-height-forward",
            "cycle-window-height-backward",
            "toggle-column-full-width",
            "expand-column-to-available-width",
            "reset-window-height",
            "set-column-width",
            "set-window-width",
            "set-window-height"
        ]

        for rawValue in removedNames {
            XCTAssertNil(IPCCommandName(rawValue: rawValue))
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    IPCCommandRequest.self,
                    from: Data(#"{"name":"\#(rawValue)"}"#.utf8)
                )
            )
        }
    }

    func testNiriSizingSettingsRoundTripOnlyNewKeys() throws {
        var export = SettingsExport.defaults()
        export.niriVisibleContainerCount = 4
        export.niriContainerPrimarySpanPresets = [0.25, 0.5, 0.75]
        export.niriDefaultContainerPrimarySpan = 0.5

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("visibleContainerCount = 4"))
        XCTAssertTrue(toml.contains("containerPrimarySpanPresets = [0.25, 0.5, 0.75]"))
        XCTAssertTrue(toml.contains("defaultContainerPrimarySpan = 0.5"))
        XCTAssertFalse(toml.contains("maxVisibleColumns"))
        XCTAssertFalse(toml.contains("columnWidthPresets"))
        XCTAssertFalse(toml.contains("defaultColumnWidth"))
        XCTAssertEqual(decoded.niriVisibleContainerCount, 4)
        XCTAssertEqual(decoded.niriContainerPrimarySpanPresets, [0.25, 0.5, 0.75])
        XCTAssertEqual(decoded.niriDefaultContainerPrimarySpan, 0.5)
    }

    func testCurrentProtocolVersion() {
        XCTAssertEqual(OmniWMIPCProtocol.version, 9)
    }
}
