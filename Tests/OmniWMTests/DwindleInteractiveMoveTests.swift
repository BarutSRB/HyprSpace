// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleInteractiveMoveTests: XCTestCase {
    private var engine: DwindleLayoutEngine!
    private let workspaceId = WorkspaceDescriptor.ID()
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    override func setUp() {
        super.setUp()
        engine = DwindleLayoutEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    func testInteractiveMoveSwapsTileNodesAndCachedFramesInTwoWindowTree() throws {
        let t1 = WindowToken(pid: 1, windowId: 101)
        let t2 = WindowToken(pid: 1, windowId: 102)

        _ = engine.addWindow(token: t1, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: t2, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        let node1Before = try XCTUnwrap(engine.findNode(for: t1, in: workspaceId))
        let node2Before = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))
        let frame1Before: CGRect = try XCTUnwrap(node1Before.cachedFrame)
        let frame2Before: CGRect = try XCTUnwrap(node2Before.cachedFrame)

        // Begin interactive move on t1
        let startLocation = CGPoint(x: frame1Before.midX, y: frame1Before.midY)
        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: startLocation, in: workspaceId))

        // Hover over t2
        let hoverLocation = CGPoint(x: frame2Before.midX, y: frame2Before.midY)
        let targetHover = engine.interactiveMoveUpdate(currentLocation: hoverLocation)
        XCTAssertEqual(targetHover?.targetToken, t2)

        // End interactive move at t2's location
        let result = engine.interactiveMoveEnd(at: hoverLocation)
        let (movedToken, targetToken) = try XCTUnwrap(result)
        XCTAssertEqual(movedToken, t1)
        XCTAssertEqual(targetToken, t2)

        let node1After = try XCTUnwrap(engine.findNode(for: t1, in: workspaceId))
        let node2After = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))

        // Verify that tokens swapped nodes
        XCTAssertEqual(node1After.id, node2Before.id)
        XCTAssertEqual(node2After.id, node1Before.id)

        // Verify that cachedFrames swapped for smooth animation interpolation
        XCTAssertEqual(node1After.cachedFrame, frame1Before)
        XCTAssertEqual(node2After.cachedFrame, frame2Before)
    }

    func testInteractiveMoveSwapsTileNodesInFourWindowDwindleTree() throws {
        let tokens = (1...4).map { WindowToken(pid: 2, windowId: 200 + $0) }
        for t in tokens {
            _ = engine.addWindow(token: t, to: workspaceId, activeWindowFrame: nil)
        }
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        let firstNode = try XCTUnwrap(engine.findNode(for: tokens[0], in: workspaceId))
        let fourthNode = try XCTUnwrap(engine.findNode(for: tokens[3], in: workspaceId))
        let firstFrame: CGRect = try XCTUnwrap(firstNode.cachedFrame)
        let fourthFrame: CGRect = try XCTUnwrap(fourthNode.cachedFrame)

        let startLoc = CGPoint(x: firstFrame.midX, y: firstFrame.midY)
        let targetLoc = CGPoint(x: fourthFrame.midX, y: fourthFrame.midY)

        XCTAssertTrue(engine.interactiveMoveBegin(token: tokens[0], startLocation: startLoc, in: workspaceId))
        _ = engine.interactiveMoveUpdate(currentLocation: targetLoc)

        let result = engine.interactiveMoveEnd(at: targetLoc)
        let (moved, target) = try XCTUnwrap(result)
        XCTAssertEqual(moved, tokens[0])
        XCTAssertEqual(target, tokens[3])

        // Verify tree integrity: all 4 tokens present in distinct leaf nodes
        let newFirstNode = try XCTUnwrap(engine.findNode(for: tokens[0], in: workspaceId))
        let newFourthNode = try XCTUnwrap(engine.findNode(for: tokens[3], in: workspaceId))
        XCTAssertEqual(newFirstNode.id, fourthNode.id)
        XCTAssertEqual(newFourthNode.id, firstNode.id)
    }

    func testExternalFrameChangeTranslationConfirmsFrameWithoutMutatingSplits() throws {
        let t1 = WindowToken(pid: 3, windowId: 301)
        let t2 = WindowToken(pid: 3, windowId: 302)
        _ = engine.addWindow(token: t1, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: t2, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        let rootBefore = try XCTUnwrap(engine.root(for: workspaceId))
        let ratioBefore = rootBefore.splitRatio

        let node1 = try XCTUnwrap(engine.findNode(for: t1, in: workspaceId))
        let oldFrame: CGRect = try XCTUnwrap(node1.cachedFrame)

        // Simulate pure window translation (e.g. dragged 100px to the right)
        let translatedFrame = oldFrame.offsetBy(dx: 100, dy: 0)

        // handleExternalFrameChange should return true (confirming frame update) and NOT touch splitRatio
        let changed = engine.handleExternalFrameChange(
            for: t1,
            in: workspaceId,
            oldFrame: oldFrame,
            newFrame: translatedFrame,
            innerGap: 10
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(rootBefore.splitRatio, ratioBefore)
        XCTAssertEqual(node1.cachedFrame, translatedFrame)
    }

    func testExternalFrameChangeTranslationRelocatesWindowWhenLandingOnTargetWindow() throws {
        let t1 = WindowToken(pid: 6, windowId: 601)
        let t2 = WindowToken(pid: 6, windowId: 602)
        _ = engine.addWindow(token: t1, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: t2, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        let node1Before = try XCTUnwrap(engine.findNode(for: t1, in: workspaceId))
        let node2Before = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))
        let frame1Before: CGRect = try XCTUnwrap(node1Before.cachedFrame)
        let frame2Before: CGRect = try XCTUnwrap(node2Before.cachedFrame)

        // Simulate dragging t1 natively until its center lands on t2's tile frame
        let t1DraggedFrame = CGRect(
            origin: CGPoint(x: frame2Before.minX, y: frame2Before.minY),
            size: frame1Before.size
        )

        let changed = engine.handleExternalFrameChange(
            for: t1,
            in: workspaceId,
            oldFrame: frame1Before,
            newFrame: t1DraggedFrame,
            innerGap: 10
        )

        XCTAssertTrue(changed)

        let node1After = try XCTUnwrap(engine.findNode(for: t1, in: workspaceId))
        let node2After = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))

        // Verify that tokens swapped leaf nodes in Dwindle layout
        XCTAssertEqual(node1After.id, node2Before.id)
        XCTAssertEqual(node2After.id, node1Before.id)
    }

    func testExternalFrameChangeOnlyResizesBorderEdgeMoves() throws {
        let t1 = WindowToken(pid: 4, windowId: 401)
        let t2 = WindowToken(pid: 4, windowId: 402)
        _ = engine.addWindow(token: t1, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: t2, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        let rootBefore = try XCTUnwrap(engine.root(for: workspaceId))
        let ratioBefore: CGFloat = try XCTUnwrap(rootBefore.splitRatio)

        let node1 = try XCTUnwrap(engine.findNode(for: t1, in: workspaceId))
        let oldFrame: CGRect = try XCTUnwrap(node1.cachedFrame)

        // Simulate dragging RIGHT edge of node1 outwards by 50px (width changes, minX stays fixed)
        let resizedFrame = CGRect(x: oldFrame.minX, y: oldFrame.minY, width: oldFrame.width + 50, height: oldFrame.height)

        let changed = engine.handleExternalFrameChange(
            for: t1,
            in: workspaceId,
            oldFrame: oldFrame,
            newFrame: resizedFrame,
            innerGap: 10
        )

        XCTAssertTrue(changed)
        XCTAssertNotEqual(rootBefore.splitRatio, ratioBefore)
    }

    func testInteractiveMoveCancelResetsMoveState() throws {
        let t1 = WindowToken(pid: 5, windowId: 501)
        _ = engine.addWindow(token: t1, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: .zero, in: workspaceId))
        XCTAssertNotNil(engine.interactiveMove)

        engine.interactiveMoveCancel()
        XCTAssertNil(engine.interactiveMove)
    }

    func testDirectionalGridSplitDropzone() throws {
        let t1 = WindowToken(pid: 6, windowId: 601)
        let t2 = WindowToken(pid: 6, windowId: 602)
        _ = engine.addWindow(token: t1, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: t2, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        let node2 = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))
        let frame2 = try XCTUnwrap(node2.cachedFrame)

        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame2.center, in: workspaceId))

        let topLocation = CGPoint(x: frame2.midX, y: frame2.maxY - 10)
        let action = try XCTUnwrap(engine.interactiveMoveUpdate(currentLocation: topLocation))

        if case let .split(targetToken, direction, _, _) = action {
            XCTAssertEqual(targetToken, t2)
            XCTAssertEqual(direction, .up)
        } else {
            XCTFail("Expected .split action for top hover")
        }

        let result = engine.interactiveMoveEnd(at: topLocation)
        XCTAssertNotNil(result)
    }

    func testInternalWindowSplitHighlightFramesForAllEdges() throws {
        let t1 = WindowToken(pid: 7, windowId: 701)
        let t2 = WindowToken(pid: 7, windowId: 702)
        _ = engine.addWindow(token: t1, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: t2, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        let node2 = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))
        let frame2 = try XCTUnwrap(node2.cachedFrame)

        // Test Top Hover (Internal Split Up)
        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: frame2.center, in: workspaceId))
        let topLoc = CGPoint(x: frame2.midX, y: frame2.maxY - 10)
        let topAction = try XCTUnwrap(engine.interactiveMoveUpdate(currentLocation: topLoc))
        if case let .split(targetToken, direction, isOuterEdge, highlightFrame) = topAction {
            XCTAssertEqual(targetToken, t2)
            XCTAssertEqual(direction, .up)
            XCTAssertFalse(isOuterEdge)
            let expectedFrame = CGRect(x: frame2.minX, y: frame2.minY + frame2.height / 2, width: frame2.width, height: frame2.height / 2)
            XCTAssertEqual(highlightFrame, expectedFrame)
        } else {
            XCTFail("Expected .split up for top hover")
        }
        _ = engine.interactiveMoveEnd(at: topLoc)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        // Test Bottom Hover (Internal Split Down)
        let refreshedNode2 = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))
        let refreshedFrame2 = try XCTUnwrap(refreshedNode2.cachedFrame)
        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: refreshedFrame2.center, in: workspaceId))
        let bottomLoc = CGPoint(x: refreshedFrame2.midX, y: refreshedFrame2.minY + 10)
        let bottomAction = try XCTUnwrap(engine.interactiveMoveUpdate(currentLocation: bottomLoc))
        if case let .split(targetToken, direction, isOuterEdge, highlightFrame) = bottomAction {
            XCTAssertEqual(targetToken, t2)
            XCTAssertEqual(direction, .down)
            XCTAssertFalse(isOuterEdge)
            let expectedFrame = CGRect(x: refreshedFrame2.minX, y: refreshedFrame2.minY, width: refreshedFrame2.width, height: refreshedFrame2.height / 2)
            XCTAssertEqual(highlightFrame, expectedFrame)
        } else {
            XCTFail("Expected .split down for bottom hover")
        }
        _ = engine.interactiveMoveEnd(at: bottomLoc)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        // Test Left Hover (Internal Split Left)
        let n2Left = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))
        let f2Left = try XCTUnwrap(n2Left.cachedFrame)
        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: f2Left.center, in: workspaceId))
        let leftLoc = CGPoint(x: f2Left.minX + 10, y: f2Left.midY)
        let leftAction = try XCTUnwrap(engine.interactiveMoveUpdate(currentLocation: leftLoc))
        if case let .split(targetToken, direction, isOuterEdge, highlightFrame) = leftAction {
            XCTAssertEqual(targetToken, t2)
            XCTAssertEqual(direction, .left)
            XCTAssertFalse(isOuterEdge)
            let expectedFrame = CGRect(x: f2Left.minX, y: f2Left.minY, width: f2Left.width / 2, height: f2Left.height)
            XCTAssertEqual(highlightFrame, expectedFrame)
        } else {
            XCTFail("Expected .split left for left hover")
        }
        _ = engine.interactiveMoveEnd(at: leftLoc)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        // Test Right Hover (Internal Split Right)
        let n2Right = try XCTUnwrap(engine.findNode(for: t2, in: workspaceId))
        let f2Right = try XCTUnwrap(n2Right.cachedFrame)
        XCTAssertTrue(engine.interactiveMoveBegin(token: t1, startLocation: f2Right.center, in: workspaceId))
        let rightLoc = CGPoint(x: f2Right.maxX - 10, y: f2Right.midY)
        let rightAction = try XCTUnwrap(engine.interactiveMoveUpdate(currentLocation: rightLoc))
        if case let .split(targetToken, direction, isOuterEdge, highlightFrame) = rightAction {
            XCTAssertEqual(targetToken, t2)
            XCTAssertEqual(direction, .right)
            XCTAssertFalse(isOuterEdge)
            let expectedFrame = CGRect(x: f2Right.midX, y: f2Right.minY, width: f2Right.width / 2, height: f2Right.height)
            XCTAssertEqual(highlightFrame, expectedFrame)
        } else {
            XCTFail("Expected .split right for right hover")
        }
        _ = engine.interactiveMoveEnd(at: rightLoc)
    }
}

