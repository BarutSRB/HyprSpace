// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class SubscribeCLIContractTests: XCTestCase {
    func testSubscribeDefaultsToPrettyJSON() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "subscribe", "focus"])

        XCTAssertEqual(parsed.outputFormat, .json)
        XCTAssertTrue(parsed.expectsEventStream)
    }

    func testSubscribeAcceptsNDJSON() throws {
        let invocations = [
            ["omniwmctl", "subscribe", "focus", "--format", "ndjson"],
            ["omniwmctl", "--format", "ndjson", "subscribe", "--all"]
        ]

        for invocation in invocations {
            let parsed = try CLIParser.parse(arguments: invocation)
            XCTAssertEqual(parsed.outputFormat, .ndjson, invocation.joined(separator: " "))
            XCTAssertTrue(parsed.expectsEventStream)
        }
    }

    func testSubscribeRejectsHumanFormats() {
        for format in ["table", "tsv", "text"] {
            XCTAssertThrowsError(
                try CLIParser.parse(arguments: ["omniwmctl", "subscribe", "focus", "--format", format])
            ) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText), format)
            }
        }
    }

    func testQueryAcceptsNDJSON() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "query", "windows", "--format", "ndjson"])

        XCTAssertEqual(parsed.outputFormat, .ndjson)
        XCTAssertFalse(parsed.expectsEventStream)
    }

    func testHelpExposesNDJSONFormat() {
        XCTAssertTrue(CLIParser.usageText.contains("--format json|ndjson|table|tsv|text"))
        XCTAssertTrue(
            CLIParser.usageText
                .contains("omniwmctl subscribe --all [--no-send-initial] [--reconnect] [--format json|ndjson]")
        )
    }

    func testSubscribeAndWatchParseReconnectFlag() throws {
        XCTAssertFalse(try CLIParser.parse(arguments: ["omniwmctl", "subscribe", "focus"]).reconnect)
        XCTAssertTrue(try CLIParser.parse(arguments: ["omniwmctl", "subscribe", "focus", "--reconnect"]).reconnect)

        let watch = try CLIParser.parse(arguments: ["omniwmctl", "watch", "--all", "--reconnect", "--exec", "cat"])
        XCTAssertTrue(watch.reconnect)
        XCTAssertEqual(watch.watchConfiguration, CLIWatchConfiguration(childArguments: ["cat"]))

        XCTAssertThrowsError(
            try CLIParser.parse(arguments: ["omniwmctl", "subscribe", "focus", "--reconnect", "--reconnect"])
        )
    }

    func testReconnectAfterExecBelongsToChild() throws {
        let watch = try CLIParser.parse(arguments: ["omniwmctl", "watch", "focus", "--exec", "cat", "--reconnect"])

        XCTAssertFalse(watch.reconnect)
        XCTAssertEqual(watch.watchConfiguration, CLIWatchConfiguration(childArguments: ["cat", "--reconnect"]))
    }

    func testHelpAndCompletionsExposeReconnectFlag() {
        XCTAssertTrue(
            CLIParser.usageText.contains("omniwmctl watch --all [--no-send-initial] [--reconnect] --exec <argv...>")
        )
        for shell in CLIShell.allCases {
            XCTAssertTrue(CLICompletionGenerator.script(for: shell).contains("--reconnect"), shell.rawValue)
        }
    }
}
