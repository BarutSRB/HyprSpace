// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class PrivateAPIFocusEventTests: XCTestCase {
    func testKeyWindowEventRecordEncodesProtocolFields() {
        let windowId: UInt32 = 0xA1B2_C3D4
        let bytes = KeyWindowEventRecord.make(windowId: windowId)

        XCTAssertEqual(bytes.count, 0x100)
        XCTAssertEqual(bytes[0x04], 0xF8)
        XCTAssertEqual(bytes[0x08], 0x01)
        XCTAssertEqual(bytes[0x3A], 0x10)

        var decodedWindowId: UInt32 = 0
        withUnsafeMutableBytes(of: &decodedWindowId) { destination in
            destination.copyBytes(from: bytes[0x3C ..< 0x3C + MemoryLayout<UInt32>.size])
        }
        XCTAssertEqual(decodedWindowId, windowId)
        XCTAssertTrue(bytes[0xF8...].allSatisfy { $0 == 0 })
    }

    func testKeyWindowEventRecordEncodesFiniteOffContentLocation() {
        let bytes = KeyWindowEventRecord.make(windowId: 1)
        var decodedLocation = CGPoint.zero
        withUnsafeMutableBytes(of: &decodedLocation) { destination in
            destination.copyBytes(from: bytes[0x20 ..< 0x20 + MemoryLayout<CGPoint>.size])
        }

        XCTAssertEqual(decodedLocation, CGPoint(x: -1, y: -1))
        XCTAssertTrue(decodedLocation.x.isFinite)
        XCTAssertTrue(decodedLocation.y.isFinite)
    }

    func testKeyWindowEventRecordSwitchesToMouseUpWithoutRebuilding() {
        var bytes = KeyWindowEventRecord.make(windowId: 1)

        KeyWindowEventRecord.setEventType(.mouseUp, in: &bytes)

        XCTAssertEqual(bytes[0x08], 0x02)
    }
}
