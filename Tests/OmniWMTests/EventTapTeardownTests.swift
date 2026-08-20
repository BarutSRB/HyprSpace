// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class EventTapTeardownTests: XCTestCase {
    private struct Fixture {
        let tap: CFMachPort
        let source: CFRunLoopSource
    }

    func testTeardownOrdersOperationsAndClearsReferences() throws {
        var tap: CFMachPort? = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        var source: CFRunLoopSource? = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        var operations: [String] = []

        EventTapTeardown.tearDown(
            tap: &tap,
            runLoopSource: &source,
            operations: EventTapTeardownOperations(
                disableTap: { _ in operations.append("disable") },
                removeRunLoopSource: { _, _, _ in operations.append("remove") },
                invalidateTap: { _ in operations.append("invalidate") }
            )
        )

        XCTAssertEqual(operations, ["disable", "remove", "invalidate"])
        XCTAssertNil(tap)
        XCTAssertNil(source)
    }

    func testLiveTeardownInvalidatesAndUnschedules() throws {
        let fixture = try makeFixture()
        var tap: CFMachPort? = fixture.tap
        var source: CFRunLoopSource? = fixture.source

        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &source)

        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
        XCTAssertNil(tap)
        XCTAssertNil(source)
    }

    func testMouseCleanupInvalidatesBothTaps() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "EventTapTeardownMouse")
        let handler = controller.mouseEventHandler
        let move = try makeFixture()
        let session = try makeFixture()
        handler.state.moveTap = move.tap
        handler.state.moveTapRunLoopSource = move.source
        handler.state.eventTap = session.tap
        handler.state.runLoopSource = session.source

        handler.cleanup()

        XCTAssertFalse(CFMachPortIsValid(move.tap))
        XCTAssertFalse(CFMachPortIsValid(session.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), move.source, .commonModes))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), session.source, .commonModes))
    }

    func testSecureInputStopInvalidatesTap() throws {
        let fixture = try makeFixture()
        let monitor = SecureInputMonitor()
        monitor.secureInputStateProviderForTests = { false }
        monitor.eventTapInstallerForTests = { (fixture.tap, fixture.source) }

        monitor.start { _ in }
        monitor.stop()

        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
    }

    func testHotkeyStopInvalidatesTap() throws {
        let fixture = try makeFixture()
        let hotkeys = HotkeyCenter()
        hotkeys.hyperTriggerTap = fixture.tap
        hotkeys.hyperTriggerRunLoopSource = fixture.source

        hotkeys.stopHyperTriggerTap()

        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
        XCTAssertNil(hotkeys.hyperTriggerTap)
        XCTAssertNil(hotkeys.hyperTriggerRunLoopSource)
    }

    private func makeFixture() throws -> Fixture {
        let tap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        let source = try XCTUnwrap(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0))
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return Fixture(tap: tap, source: source)
    }
}
