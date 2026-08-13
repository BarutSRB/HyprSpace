// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriColumnMinWidthTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let gaps: CGFloat = 12

    private func makeSingleWindowEngine() -> (NiriLayoutEngine, WorkspaceDescriptor.ID, WindowToken, NiriContainer) {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let column = engine.columns(in: workspaceId)[0]
        return (engine, workspaceId, token, column)
    }

    private func minConstraints(width: CGFloat = 1, height: CGFloat = 1) -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: CGSize(width: width, height: height),
            maxSize: .zero,
            isFixed: false
        )
    }

    func testBalanceSizesRespectsMinWidth() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800), in: workspaceId)

        XCTAssertTrue(
            engine.balanceSizes(
                in: workspaceId,
                motion: .disabled,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: .horizontal
            )
        )
        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testSetContainerPrimarySpanBelowMinSettlesAtMin() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800), in: workspaceId)
        var state = ViewportState()

        engine.setContainerPrimarySpan(
            column,
            change: .setFixed(200),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )

        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testTabbedFixedPrimarySpanUsesOuterContainerPixels() throws {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        let second = engine.addWindow(
            token: WindowToken(pid: 2, windowId: 2),
            to: workspaceId,
            afterSelection: nil
        )
        var state = ViewportState()
        XCTAssertTrue(
            engine.consumeWindow(
                second,
                into: column,
                enteringFrom: .right,
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: .horizontal
            )
        )
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        engine.renderStyle.tabIndicatorWidth = 30
        column.displayMode = .tabbed

        engine.setContainerPrimarySpan(
            column,
            change: .setFixed(500),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )

        let frame = try XCTUnwrap(
            engine.calculateLayout(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: workingFrame,
                gaps: (horizontal: gaps, vertical: gaps),
                orientation: .horizontal
            )[token]
        )

        XCTAssertEqual(column.width, .fixed(500))
        XCTAssertEqual(column.cachedWidth, 500, accuracy: 0.001)
        XCTAssertEqual(frame.width, 470, accuracy: 0.001)
    }

    func testTabbedFixedPrimarySpanPresetsCycleByOuterContainerPixels() {
        let (engine, workspaceId, _, column) = makeSingleWindowEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        engine.renderStyle.tabIndicatorWidth = 30
        engine.presetContainerPrimarySpans = [.fixed(480), .fixed(520)]
        column.displayMode = .tabbed
        column.width = .fixed(500)
        column.cachedWidth = 500
        column.presetWidthIdx = nil
        var state = ViewportState()

        engine.toggleContainerPrimarySpan(
            column,
            forwards: true,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )

        XCTAssertEqual(column.width, .fixed(520))
        XCTAssertEqual(column.cachedWidth, 520, accuracy: 0.001)
        XCTAssertEqual(column.presetWidthIdx, 1)
    }

    func testTabbedContentConstraintsIncludeRailInOuterWidth() throws {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        engine.renderStyle.tabIndicatorWidth = 30
        column.displayMode = .tabbed
        engine.updateWindowConstraints(
            for: token,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 400, height: 1),
                maxSize: CGSize(width: 600, height: 0),
                isFixed: false
            ),
            in: workspaceId
        )
        var state = ViewportState()

        engine.setContainerPrimarySpan(
            column,
            change: .setFixed(200),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )
        var frame = try XCTUnwrap(
            engine.calculateLayout(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: workingFrame,
                gaps: (horizontal: gaps, vertical: gaps),
                orientation: .horizontal
            )[token]
        )

        XCTAssertEqual(column.cachedWidth, 430, accuracy: 0.001)
        XCTAssertEqual(frame.width, 400, accuracy: 0.001)

        engine.setContainerPrimarySpan(
            column,
            change: .setFixed(900),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )
        frame = try XCTUnwrap(
            engine.calculateLayout(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: workingFrame,
                gaps: (horizontal: gaps, vertical: gaps),
                orientation: .horizontal
            )[token]
        )

        XCTAssertEqual(column.cachedWidth, 630, accuracy: 0.001)
        XCTAssertEqual(frame.width, 600, accuracy: 0.001)
    }

    func testEnteringTabbedModeReclampsCachedOuterWidth() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.renderStyle.tabIndicatorWidth = 30
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 400), in: workspaceId)
        column.width = .fixed(200)
        column.cachedWidth = 400

        XCTAssertTrue(
            engine.setColumnDisplay(
                .tabbed,
                for: column,
                in: workspaceId,
                motion: .disabled,
                orientation: .horizontal
            )
        )

        XCTAssertEqual(column.cachedWidth, 430, accuracy: 0.001)
    }

    func testTabbedConstraintArrivalReclampsOuterWidth() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.renderStyle.tabIndicatorWidth = 30
        column.displayMode = .tabbed
        column.cachedWidth = 500

        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 600), in: workspaceId)

        XCTAssertEqual(column.cachedWidth, 630, accuracy: 0.001)
    }

    func testOversizedMinWidthIsKeptBeyondWorkArea() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 2000), in: workspaceId)

        column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)

        XCTAssertEqual(column.cachedWidth, 2000, accuracy: 0.001)
    }

    func testToggleFullWidthRestoreRespectsMin() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800), in: workspaceId)
        var state = ViewportState()

        engine.toggleContainerFullPrimarySpan(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )
        XCTAssertGreaterThanOrEqual(column.cachedWidth, 800)

        engine.toggleContainerFullPrimarySpan(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )
        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testConstraintArrivalRetargetsActiveAnimationWithoutSnapping() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
        let widthBeforeConstraint = column.cachedWidth

        column.animateWidthTo(
            newWidth: 400,
            clock: nil,
            config: .niriWindowMovement,
            displayRefreshRate: 60,
            animated: true
        )
        XCTAssertEqual(column.targetWidth, 400)

        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800), in: workspaceId)

        XCTAssertEqual(column.targetWidth, 800)
        XCTAssertEqual(column.cachedWidth, widthBeforeConstraint, accuracy: 0.001)

        _ = column.tickWidthAnimation(at: CACurrentMediaTime() + 30)
        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testConstraintArrivalWithoutAnimationReclampsImmediately() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        column.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
        XCTAssertLessThan(column.cachedWidth, 800)

        engine.updateWindowConstraints(for: token, constraints: minConstraints(width: 800), in: workspaceId)

        XCTAssertNil(column.targetWidth)
        XCTAssertEqual(column.cachedWidth, 800, accuracy: 0.001)
    }

    func testTickFloorPreventsUndershootBelowMinClampedTarget() {
        var rawMinAcrossVelocities = CGFloat.greatestFiniteMagnitude
        for initialVelocity in [-8000.0, 8000.0] {
            let spring = SpringAnimation(
                from: 950,
                to: 800,
                initialVelocity: initialVelocity,
                startTime: 0,
                config: .niriWindowMovement,
                displayRefreshRate: 60
            )
            let (_, _, _, column) = makeSingleWindowEngine()
            column.cachedWidth = 950
            column.widthAnimation = spring
            column.targetWidth = 800

            var flooredMin = CGFloat.greatestFiniteMagnitude
            for tick in stride(from: 0.0, through: 1.0, by: 0.002) {
                rawMinAcrossVelocities = min(rawMinAcrossVelocities, CGFloat(spring.value(at: tick)))
                if column.widthAnimation != nil {
                    _ = column.tickWidthAnimation(at: tick)
                    flooredMin = min(flooredMin, column.cachedWidth)
                }
            }

            XCTAssertGreaterThanOrEqual(flooredMin, 800)
        }
        XCTAssertLessThan(rawMinAcrossVelocities, 800)
    }

    func testCachedHeightReclampedOnConstraintArrival() {
        let (engine, workspaceId, token, column) = makeSingleWindowEngine()
        column.cachedHeight = 300

        engine.updateWindowConstraints(for: token, constraints: minConstraints(height: 700), in: workspaceId)

        XCTAssertEqual(column.cachedHeight, 700, accuracy: 0.001)
    }
}
