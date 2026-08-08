// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

// MARK: - Overlay Detection Helpers

extension XCTestCase {
    /// Asserts that all provided frames are non-overlapping.
    func assertNoOverlaps(
        _ frames: [WindowToken: CGRect],
        tolerance: CGFloat = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pairs = Array(frames)
        for i in 0 ..< pairs.count {
            for j in (i + 1) ..< pairs.count {
                let (tokA, frameA) = pairs[i]
                let (tokB, frameB) = pairs[j]
                let intersection = frameA.intersection(frameB)
                if !intersection.isNull, intersection.width > tolerance, intersection.height > tolerance {
                    XCTFail(
                        "OVERLAY DETECTED: \(tokA) (\(frameA)) overlaps \(tokB) (\(frameB)) — intersection: \(intersection)",
                        file: file,
                        line: line
                    )
                }
            }
        }
    }

    /// Asserts that all frames are within the screen bounds.
    func assertAllFramesWithinScreen(
        _ frames: [WindowToken: CGRect],
        screen: CGRect,
        tolerance: CGFloat = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expanded = screen.insetBy(dx: -tolerance, dy: -tolerance)
        for (token, frame) in frames {
            XCTAssertTrue(
                expanded.contains(frame),
                "OFFSCREEN WINDOW: \(token) frame \(frame) not within screen \(screen)",
                file: file,
                line: line
            )
        }
    }

