// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriAxisSolverTests: XCTestCase {
    private func auto(weight: CGFloat = 1, min: CGFloat = 1, max: CGFloat = 0) -> NiriAxisSolver.Input {
        NiriAxisSolver.Input(
            weight: weight,
            minConstraint: min,
            maxConstraint: max,
            hasMaxConstraint: max > 0,
            isConstraintFixed: false,
            hasFixedValue: false,
            fixedValue: nil
        )
    }

    private func fixed(value: CGFloat, min: CGFloat = 1) -> NiriAxisSolver.Input {
        NiriAxisSolver.Input(
            weight: 1,
            minConstraint: min,
            maxConstraint: 0,
            hasMaxConstraint: false,
            isConstraintFixed: false,
            hasFixedValue: true,
            fixedValue: value
        )
    }

    func testFeasibleMinsArePinnedExactly() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 600), auto(min: 100)],
            availableSpace: 1000,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 600, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 400, accuracy: 0.001)
    }

    func testInfeasibleEqualMinsScaleProportionally() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 800), auto(min: 800)],
            availableSpace: 1000,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 500, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 500, accuracy: 0.001)
        XCTAssertTrue(outputs.allSatisfy(\.wasConstrained))
    }

    func testInfeasibleUnequalMinsPreserveRatioWithoutCollapse() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 900), auto(min: 300)],
            availableSpace: 800,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 600, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 200, accuracy: 0.001)
    }

    func testInfeasibleIgnoresFixedValues() {
        let outputs = NiriAxisSolver.solve(
            windows: [fixed(value: 900, min: 100), auto(min: 700)],
            availableSpace: 600,
            gapSize: 0
        )
        XCTAssertEqual(outputs[0].value, 75, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 525, accuracy: 0.001)
    }

    func testFeasibleFixedSurplusScalingKeepsEveryFixedTileAboveItsMin() {
        let outputs = NiriAxisSolver.solve(
            windows: [fixed(value: 900, min: 100), fixed(value: 300, min: 290)],
            availableSpace: 1000,
            gapSize: 0
        )
        XCTAssertGreaterThanOrEqual(outputs[0].value, 100)
        XCTAssertGreaterThanOrEqual(outputs[1].value, 290)
        XCTAssertEqual(outputs[0].value + outputs[1].value, 1000, accuracy: 0.01)
    }

    func testDegenerateSpaceKeepsOnePixelBackstop() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 500), auto(min: 500)],
            availableSpace: 0,
            gapSize: 0
        )
        XCTAssertTrue(outputs.allSatisfy { $0.value >= 1 })
    }

    func testTabbedOversizedMinOverflows() {
        let outputs = NiriAxisSolver.solve(
            windows: [auto(min: 2000), auto(min: 100)],
            availableSpace: 1000,
            gapSize: 0,
            isTabbed: true
        )
        XCTAssertEqual(outputs[0].value, 2000, accuracy: 0.001)
        XCTAssertEqual(outputs[1].value, 2000, accuracy: 0.001)
    }

    func testLayoutCacheInvalidatesWhenWindowConstraintsChange() throws {
        let fixture = try makeStackedEngine()
        let initialFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(initialFrames[fixture.first.token]).height, 400, accuracy: 0.001)

        fixture.engine.updateWindowConstraints(
            for: fixture.first.token,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 1, height: 600),
                maxSize: .zero,
                isFixed: false
            ),
            in: fixture.workspaceId
        )

        let constrainedFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(constrainedFrames[fixture.first.token]).height, 600, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(constrainedFrames[fixture.second.token]).height, 200, accuracy: 0.001)
    }

    func testLayoutCacheInvalidatesWhenSecondaryPresetsChange() throws {
        let fixture = try makeStackedEngine()
        fixture.first.height = .preset(0)
        fixture.engine.presetWindowSecondarySpans = [.proportion(0.25)]

        let proportionalFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(proportionalFrames[fixture.first.token]).height, 200, accuracy: 0.001)

        fixture.engine.presetWindowSecondarySpans = [.fixed(500)]

        let fixedFrames = layout(fixture)
        XCTAssertEqual(try XCTUnwrap(fixedFrames[fixture.first.token]).height, 500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fixedFrames[fixture.second.token]).height, 300, accuracy: 0.001)
    }

    func testLayoutCacheInvalidatesWhenProjectionMembershipChanges() throws {
        let fixture = try makeStackedEngine()
        _ = layout(fixture)

        let excludedFrames = fixture.engine.calculateLayout(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal,
            excludedTokens: [fixture.first.token]
        )

        XCTAssertNil(excludedFrames[fixture.first.token])
        XCTAssertEqual(try XCTUnwrap(excludedFrames[fixture.second.token]).height, 800, accuracy: 0.001)
    }

    func testLayoutCacheSeparatesOrientations() throws {
        let fixture = try makeStackedEngine()
        fixture.first.height = .fixed(200)
        fixture.first.windowWidth = .fixed(500)

        let horizontalFrames = layout(fixture)
        let verticalFrames = fixture.engine.calculateLayout(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )

        XCTAssertEqual(try XCTUnwrap(horizontalFrames[fixture.first.token]).height, 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(verticalFrames[fixture.first.token]).width, 500, accuracy: 0.001)
    }

    private func makeStackedEngine() throws -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        first: NiriWindow,
        second: NiriWindow
    ) {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = engine.addWindow(
            token: WindowToken(pid: 71_001, windowId: 1),
            to: workspaceId,
            afterSelection: nil
        )
        let second = engine.addWindow(
            token: WindowToken(pid: 71_002, windowId: 2),
            to: workspaceId,
            afterSelection: first.id
        )
        let column = try XCTUnwrap(engine.column(of: first))
        var state = ViewportState()
        XCTAssertTrue(
            engine.consumeWindow(
                second,
                into: column,
                enteringFrom: .down,
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                gaps: 0,
                orientation: .horizontal
            )
        )
        return (engine, workspaceId, state, first, second)
    }

    private func layout(
        _ fixture: (
            engine: NiriLayoutEngine,
            workspaceId: WorkspaceDescriptor.ID,
            state: ViewportState,
            first: NiriWindow,
            second: NiriWindow
        )
    ) -> [WindowToken: CGRect] {
        fixture.engine.calculateLayout(
            state: fixture.state,
            workspaceId: fixture.workspaceId,
            monitorFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal
        )
    }
}
