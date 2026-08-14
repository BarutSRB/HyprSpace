// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class NativeFullscreenCardGeometryTests: XCTestCase {
    func testRegularCardUsesMeasuredClampedWidthAndVisibleCenter() throws {
        let slot = CGRect(x: 100, y: 80, width: 600, height: 400)
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        let minimum = try XCTUnwrap(
            resolve(slot: slot, workingFrame: workingFrame, preferredWidth: 120)
        )
        XCTAssertEqual(minimum.mode, .regular)
        XCTAssertEqual(minimum.frame.width, 176)
        XCTAssertEqual(minimum.frame.height, 64)
        XCTAssertEqual(minimum.frame.midX, slot.intersection(workingFrame).midX)
        XCTAssertEqual(minimum.frame.midY, slot.intersection(workingFrame).midY)

        let maximum = try XCTUnwrap(
            resolve(slot: slot, workingFrame: workingFrame, preferredWidth: 400)
        )
        XCTAssertEqual(maximum.frame.width, 288)
        XCTAssertEqual(maximum.frame.midX, slot.intersection(workingFrame).midX)
        XCTAssertEqual(maximum.frame.midY, slot.intersection(workingFrame).midY)
    }

    func testPartiallyVisibleRegularCardStaysInsideVisibleIntersection() throws {
        let slot = CGRect(x: -100, y: 100, width: 300, height: 100)
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let visibleFrame = slot.intersection(workingFrame)
        let layout = try XCTUnwrap(
            resolve(slot: slot, workingFrame: workingFrame, preferredWidth: 200)
        )

        XCTAssertEqual(layout.mode, .regular)
        XCTAssertEqual(layout.frame.width, 176)
        XCTAssertEqual(layout.frame.midX, visibleFrame.midX)
        XCTAssertEqual(layout.frame.midY, visibleFrame.midY)
        XCTAssertGreaterThanOrEqual(layout.frame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(layout.frame.maxX, visibleFrame.maxX)
    }

    func testPartiallyVisibleCompactCardStaysInsideVisibleIntersection() throws {
        let slot = CGRect(x: -200, y: 100, width: 260, height: 60)
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let visibleFrame = slot.intersection(workingFrame)
        let layout = try XCTUnwrap(resolve(slot: slot, workingFrame: workingFrame))

        XCTAssertEqual(layout.mode, .compact)
        XCTAssertEqual(layout.frame.midX, visibleFrame.midX)
        XCTAssertEqual(layout.frame.midY, visibleFrame.midY)
        XCTAssertGreaterThanOrEqual(layout.frame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(layout.frame.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(layout.frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(layout.frame.maxY, visibleFrame.maxY)
    }

    func testCompactCardScalesBetweenFortyFourAndSixtyFourPoints() throws {
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let minimum = try XCTUnwrap(
            resolve(
                slot: CGRect(x: 20, y: 20, width: 52, height: 52),
                workingFrame: workingFrame
            )
        )
        XCTAssertEqual(minimum.mode, .compact)
        XCTAssertEqual(minimum.frame.size, CGSize(width: 44, height: 44))

        let maximum = try XCTUnwrap(
            resolve(
                slot: CGRect(x: 20, y: 20, width: 72, height: 72),
                workingFrame: workingFrame
            )
        )
        XCTAssertEqual(maximum.mode, .compact)
        XCTAssertEqual(maximum.frame.size, CGSize(width: 64, height: 64))
    }

    func testCardHidesBelowCompactThresholdAndUsesExitHysteresis() throws {
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let slot = CGRect(x: 20, y: 20, width: 48, height: 48)

        XCTAssertNil(resolve(slot: slot, workingFrame: workingFrame))
        let retained = try XCTUnwrap(
            resolve(slot: slot, workingFrame: workingFrame, previousMode: .compact)
        )
        XCTAssertEqual(retained.mode, .compact)
        XCTAssertEqual(retained.frame.size, CGSize(width: 44, height: 44))
        XCTAssertNil(
            resolve(
                slot: CGRect(x: 20, y: 20, width: 43, height: 43),
                workingFrame: workingFrame,
                previousMode: .compact
            )
        )
    }

    func testRegularModeUsesEightPointExitHysteresis() throws {
        let workingFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let retained = try XCTUnwrap(
            resolve(
                slot: CGRect(x: 20, y: 20, width: 192, height: 80),
                workingFrame: workingFrame,
                previousMode: .regular
            )
        )
        XCTAssertEqual(retained.mode, .regular)

        let demoted = try XCTUnwrap(
            resolve(
                slot: CGRect(x: 20, y: 20, width: 191, height: 80),
                workingFrame: workingFrame,
                previousMode: .regular
            )
        )
        XCTAssertEqual(demoted.mode, .compact)
    }

    func testGeometryRoundsToPhysicalPixelsAndRejectsInvalidFrames() throws {
        let layout = try XCTUnwrap(
            resolve(
                slot: CGRect(x: 10.13, y: 20.37, width: 400.21, height: 300.19),
                workingFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                scale: 2
            )
        )
        XCTAssertEqual((layout.frame.origin.x * 2).rounded(), layout.frame.origin.x * 2)
        XCTAssertEqual((layout.frame.origin.y * 2).rounded(), layout.frame.origin.y * 2)
        XCTAssertEqual((layout.frame.width * 2).rounded(), layout.frame.width * 2)
        XCTAssertEqual((layout.frame.height * 2).rounded(), layout.frame.height * 2)

        XCTAssertNil(
            resolve(
                slot: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                workingFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        )
        XCTAssertNil(
            resolve(
                slot: CGRect(x: 0, y: 0, width: 0, height: 100),
                workingFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        )
    }

    private func resolve(
        slot: CGRect,
        workingFrame: CGRect,
        scale: CGFloat = 1,
        preferredWidth: CGFloat = 220,
        previousMode: NativeFullscreenCardMode? = nil
    ) -> NativeFullscreenCardLayout? {
        NativeFullscreenCardGeometry.resolve(
            slotFrame: slot,
            workingFrame: workingFrame,
            scale: scale,
            preferredRegularWidth: preferredWidth,
            previousMode: previousMode
        )
    }
}