    /// Asserts that no frame has zero or negative dimensions.
    func assertAllFramesDimensionsPositive(
        _ frames: [WindowToken: CGRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (token, frame) in frames {
            XCTAssertGreaterThan(frame.width, 0, "ZERO-WIDTH WINDOW: \(token)", file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, "ZERO-HEIGHT WINDOW: \(token)", file: file, line: line)
        }
    }

    /// Full layout integrity check: no overlaps, within screen, positive dimensions.
    func assertLayoutIntegrity(
        _ frames: [WindowToken: CGRect],
        screen: CGRect,
        tolerance: CGFloat = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertNoOverlaps(frames, tolerance: tolerance, file: file, line: line)
        assertAllFramesWithinScreen(frames, screen: screen, tolerance: tolerance + 1, file: file, line: line)
        assertAllFramesDimensionsPositive(frames, file: file, line: line)
    }
}

// MARK: - CGRect center helper
private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - Window Overlay Integrity Tests

final class DwindleOverlayIntegrityTests: XCTestCase {
    private var engine: DwindleLayoutEngine!
    private let wsId = WorkspaceDescriptor.ID()
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    override func setUp() {
        super.setUp()
        engine = DwindleLayoutEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Static Layout Integrity

    func testTwoWindowLayoutHasNoOverlap() {
        let t1 = WindowToken(pid: 1, windowId: 101)
        let t2 = WindowToken(pid: 1, windowId: 102)
        engine.addWindow(token: t1, to: wsId, activeWindowFrame: nil)
        engine.addWindow(token: t2, to: wsId, activeWindowFrame: nil)
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 2)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testThreeWindowLayoutHasNoOverlap() {
        let tokens = (1...3).map { WindowToken(pid: 2, windowId: 200 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 3)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testFourWindowLayoutHasNoOverlap() {
        let tokens = (1...4).map { WindowToken(pid: 3, windowId: 300 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 4)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testFiveWindowLayoutHasNoOverlap() {
        let tokens = (1...5).map { WindowToken(pid: 4, windowId: 400 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 5)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testSixWindowLayoutHasNoOverlap() {
        let tokens = (1...6).map { WindowToken(pid: 5, windowId: 500 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 6)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testEightWindowLayoutHasNoOverlap() {
        let tokens = (1...8).map { WindowToken(pid: 6, windowId: 600 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 8)
        assertLayoutIntegrity(frames, screen: screen)
    }

    // MARK: - Layout Integrity After Window Removal

    func testLayoutIntegrityAfterWindowRemovalFourToThree() {
        let tokens = (1...4).map { WindowToken(pid: 7, windowId: 700 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)
        engine.removeWindow(token: tokens[1], from: wsId)
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 3)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testLayoutIntegrityAfterWindowRemovalThreeToTwo() {
        let tokens = (1...3).map { WindowToken(pid: 8, windowId: 800 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)
        engine.removeWindow(token: tokens[0], from: wsId)
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 2)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testLayoutIntegrityAfterMultipleRapidRemovals() {
        let tokens = (1...6).map { WindowToken(pid: 9, windowId: 900 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)
        for t in [tokens[2], tokens[0], tokens[4]] {
            engine.removeWindow(token: t, from: wsId)
            let frames = engine.calculateLayout(for: wsId, screen: screen)
            assertLayoutIntegrity(frames, screen: screen)
        }
    }

    // MARK: - Interactive Move Overlay Tests (Critical Path)

    func testNoOverlapAfterInteractiveMoveSwapTwoWindows() throws {
        let t1 = WindowToken(pid: 10, windowId: 1001)
        let t2 = WindowToken(pid: 10, windowId: 1002)
        engine.addWindow(token: t1, to: wsId, activeWindowFrame: nil)
        engine.addWindow(token: t2, to: wsId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame1 = try XCTUnwrap(engine.findNode(for: t1, in: wsId)?.cachedFrame)
        let frame2 = try XCTUnwrap(engine.findNode(for: t2, in: wsId)?.cachedFrame)

        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame1.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: frame2.center)
        _ = engine.interactiveMoveEnd(at: frame2.center)

        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 2)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testNoOverlapAfterInteractiveMoveSwapInFourWindowTree() throws {
        let tokens = (1...4).map { WindowToken(pid: 11, windowId: 1100 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame0 = try XCTUnwrap(engine.findNode(for: tokens[0], in: wsId)?.cachedFrame)
        let frame3 = try XCTUnwrap(engine.findNode(for: tokens[3], in: wsId)?.cachedFrame)

        XCTAssertTrue(engine.interactiveMoveBegin(token: tokens[0], startLocation: frame0.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: frame3.center)
        _ = engine.interactiveMoveEnd(at: frame3.center)

        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 4)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testNoOverlapAfterInteractiveMoveSwapAllCombinationsInFourWindowTree() throws {
        let baseTokens = (1...4).map { WindowToken(pid: 12, windowId: 1200 + $0) }

        for i in 0 ..< baseTokens.count {
            for j in (i + 1) ..< baseTokens.count {
                let freshWsId = WorkspaceDescriptor.ID()
                for t in baseTokens { engine.addWindow(token: t, to: freshWsId, activeWindowFrame: nil) }
                _ = engine.calculateLayout(for: freshWsId, screen: screen)

                let frameI = try XCTUnwrap(engine.findNode(for: baseTokens[i], in: freshWsId)?.cachedFrame)
                let frameJ = try XCTUnwrap(engine.findNode(for: baseTokens[j], in: freshWsId)?.cachedFrame)

                XCTAssertTrue(engine.interactiveMoveBegin(token: baseTokens[i], startLocation: frameI.center, in: freshWsId))
                _ = engine.interactiveMoveUpdate(currentLocation: frameJ.center)
                _ = engine.interactiveMoveEnd(at: frameJ.center)

                let frames = engine.calculateLayout(for: freshWsId, screen: screen)
                XCTAssertEqual(frames.count, 4, "Window count changed after swap(\(i),\(j))")
                assertLayoutIntegrity(frames, screen: screen)

                for t in baseTokens { engine.removeWindow(token: t, from: freshWsId) }
            }
        }
    }

    func testNoOverlapAfterInteractiveMoveIntoTopEdgeSplit() throws {
        let t1 = WindowToken(pid: 13, windowId: 1301)
        let t2 = WindowToken(pid: 13, windowId: 1302)
        engine.addWindow(token: t1, to: wsId, activeWindowFrame: nil)
        engine.addWindow(token: t2, to: wsId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame2 = try XCTUnwrap(engine.findNode(for: t2, in: wsId)?.cachedFrame)
        let topEdgeDrop = CGPoint(x: frame2.midX, y: frame2.maxY - 10)
        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame2.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: topEdgeDrop)
        _ = engine.interactiveMoveEnd(at: topEdgeDrop)

        let frames = engine.calculateLayout(for: wsId, screen: screen)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testNoOverlapAfterInteractiveMoveIntoBottomEdgeSplit() throws {
        let t1 = WindowToken(pid: 14, windowId: 1401)
        let t2 = WindowToken(pid: 14, windowId: 1402)
        engine.addWindow(token: t1, to: wsId, activeWindowFrame: nil)
        engine.addWindow(token: t2, to: wsId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame1 = try XCTUnwrap(engine.findNode(for: t1, in: wsId)?.cachedFrame)
        let frame2 = try XCTUnwrap(engine.findNode(for: t2, in: wsId)?.cachedFrame)
        let bottomEdgeDrop = CGPoint(x: frame2.midX, y: frame2.minY + 10)

        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame1.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: bottomEdgeDrop)
        _ = engine.interactiveMoveEnd(at: bottomEdgeDrop)

        let frames = engine.calculateLayout(for: wsId, screen: screen)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testNoOverlapAfterChainedMovesInFiveWindowTree() throws {
        let tokens = (1...5).map { WindowToken(pid: 15, windowId: 1500 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let movePairs = [(0, 4), (1, 3), (2, 0)]
        for (i, j) in movePairs {
            let frameI = try XCTUnwrap(engine.findNode(for: tokens[i], in: wsId)?.cachedFrame)
            let frameJ = try XCTUnwrap(engine.findNode(for: tokens[j], in: wsId)?.cachedFrame)

            XCTAssertTrue(engine.interactiveMoveBegin(token: tokens[i], startLocation: frameI.center, in: wsId))
            _ = engine.interactiveMoveUpdate(currentLocation: frameJ.center)
            _ = engine.interactiveMoveEnd(at: frameJ.center)

            let frames = engine.calculateLayout(for: wsId, screen: screen)
            assertLayoutIntegrity(frames, screen: screen)
        }
    }

    func testNoOverlapAfterInteractiveMoveFollowedByWindowAddition() throws {
        let t1 = WindowToken(pid: 16, windowId: 1601)
        let t2 = WindowToken(pid: 16, windowId: 1602)
        engine.addWindow(token: t1, to: wsId, activeWindowFrame: nil)
        engine.addWindow(token: t2, to: wsId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame1 = try XCTUnwrap(engine.findNode(for: t1, in: wsId)?.cachedFrame)
        let frame2 = try XCTUnwrap(engine.findNode(for: t2, in: wsId)?.cachedFrame)

        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame1.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: frame2.center)
        _ = engine.interactiveMoveEnd(at: frame2.center)

        let t3 = WindowToken(pid: 16, windowId: 1603)
        engine.addWindow(token: t3, to: wsId, activeWindowFrame: nil)
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 3)
        assertLayoutIntegrity(frames, screen: screen)
    }

    func testNoOverlapAfterInteractiveMoveFollowedByWindowRemoval() throws {
        let tokens = (1...4).map { WindowToken(pid: 17, windowId: 1700 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame0 = try XCTUnwrap(engine.findNode(for: tokens[0], in: wsId)?.cachedFrame)
        let frame2 = try XCTUnwrap(engine.findNode(for: tokens[2], in: wsId)?.cachedFrame)

        XCTAssertTrue(engine.interactiveMoveBegin(token: tokens[0], startLocation: frame0.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: frame2.center)
        _ = engine.interactiveMoveEnd(at: frame2.center)

        engine.removeWindow(token: tokens[1], from: wsId)
        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 3)
        assertLayoutIntegrity(frames, screen: screen)
    }

    // MARK: - cachedFrame Direct Overlap Tests (no calculateLayout re-call)

    func testCachedFramesHaveNoOverlapAfterSwapTwoWindows() throws {
        let t1 = WindowToken(pid: 18, windowId: 1801)
        let t2 = WindowToken(pid: 18, windowId: 1802)
        engine.addWindow(token: t1, to: wsId, activeWindowFrame: nil)
        engine.addWindow(token: t2, to: wsId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame1 = try XCTUnwrap(engine.findNode(for: t1, in: wsId)?.cachedFrame)
        let frame2 = try XCTUnwrap(engine.findNode(for: t2, in: wsId)?.cachedFrame)

        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame1.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: frame2.center)
        _ = engine.interactiveMoveEnd(at: frame2.center)

        let cached1 = try XCTUnwrap(engine.findNode(for: t1, in: wsId)?.cachedFrame)
        let cached2 = try XCTUnwrap(engine.findNode(for: t2, in: wsId)?.cachedFrame)
        let cachedFrames: [WindowToken: CGRect] = [t1: cached1, t2: cached2]
        assertLayoutIntegrity(cachedFrames, screen: screen)
    }

    func testCachedFramesHaveNoOverlapAfterSwapInFourWindowTree() throws {
        let tokens = (1...4).map { WindowToken(pid: 19, windowId: 1900 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame0 = try XCTUnwrap(engine.findNode(for: tokens[0], in: wsId)?.cachedFrame)
        let frame3 = try XCTUnwrap(engine.findNode(for: tokens[3], in: wsId)?.cachedFrame)

        XCTAssertTrue(engine.interactiveMoveBegin(token: tokens[0], startLocation: frame0.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: frame3.center)
        _ = engine.interactiveMoveEnd(at: frame3.center)

        var cachedFrames: [WindowToken: CGRect] = [:]
        for t in tokens {
            if let f = engine.findNode(for: t, in: wsId)?.cachedFrame {
                cachedFrames[t] = f
            }
        }
        XCTAssertEqual(cachedFrames.count, 4, "Not all windows have cachedFrame after move")
        assertLayoutIntegrity(cachedFrames, screen: screen)
    }

    func testCachedFramesHaveNoOverlapImmediatelyAfterSplitDrop() throws {
        let t1 = WindowToken(pid: 20, windowId: 2001)
        let t2 = WindowToken(pid: 20, windowId: 2002)
        engine.addWindow(token: t1, to: wsId, activeWindowFrame: nil)
        engine.addWindow(token: t2, to: wsId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: wsId, screen: screen)

        let frame2 = try XCTUnwrap(engine.findNode(for: t2, in: wsId)?.cachedFrame)
        let topEdgeDrop = CGPoint(x: frame2.midX, y: frame2.maxY - 10)

        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame2.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: topEdgeDrop)
        _ = engine.interactiveMoveEnd(at: topEdgeDrop)

        // Collect cached frames without calling calculateLayout — tests synchronous recalc in interactiveMoveEnd
        let allTokens = [t1, t2]
        var cachedFrames: [WindowToken: CGRect] = [:]
        for t in allTokens {
            if let f = engine.findNode(for: t, in: wsId)?.cachedFrame {
                cachedFrames[t] = f
            }
        }

        XCTAssertEqual(cachedFrames.count, 2, "Both windows must have a cachedFrame after split drop")
        assertNoOverlaps(cachedFrames, tolerance: 1.0)
    }

    // MARK: - All Permutations in Three-Window Tree

    func testLayoutIntegrityAfterEveryPermutationInThreeWindowTree() throws {
        let baseTokens = (1...3).map { WindowToken(pid: 21, windowId: 2100 + $0) }

        for i in 0 ..< baseTokens.count {
            for j in 0 ..< baseTokens.count where i != j {
                let freshWsId = WorkspaceDescriptor.ID()
                for t in baseTokens { engine.addWindow(token: t, to: freshWsId, activeWindowFrame: nil) }
                _ = engine.calculateLayout(for: freshWsId, screen: screen)

                let frameI = try XCTUnwrap(engine.findNode(for: baseTokens[i], in: freshWsId)?.cachedFrame)
                let frameJ = try XCTUnwrap(engine.findNode(for: baseTokens[j], in: freshWsId)?.cachedFrame)

                XCTAssertTrue(engine.interactiveMoveBegin(token: baseTokens[i], startLocation: frameI.center, in: freshWsId))
                _ = engine.interactiveMoveUpdate(currentLocation: frameJ.center)
                _ = engine.interactiveMoveEnd(at: frameJ.center)

                let frames = engine.calculateLayout(for: freshWsId, screen: screen)
                XCTAssertEqual(frames.count, 3, "Window count changed after swap(\(i),\(j))")
                assertLayoutIntegrity(frames, screen: screen)

                for t in baseTokens { engine.removeWindow(token: t, from: freshWsId) }
            }
        }
    }

    // MARK: - Screen Size Variations

    func testLayoutIntegrityOnPortraitScreen() {
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let tokens = (1...4).map { WindowToken(pid: 22, windowId: 2200 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        let frames = engine.calculateLayout(for: wsId, screen: portrait)
        assertLayoutIntegrity(frames, screen: portrait)
    }

    func testLayoutIntegrityOnUltrawideScreen() {
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let tokens = (1...5).map { WindowToken(pid: 23, windowId: 2300 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        let frames = engine.calculateLayout(for: wsId, screen: ultrawide)
        assertLayoutIntegrity(frames, screen: ultrawide)
    }

    func testLayoutIntegrityOnSmallLaptopScreen() {
        let laptop = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let tokens = (1...6).map { WindowToken(pid: 24, windowId: 2400 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        let frames = engine.calculateLayout(for: wsId, screen: laptop)
        assertLayoutIntegrity(frames, screen: laptop)
    }

    func testNoOverlapAfterInteractiveMoveOnUltrwide() throws {
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let t1 = WindowToken(pid: 25, windowId: 2501)
        let t2 = WindowToken(pid: 25, windowId: 2502)
        engine.addWindow(token: t1, to: wsId, activeWindowFrame: nil)
        engine.addWindow(token: t2, to: wsId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: wsId, screen: ultrawide)

        let frame1 = try XCTUnwrap(engine.findNode(for: t1, in: wsId)?.cachedFrame)
        let frame2 = try XCTUnwrap(engine.findNode(for: t2, in: wsId)?.cachedFrame)

        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame1.center, in: wsId))
        _ = engine.interactiveMoveUpdate(currentLocation: frame2.center)
        _ = engine.interactiveMoveEnd(at: frame2.center)

        let frames = engine.calculateLayout(for: wsId, screen: ultrawide)
        assertLayoutIntegrity(frames, screen: ultrawide)
    }

    // MARK: - Cancel Does Not Corrupt Layout

    func testLayoutIntegrityAfterInteractiveMoveCancel() {
        let tokens = (1...3).map { WindowToken(pid: 26, windowId: 2600 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)

        guard let frame0 = engine.findNode(for: tokens[0], in: wsId)?.cachedFrame,
              let frame2 = engine.findNode(for: tokens[2], in: wsId)?.cachedFrame else {
            XCTFail("Missing cachedFrame")
            return
        }

        guard engine.interactiveMoveBegin(token: tokens[0], startLocation: frame0.center, in: wsId) else {
            XCTFail("interactiveMoveBegin failed")
            return
        }
        _ = engine.interactiveMoveUpdate(currentLocation: frame2.center)
        engine.interactiveMoveCancel()

        let frames = engine.calculateLayout(for: wsId, screen: screen)
        XCTAssertEqual(frames.count, 3)
        assertLayoutIntegrity(frames, screen: screen)
    }

    // MARK: - Stress: Rapid Sequential Moves

    func testLayoutIntegrityAfterTenSequentialMovesInFiveWindowTree() {
        let tokens = (1...5).map { WindowToken(pid: 27, windowId: 2700 + $0) }
        for t in tokens { engine.addWindow(token: t, to: wsId, activeWindowFrame: nil) }
        _ = engine.calculateLayout(for: wsId, screen: screen)

        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 10 {
            let i = Int.random(in: 0 ..< tokens.count, using: &rng)
            var j = Int.random(in: 0 ..< tokens.count, using: &rng)
            while j == i { j = Int.random(in: 0 ..< tokens.count, using: &rng) }

            guard let frameI = engine.findNode(for: tokens[i], in: wsId)?.cachedFrame,
                  let frameJ = engine.findNode(for: tokens[j], in: wsId)?.cachedFrame
            else { continue }

            if engine.interactiveMoveBegin(token: tokens[i], startLocation: frameI.center, in: wsId) {
                _ = engine.interactiveMoveUpdate(currentLocation: frameJ.center)
                _ = engine.interactiveMoveEnd(at: frameJ.center)
            }

            let frames = engine.calculateLayout(for: wsId, screen: screen)
            assertLayoutIntegrity(frames, screen: screen)
        }
    }
}
