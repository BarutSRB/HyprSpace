// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class PrivateAPIFocusEventTests: XCTestCase {
    func testKeyWindowRecordsPostMouseDownThenMouseUp() {
        let records = KeyWindowEventRecord.pressAndRelease(windowId: 1)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0][0x08], 0x01)
        XCTAssertEqual(records[1][0x08], 0x02)
    }

    func testKeyWindowRecordsEncodeProtocolFields() {
        let windowId: UInt32 = 0xA1B2_C3D4

        for bytes in KeyWindowEventRecord.pressAndRelease(windowId: windowId) {
            XCTAssertEqual(bytes.count, 0x100)
            XCTAssertEqual(bytes[0x04], 0xF8)
            XCTAssertEqual(bytes[0x3A], 0x10)

            var decodedWindowId: UInt32 = 0
            withUnsafeMutableBytes(of: &decodedWindowId) { destination in
                destination.copyBytes(from: bytes[0x3C ..< 0x3C + MemoryLayout<UInt32>.size])
            }
            XCTAssertEqual(decodedWindowId, windowId)
            XCTAssertTrue(bytes[0xF8...].allSatisfy { $0 == 0 })
        }
    }

    func testKeyWindowRecordsEncodeFiniteFarOffContentLocation() {
        for bytes in KeyWindowEventRecord.pressAndRelease(windowId: 1) {
            var decodedLocation = CGPoint.zero
            withUnsafeMutableBytes(of: &decodedLocation) { destination in
                destination.copyBytes(from: bytes[0x20 ..< 0x20 + MemoryLayout<CGPoint>.size])
            }

            XCTAssertEqual(decodedLocation, CGPoint(x: 300_000, y: 300_000))
            XCTAssertTrue(decodedLocation.x.isFinite)
            XCTAssertTrue(decodedLocation.y.isFinite)
        }
    }
}
