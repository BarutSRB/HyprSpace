// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleMinimumSizeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func minConstraints(width: CGFloat = 1, height: CGFloat = 1) -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: CGSize(width: width, height: height),
            maxSize: .zero,
            isFixed: false
        )
    }

    private func makeTwoWindowEngine(
        firstMinWidth: CGFloat = 1,
        secondMinWidth: CGFloat = 1,
        innerGap: CGFloat = 8
    ) -> (DwindleLayoutEngine, WorkspaceDescriptor.ID, WindowToken, WindowToken) {
        let engine = DwindleLayoutEngine()
        engine.settings.innerGap = innerGap
        let ws = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: ws, activeWindowFrame: nil)
        engine.updateWindowConstraints(for: first, constraints: minConstraints(width: firstMinWidth))
        engine.updateWindowConstraints(for: second, constraints: minConstraints(width: secondMinWidth))
        _ = engine.calculateLayout(for: ws, screen: screen)
        return (engine, ws, first, second)
    }

    func testMinWidthRespectedInLayout() {
        let (engine, ws, first, second) = makeTwoWindowEngine(firstMinWidth: 600)
        let frames = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertEqual(frames[first]?.width ?? 0, 600, accuracy: 0.5)
        XCTAssertEqual(frames[second]?.width ?? 0, 392, accuracy: 0.5)
    }

    func testResizeCommandStopsAtMinFeasibleBoundary() {
        let (engine, ws, first, second) = makeTwoWindowEngine(secondMinWidth: 300)
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)

        var changed = true
        for _ in 0 ..< 100 where changed {
            changed = engine.resizeFocusedWindow(by: 0.1, in: ws)
        }

        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.392, accuracy: 1e-6)
        XCTAssertFalse(engine.resizeFocusedWindow(by: 0.1, in: ws))

        let frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[second]?.width ?? 0, 300, accuracy: 0.5)
    }

    func testInteractiveDragStopsAtMinWithoutPhantomTravel() {
        let (engine, ws, first, second) = makeTwoWindowEngine(secondMinWidth: 300)
        let start = CGPoint(x: 500, y: 400)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: first,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 5000, y: start.y)))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.392, accuracy: 1e-6)

        let frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[second]?.width ?? 0, 300, accuracy: 0.5)

        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y)))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.2, accuracy: 1e-6)
        XCTAssertTrue(engine.interactiveResizeEnd())
    }

    func testInteractiveDragUsesCapturedGap() {
        let (engine, ws, first, _) = makeTwoWindowEngine(secondMinWidth: 300, innerGap: 4)
        let start = CGPoint(x: 500, y: 400)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: first,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        engine.settings.innerGap = 24

        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 5000, y: start.y)))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.396, accuracy: 1e-6)
    }

    func testInfeasibleMinsDegradeProportionallyAndResizeStops() {
        let (engine, ws, first, second) = makeTwoWindowEngine(firstMinWidth: 700, secondMinWidth: 600)
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)

        XCTAssertFalse(engine.resizeFocusedWindow(by: 0.1, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.0, accuracy: 1e-6)

        let frames = engine.calculateLayout(for: ws, screen: screen)
        let firstWidth = frames[first]?.width ?? 0
        let secondWidth = frames[second]?.width ?? 0
        XCTAssertEqual(firstWidth, 1000 * 704 / 1308 - 4, accuracy: 0.5)
        XCTAssertEqual(secondWidth, 1000 * 604 / 1308 - 4, accuracy: 0.5)
        XCTAssertLessThan(firstWidth, 700)
        XCTAssertLessThan(secondWidth, 600)
    }

    func testNestedSplitGapInsetsDoNotEatIntoMin() {
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()
        let tokenC = WindowToken(pid: 1, windowId: 1)
        let tokenA = WindowToken(pid: 2, windowId: 2)
        let tokenB = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: tokenC, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: tokenA, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: tokenB, to: ws, activeWindowFrame: nil)
        engine.updateWindowConstraints(for: tokenA, constraints: minConstraints(width: 500))

        let frames = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertEqual(frames[tokenA]?.width ?? 0, 500, accuracy: 0.5)
    }

    func testBalanceSizesClampsToMinFeasibleRatio() {
        let (engine, ws, first, _) = makeTwoWindowEngine(firstMinWidth: 700)
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertTrue(engine.resizeFocusedWindow(by: 0.1, in: ws))
        XCTAssertTrue(engine.resizeFocusedWindow(by: 0.1, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.508, accuracy: 1e-6)

        XCTAssertTrue(engine.balanceSizes(in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.408, accuracy: 1e-6)

        let frames = engine.calculateLayout(for: ws, screen: screen)
        XCTAssertEqual(frames[first]?.width ?? 0, 700, accuracy: 0.5)

        XCTAssertFalse(engine.balanceSizes(in: ws))
    }

    func testCycleSplitRatioClampsAndStops() {
        let (engine, ws, first, _) = makeTwoWindowEngine(firstMinWidth: 600)
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)

        XCTAssertTrue(engine.cycleSplitRatio(forward: false, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.208, accuracy: 1e-6)

        XCTAssertFalse(engine.cycleSplitRatio(forward: false, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.208, accuracy: 1e-6)
    }

    func testRenderClampActsAsSafetyNetWithoutMutation() {
        let (engine, ws, first, _) = makeTwoWindowEngine()
        engine.updateWindowConstraints(for: first, constraints: minConstraints(width: 600))

        let frames = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertEqual(frames[first]?.width ?? 0, 600, accuracy: 0.5)
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.0, accuracy: 1e-6)
    }

    private func makeSingleWindowEngine(
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> (DwindleLayoutEngine, WorkspaceDescriptor.ID, WindowToken) {
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: token, to: ws, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: token,
            constraints: minConstraints(width: minWidth, height: minHeight)
        )
        return (engine, ws, token)
    }

    func testSingleWindowCustomFitIsFlooredToMin() {
        let (engine, ws, token) = makeSingleWindowEngine(minWidth: 600, minHeight: 500)
        engine.settings.singleWindowFit = SingleWindowFit(mode: .custom, width: 400, height: 300)

        let frame = engine.calculateLayout(for: ws, screen: screen)[token]

        XCTAssertEqual(frame?.width ?? 0, 600, accuracy: 0.5)
        XCTAssertEqual(frame?.height ?? 0, 500, accuracy: 0.5)
        XCTAssertEqual(screen.contains(frame ?? .zero), true)
    }

    func testSingleWindowOversizedMinStaysInsideWorkArea() {
        let (engine, ws, token) = makeSingleWindowEngine(minWidth: 1300, minHeight: 900)
        engine.settings.singleWindowFit = SingleWindowFit(mode: .custom, width: 400, height: 300)

        let frame = engine.calculateLayout(for: ws, screen: screen)[token]

        XCTAssertEqual(frame, screen)
    }

    func testSingleWindowFullScreenFitUnchangedByFittingMin() {
        let (engine, ws, token) = makeSingleWindowEngine(minWidth: 200, minHeight: 200)

        let frame = engine.calculateLayout(for: ws, screen: screen)[token]

        XCTAssertEqual(frame, screen)
    }

    func testCalculationSettingsDoNotMutateStoredSettings() {
        let (engine, ws, token) = makeSingleWindowEngine(minWidth: 200, minHeight: 200)
        var calculationSettings = engine.settings
        calculationSettings.singleWindowFit = SingleWindowFit(mode: .custom, width: 600, height: 500)

        let customFrame = engine.calculateLayout(
            for: ws,
            screen: screen,
            calculationSettings: calculationSettings
        )[token]
        let storedFrame = engine.calculateLayout(for: ws, screen: screen)[token]

        XCTAssertEqual(customFrame?.size, CGSize(width: 600, height: 500))
        XCTAssertEqual(storedFrame, screen)
        XCTAssertEqual(engine.settings.singleWindowFit, .fullScreen)
    }
}
