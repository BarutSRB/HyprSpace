// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleSplitRatioPresetTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func makeEngine(
        screen: CGRect,
        innerGap: CGFloat = 0
    ) -> (DwindleLayoutEngine, WorkspaceDescriptor.ID, WindowToken, WindowToken) {
        let engine = DwindleLayoutEngine()
        engine.settings.innerGap = innerGap
        let ws = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)
        return (engine, ws, first, second)
    }

    func testForwardCyclesFocusedFirstChildThroughThirdsAndHalf() {
        let (engine, ws, first, second) = makeEngine(screen: screen)
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertEqual(engine.root(for: ws)?.splitOrientation, .horizontal)

        XCTAssertTrue(engine.cycleSplitRatio(forward: true, in: ws))
        var frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[first]?.width ?? 0, 700, accuracy: 0.5)
        XCTAssertEqual(frames[second]?.minX ?? 0, 700, accuracy: 0.5)
        XCTAssertEqual(frames[second]?.width ?? 0, 300, accuracy: 0.5)

        XCTAssertTrue(engine.cycleSplitRatio(forward: true, in: ws))
        frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[first]?.width ?? 0, 300, accuracy: 0.5)
        XCTAssertEqual(frames[second]?.width ?? 0, 700, accuracy: 0.5)

        XCTAssertTrue(engine.cycleSplitRatio(forward: true, in: ws))
        frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[first]?.width ?? 0, 500, accuracy: 0.5)
        XCTAssertEqual(frames[second]?.width ?? 0, 500, accuracy: 0.5)
    }

    func testPresetAppliesToFocusedSecondChildShare() {
        let (engine, ws, first, second) = makeEngine(screen: screen)
        engine.setSelectedNode(engine.findNode(for: second, in: ws), in: ws)

        XCTAssertTrue(engine.cycleSplitRatio(forward: true, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 0.6, accuracy: 1e-6)
        var frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[second]?.width ?? 0, 700, accuracy: 0.5)
        XCTAssertEqual(frames[first]?.width ?? 0, 300, accuracy: 0.5)

        XCTAssertTrue(engine.cycleSplitRatio(forward: false, in: ws))
        XCTAssertTrue(engine.cycleSplitRatio(forward: false, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.4, accuracy: 1e-6)
        frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[second]?.width ?? 0, 300, accuracy: 0.5)
    }

    func testVerticalSplitAppliesPresetToFocusedHeight() {
        let (engine, ws, _, second) = makeEngine(screen: screen)
        let third = WindowToken(pid: 3, windowId: 3)
        engine.setSelectedNode(engine.findNode(for: second, in: ws), in: ws)
        _ = engine.addWindow(token: third, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(engine.findNode(for: third, in: ws)?.parent?.splitOrientation, .vertical)
        engine.setSelectedNode(engine.findNode(for: third, in: ws), in: ws)

        XCTAssertTrue(engine.cycleSplitRatio(forward: true, in: ws))
        let frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[third]?.height ?? 0, 560, accuracy: 0.5)
        XCTAssertEqual(frames[second]?.height ?? 0, 240, accuracy: 0.5)
        XCTAssertEqual(frames[third]?.width ?? 0, 500, accuracy: 0.5)
    }

    func testSeedingUsesNearestPresetInFocusedSpace() {
        let (engine, ws, first, second) = makeEngine(screen: screen)
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertTrue(engine.resizeFocusedWindow(by: 0.25, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.25, accuracy: 1e-6)

        engine.setSelectedNode(engine.findNode(for: second, in: ws), in: ws)
        XCTAssertTrue(engine.cycleSplitRatio(forward: true, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.0, accuracy: 1e-6)
    }

    func testInnerGapKeepsPresetSharesOnNodeRects() {
        let (engine, ws, first, second) = makeEngine(screen: screen, innerGap: 20)
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)

        XCTAssertTrue(engine.cycleSplitRatio(forward: true, in: ws))
        let frames = engine.calculateLayout(for: ws, screen: screen)
        let firstFrame = frames[first] ?? .zero
        let secondFrame = frames[second] ?? .zero
        XCTAssertEqual(secondFrame.minX - firstFrame.maxX, 20, accuracy: 0.5)
        XCTAssertEqual(firstFrame.width + secondFrame.width + 20, 1000, accuracy: 0.5)
        XCTAssertGreaterThan(firstFrame.width, 2 * secondFrame.width)
    }

    func testMinimumWidthClampsPresetAndReportsNoChange() {
        let (engine, ws, first, second) = makeEngine(screen: screen)
        engine.updateWindowConstraints(
            for: second,
            constraints: WindowSizeConstraints(minSize: CGSize(width: 450, height: 0), maxSize: .zero, isFixed: false)
        )
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)

        XCTAssertTrue(engine.cycleSplitRatio(forward: true, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.1, accuracy: 1e-6)
        XCTAssertFalse(engine.cycleSplitRatio(forward: true, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.1, accuracy: 1e-6)
    }
}
