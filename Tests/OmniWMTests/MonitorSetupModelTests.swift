// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MonitorSetupModelTests: XCTestCase {
    private let displayUUIDA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let displayUUIDB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let accuracy: CGFloat = 1e-6

    func testCompleteActiveCustomLayoutSeedsDraftAndPreservesMouseWarpChoice() {
        let monitors = sideBySideMonitors()
        let routing = [
            routing(for: monitors[0], column: 9, row: -4),
            routing(for: monitors[1], column: 9, row: 12)
        ]

        let draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .custom,
            arrangements: [MonitorArrangement(monitors: routing)],
            mouseWarpEnabled: false,
            workspaceConfigurations: []
        )

        XCTAssertEqual(draft.cell(for: monitors[0].id), .init(column: 0, row: 0))
        XCTAssertEqual(draft.cell(for: monitors[1].id), .init(column: 0, row: 1))
        XCTAssertFalse(draft.mouseWarpEnabled)
        XCTAssertTrue(draft.isCardinallyConnected)
    }

    func testMacOSModeSnapshotsGeometryInsteadOfInactiveCustomLayout() {
        let monitors = sideBySideMonitors()
        let inactiveRouting = [
            routing(for: monitors[0], column: 0, row: 0),
            routing(for: monitors[1], column: 0, row: 1)
        ]

        let draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .macOS,
            arrangements: [MonitorArrangement(monitors: inactiveRouting)],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        XCTAssertEqual(draft.cell(for: monitors[0].id), .init(column: 0, row: 0))
        XCTAssertEqual(draft.cell(for: monitors[1].id), .init(column: 1, row: 0))
    }

    func testIncompleteCustomLayoutFallsBackToMacOSSnapshot() {
        let monitors = sideBySideMonitors()
        let incompleteRouting = [routing(for: monitors[0], column: 0, row: 0)]

        let draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .custom,
            arrangements: [MonitorArrangement(monitors: incompleteRouting)],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        XCTAssertEqual(draft.cell(for: monitors[0].id), .init(column: 0, row: 0))
        XCTAssertEqual(draft.cell(for: monitors[1].id), .init(column: 1, row: 0))
    }

    func testCollidingMacOSSnapshotProducesUniqueCompactedCells() {
        let first = makeMonitor(
            displayId: 2,
            name: "First",
            displayUUID: displayUUIDA,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900)
        )
        let second = makeMonitor(
            displayId: 3,
            name: "Second",
            displayUUID: displayUUIDB,
            frame: first.frame
        )

        let draft = MonitorSetupDraft(
            monitors: [first, second],
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        XCTAssertEqual(Set(draft.cells.values).count, 2)
        XCTAssertEqual(Set(draft.cells.values.map(\.column)), [0, 1])
        XCTAssertEqual(Set(draft.cells.values.map(\.row)), [0])
    }

    func testPlaceSwapsOccupantAndCompactsUnusedAxes() {
        let monitors = threeSideBySideMonitors()
        var draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        draft.place(monitors[0].id, at: .init(column: 2, row: 0))

        XCTAssertEqual(draft.cell(for: monitors[0].id), .init(column: 2, row: 0))
        XCTAssertEqual(draft.cell(for: monitors[1].id), .init(column: 1, row: 0))
        XCTAssertEqual(draft.cell(for: monitors[2].id), .init(column: 0, row: 0))

        draft.place(monitors[1].id, at: .init(column: 8, row: 5))

        XCTAssertEqual(draft.cell(for: monitors[0].id), .init(column: 1, row: 0))
        XCTAssertEqual(draft.cell(for: monitors[1].id), .init(column: 2, row: 1))
        XCTAssertEqual(draft.cell(for: monitors[2].id), .init(column: 0, row: 0))
    }

    func testMoveUsesDirectionalCellAndCollisionSwap() {
        let monitors = sideBySideMonitors()
        var draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        draft.move(monitors[0].id, direction: .right)

        XCTAssertEqual(draft.cell(for: monitors[0].id), .init(column: 1, row: 0))
        XCTAssertEqual(draft.cell(for: monitors[1].id), .init(column: 0, row: 0))

        draft.move(monitors[0].id, direction: .down)

        XCTAssertEqual(draft.cell(for: monitors[0].id), .init(column: 1, row: 1))
        XCTAssertEqual(draft.cell(for: monitors[1].id), .init(column: 0, row: 0))
        XCTAssertFalse(draft.isCardinallyConnected)
    }

    func testConnectivityMatchesRuntimeCardinalLines() {
        let horizontal = sideBySideMonitors()
        let diagonal = [
            makeMonitor(
                displayId: 2,
                name: "First",
                displayUUID: displayUUIDA,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 600)
            ),
            makeMonitor(
                displayId: 3,
                name: "Second",
                displayUUID: displayUUIDB,
                frame: CGRect(x: 1000, y: 600, width: 800, height: 500)
            )
        ]

        let connectedDraft = MonitorSetupDraft(
            monitors: horizontal,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )
        let disconnectedDraft = MonitorSetupDraft(
            monitors: diagonal,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        XCTAssertTrue(connectedDraft.isCardinallyConnected)
        XCTAssertFalse(disconnectedDraft.isCardinallyConnected)
        XCTAssertEqual(disconnectedDraft.readiness(for: diagonal), .disconnected)
    }

    func testReadinessDetectsMonitorIdentitySetChanges() {
        let monitors = sideBySideMonitors()
        let replacement = makeMonitor(
            displayId: 4,
            name: "Replacement",
            displayUUID: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
            frame: monitors[1].frame
        )
        let draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        XCTAssertEqual(draft.readiness(for: monitors.reversed()), .ready)
        XCTAssertEqual(draft.readiness(for: [monitors[0], replacement]), .monitorConfigurationChanged)
        XCTAssertNil(draft.routingSettings(monitors: [monitors[0], replacement]))
    }

    func testReadinessDetectsStableIdentityReplacementWithReusedRuntimeID() {
        let monitors = sideBySideMonitors()
        let replacement = makeMonitor(
            displayId: monitors[1].displayId,
            name: monitors[1].name,
            displayUUID: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
            frame: monitors[1].frame
        )
        let draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        XCTAssertEqual(
            draft.readiness(for: [monitors[0], replacement]),
            .monitorConfigurationChanged
        )
    }

    func testRoutingSettingsStampStableIdentityForConnectedSet() throws {
        let monitors = threeSideBySideMonitors()
        let connected = Array(monitors.prefix(2))
        let arrangement = MonitorArrangement(monitors: MonitorRouting.seedLayout(from: monitors))
        let draft = MonitorSetupDraft(
            monitors: connected,
            routingMode: .custom,
            arrangements: [arrangement],
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        let updated = try XCTUnwrap(draft.routingSettings(monitors: connected))
        let first = try XCTUnwrap(MonitorSettingsStore.get(for: connected[0], in: updated))
        let second = try XCTUnwrap(MonitorSettingsStore.get(for: connected[1], in: updated))

        XCTAssertEqual(first.monitorName, connected[0].name)
        XCTAssertEqual(first.monitorDisplayUUID, displayUUIDA)
        XCTAssertEqual(first.monitorDisplayId, connected[0].displayId)
        XCTAssertEqual(second.monitorName, connected[1].name)
        XCTAssertEqual(second.monitorDisplayUUID, displayUUIDB)
        XCTAssertEqual(second.monitorDisplayId, connected[1].displayId)
        XCTAssertEqual(first.gridColumn, 0)
        XCTAssertEqual(second.gridColumn, 1)
        XCTAssertEqual(updated.count, connected.count)
        XCTAssertNil(MonitorSettingsStore.get(for: monitors[2], in: updated))
        XCTAssertEqual(arrangement.monitors.count, 3)
    }

    func testWorkspaceCoverageUsesRuntimeMonitorAssignmentResolution() throws {
        let monitors = threeSideBySideMonitors()
        let configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
        var draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: configurations
        )

        XCTAssertFalse(draft.hasWorkspaceCoverage(in: monitors))
        XCTAssertEqual(draft.uncoveredMonitors(in: monitors).count, 1)
        let uncoveredMonitor = try XCTUnwrap(draft.uncoveredMonitors(in: monitors).first)
        XCTAssertEqual(
            Set(draft.uncoveredMonitors(in: monitors.reversed()).map(\.id)),
            [uncoveredMonitor.id]
        )

        draft.addWorkspace(for: uncoveredMonitor)

        XCTAssertTrue(draft.hasWorkspaceCoverage(in: monitors))
    }

    func testWorkspaceReassignmentChangesDraftCoverageWithoutChangingConfigurationIdentity() {
        let monitors = sideBySideMonitors()
        let configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .niri),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main, layoutType: .dwindle)
        ]
        var draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: configurations
        )

        XCTAssertFalse(draft.hasWorkspaceCoverage(in: monitors))

        draft.setMonitorAssignment(.secondary, for: configurations[1].id)

        XCTAssertTrue(draft.hasWorkspaceCoverage(in: monitors))
        XCTAssertEqual(draft.workspaceConfigurations.map(\.id), configurations.map(\.id))
        XCTAssertEqual(draft.workspaceConfigurations.map(\.name), configurations.map(\.name))
        XCTAssertEqual(draft.workspaceConfigurations.map(\.layoutType), configurations.map(\.layoutType))
        XCTAssertEqual(configurations.map(\.monitorAssignment), [.main, .main])
    }

    func testAddingAndRemovingWorkspaceOnlyMutatesDraftCreatedRows() throws {
        let monitors = threeSideBySideMonitors()
        let configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "3", monitorAssignment: .secondary)
        ]
        var draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: configurations
        )
        let uncoveredMonitor = try XCTUnwrap(draft.uncoveredMonitors(in: monitors).first)

        draft.addWorkspace(for: uncoveredMonitor)

        XCTAssertEqual(draft.workspaceConfigurations.map(\.name), ["1", "2", "3"])
        let added = try XCTUnwrap(draft.workspaceConfigurations.first(where: { $0.name == "2" }))
        XCTAssertEqual(added.layoutType, .defaultLayout)
        XCTAssertEqual(
            added.monitorAssignment,
            .specificDisplay(OutputId(from: uncoveredMonitor))
        )
        XCTAssertTrue(draft.isDraftCreatedWorkspace(added.id))
        XCTAssertTrue(draft.hasWorkspaceCoverage(in: monitors))

        draft.removeDraftCreatedWorkspace(configurations[0].id)
        XCTAssertEqual(draft.workspaceConfigurations.count, 3)

        draft.removeDraftCreatedWorkspace(added.id)
        XCTAssertEqual(draft.workspaceConfigurations.map(\.name), ["1", "3"])
        XCTAssertFalse(draft.hasWorkspaceCoverage(in: monitors))
        XCTAssertFalse(draft.isDraftCreatedWorkspace(added.id))

        draft.removeDraftCreatedWorkspace(added.id)
        XCTAssertEqual(draft.workspaceConfigurations.map(\.name), ["1", "3"])
    }

    func testEmptyMonitorSetDoesNotHaveWorkspaceCoverage() {
        let draft = MonitorSetupDraft(
            monitors: [],
            routingMode: .macOS,
            arrangements: [],
            mouseWarpEnabled: true,
            workspaceConfigurations: [WorkspaceConfiguration(name: "1", monitorAssignment: .main)]
        )

        XCTAssertFalse(draft.hasWorkspaceCoverage(in: []))
        XCTAssertTrue(draft.uncoveredMonitors(in: []).isEmpty)
    }

    func testStaircaseFramesShrinkAndTouchAtEveryCorner() {
        let frames = MonitorSetupStaircaseGeometry.logicalFrames(displayCount: 6)

        XCTAssertEqual(frames.count, 6)
        for index in frames.indices.dropFirst() {
            XCTAssertLessThan(frames[index].width, frames[index - 1].width)
            XCTAssertLessThan(frames[index].height, frames[index - 1].height)
            XCTAssertEqual(frames[index].minX, frames[index - 1].maxX, accuracy: accuracy)
            XCTAssertEqual(frames[index].minY, frames[index - 1].maxY, accuracy: accuracy)
        }
    }

    func testStaircaseCanvasRectsFitTwoAndFourDisplays() {
        let canvas = CGSize(width: 420, height: 240)
        let padding: CGFloat = 12

        for count in [2, 4] {
            let rects = MonitorSetupStaircaseGeometry.canvasRects(
                displayCount: count,
                in: canvas,
                padding: padding
            )

            XCTAssertEqual(rects.count, count)
            XCTAssertGreaterThanOrEqual(rects.map(\.minX).min() ?? 0, padding - accuracy)
            XCTAssertLessThanOrEqual(rects.map(\.maxX).max() ?? 0, canvas.width - padding + accuracy)
            XCTAssertGreaterThanOrEqual(rects.map(\.minY).min() ?? 0, padding - accuracy)
            XCTAssertLessThanOrEqual(rects.map(\.maxY).max() ?? 0, canvas.height - padding + accuracy)
            XCTAssertGreaterThan(rects[0].width, rects[count - 1].width)
            XCTAssertGreaterThan(rects[0].minY, rects[count - 1].minY)
        }
    }

    func testTransitionUsesOneStableFitForBothArrangements() {
        let transition = MonitorSetupStaircaseGeometry.transition(
            displayCount: 4,
            in: CGSize(width: 400, height: 240),
            padding: 10
        )

        XCTAssertEqual(transition.sideBySide.count, 4)
        XCTAssertEqual(transition.staircase.count, 4)
        for index in transition.sideBySide.indices {
            XCTAssertEqual(
                transition.sideBySide[index].size,
                transition.staircase[index].size
            )
            XCTAssertEqual(
                transition.sideBySide[index].minX,
                transition.staircase[index].minX,
                accuracy: accuracy
            )
        }
        let sideBySideBottom = transition.sideBySide[0].maxY
        for rect in transition.sideBySide {
            XCTAssertEqual(rect.maxY, sideBySideBottom, accuracy: accuracy)
        }
        XCTAssertTrue(
            zip(transition.staircase, transition.staircase.dropFirst()).allSatisfy {
                $0.minY > $1.minY
            }
        )
    }

    func testEmptyStaircaseGeometryIsEmpty() {
        XCTAssertTrue(MonitorSetupStaircaseGeometry.logicalFrames(displayCount: 0).isEmpty)
        let transition = MonitorSetupStaircaseGeometry.transition(
            displayCount: 0,
            in: CGSize(width: 300, height: 200),
            padding: 10
        )
        XCTAssertTrue(transition.sideBySide.isEmpty)
        XCTAssertTrue(transition.staircase.isEmpty)
    }

    private func sideBySideMonitors() -> [Monitor] {
        [
            makeMonitor(
                displayId: 2,
                name: "First",
                displayUUID: displayUUIDA,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 900)
            ),
            makeMonitor(
                displayId: 3,
                name: "Second",
                displayUUID: displayUUIDB,
                frame: CGRect(x: 1600, y: 50, width: 1200, height: 800)
            )
        ]
    }

    private func threeSideBySideMonitors() -> [Monitor] {
        [
            makeMonitor(
                displayId: 2,
                name: "First",
                displayUUID: displayUUIDA,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 900)
            ),
            makeMonitor(
                displayId: 3,
                name: "Second",
                displayUUID: displayUUIDB,
                frame: CGRect(x: 1600, y: 50, width: 1200, height: 800)
            ),
            makeMonitor(
                displayId: 4,
                name: "Third",
                displayUUID: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
                frame: CGRect(x: 2800, y: 100, width: 1000, height: 700)
            )
        ]
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        displayUUID: String,
        frame: CGRect
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name,
            displayUUID: displayUUID
        )
    }

    private func routing(
        for monitor: Monitor,
        column: Int,
        row: Int
    ) -> MonitorRoutingSettings {
        MonitorRoutingSettings(
            monitorName: monitor.name,
            monitorDisplayUUID: monitor.displayUUID,
            gridColumn: column,
            gridRow: row
        )
    }
}
