// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class NiriSettledCoverageTests: NiriInteractionTestCase {
    private let sourceFrame = CGRect(x: 0, y: 0, width: 1_440, height: 2_560)
    private let traceWorkingFrame = CGRect(x: 16, y: 16, width: 1_408, height: 2_498)

    func testTraceGeometrySelectsTrailingFitAndIsIdempotent() {
        let source = monitorContext(
            displayId: 3,
            frame: sourceFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 2_530)
        )
        let upperNeighbor = monitorContext(
            displayId: 5,
            frame: CGRect(x: 328, y: 2_560, width: 1_920, height: 1_080)
        )
        let input = NiriSettledCoverageEvaluator.Input(
            containerSpans: [1_581, 1_581, 1_241, 1_581],
            selectedIndex: 2,
            activeIndex: 2,
            semanticOffset: -16,
            gap: 16,
            workingFrame: traceWorkingFrame,
            sourceMonitor: source,
            monitors: [source, upperNeighbor],
            orientation: .vertical,
            scale: 2
        )

        let recovered = NiriSettledCoverageEvaluator.bestOffset(for: input)

        XCTAssertEqual(recovered, -1_241, accuracy: 0.001)
        XCTAssertEqual(
            NiriSettledCoverageEvaluator.bestOffset(
                for: .init(
                    containerSpans: input.containerSpans,
                    selectedIndex: input.selectedIndex,
                    activeIndex: input.activeIndex,
                    semanticOffset: recovered,
                    gap: input.gap,
                    workingFrame: input.workingFrame,
                    sourceMonitor: input.sourceMonitor,
                    monitors: input.monitors,
                    orientation: input.orientation,
                    scale: input.scale
                )
            ),
            recovered,
            accuracy: 0.001
        )
    }

    func testMirroredLowerNeighborSelectsLeadingFit() {
        let source = monitorContext(displayId: 10, frame: sourceFrame)
        let lowerNeighbor = monitorContext(
            displayId: 11,
            frame: CGRect(x: 328, y: -1_080, width: 1_920, height: 1_080)
        )

        let recovered = NiriSettledCoverageEvaluator.bestOffset(
            for: .init(
                containerSpans: [1_581, 1_241, 1_581],
                selectedIndex: 1,
                activeIndex: 1,
                semanticOffset: -1_241,
                gap: 16,
                workingFrame: traceWorkingFrame,
                sourceMonitor: source,
                monitors: [source, lowerNeighbor],
                orientation: .vertical,
                scale: 2
            )
        )

        XCTAssertEqual(recovered, -16, accuracy: 0.001)
    }

    func testHorizontalNeighborUsesTheSameAxisGenericRecovery() {
        let horizontalSourceFrame = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let horizontalWorkingFrame = CGRect(x: 16, y: 16, width: 2_498, height: 1_408)
        let source = monitorContext(displayId: 20, frame: horizontalSourceFrame)
        let rightNeighbor = monitorContext(
            displayId: 21,
            frame: CGRect(x: 2_560, y: 328, width: 1_080, height: 1_920)
        )

        let recovered = NiriSettledCoverageEvaluator.bestOffset(
            for: .init(
                containerSpans: [1_581, 1_581, 1_241, 1_581],
                selectedIndex: 2,
                activeIndex: 2,
                semanticOffset: -16,
                gap: 16,
                workingFrame: horizontalWorkingFrame,
                sourceMonitor: source,
                monitors: [source, rightNeighbor],
                orientation: .horizontal,
                scale: 2
            )
        )

        XCTAssertEqual(recovered, -1_241, accuracy: 0.001)
    }

    func testOnePhysicalPixelGainStaysAndTwoPixelGainMoves() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let source = monitorContext(displayId: 30, frame: frame)

        func recoveredOffset(from semanticOffset: CGFloat) -> CGFloat {
            NiriSettledCoverageEvaluator.bestOffset(
                for: .init(
                    containerSpans: [50, 50],
                    selectedIndex: 0,
                    activeIndex: 0,
                    semanticOffset: semanticOffset,
                    gap: 0,
                    workingFrame: frame,
                    sourceMonitor: source,
                    monitors: [source],
                    orientation: .vertical,
                    scale: 2
                )
            )
        }

        XCTAssertEqual(recoveredOffset(from: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(recoveredOffset(from: 1), 0, accuracy: 0.001)
    }

    func testSemanticCandidateUsesItsExactExistingOffset() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let source = monitorContext(displayId: 31, frame: frame)

        let recovered = NiriSettledCoverageEvaluator.bestOffset(
            for: .init(
                containerSpans: [35, 63.25, 57.5, 90.5, 43.5],
                selectedIndex: 1,
                activeIndex: 2,
                semanticOffset: -97.25,
                gap: 0.25,
                workingFrame: frame,
                sourceMonitor: source,
                monitors: [source],
                orientation: .vertical,
                scale: 2
            )
        )

        XCTAssertEqual(recovered, -97.25, accuracy: 0.001)
    }

    func testInteractiveResizeRecoversOnlyAfterRelease() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let sourceMonitor = Monitor(
            id: .init(displayId: 40),
            displayId: 40,
            frame: sourceFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 2_530),
            hasNotch: false,
            name: "Portrait Source"
        )
        let upperMonitor = Monitor(
            id: .init(displayId: 41),
            displayId: 41,
            frame: CGRect(x: 328, y: 2_560, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 328, y: 2_560, width: 1_920, height: 1_080),
            hasNotch: false,
            name: "Upper Neighbor"
        )
        _ = engine.ensureMonitor(for: sourceMonitor.id, monitor: sourceMonitor, orientation: .vertical)
        _ = engine.ensureMonitor(for: upperMonitor.id, monitor: upperMonitor, orientation: .horizontal)

        var windows: [NiriWindow] = []
        for index in 0 ..< 4 {
            let window = addWindow(
                engine,
                pid: 9_000,
                windowId: index + 1,
                to: workspaceId,
                after: windows.last
            )
            windows.append(window)
        }
        engine.moveWorkspace(workspaceId, to: sourceMonitor.id, monitor: sourceMonitor)

        let columns = engine.columns(in: workspaceId)
        XCTAssertEqual(columns.count, 4)
        for column in columns {
            column.height = .fixed(1_581)
            column.cachedHeight = 1_581
        }

        var state = ViewportState()
        state.activeColumnIndex = 2
        state.selectedNodeId = windows[2].id
        state.jumpOffset(to: -16)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: windows[2].id,
                edges: .top,
                startLocation: .zero,
                in: workspaceId,
                orientation: .vertical,
                viewOffset: state.viewOffset
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: 0, y: -340),
                monitorFrame: traceWorkingFrame,
                gaps: LayoutGaps(horizontal: 16, vertical: 16),
                viewportState: { mutate in mutate(&state) }
            )
        )

        XCTAssertEqual(columns[2].cachedHeight, 1_241, accuracy: 0.001)
        XCTAssertEqual(state.viewOffset, -16, accuracy: 0.001)

        engine.interactiveResizeEnd(
            motion: .disabled,
            state: &state,
            workingFrame: traceWorkingFrame,
            gaps: 16
        )

        XCTAssertNil(engine.interactiveResize)
        XCTAssertEqual(state.viewOffset, -1_241, accuracy: 0.001)

        let layout = engine.calculateCombinedLayoutWithVisibility(
            in: workspaceId,
            monitor: sourceMonitor,
            gaps: LayoutGaps(horizontal: 16, vertical: 16),
            state: state,
            workingArea: WorkingAreaContext(
                workingFrame: traceWorkingFrame,
                fullscreenLayoutFrame: sourceMonitor.visibleFrame,
                viewFrame: sourceMonitor.frame,
                scale: 2
            )
        )
        let visibleFrames = windows.compactMap { window -> CGRect? in
            guard layout.hiddenHandles[window.token] == nil else { return nil }
            return layout.frames[window.token]
        }
        for frame in layout.frames.values {
            XCTAssertFalse(frame.intersects(upperMonitor.frame))
        }

        let intervals = visibleFrames.compactMap { frame -> ClosedRange<CGFloat>? in
            let intersection = frame.intersection(traceWorkingFrame)
            guard !intersection.isNull, intersection.height > 0 else { return nil }
            return intersection.minY ... intersection.maxY
        }
        .sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertGreaterThanOrEqual(intervals.count, 2)
        let firstInterval = try XCTUnwrap(intervals.first)
        let lastInterval = try XCTUnwrap(intervals.last)
        XCTAssertEqual(firstInterval.lowerBound, traceWorkingFrame.minY, accuracy: 0.001)
        XCTAssertEqual(lastInterval.upperBound, traceWorkingFrame.maxY - 16, accuracy: 0.001)
        for index in 1 ..< intervals.count {
            XCTAssertLessThanOrEqual(
                intervals[index].lowerBound - intervals[index - 1].upperBound,
                16.001
            )
        }

        state.jumpOffset(to: -16)
        engine.centerFocusedColumn = .always
        XCTAssertFalse(
            engine.recoverSettledCoverage(
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: traceWorkingFrame,
                gaps: 16,
                orientation: .vertical
            )
        )
        XCTAssertEqual(state.viewOffset, -16, accuracy: 0.001)

        engine.centerFocusedColumn = .never
        windows[2].sizingMode = .fullscreen
        XCTAssertFalse(
            engine.recoverSettledCoverage(
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: traceWorkingFrame,
                gaps: 16,
                orientation: .vertical
            )
        )
        XCTAssertEqual(state.viewOffset, -16, accuracy: 0.001)

        windows[2].sizingMode = .normal
        XCTAssertTrue(
            engine.recoverSettledCoverage(
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: traceWorkingFrame,
                gaps: 16,
                orientation: .vertical
            )
        )
        XCTAssertEqual(state.viewOffset, -1_241, accuracy: 0.001)

        state.jumpOffset(to: -16)
        windows[0].sizingMode = .maximized
        XCTAssertFalse(
            engine.recoverSettledCoverage(
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: traceWorkingFrame,
                gaps: 16,
                orientation: .vertical
            )
        )
        XCTAssertEqual(state.viewOffset, -16, accuracy: 0.001)
    }

    func testSingleWindowFitAndForcedCenteringPreserveOffset() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let sourceMonitor = Monitor(
            id: .init(displayId: 50),
            displayId: 50,
            frame: sourceFrame,
            visibleFrame: sourceFrame,
            hasNotch: false,
            name: "Single Window Source"
        )
        _ = engine.ensureMonitor(for: sourceMonitor.id, monitor: sourceMonitor, orientation: .vertical)
        let window = addWindow(engine, pid: 9_100, windowId: 1, to: workspaceId)
        engine.moveWorkspace(workspaceId, to: sourceMonitor.id, monitor: sourceMonitor)

        var state = ViewportState()
        state.selectedNodeId = window.id
        state.jumpOffset(to: 37)
        engine.singleWindowFit = .fullScreen

        XCTAssertFalse(
            engine.recoverSettledCoverage(
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: traceWorkingFrame,
                gaps: 16,
                orientation: .vertical
            )
        )
        XCTAssertEqual(state.viewOffset, 37, accuracy: 0.001)

        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        engine.alwaysCenterSingleColumn = true
        XCTAssertFalse(
            engine.recoverSettledCoverage(
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: traceWorkingFrame,
                gaps: 16,
                orientation: .vertical
            )
        )
        XCTAssertEqual(state.viewOffset, 37, accuracy: 0.001)
    }

    private func monitorContext(
        displayId: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect? = nil
    ) -> HiddenPlacementMonitorContext {
        HiddenPlacementMonitorContext(
            id: .init(displayId: displayId),
            frame: frame,
            visibleFrame: visibleFrame ?? frame
        )
    }
}
