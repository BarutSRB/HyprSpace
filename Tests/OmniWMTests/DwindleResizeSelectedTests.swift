// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleResizeSelectedTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func makeTwoWindowEngine() -> (DwindleLayoutEngine, WorkspaceDescriptor.ID, WindowToken, WindowToken) {
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)
        return (engine, ws, first, second)
    }

    func testGrowRightOnFirstChildIncreasesRatio() {
        let (engine, ws, first, _) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertTrue(engine.resizeSelected(by: 0.1, direction: .right, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.1, accuracy: 1e-6)
    }

    func testGrowRightOnSecondChildDecreasesRatio() {
        let (engine, ws, _, second) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: second, in: ws), in: ws)
        XCTAssertTrue(engine.resizeSelected(by: 0.1, direction: .right, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 0.9, accuracy: 1e-6)
    }

    func testShrinkRightOnFirstChildDecreasesRatio() {
        let (engine, ws, first, _) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertTrue(engine.resizeSelected(by: -0.1, direction: .right, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 0.9, accuracy: 1e-6)
    }

    func testGrowLeftOnFirstChildAlsoIncreasesRatio() {
        let (engine, ws, first, _) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertTrue(engine.resizeSelected(by: 0.1, direction: .left, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.1, accuracy: 1e-6)
    }

    func testVerticalDirectionFindsNoHorizontalSplitAndReturnsFalse() {
        let (engine, ws, first, _) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertFalse(engine.resizeSelected(by: 0.1, direction: .up, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.0, accuracy: 1e-6)
    }
}
