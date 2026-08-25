// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CaptureCLIContractTests: XCTestCase {
    func testParserBuildsCaptureRequests() throws {
        let cases: [([String], IPCCaptureRequest)] = [
            (["capture", "start", "trace"], .start(.trace)),
            (["capture", "start", "performance"], .start(.performance)),
            (["capture", "stop"], .stop),
            (["capture", "status"], .status)
        ]

        for (arguments, expected) in cases {
            let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + arguments)
            guard case let .capture(request) = parsed.request.payload else {
                return XCTFail("Expected capture request for \(arguments)")
            }

            XCTAssertEqual(request, expected)
            XCTAssertEqual(parsed.outputFormat, .text)
            XCTAssertFalse(parsed.expectsEventStream)
        }
    }

    func testParserRejectsMalformedCaptureRequests() {
        let invalidArguments = [
            ["capture"],
            ["capture", "start"],
            ["capture", "start", "problem"],
            ["capture", "start", "trace", "extra"],
            ["capture", "stop", "trace"],
            ["capture", "status", "extra"],
            ["capture", "unknown"]
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + arguments)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testHelpAndCompletionsExposeCaptureContract() {
        XCTAssertTrue(CLIParser.usageText.contains("omniwmctl capture start <trace|performance>"))
        XCTAssertTrue(CLIParser.usageText.contains("omniwmctl capture stop"))
        XCTAssertTrue(CLIParser.usageText.contains("omniwmctl capture status"))

        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            switch shell {
            case .zsh:
                XCTAssertTrue(script.contains("capture)\n      if (( CURRENT == 3 ))"))
                XCTAssertTrue(script.contains("suggestions=\"start status stop\""))
                XCTAssertTrue(script.contains("suggestions=\"performance trace\""))
            case .bash:
                XCTAssertTrue(script.contains("capture)\n      if [[ ${COMP_CWORD} -eq 2 ]]"))
                XCTAssertTrue(script.contains("__omniwmctl_compgen \"start status stop\""))
                XCTAssertTrue(script.contains("__omniwmctl_compgen \"performance trace\""))
            case .fish:
                XCTAssertTrue(script.contains("__fish_seen_subcommand_from capture"))
                XCTAssertTrue(script.contains("__fish_seen_subcommand_from performance trace' -a 'trace'"))
                XCTAssertTrue(script.contains("__fish_seen_subcommand_from performance trace' -a 'performance'"))
            }
        }
    }

    func testRendererIncludesCaptureStateAndArtifactMetadata() throws {
        let result = captureResult()
        let response = IPCResponse.success(
            id: "capture",
            kind: .capture,
            status: .executed,
            result: IPCResult(capture: result)
        )

        let json = try CLIRenderer.responseOutput(response, format: .json)
        XCTAssertEqual(try IPCWire.decodeResponse(from: json.data), response)

        for format in [CLIOutputFormat.text, .table, .tsv] {
            let output = try CLIRenderer.responseOutput(response, format: format)
            let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))

            XCTAssertTrue(text.contains("recording"), format.rawValue)
            XCTAssertTrue(text.contains("performance"), format.rawValue)
            XCTAssertTrue(text.contains("2026-08-25T12:00:00Z"), format.rawValue)
            XCTAssertTrue(text.contains("trace"), format.rawValue)
            XCTAssertTrue(text.contains("/tmp/omniwm-trace.json"), format.rawValue)
            XCTAssertTrue(text.contains("2026-08-25T10:00:00Z"), format.rawValue)
            XCTAssertTrue(text.contains("2026-08-25T10:05:00Z"), format.rawValue)
        }
    }

    func testCaptureFailureReasonAppearsInHumanErrorOutput() throws {
        let failureResult = IPCCaptureResult(
            phase: .idle,
            failureReason: "The diagnostics volume is\nread-only."
        )
        let response = IPCResponse.failure(
            id: "capture",
            kind: .capture,
            code: .internalError,
            result: IPCResult(capture: failureResult)
        )
        let output = try CLIRenderer.responseOutput(response, format: .text)
        let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))

        XCTAssertEqual(CLIRenderer.exitCode(for: response), .internalError)
        XCTAssertTrue(text.hasPrefix("error: internal_error\n"))
        XCTAssertTrue(text.contains("idle"))
        XCTAssertTrue(text.contains("The diagnostics volume is read-only."))
    }

    func testCaptureStateConflictUsesRejectedExitCode() throws {
        let response = IPCResponse.failure(
            id: "capture",
            kind: .capture,
            code: .captureStateConflict,
            result: IPCResult(capture: captureResult())
        )
        XCTAssertEqual(CLIRenderer.exitCode(for: response), .rejected)
        for format in [CLIOutputFormat.text, .table, .tsv] {
            let output = try CLIRenderer.responseOutput(response, format: format)
            let text = try XCTUnwrap(String(data: output.data, encoding: .utf8))
            XCTAssertTrue(text.hasPrefix("error: capture_state_conflict\n"), format.rawValue)
            XCTAssertTrue(text.contains("recording"), format.rawValue)
            XCTAssertTrue(text.contains("performance"), format.rawValue)
            XCTAssertTrue(text.contains("/tmp/omniwm-trace.json"), format.rawValue)
        }
    }

    private func captureResult() -> IPCCaptureResult {
        IPCCaptureResult(
            phase: .recording,
            profile: .performance,
            startedAt: "2026-08-25T12:00:00Z",
            lastArtifact: IPCCaptureArtifact(
                profile: .trace,
                path: "/tmp/omniwm-trace.json",
                startedAt: "2026-08-25T10:00:00Z",
                endedAt: "2026-08-25T10:05:00Z"
            )
        )
    }
}
