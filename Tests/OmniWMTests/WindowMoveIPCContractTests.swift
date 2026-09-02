// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class WindowMoveIPCContractTests: XCTestCase {
    private enum TestFailure: Error {
        case unexpectedPayload
    }

    func testMoveWireShapeIncludesWorkspaceTarget() throws {
        let request = IPCWindowRequest(name: .moveToWorkspace, windowId: "ow_x", workspaceTarget: .rawID("3"))
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["workspaceTarget"] as? [String: String])

        XCTAssertEqual(object["name"] as? String, "move-to-workspace")
        XCTAssertEqual(object["windowId"] as? String, "ow_x")
        XCTAssertEqual(target, ["kind": "raw-id", "value": "3"])
        XCTAssertEqual(try JSONDecoder().decode(IPCWindowRequest.self, from: data), request)
    }

    func testFocusWireShapeHasNoWorkspaceTargetKey() throws {
        let request = IPCWindowRequest(name: .focus, windowId: "ow_x")
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["name"] as? String, "focus")
        XCTAssertNil(object["workspaceTarget"])
        XCTAssertEqual(try JSONDecoder().decode(IPCWindowRequest.self, from: data), request)
    }

    func testMoveDecodeRequiresWorkspaceTarget() {
        let data = Data(#"{"name":"move-to-workspace","windowId":"ow_x"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(IPCWindowRequest.self, from: data))
    }

    func testNonMoveDecodeRejectsWorkspaceTarget() {
        let data = Data(
            #"{"name":"focus","windowId":"ow_x","workspaceTarget":{"kind":"raw-id","value":"3"}}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(IPCWindowRequest.self, from: data))
    }

    func testManifestDescribesWindowMove() throws {
        let descriptor = try XCTUnwrap(
            IPCAutomationManifest.windowActionDescriptors.first { $0.name == .moveToWorkspace }
        )

        XCTAssertEqual(descriptor.path, "window move-to-workspace <opaque-id> <workspace>")
        XCTAssertEqual(descriptor.arguments, ["opaque-id", "workspace"])
    }

    func testParserBuildsWindowMove() throws {
        XCTAssertEqual(
            try parseWindowRequest(["window", "move-to-workspace", "ow_x", "3"]),
            IPCWindowRequest(name: .moveToWorkspace, windowId: "ow_x", workspaceTarget: .rawID("3"))
        )
        XCTAssertEqual(
            try parseWindowRequest(["window", "move-to-workspace", "ow_x", "Slack"]),
            IPCWindowRequest(name: .moveToWorkspace, windowId: "ow_x", workspaceTarget: .displayName("Slack"))
        )
        XCTAssertEqual(
            try parseWindowRequest(["window", "focus", "ow_x"]),
            IPCWindowRequest(name: .focus, windowId: "ow_x")
        )
    }

    func testParserRejectsMalformedWindowMoves() {
        let invocations = [
            ["window", "move-to-workspace", "ow_x"],
            ["window", "move-to-workspace", "ow_x", "3", "extra"],
            ["window", "focus", "ow_x", "3"],
            ["window", "teleport", "ow_x"]
        ]

        for invocation in invocations {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + invocation)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testHelpAndCompletionsExposeWindowMove() {
        XCTAssertTrue(CLIParser.usageText.contains("omniwmctl window move-to-workspace <opaque-id> <workspace>"))

        for shell in CLIShell.allCases {
            XCTAssertTrue(CLICompletionGenerator.script(for: shell).contains("move-to-workspace"))
        }
    }

    private func parseWindowRequest(_ arguments: [String]) throws -> IPCWindowRequest {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + arguments)
        guard case let .window(request) = parsed.request.payload else {
            throw TestFailure.unexpectedPayload
        }
        return request
    }
}
