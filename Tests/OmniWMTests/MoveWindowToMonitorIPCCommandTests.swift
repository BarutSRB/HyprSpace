// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class MoveWindowToMonitorIPCCommandTests: XCTestCase {
    private let directions: [IPCDirection] = [.left, .right, .up, .down]

    func testDirectionalRequestsExposeCanonicalWireContract() throws {
        for direction in directions {
            let request = IPCCommandRequest.moveToMonitor(direction: direction)

            XCTAssertEqual(request.name, .moveToMonitor)
            XCTAssertEqual(
                try IPCCommandRequest(
                    name: .moveToMonitor,
                    argumentValues: [.direction(direction)]
                ),
                request
            )

            let data = try JSONEncoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let arguments = try XCTUnwrap(object["arguments"] as? [String: String])

            XCTAssertEqual(object["name"] as? String, "move-to-monitor")
            XCTAssertEqual(arguments, ["direction": direction.rawValue])
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request)
        }
    }

    func testRequestConstructionRejectsInvalidArguments() {
        XCTAssertThrowsError(try IPCCommandRequest(name: .moveToMonitor))
        XCTAssertThrowsError(
            try IPCCommandRequest(
                name: .moveToMonitor,
                argumentValues: [.integer(1)]
            )
        )
        XCTAssertThrowsError(
            try IPCCommandRequest(
                name: .moveToMonitor,
                argumentValues: [.direction(.left), .direction(.right)]
            )
        )
    }

    func testManifestDescribesDirectionalMonitorMove() throws {
        let descriptor = try XCTUnwrap(
            IPCAutomationManifest.commandDescriptor(for: .moveToMonitor)
        )

        XCTAssertEqual(descriptor.commandWords, ["move-to-monitor"])
        XCTAssertEqual(descriptor.path, "command move-to-monitor <left|right|up|down>")
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.direction])
        XCTAssertEqual(descriptor.layoutCompatibility, .shared)
        XCTAssertTrue(descriptor.summary.contains("active workspace"))
        XCTAssertEqual(
            IPCAutomationManifest.commandDescriptors(matching: ["move-to-monitor", "right"]).first?.name,
            .moveToMonitor
        )
    }

    func testCLIParserBuildsDirectionalMonitorMoveRequests() throws {
        for direction in directions {
            let parsed = try CLIParser.parse(
                arguments: ["omniwmctl", "command", "move-to-monitor", direction.rawValue]
            )
            guard case let .command(request) = parsed.request.payload else {
                return XCTFail("Expected command request")
            }

            XCTAssertEqual(request, .moveToMonitor(direction: direction))
        }
    }

    func testCLIRejectsMissingOrInvalidDirection() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: ["omniwmctl", "command", "move-to-monitor"])
        )
        XCTAssertThrowsError(
            try CLIParser.parse(
                arguments: ["omniwmctl", "command", "move-to-monitor", "diagonal"]
            )
        )
    }

    func testHelpAndCompletionsExposeMonitorMove() {
        XCTAssertTrue(
            CLIParser.usageText.contains(
                "omniwmctl command move-to-monitor <left|right|up|down>"
            )
        )

        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            switch shell {
            case .zsh,
                 .bash:
                XCTAssertTrue(script.contains("\"move-to-monitor\")"))
                XCTAssertTrue(script.contains("suggestions=\"down left right up\""))
            case .fish:
                XCTAssertTrue(
                    script.contains(
                        "__fish_seen_subcommand_from command; and __fish_seen_subcommand_from move-to-monitor"
                    )
                )
            }
        }
    }

    @MainActor
    func testRouterReturnsNotFoundWithoutFocusedWindow() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMMoveToMonitorIPCTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
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
        let controller = WMController(settings: settings)
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.moveToMonitor(direction: .right)), .notFound)
    }
}
