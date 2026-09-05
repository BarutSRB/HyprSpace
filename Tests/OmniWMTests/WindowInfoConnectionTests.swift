// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

private final class WindowInfoConnectionProbe: Sendable {
    private let events = Mutex<[String]>([])

    func record(_ event: String) {
        events.withLock { $0.append(event) }
    }

    var recorded: [String] {
        events.withLock { $0 }
    }
}

@MainActor
final class WindowInfoConnectionTests: XCTestCase {
    func testConnectionIsCreatedLazilyReusedAndReleasedOffMain() async throws {
        let probe = WindowInfoConnectionProbe()
        let released = expectation(description: "owned connection released")
        var connection: SkyLight.WindowInfoConnection? = SkyLight.WindowInfoConnection(
            mainConnectionId: 1,
            create: {
                XCTAssertFalse(Thread.isMainThread)
                probe.record("create")
                return (.success, 42)
            },
            release: {
                XCTAssertFalse(Thread.isMainThread)
                probe.record("release \($0)")
                released.fulfill()
            }
        )
        XCTAssertTrue(probe.recorded.isEmpty)
        for _ in 0 ..< 2 {
            let result = try await connection?.perform { cid in
                XCTAssertFalse(Thread.isMainThread)
                probe.record("read \(cid)")
                return [77: WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero)]
            }
            XCTAssertEqual(result?[77]?.level, 8)
        }
        connection = nil
        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(probe.recorded, ["create", "read 42", "read 42", "release 42"])
    }

    func testFailedOrInvalidCreationCannotReadOrReleaseMainConnection() async throws {
        for (error, cid): (CGError, Int32) in [(.failure, 42), (.success, 0), (.success, 1)] {
            let probe = WindowInfoConnectionProbe()
            var connection: SkyLight.WindowInfoConnection? = SkyLight.WindowInfoConnection(
                mainConnectionId: 1,
                create: {
                    probe.record("create")
                    return (error, cid)
                },
                release: { probe.record("release \($0)") }
            )
            let result = try await connection?.perform { cid in
                probe.record("read \(cid)")
                return [UInt32: WindowServerInfo]()
            }
            XCTAssertNil(result)
            connection = nil
            _ = try await SkyLight.performWindowInfoQuery { [UInt32: WindowServerInfo]() }
            XCTAssertEqual(probe.recorded, ["create"])
        }
    }

    func testUnusedConnectionDoesNotCreateOrRelease() async throws {
        let probe = WindowInfoConnectionProbe()
        var connection: SkyLight.WindowInfoConnection? = SkyLight.WindowInfoConnection(
            mainConnectionId: 1,
            create: {
                probe.record("create")
                return (.success, 42)
            },
            release: { probe.record("release \($0)") }
        )
        XCTAssertNotNil(connection)
        connection = nil
        _ = try await SkyLight.performWindowInfoQuery { [UInt32: WindowServerInfo]() }
        XCTAssertTrue(probe.recorded.isEmpty)
    }

    func testCancelledEnteredReadRetainsConnectionUntilItReturns() async throws {
        let probe = WindowInfoConnectionProbe()
        let entered = expectation(description: "read entered")
        let released = expectation(description: "release after read")
        let gate = DispatchSemaphore(value: 0)
        var connection: SkyLight.WindowInfoConnection? = SkyLight.WindowInfoConnection(
            mainConnectionId: 1,
            create: {
                probe.record("create")
                return (.success, 42)
            },
            release: {
                XCTAssertFalse(Thread.isMainThread)
                probe.record("release \($0)")
                released.fulfill()
            }
        )
        let task = Task { [owner = try XCTUnwrap(connection)] in
            try await owner.perform { cid in
                probe.record("read \(cid)")
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
                probe.record("read finished")
                return [77: WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero)]
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        connection = nil
        task.cancel()
        XCTAssertEqual(probe.recorded, ["create", "read 42"])
        gate.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled evidence must not be published")
        } catch is CancellationError {
        }
        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(probe.recorded, ["create", "read 42", "read finished", "release 42"])
    }

    func testCancellationWhileQueueBlockedSkipsConnectionCreationAndRead() async throws {
        let entered = expectation(description: "queue occupied")
        let gate = DispatchSemaphore(value: 0)
        let blocker = Task {
            try await SkyLight.performWindowInfoQuery {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
                return [UInt32: WindowServerInfo]()
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        let probe = WindowInfoConnectionProbe()
        let connection = SkyLight.WindowInfoConnection(
            mainConnectionId: 1,
            create: {
                probe.record("create")
                return (.success, 42)
            },
            release: { probe.record("release \($0)") }
        )
        let scheduled = expectation(description: "read scheduled")
        let task = Task {
            scheduled.fulfill()
            return try await connection.perform { cid in
                probe.record("read \(cid)")
                return [UInt32: WindowServerInfo]()
            }
        }
        await fulfillment(of: [scheduled], timeout: 1)
        task.cancel()
        gate.signal()
        _ = try await blocker.value
        do {
            _ = try await task.value
            XCTFail("Cancelled queued query must not run")
        } catch is CancellationError {
        }
        XCTAssertTrue(probe.recorded.isEmpty)
    }

    func testLiveDedicatedConnectionReadsForeignWindowMetadata() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_METADATA_READ_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Enable OMNIWM_RUN_METADATA_READ_LIVE_TESTS for read-only WindowServer checks")
        }
        let sky = SkyLight.shared
        defer { sky.stopWindowInfoQueries() }
        let windows = sky.queryAllVisibleWindows().filter {
            $0.pid != getpid() && $0.pid > 0 && $0.level == 0 && $0.frame.width > 0 && $0.frame.height > 0
        }.prefix(8)
        let ids = Set(windows.map(\.id))
        guard !ids.isEmpty else { throw XCTSkip("No visible foreign application windows") }
        let expected = try XCTUnwrap(sky.queryWindowInfo(windowIds: ids))
        let result = try await sky.queryWindowInfoDeferred(windowIds: ids)
        let actual = try XCTUnwrap(result)
        XCTAssertEqual(Set(actual.keys), ids)
        for id in ids {
            XCTAssertEqual(actual[id]?.pid, expected[id]?.pid)
            XCTAssertEqual(actual[id]?.level, expected[id]?.level)
        }
    }

    func testConnectionReturnsCornerValuesParsedOffMain() async throws {
        let connection = SkyLight.WindowInfoConnection(
            mainConnectionId: 1, create: { (.success, 42) }, release: { _ in }
        )
        let result = try await connection.perform { _ in
            XCTAssertFalse(Thread.isMainThread)
            let resolved = [NSNumber(value: 0)] as CFArray
            let raw = [NSNumber(value: 11.5)] as CFArray
            return SkyLight.cornerSample(resolved: resolved, raw: raw, observedSize: CGSize(width: 200, height: 150))
        }
        XCTAssertEqual(result, WindowCornerSample(
            radii: WindowCornerRadii(uniform: 11.5), observedSize: CGSize(width: 200, height: 150), source: .raw
        ))
    }

    func testLiveDedicatedConnectionReadsCornersAndRejectsWrongPID() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_METADATA_READ_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Enable OMNIWM_RUN_METADATA_READ_LIVE_TESTS for read-only WindowServer checks")
        }
        let sky = SkyLight.shared
        defer { sky.stopWindowInfoQueries() }
        let windows = sky.queryAllVisibleWindows().filter {
            $0.pid != getpid() && $0.pid > 0 && $0.level == 0 && $0.frame.width > 0 && $0.frame.height > 0
        }.prefix(8)
        var comparisons = 0
        for window in windows {
            let token = WindowToken(pid: window.pid, windowId: Int(window.id))
            guard let expected = sky.cornerSample(forWindowId: token.windowId) else { continue }
            let actual = try await sky.cornerSampleDeferred(for: token)
            XCTAssertEqual(actual, expected)
            let wrongOwner = try await sky.cornerSampleDeferred(for: WindowToken(pid: -1, windowId: token.windowId))
            XCTAssertNil(wrongOwner)
            comparisons += 1
        }
        XCTAssertGreaterThan(comparisons, 0)
        let missing = try await sky.cornerSampleDeferred(for: WindowToken(pid: -1, windowId: Int(UInt32.max)))
        XCTAssertNil(missing)
    }
}
