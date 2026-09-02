// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class WorkspaceSlotIPCCommandTests: XCTestCase {
    func testSlotRequestsRoundTripThroughJSONAndManifest() throws {
        let cases: [(request: IPCCommandRequest, name: IPCCommandName, words: [String], slot: Int)] = [
            (.switchWorkspaceSlot(slotNumber: 2), .switchWorkspaceSlot, ["switch-workspace", "slot"], 2),
            (.moveToWorkspaceSlot(slotNumber: 3), .moveToWorkspaceSlot, ["move-to-workspace", "slot"], 3)
        ]

        for entry in cases {
            XCTAssertEqual(entry.request.name, entry.name)
            let data = try JSONEncoder().encode(entry.request)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), entry.request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((json["arguments"] as? [String: Any])?["slotNumber"] as? Int, entry.slot)

            let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: entry.name))
            XCTAssertEqual(descriptor.commandWords, entry.words)
            XCTAssertEqual(descriptor.arguments.map(\.kind), [.workspaceNumber])
            XCTAssertEqual(descriptor.layoutCompatibility, .shared)
            XCTAssertEqual(
                try IPCCommandRequest(name: entry.name, argumentValues: [.integer(entry.slot)]),
                entry.request
            )
        }
    }

    func testParserBuildsSlotRequestsAndKeepsNumericForms() throws {
        XCTAssertEqual(
            try commandPayload(["switch-workspace", "slot", "2"]),
            .switchWorkspaceSlot(slotNumber: 2)
        )
        XCTAssertEqual(
            try commandPayload(["move-to-workspace", "slot", "3"]),
            .moveToWorkspaceSlot(slotNumber: 3)
        )
        XCTAssertEqual(try commandPayload(["switch-workspace", "2"]), .switchWorkspace(workspaceNumber: 2))
        XCTAssertEqual(try commandPayload(["move-to-workspace", "3"]), .moveToWorkspace(workspaceNumber: 3))

        for malformed in [
            ["switch-workspace", "slot"],
            ["switch-workspace", "slot", "0"],
            ["move-to-workspace", "slot", "x"],
            ["move-to-workspace", "slot", "2", "3"]
        ] {
            XCTAssertThrowsError(try commandPayload(malformed), malformed.joined(separator: " "))
        }
    }

    func testHelpAndCompletionsExposeSlotCommands() {
        XCTAssertTrue(CLIParser.usageText.contains("switch-workspace slot <number>"))
        XCTAssertTrue(CLIParser.usageText.contains("move-to-workspace slot <number>"))
        for shell in CLIShell.allCases {
            XCTAssertTrue(CLICompletionGenerator.script(for: shell).contains("slot"), shell.rawValue)
        }
    }

    private func commandPayload(_ words: [String]) throws -> IPCCommandRequest {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command"] + words)
        guard case let .command(request) = parsed.request.payload else {
            throw CLIParseError.usage("expected a command payload")
        }
        return request
    }
}
