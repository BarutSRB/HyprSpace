// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleInteractiveResizeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let start = CGPoint(x: 100, y: 100)

    private func makeEngine() -> (DwindleLayoutEngine, WorkspaceDescriptor.ID) {
        (DwindleLayoutEngine(), WorkspaceDescriptor.ID())
    }

    func testHorizontalRightEdgeGrowsControllingSplit() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(engine.root(for: ws)?.splitOrientation, .horizontal)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y)))

        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.2, accuracy: 1e-6)
    }

    func testHorizontalRatioClampsAtMax() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 5000, y: start.y)))

        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.9, accuracy: 1e-6)
    }

    func testVerticalTopEdgeGrowsControllingSplit() {
        let (engine, ws) = makeEngine()
        let bottom = WindowToken(pid: 1, windowId: 1)
        let top = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: bottom, to: ws, activeWindowFrame: nil)
        engine.setPreselection(.up, in: ws)
        _ = engine.addWindow(token: top, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(engine.root(for: ws)?.splitOrientation, .vertical)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: bottom,
                edges: [.top],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x, y: start.y + 80)))

        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.2, accuracy: 1e-6)
    }

    func testCornerDragResizesBothAxes() {
        let (engine, ws) = makeEngine()
        let leaf1 = WindowToken(pid: 1, windowId: 1)
        let other = WindowToken(pid: 2, windowId: 2)
        let leaf3 = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: leaf1, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: other, to: ws, activeWindowFrame: nil)
        engine.setSelectedNode(engine.findNode(for: leaf1, in: ws), in: ws)
        engine.setPreselection(.up, in: ws)
        _ = engine.addWindow(token: leaf3, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        let verticalSplit = engine.findNode(for: leaf1, in: ws)?.parent
        let horizontalSplit = engine.root(for: ws)
        XCTAssertEqual(verticalSplit?.splitOrientation, .vertical)
        XCTAssertEqual(horizontalSplit?.splitOrientation, .horizontal)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: leaf1,
                edges: [.right, .top],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y + 80))
        )

        XCTAssertEqual(horizontalSplit?.splitRatio ?? 0, 1.2, accuracy: 1e-6)
        XCTAssertEqual(verticalSplit?.splitRatio ?? 0, 1.2, accuracy: 1e-6)
    }

    func testEdgeAtScreenBoundaryIsNotResizable() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertFalse(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.left],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertNil(engine.interactiveResize)
    }

    func testEndWithoutMovementReportsNoChange() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertFalse(engine.interactiveResizeEnd())
        XCTAssertNil(engine.interactiveResize)
    }

    func testWindowRemovedMidGestureAborts() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        engine.removeWindow(token: left, from: ws)

        XCTAssertFalse(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y)))
        XCTAssertNil(engine.interactiveResize)
    }

    func testTopologyChangeSkipsAxisOnIdentityMismatch() {
        let (engine, ws) = makeEngine()
        let outer = WindowToken(pid: 3, windowId: 3)
        let leaf1 = WindowToken(pid: 1, windowId: 1)
        let leaf2 = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: outer, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: leaf1, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: leaf2, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        let innerSplit = engine.findNode(for: leaf1, in: ws)?.parent
        XCTAssertEqual(innerSplit?.splitOrientation, .horizontal)
        XCTAssertNotEqual(innerSplit?.id, engine.root(for: ws)?.id)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: leaf1,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )

        engine.removeWindow(token: outer, from: ws)
        let collapsedRoot = engine.root(for: ws)
        XCTAssertEqual(collapsedRoot?.splitOrientation, .horizontal)
        XCTAssertEqual(engine.findNode(for: leaf1, in: ws)?.isFirstChild(of: collapsedRoot!), true)

        XCTAssertFalse(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y)))
        XCTAssertEqual(collapsedRoot?.splitRatio ?? 0, 1.0, accuracy: 1e-6)
        XCTAssertNotNil(engine.findNode(for: leaf1, in: ws))
    }

    func testExternalFrameChangeUpdatesControllingSplitForEitherSibling() throws {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        let frames = engine.calculateLayout(for: ws, screen: screen)
        let leftFrame = try XCTUnwrap(frames[left])
        let rightFrame = try XCTUnwrap(frames[right])

        XCTAssertTrue(
            engine.handleExternalFrameChange(
                for: left,
                in: ws,
                oldFrame: leftFrame,
                newFrame: CGRect(
                    origin: leftFrame.origin,
                    size: CGSize(width: leftFrame.width + 100, height: leftFrame.height)
                ),
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.2, accuracy: 1e-6)

        XCTAssertTrue(
            engine.handleExternalFrameChange(
                for: right,
                in: ws,
                oldFrame: rightFrame,
                newFrame: CGRect(
                    origin: CGPoint(x: rightFrame.origin.x + 100, y: rightFrame.origin.y),
                    size: CGSize(width: rightFrame.width - 100, height: rightFrame.height)
                ),
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.4, accuracy: 1e-6)
    }

    func testExternalCornerFrameChangeUpdatesBothAxes() throws {
        let (engine, ws) = makeEngine()
        let leaf = WindowToken(pid: 1, windowId: 1)
        let other = WindowToken(pid: 2, windowId: 2)
        let top = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: leaf, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: other, to: ws, activeWindowFrame: nil)
        engine.setSelectedNode(engine.findNode(for: leaf, in: ws), in: ws)
        engine.setPreselection(.up, in: ws)
        _ = engine.addWindow(token: top, to: ws, activeWindowFrame: nil)
        let frames = engine.calculateLayout(for: ws, screen: screen)
        let oldFrame = try XCTUnwrap(frames[leaf])

        XCTAssertTrue(
            engine.handleExternalFrameChange(
                for: leaf,
                in: ws,
                oldFrame: oldFrame,
                newFrame: CGRect(
                    origin: oldFrame.origin,
                    size: CGSize(width: oldFrame.width + 100, height: oldFrame.height + 80)
                ),
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.2, accuracy: 1e-6)
        XCTAssertEqual(
            engine.findNode(for: leaf, in: ws)?.parent?.splitRatio ?? 0,
            1.2,
            accuracy: 1e-6
        )
    }
}
