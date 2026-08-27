// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class ScratchpadCommandTests: XCTestCase {
    func testEverySlotRegistersBothActions() throws {
        for slot in ScratchpadIndex.range {
            let toggle = try XCTUnwrap(ActionCatalog.spec(for: .toggleScratchpad(slot)))
            XCTAssertEqual(toggle.id, "toggleScratchpad.\(slot)")
            XCTAssertEqual(toggle.title, "Toggle Scratchpad \(slot)")
            XCTAssertEqual(toggle.layoutCompatibility, .shared)
            XCTAssertEqual(toggle.defaultBinding, .unassigned)
            XCTAssertEqual(toggle.ipcCommandName, .scratchpadToggle)
            XCTAssertNotNil(toggle.ipcDescriptor)

            let assign = try XCTUnwrap(ActionCatalog.spec(for: .assignFocusedWindowToScratchpad(slot)))
            XCTAssertEqual(assign.id, "assignFocusedWindowToScratchpad.\(slot)")
            XCTAssertEqual(assign.title, "Assign Focused Window to Scratchpad \(slot)")
            XCTAssertEqual(assign.ipcCommandName, .scratchpadAssign)
        }
    }

    func testActionSpecIDsUnique() {
        let ids = ActionCatalog.allSpecs().map(\.id)

        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testCommandNameMapping() {
        XCTAssertEqual(IPCCommandRequest.scratchpadAssign(index: 4).name, .scratchpadAssign)
        XCTAssertEqual(IPCCommandRequest.scratchpadToggle(index: 4).name, .scratchpadToggle)
    }

    func testCommandJSONRoundTripCarriesIndex() throws {
        for request in [IPCCommandRequest.scratchpadAssign(index: 2), .scratchpadToggle(index: 10)] {
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request)
        }
    }

    func testManifestResolvesIndexArgument() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["scratchpad", "toggle"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .scratchpadToggle })

        XCTAssertEqual(descriptor.commandWords, ["scratchpad", "toggle"])
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.scratchpadIndex])
        XCTAssertEqual(
            try IPCCommandRequest(name: descriptor.name, argumentValues: [.integer(3)]),
            .scratchpadToggle(index: 3)
        )
        XCTAssertThrowsError(try IPCCommandRequest(name: descriptor.name, argumentValues: []))
    }

    func testCLIParsesSlotAndRejectsOutOfRange() throws {
        let parsed = try CLIParser.parse(
            arguments: ["omniwmctl", "command", "scratchpad", "toggle", "7"]
        )
        guard case let .command(request) = parsed.request.payload else {
            return XCTFail("expected a command payload")
        }
        XCTAssertEqual(request, .scratchpadToggle(index: 7))

        XCTAssertThrowsError(
            try CLIParser.parse(arguments: ["omniwmctl", "command", "scratchpad", "toggle", "11"])
        )
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: ["omniwmctl", "command", "scratchpad", "assign", "0"])
        )
    }

    @MainActor
    func testRouterRejectsOutOfRangeSlot() {
        let controller = WMController(settings: makeSettingsStore())
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.scratchpadToggle(index: 11)), .invalidArguments)
        XCTAssertEqual(router.handle(.scratchpadAssign(index: 0)), .invalidArguments)
    }

    @MainActor
    func testRouterReportsEmptySlotAsNotFound() {
        let controller = WMController(settings: makeSettingsStore())
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.scratchpadToggle(index: 1)), .notFound)
    }

    func testLabelsRoundTripThroughTOML() throws {
        XCTAssertTrue(SettingsExport.defaults().scratchpadLabels.isEmpty)

        var export = SettingsExport.defaults()
        export.scratchpadLabels = ["3": "COMMS"]
        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("COMMS"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).scratchpadLabels, ["3": "COMMS"])
    }

    @MainActor
    func testLabelNormalizationDropsUnusableEntries() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()
        export.scratchpadLabels = ["1": " term ", "0": "low", "11": "high", "4": "   "]

        settings.applyExport(export)

        XCTAssertEqual(settings.scratchpadLabels, ["1": "term"])
        XCTAssertEqual(settings.scratchpadLabel(for: 1), "term")
        XCTAssertNil(settings.scratchpadLabel(for: 4))
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMScratchpadCommandTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
