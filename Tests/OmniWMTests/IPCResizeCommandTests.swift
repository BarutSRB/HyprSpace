// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class IPCResizeCommandTests: XCTestCase {
    private let axes: [IPCResizeAxis] = [.horizontal, .vertical]
    private let operations: [IPCResizeOperation] = [.grow, .shrink]

    func testRequestsExposeAxisAndOperationWireContract() throws {
        for axis in axes {
            for operation in operations {
                let request = IPCCommandRequest.resize(axis: axis, operation: operation)

                XCTAssertEqual(request.name, .resize)
                XCTAssertEqual(
                    try IPCCommandRequest(
                        name: .resize,
                        argumentValues: [.resizeAxis(axis), .resizeOperation(operation)]
                    ),
                    request
                )

                let data = try JSONEncoder().encode(request)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let arguments = try XCTUnwrap(object["arguments"] as? [String: String])

                XCTAssertEqual(object["name"] as? String, "resize")
                XCTAssertEqual(arguments, ["axis": axis.rawValue, "operation": operation.rawValue])
                XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request)
            }
        }
    }

    func testRequestConstructionRejectsInvalidArguments() {
        let invalidArguments: [[IPCCommandArgumentValue]] = [
            [],
            [.resizeAxis(.horizontal)],
            [.resizeOperation(.grow)],
            [.direction(.left), .resizeOperation(.grow)],
            [.resizeOperation(.grow), .resizeAxis(.horizontal)],
            [.resizeAxis(.horizontal), .resizeOperation(.grow), .resizeOperation(.shrink)]
        ]

        for argumentValues in invalidArguments {
            XCTAssertThrowsError(
                try IPCCommandRequest(name: .resize, argumentValues: argumentValues)
            )
        }
    }

    func testLegacyDirectionalWireShapeDoesNotDecode() {
        let data = Data(
            #"{"name":"resize","arguments":{"direction":"left","operation":"grow"}}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(IPCCommandRequest.self, from: data))
    }

    func testManifestDescribesAxisResizeContract() throws {
        let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: .resize))

        XCTAssertEqual(descriptor.commandWords, ["resize"])
        XCTAssertEqual(descriptor.path, "command resize <horizontal|vertical> <grow|shrink>")
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.resizeAxis, .resizeOperation])
        XCTAssertEqual(descriptor.layoutCompatibility, .dwindle)
        XCTAssertEqual(
            IPCAutomationManifest.commandDescriptors(matching: ["resize", "horizontal", "grow"]).first?.name,
            .resize
        )
        XCTAssertEqual(
            IPCAutomationManifest.commandDescriptors(matching: ["resize", "vertical", "shrink"]).first?.name,
            .resize
        )
    }

    func testCLIParserBuildsEveryAxisResizeRequest() throws {
        for axis in axes {
            for operation in operations {
                let parsed = try CLIParser.parse(
                    arguments: ["omniwmctl", "command", "resize", axis.rawValue, operation.rawValue]
                )
                guard case let .command(request) = parsed.request.payload else {
                    return XCTFail("Expected command request")
                }

                XCTAssertEqual(parsed.request.version, 15)
                XCTAssertEqual(request, .resize(axis: axis, operation: operation))
            }
        }
    }

    func testCLIRejectsDirectionalAndMalformedResizeArguments() {
        let invalidArguments = [
            ["resize"],
            ["resize", "horizontal"],
            ["resize", "left", "grow"],
            ["resize", "right", "shrink"],
            ["resize", "up", "grow"],
            ["resize", "down", "shrink"],
            ["resize", "horizontal", "larger"],
            ["resize", "diagonal", "grow"],
            ["resize", "vertical", "shrink", "extra"]
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(
                try CLIParser.parse(arguments: ["omniwmctl", "command"] + arguments)
            )
        }
    }

    func testHelpAndCompletionsExposeBothAxesAndOperations() {
        XCTAssertTrue(
            CLIParser.usageText.contains(
                "omniwmctl command resize <horizontal|vertical> <grow|shrink>"
            )
        )

        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            XCTAssertTrue(script.contains("horizontal"), shell.rawValue)
            XCTAssertTrue(script.contains("vertical"), shell.rawValue)
            XCTAssertTrue(script.contains("grow"), shell.rawValue)
            XCTAssertTrue(script.contains("shrink"), shell.rawValue)
        }
    }
}
