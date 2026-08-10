// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleResizeSelectedTests: XCTestCase {
    private struct TwoWindowFixture {
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let first: WindowToken
        let second: WindowToken
    }

    private enum SelectedChild {
        case first
        case second
    }

    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func makeTwoWindowEngine(orientation: DwindleOrientation) -> TwoWindowFixture {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        if orientation == .vertical {
            XCTAssertTrue(engine.setPreselection(.up, in: workspaceId))
        }
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        XCTAssertEqual(engine.root(for: workspaceId)?.splitOrientation, orientation)
        return TwoWindowFixture(
            engine: engine,
            workspaceId: workspaceId,
            first: first,
            second: second
        )
    }

    private func assertResize(
        orientation: DwindleOrientation,
        delta: CGFloat,
        selectedChild: SelectedChild,
        expectedRatio: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fixture = makeTwoWindowEngine(orientation: orientation)
        let selected = selectedChild == .first ? fixture.first : fixture.second
        fixture.engine.setSelectedNode(
            fixture.engine.findNode(for: selected, in: fixture.workspaceId),
            in: fixture.workspaceId
        )

        XCTAssertTrue(
            fixture.engine.resizeSelected(
                by: delta,
                orientation: orientation,
                in: fixture.workspaceId
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.engine.root(for: fixture.workspaceId)?.splitRatio ?? 0,
            expectedRatio,
            accuracy: 1e-6,
            file: file,
            line: line
        )
    }

    func testHorizontalGrowNormalizesForSelectedChild() {
        assertResize(orientation: .horizontal, delta: 0.1, selectedChild: .first, expectedRatio: 1.1)
        assertResize(orientation: .horizontal, delta: 0.1, selectedChild: .second, expectedRatio: 0.9)
    }

    func testHorizontalShrinkNormalizesForSelectedChild() {
        assertResize(orientation: .horizontal, delta: -0.1, selectedChild: .first, expectedRatio: 0.9)
        assertResize(orientation: .horizontal, delta: -0.1, selectedChild: .second, expectedRatio: 1.1)
    }

    func testVerticalGrowNormalizesForSelectedChild() {
        assertResize(orientation: .vertical, delta: 0.1, selectedChild: .first, expectedRatio: 1.1)
        assertResize(orientation: .vertical, delta: 0.1, selectedChild: .second, expectedRatio: 0.9)
    }

    func testVerticalShrinkNormalizesForSelectedChild() {
        assertResize(orientation: .vertical, delta: -0.1, selectedChild: .first, expectedRatio: 0.9)
        assertResize(orientation: .vertical, delta: -0.1, selectedChild: .second, expectedRatio: 1.1)
    }

    func testMissingMatchingAxisReturnsFalse() {
        let fixture = makeTwoWindowEngine(orientation: .horizontal)
        fixture.engine.setSelectedNode(
            fixture.engine.findNode(for: fixture.first, in: fixture.workspaceId),
            in: fixture.workspaceId
        )

        XCTAssertFalse(
            fixture.engine.resizeSelected(
                by: 0.1,
                orientation: .vertical,
                in: fixture.workspaceId
            )
        )
        XCTAssertEqual(fixture.engine.root(for: fixture.workspaceId)?.splitRatio ?? 0, 1.0, accuracy: 1e-6)
    }

    func testSingleWindowReturnsFalse() {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let window = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: window, to: workspaceId, activeWindowFrame: nil)

        XCTAssertFalse(engine.resizeSelected(by: 0.1, orientation: .horizontal, in: workspaceId))
    }

    func testAxisResizeSkipsNearerPerpendicularSplit() throws {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        let third = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        engine.setSelectedNode(engine.findNode(for: first, in: workspaceId), in: workspaceId)
        XCTAssertTrue(engine.setPreselection(.up, in: workspaceId))
        _ = engine.addWindow(token: third, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        engine.setSelectedNode(engine.findNode(for: first, in: workspaceId), in: workspaceId)

        let root = try XCTUnwrap(engine.root(for: workspaceId))
        let nearerSplit = try XCTUnwrap(engine.findNode(for: first, in: workspaceId)?.parent)
        XCTAssertEqual(root.splitOrientation, .horizontal)
        XCTAssertEqual(nearerSplit.splitOrientation, .vertical)

        XCTAssertTrue(engine.resizeSelected(by: 0.1, orientation: .horizontal, in: workspaceId))
        XCTAssertEqual(root.splitRatio ?? 0, 1.1, accuracy: 1e-6)
        XCTAssertEqual(nearerSplit.splitRatio ?? 0, 1.0, accuracy: 1e-6)

        XCTAssertTrue(engine.resizeFocusedWindow(by: 0.1, in: workspaceId))
        XCTAssertEqual(root.splitRatio ?? 0, 1.1, accuracy: 1e-6)
        XCTAssertEqual(nearerSplit.splitRatio ?? 0, 1.1, accuracy: 1e-6)
    }
}
