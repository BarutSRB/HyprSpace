// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class WorkspaceMoveIPCContractTests: XCTestCase {
    func testFocusNameWireShapeIsPreserved() throws {
        let request = IPCWorkspaceRequest.focusName(target: .displayName("S"))
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["workspaceTarget"] as? [String: String])

        XCTAssertEqual(object["name"] as? String, "focus-name")
        XCTAssertEqual(target, ["kind": "display-name", "value": "S"])
        XCTAssertNil(object["direction"])
        XCTAssertNil(object["force"])
        XCTAssertEqual(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data), request)
    }

    func testMoveWireShapeIncludesDirectionAndDefaultForce() throws {
        let request = IPCWorkspaceRequest.moveToMonitor(target: .displayName("S"), direction: .right)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["workspaceTarget"] as? [String: String])

        XCTAssertEqual(object["name"] as? String, "move-to-monitor")
        XCTAssertEqual(target, ["kind": "display-name", "value": "S"])
        XCTAssertEqual(object["direction"] as? String, "right")
        XCTAssertEqual(object["force"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data), request)
    }

    func testMoveDecodeDefaultsMissingForceToFalse() throws {
        let data = Data(
            """
            {
              "name": "move-to-monitor",
              "workspaceTarget": {"kind": "raw-id", "value": "12"},
              "direction": "left"
            }
            """.utf8
        )

        XCTAssertEqual(
            try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data),
            .moveToMonitor(target: .rawID("12"), direction: .left, force: false)
        )
    }

    func testMoveWireRoundTripPreservesExplicitForce() throws {
        let request = IPCWorkspaceRequest.moveToMonitor(
            target: .rawID("12"),
            direction: .up,
            force: true
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["workspaceTarget"] as? [String: String])

        XCTAssertEqual(object["name"] as? String, "move-to-monitor")
        XCTAssertEqual(target, ["kind": "raw-id", "value": "12"])
        XCTAssertEqual(object["direction"] as? String, "up")
        XCTAssertEqual(object["force"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data), request)
    }

    func testManifestDescribesWorkspaceMove() throws {
        let descriptor = try XCTUnwrap(
            IPCAutomationManifest.workspaceActionDescriptors.first { $0.name == .moveToMonitor }
        )

        XCTAssertEqual(descriptor.actionWords, ["move-to-monitor"])
        XCTAssertEqual(
            descriptor.path,
            "workspace move-to-monitor <workspace> <left|right|up|down> [--force]"
        )
        XCTAssertEqual(descriptor.arguments, ["workspace", "left|right|up|down"])
        XCTAssertEqual(descriptor.optionalFlags, ["--force"])
    }

    func testParserBuildsNamedWorkspaceMove() throws {
        XCTAssertEqual(
            try parseWorkspaceRequest(["workspace", "move-to-monitor", "S", "right"]),
            .moveToMonitor(target: .displayName("S"), direction: .right, force: false)
        )
        XCTAssertEqual(
            try parseWorkspaceRequest(["workspace", "move-to-monitor", "12", "left"]),
            .moveToMonitor(target: .rawID("12"), direction: .left, force: false)
        )
    }

    func testParserAcceptsForceAnywhereOnce() throws {
        let invocations = [
            ["workspace", "move-to-monitor", "--force", "S", "right"],
            ["workspace", "move-to-monitor", "S", "--force", "right"],
            ["workspace", "move-to-monitor", "S", "right", "--force"]
        ]

        for invocation in invocations {
            XCTAssertEqual(
                try parseWorkspaceRequest(invocation),
                .moveToMonitor(target: .displayName("S"), direction: .right, force: true)
            )
        }
    }

    func testParserRejectsMalformedWorkspaceMoves() {
        let invocations = [
            ["workspace", "move-to-monitor", "S"],
            ["workspace", "move-to-monitor", "S", "diagonal"],
            ["workspace", "move-to-monitor", "S", "right", "--force", "--force"],
            ["workspace", "move-to-monitor", "S", "right", "--unknown"],
            ["workspace", "move-to-monitor", "S", "right", "extra"]
        ]

        for invocation in invocations {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + invocation)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testHelpAndCompletionsExposeWorkspaceMoveContract() {
        XCTAssertTrue(
            CLIParser.usageText.contains(
                "omniwmctl workspace move-to-monitor <workspace> <left|right|up|down> [--force]"
            )
        )

        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            XCTAssertTrue(script.contains("move-to-monitor"))
            XCTAssertTrue(script.contains("--force"))
            XCTAssertTrue(script.contains("left"))
            XCTAssertTrue(script.contains("right"))
            XCTAssertTrue(script.contains("up"))
            XCTAssertTrue(script.contains("down"))
        }
    }

    func testWorkspaceMoveCompletionsTrackNonFlagPositionals() throws {
        for shell in [CLIShell.zsh, .bash] {
            for completionCase in workspaceMoveCompletionCases {
                XCTAssertEqual(
                    Set(try workspaceMoveCompletions(
                        shell: shell,
                        arguments: completionCase.arguments
                    )),
                    completionCase.expected,
                    "\(shell.rawValue): \(completionCase.arguments)"
                )
            }
        }
    }

    func testFishWorkspaceMoveCompletionsTrackNonFlagPositionals() throws {
        guard fishExecutablePath() != nil else {
            throw XCTSkip("Fish is not installed")
        }

        for completionCase in workspaceMoveCompletionCases {
            XCTAssertEqual(
                Set(try workspaceMoveCompletions(
                    shell: .fish,
                    arguments: completionCase.arguments
                )),
                completionCase.expected,
                "fish: \(completionCase.arguments)"
            )
        }
    }

    func testWorkspaceAssignmentConflictRendering() throws {
        let response = IPCResponse.failure(
            id: "move",
            kind: .workspace,
            code: .workspaceAssignmentConflict
        )
        let output = try CLIRenderer.responseOutput(response, format: .text)

        XCTAssertEqual(CLIRenderer.exitCode(for: response), .rejected)
        XCTAssertEqual(output.destination, .standardOutput)
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "error: workspace_assignment_conflict\n")
    }

    func testWorkspaceStateConflictRendering() throws {
        let response = IPCResponse.failure(
            id: "move",
            kind: .workspace,
            code: .workspaceStateConflict
        )
        let output = try CLIRenderer.responseOutput(response, format: .text)

        XCTAssertEqual(CLIRenderer.exitCode(for: response), .rejected)
        XCTAssertEqual(output.destination, .standardOutput)
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "error: workspace_state_conflict\n")
    }

    private func parseWorkspaceRequest(_ arguments: [String]) throws -> IPCWorkspaceRequest {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + arguments)
        guard case let .workspace(request) = parsed.request.payload else {
            throw TestFailure.unexpectedPayload
        }
        return request
    }

    private func workspaceMoveCompletions(shell: CLIShell, arguments: String) throws -> [String] {
        let argumentCount = arguments.split(separator: " ").count
        let words = "omniwmctl workspace move-to-monitor \(arguments) ''"
        let generatedScript = CLICompletionGenerator.script(for: shell)
        let script: String
        let executable: String

        switch shell {
        case .zsh:
            executable = "/bin/zsh"
            script = """
            function compadd {
              if [[ "$1" == "--" ]]; then
                shift
              fi
              print -rl -- "$@"
            }
            words=(\(words))
            CURRENT=\(argumentCount + 4)
            \(generatedScript)
            true
            """
        case .bash:
            executable = "/bin/bash"
            script = """
            \(generatedScript)
            COMP_WORDS=(\(words))
            COMP_CWORD=\(argumentCount + 3)
            _omniwmctl
            printf '%s\\n' "${COMPREPLY[@]}"
            """
        case .fish:
            guard let fishExecutable = fishExecutablePath() else {
                throw XCTSkip("Fish is not installed")
            }
            executable = fishExecutable
            script = """
            \(generatedScript)
            complete -C "omniwmctl workspace move-to-monitor \(arguments) "
            """
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", script]
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw TestFailure.shellFailure(
                process.terminationStatus,
                String(decoding: error, as: UTF8.self)
            )
        }

        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                line.split(separator: "\t", maxSplits: 1).first.map(String.init)
            }
    }

    private var workspaceMoveCompletionCases: [(arguments: String, expected: Set<String>)] {
        [
            ("", ["--force"]),
            ("S", ["left", "right", "up", "down", "--force"]),
            ("--format json", ["--force"]),
            ("--format json S", ["left", "right", "up", "down", "--force"]),
            ("S --format table", ["left", "right", "up", "down", "--force"]),
            ("S --format tsv right", ["--force"]),
            ("S right --format text", ["--force"]),
            ("--json S", ["left", "right", "up", "down", "--force"]),
            ("S --json", ["left", "right", "up", "down", "--force"]),
            ("S --json right", ["--force"]),
            ("S right --json", ["--force"]),
            ("--force S", ["left", "right", "up", "down"]),
            ("S --force", ["left", "right", "up", "down"]),
            ("S right --force", []),
            ("--force --format json S", ["left", "right", "up", "down"]),
            ("S --format json --force", ["left", "right", "up", "down"]),
            ("S right", ["--force"]),
            ("S --format json right --force", [])
        ]
    }

    private func fishExecutablePath() -> String? {
        let paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) } ?? []
        return paths
            .map { URL(fileURLWithPath: $0).appendingPathComponent("fish").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private enum TestFailure: Error {
        case unexpectedPayload
        case shellFailure(Int32, String)
    }
}
