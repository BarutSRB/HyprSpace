// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AssetCatalogProcessRunnerTests: XCTestCase {
    func testSuccessfulCommandReturnsStandardOutput() async {
        let data = await WorkspaceBarAssetCatalogProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["asset-catalog"],
            timeout: .seconds(1)
        )

        XCTAssertEqual(data, Data("asset-catalog".utf8))
    }

    func testMissingExecutableReturnsNil() async {
        let data = await WorkspaceBarAssetCatalogProcessRunner.run(
            executableURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "OmniWMMissingExecutable-\(UUID().uuidString)"
            ),
            arguments: [],
            timeout: .seconds(1)
        )

        XCTAssertNil(data)
    }

    func testNonzeroExitReturnsNil() async {
        let data = await WorkspaceBarAssetCatalogProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeout: .seconds(1)
        )

        XCTAssertNil(data)
    }

    func testTimeoutTerminatesCommand() async throws {
        let startedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMAssetCatalogTimeout-\(UUID().uuidString)"
        )
        defer {
            try? FileManager.default.removeItem(at: startedURL)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let task = Task {
            await WorkspaceBarAssetCatalogProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: sleepingCommandArguments(startedURL: startedURL),
                timeout: .seconds(1)
            )
        }
        guard await waitForFile(at: startedURL, attempts: 50) else {
            task.cancel()
            _ = await task.value
            XCTFail("Command did not start")
            return
        }
        let processIdentifier = try processIdentifier(from: startedURL)
        var processExited = false
        defer {
            if !processExited {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
        let data = await task.value
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertNil(data)
        XCTAssertLessThan(elapsed, .seconds(2))
        processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)
    }

    func testCancellationTerminatesCommand() async throws {
        let startedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMAssetCatalogCancellation-\(UUID().uuidString)"
        )
        defer {
            try? FileManager.default.removeItem(at: startedURL)
        }

        let task = Task {
            await WorkspaceBarAssetCatalogProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: sleepingCommandArguments(startedURL: startedURL),
                timeout: .seconds(10)
            )
        }

        guard await waitForFile(at: startedURL) else {
            task.cancel()
            _ = await task.value
            XCTFail("Command did not start")
            return
        }

        let processIdentifier = try processIdentifier(from: startedURL)
        var processExited = false
        defer {
            if !processExited {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        let data = await task.value
        let elapsed = cancelledAt.duration(to: clock.now)

        XCTAssertNil(data)
        XCTAssertLessThan(elapsed, .seconds(1))
        processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)
    }

    private func sleepingCommandArguments(startedURL: URL) -> [String] {
        [
            "-c",
            "echo $$ > \"$1\"; exec /bin/sleep 30",
            "sh",
            startedURL.path
        ]
    }

    private func waitForFile(
        at url: URL,
        attempts: Int = 100
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func processIdentifier(from url: URL) throws -> pid_t {
        let data = try Data(contentsOf: url)
        let value = try XCTUnwrap(
            String(bytes: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return try XCTUnwrap(pid_t(value))
    }

    private func waitForProcessExit(_ processIdentifier: pid_t) async -> Bool {
        for _ in 0 ..< 100 {
            if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
