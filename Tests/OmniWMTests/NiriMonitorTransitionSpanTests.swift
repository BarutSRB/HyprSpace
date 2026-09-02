// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriMonitorTransitionSpanTests: XCTestCase {
    private struct Target {
        let monitor: Monitor
        let orientation: Monitor.Orientation
        let visibleContainerCount: Int
    }

    private let workspaceId = WorkspaceDescriptor.ID()
    private let wide = Target(
        monitor: monitor(displayId: 1, width: 3_840, height: 1_440),
        orientation: .horizontal,
        visibleContainerCount: 2
    )
    private let narrow = Target(
        monitor: monitor(displayId: 2, width: 1_800, height: 1_440),
        orientation: .horizontal,
        visibleContainerCount: 1
    )
    private let tall = Target(
        monitor: monitor(displayId: 3, width: 1_440, height: 2_560),
        orientation: .vertical,
        visibleContainerCount: 1
    )
    private let tallTriple = Target(
        monitor: monitor(displayId: 4, width: 1_440, height: 2_560),
        orientation: .vertical,
        visibleContainerCount: 3
    )

    func testMovingAWorkspaceRederivesAutomaticSpansForTheNewMonitor() {
        let engine = makeEngine(startingOn: wide)
        let columns = engine.columns(in: workspaceId)
        XCTAssertEqual(columns.map(\.width), [.proportion(0.5), .proportion(0.5), .proportion(0.5)])
        columns[1].width = .proportion(0.3)
        columns[1].hasManualSingleWindowWidthOverride = true

        assign(engine, to: narrow)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map(\.width),
            [.proportion(1), .proportion(0.3), .proportion(1)]
        )

        engine.moveWorkspace(workspaceId, to: wide.monitor.id, monitor: wide.monitor)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map(\.width),
            [.proportion(0.5), .proportion(0.3), .proportion(0.5)]
        )
    }

    func testMovingToAVerticalMonitorRederivesAutomaticHeightsAndKeepsWidths() {
        let engine = makeEngine(startingOn: wide)
        let columns = engine.columns(in: workspaceId)
        XCTAssertEqual(columns.map(\.height), [.proportion(0.5), .proportion(0.5), .proportion(0.5)])
        columns[1].height = .proportion(0.3)
        columns[1].hasManualSingleWindowHeightOverride = true

        assign(engine, to: tall)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map(\.height),
            [.proportion(1), .proportion(0.3), .proportion(1)]
        )
        XCTAssertEqual(
            engine.columns(in: workspaceId).map(\.width),
            [.proportion(0.5), .proportion(0.5), .proportion(0.5)]
        )
    }

    func testMovingBetweenVerticalMonitorsRederivesAutomaticHeights() {
        let engine = makeEngine(startingOn: tall)
        XCTAssertEqual(engine.columns(in: workspaceId).map(\.height), [.proportion(1), .proportion(1), .proportion(1)])

        assign(engine, to: tallTriple)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map(\.height),
            [.proportion(1.0 / 3), .proportion(1.0 / 3), .proportion(1.0 / 3)]
        )
    }

    func testReassigningTheSameMonitorLeavesSpansUntouched() {
        let engine = makeEngine(startingOn: wide)
        engine.columns(in: workspaceId)[0].width = .proportion(0.7)

        assign(engine, to: wide)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map(\.width),
            [.proportion(0.7), .proportion(0.5), .proportion(0.5)]
        )
    }

    private func makeEngine(startingOn start: Target) -> NiriLayoutEngine {
        let engine = NiriLayoutEngine()
        engine.isMutationSanctioned = true
        engine.defaultContainerPrimarySpan = nil
        for target in [wide, narrow, tall, tallTriple] {
            _ = engine.ensureMonitor(for: target.monitor.id, monitor: target.monitor, orientation: target.orientation)
            engine.updateMonitorSettings(
                settings(engine, visibleContainerCount: target.visibleContainerCount),
                for: target.monitor.id
            )
        }
        assign(engine, to: start)
        for windowId in 1 ... 3 {
            _ = engine.addWindow(token: WindowToken(pid: 1, windowId: windowId), to: workspaceId, afterSelection: nil)
        }
        return engine
    }

    private func assign(_ engine: NiriLayoutEngine, to target: Target) {
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: target.monitor)],
            orientations: [target.monitor.id: target.orientation]
        )
    }

    private func settings(_ engine: NiriLayoutEngine, visibleContainerCount: Int) -> ResolvedNiriSettings {
        let global = engine.globalResolvedSettings()
        return ResolvedNiriSettings(
            visibleContainerCount: visibleContainerCount,
            centerFocusedColumn: global.centerFocusedColumn,
            alwaysCenterSingleColumn: global.alwaysCenterSingleColumn,
            singleWindowFit: global.singleWindowFit,
            infiniteLoop: global.infiniteLoop
        )
    }

    private nonisolated static func monitor(displayId: CGDirectDisplayID, width: CGFloat, height: CGFloat) -> Monitor {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        return Monitor(
            id: Monitor.ID(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Display \(displayId)"
        )
    }
}
