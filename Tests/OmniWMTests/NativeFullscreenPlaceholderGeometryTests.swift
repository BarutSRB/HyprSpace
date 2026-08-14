// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class NativeFullscreenPlaceholderGeometryTests: XCTestCase {
    func testVisibleSlotUsesTheEntireAcceptedTileFrame() throws {
        let slot = CGRect(x: 100, y: 80, width: 600, height: 400)
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        let frame = try XCTUnwrap(
            NativeFullscreenPlaceholderGeometry.resolve(
                slotFrame: slot,
                workingFrame: workingFrame
            )
        )

        XCTAssertEqual(frame, slot)
    }

    func testPartiallyVisibleSlotRetainsFullTileGeometry() throws {
        let slot = CGRect(x: -200, y: 100, width: 500, height: 360)
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        let frame = try XCTUnwrap(
            NativeFullscreenPlaceholderGeometry.resolve(
                slotFrame: slot,
                workingFrame: workingFrame
            )
        )

        XCTAssertEqual(frame, slot)
    }

    func testOffscreenAndInvalidSlotsAreRejected() {
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        XCTAssertNil(
            NativeFullscreenPlaceholderGeometry.resolve(
                slotFrame: CGRect(x: -500, y: 100, width: 200, height: 200),
                workingFrame: workingFrame
            )
        )
        XCTAssertNil(
            NativeFullscreenPlaceholderGeometry.resolve(
                slotFrame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                workingFrame: workingFrame
            )
        )
        XCTAssertNil(
            NativeFullscreenPlaceholderGeometry.resolve(
                slotFrame: CGRect(x: 0, y: 0, width: 0, height: 100),
                workingFrame: workingFrame
            )
        )
    }
}
