// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class CursorContainmentHandlerTests: XCTestCase {
    private struct Fixture {
        let settings: SettingsStore
        let controller: WMController
        let handler: MouseWarpHandler
        let bottom: Monitor
        let top: Monitor
    }

    private struct ReporterFixture {
        let controller: WMController
        let handler: MouseWarpHandler
        let source: Monitor
        let target: Monitor
    }

    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCursorContainmentTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }

    private func makeMonitor(_ displayId: CGDirectDisplayID, _ name: String, _ frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func routing(
        _ displayId: CGDirectDisplayID,
        _ name: String,
        _ column: Int,
        _ row: Int
    ) -> MonitorRoutingSettings {
        MonitorRoutingSettings(monitorName: name, monitorDisplayId: displayId, gridColumn: column, gridRow: row)
    }

    private func makeFixture(verticalRouting: Bool = false, margin: Int = 1) -> Fixture {
        let settings = makeSettings()
        settings.mouseWarpEnabled = true
        settings.cursorContainmentEnabled = true
        settings.monitorRoutingMode = .custom
        settings.mouseWarpMargin = margin

        let bottom = makeMonitor(1, "Bottom", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let top = makeMonitor(2, "Top", CGRect(x: 0, y: 1080, width: 1920, height: 1080))
        let layout = verticalRouting
            ? [routing(2, "Top", 0, 0), routing(1, "Bottom", 0, 1)]
            : [routing(1, "Bottom", 0, 0), routing(2, "Top", 1, 0)]
        settings.monitorArrangements = [MonitorArrangement(monitors: layout)]

        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([bottom, top])
        let handler = controller.mouseWarpHandler
        handler.activeDisplayBounds = { _ in .infinite }
        return Fixture(settings: settings, controller: controller, handler: handler, bottom: bottom, top: top)
    }

    private func makeReporterFixture() -> ReporterFixture {
        let settings = makeSettings()
        settings.mouseWarpEnabled = true
        settings.cursorContainmentEnabled = false
        settings.monitorRoutingMode = .custom
        settings.mouseWarpMargin = 1

        let source = makeMonitor(2, "Dell", CGRect(x: 0, y: 0, width: 3360, height: 1418))
        let target = makeMonitor(3, "espresso", CGRect(x: 3360, y: 1418, width: 1080, height: 1920))
        settings.monitorArrangements = [MonitorArrangement(monitors: [
            routing(3, "espresso", 0, 0),
            routing(2, "Dell", 1, 0)
        ])]

        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([source, target])
        _ = controller.workspaceManager.setInteractionMonitor(source.id)
        let handler = controller.mouseWarpHandler
        handler.activeDisplayBounds = { _ in .infinite }
        return ReporterFixture(controller: controller, handler: handler, source: source, target: target)
    }

    func testWallFiresAfterFreshSourceSampleInsideForbiddenMonitor() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)

        XCTAssertEqual(warped.count, 1)
        assertPoint(
            warped[0],
            ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: 960, y: 1078))
        )
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.bottom.id)
    }

    func testAllowedPhysicalCrossingInDestinationEntryBandConsumesSample() {
        let fixture = makeFixture(verticalRouting: true, margin: 4)
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: CGPoint(x: 960, y: fixture.top.frame.minY + 1))

        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testRoutedSameMonitorEdgeTeleportStillWorksWithContainmentEnabled() {
        let fixture = makeFixture(margin: 2)
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        let edgeLocation = CGPoint(x: fixture.bottom.frame.maxX - 1, y: fixture.bottom.frame.midY)
        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: edgeLocation)

        let crossing = MouseWarpGeometry.crossing(location: edgeLocation, frame: fixture.bottom.frame, margin: 2)
        let destination = MouseWarpGeometry.destinationPoint(
            on: fixture.top.frame,
            entryEdge: crossing?.entryEdge ?? .left,
            ratio: crossing?.ratio ?? 0,
            margin: 2
        )
        XCTAssertEqual(warped.count, 1)
        assertPoint(warped[0], ScreenCoordinateSpace.toWindowServer(point: destination))
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testInheritedArrangementAndExactEditAgreeAcrossNavigationWarpAndContainment() {
        let fixture = makeFixture()
        let inherited = MonitorArrangement(monitors: [
            routing(1, "Bottom", 0, 0), routing(2, "Top", 1, 0), routing(3, "Disconnected", 2, 0)
        ])
        fixture.settings.monitorArrangements = [inherited]
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }
        let manager = fixture.controller.workspaceManager

        XCTAssertEqual(manager.adjacentMonitor(from: fixture.bottom.id, direction: .right), fixture.top)
        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertEqual(warped.count, 1)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.bottom.id)

        fixture.handler.resetTransientState()
        warped.removeAll()
        fixture.handler.handleMouseWarpMoved(at: CGPoint(
            x: fixture.bottom.frame.maxX - 1,
            y: fixture.bottom.frame.midY
        ))
        XCTAssertEqual(warped.count, 1)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)

        fixture.handler.resetTransientState()
        warped.removeAll()
        fixture.settings.storeRoutingLayout(
            [routing(1, "Bottom", 0, 1), routing(2, "Top", 0, 0)],
            for: [fixture.bottom, fixture.top]
        )
        XCTAssertEqual(fixture.settings.monitorArrangements.count, 2)
        XCTAssertEqual(fixture.settings.monitorArrangements[0], inherited)
        XCTAssertEqual(manager.adjacentMonitor(from: fixture.bottom.id, direction: .up), fixture.top)
        XCTAssertNil(manager.adjacentMonitor(from: fixture.bottom.id, direction: .right))
        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }
}

extension CursorContainmentHandlerTests {
    func testReporterCornerWarpCommitsOnlyTargetInteractionState() {
        let fixture = makeReporterFixture()
        var warped: [CGPoint] = []
        var posted: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { posted.append($0) }
        fixture.handler.activeDisplayBounds = { displayId in
            XCTAssertEqual(displayId, fixture.target.displayId)
            return .infinite
        }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.source.frame.center)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.source.id)
        XCTAssertFalse(fixture.handler.state.isWarping)
        XCTAssertNil(fixture.handler.state.cooldownTimer)

        let visibleWorkspaces = fixture.controller.workspaceManager.activeVisibleWorkspaceMap()
        let expectedDestination = CGPoint(x: 4438, y: 1434)
        let expectedWarpPoint = ScreenCoordinateSpace.toWindowServer(point: expectedDestination)

        fixture.handler.handleMouseWarpMoved(at: CGPoint(x: -1, y: -1))

        XCTAssertEqual(warped.count, 1)
        XCTAssertEqual(posted.count, 1)
        assertPoint(warped[0], expectedWarpPoint)
        assertPoint(posted[0], expectedWarpPoint)
        XCTAssertTrue(fixture.handler.state.isWarping)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.target.id)
        XCTAssertNotNil(fixture.handler.state.cooldownTimer)
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, fixture.target.id)
        XCTAssertEqual(fixture.controller.workspaceManager.activeVisibleWorkspaceMap(), visibleWorkspaces)
    }

    func testReporterCornerWarpRejectsMissingAndExcludingTargetBounds() {
        let rejectedBounds: [CGRect?] = [nil, CGRect(x: -1, y: -1, width: 1, height: 1)]

        for bounds in rejectedBounds {
            let fixture = makeReporterFixture()
            var warpCalls = 0
            var postCalls = 0
            fixture.handler.activeDisplayBounds = { _ in bounds }
            fixture.handler.warpCursor = { _ in
                warpCalls += 1
                return .success
            }
            fixture.handler.postMouseMovedEvent = { _ in postCalls += 1 }
            defer { fixture.handler.resetTransientState() }

            fixture.handler.handleMouseWarpMoved(at: fixture.source.frame.center)
            XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.source.id)
            XCTAssertFalse(fixture.handler.state.isWarping)
            XCTAssertNil(fixture.handler.state.cooldownTimer)

            let interactionMonitorId = fixture.controller.workspaceManager.interactionMonitorId
            let sourceSampleAt = fixture.handler.state.lastSampleAt
            let visibleWorkspaces = fixture.controller.workspaceManager.activeVisibleWorkspaceMap()

            fixture.handler.handleMouseWarpMoved(at: CGPoint(x: -1, y: -1))

            XCTAssertEqual(warpCalls, 0)
            XCTAssertEqual(postCalls, 0)
            XCTAssertFalse(fixture.handler.state.isWarping)
            XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.source.id)
            XCTAssertEqual(fixture.handler.state.lastSampleAt, sourceSampleAt)
            XCTAssertNil(fixture.handler.state.cooldownTimer)
            XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, interactionMonitorId)
            XCTAssertEqual(fixture.controller.workspaceManager.activeVisibleWorkspaceMap(), visibleWorkspaces)
        }
    }

    func testReporterCornerWarpErrorDoesNotCommitTargetState() {
        let fixture = makeReporterFixture()
        var warpCalls = 0
        var postCalls = 0
        fixture.handler.warpCursor = { _ in
            warpCalls += 1
            return .failure
        }
        fixture.handler.postMouseMovedEvent = { _ in postCalls += 1 }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.source.frame.center)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.source.id)
        XCTAssertFalse(fixture.handler.state.isWarping)
        XCTAssertNil(fixture.handler.state.cooldownTimer)

        let interactionMonitorId = fixture.controller.workspaceManager.interactionMonitorId
        let sourceSampleAt = fixture.handler.state.lastSampleAt
        let visibleWorkspaces = fixture.controller.workspaceManager.activeVisibleWorkspaceMap()

        fixture.handler.handleMouseWarpMoved(at: CGPoint(x: -1, y: -1))

        XCTAssertEqual(warpCalls, 1)
        XCTAssertEqual(postCalls, 0)
        XCTAssertFalse(fixture.handler.state.isWarping)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.source.id)
        XCTAssertEqual(fixture.handler.state.lastSampleAt, sourceSampleAt)
        XCTAssertNil(fixture.handler.state.cooldownTimer)
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, interactionMonitorId)
        XCTAssertEqual(fixture.controller.workspaceManager.activeVisibleWorkspaceMap(), visibleWorkspaces)
    }
}

extension CursorContainmentHandlerTests {
    func testCooldownExpiryRecheckWallsParkedForbiddenCursor() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        fixture.controller.currentMouseLocation = { fixture.top.frame.center }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertEqual(warped.count, 1)

        fixture.handler.handleCooldownExpiry()

        XCTAssertEqual(warped.count, 2)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.bottom.id)
    }

    func testContainmentBoundsFailureAdvancesSampleWithoutWarpState() throws {
        let fixture = makeFixture()
        var warpCalls = 0
        var postCalls = 0
        fixture.handler.warpCursor = { _ in
            warpCalls += 1
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in postCalls += 1 }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        let sourceSampleAt = Date(timeIntervalSinceNow: -0.5)
        fixture.handler.state.lastSampleAt = sourceSampleAt
        let sourceMonitorId = fixture.handler.state.lastMonitorId
        let interactionMonitorId = fixture.controller.workspaceManager.interactionMonitorId
        var validatedDisplayId: CGDirectDisplayID?
        fixture.handler.activeDisplayBounds = { displayId in
            validatedDisplayId = displayId
            return nil
        }

        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)

        let failedSampleAt = try XCTUnwrap(fixture.handler.state.lastSampleAt)
        XCTAssertEqual(warpCalls, 0)
        XCTAssertEqual(postCalls, 0)
        XCTAssertEqual(validatedDisplayId, fixture.bottom.displayId)
        XCTAssertGreaterThan(failedSampleAt, sourceSampleAt)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, sourceMonitorId)
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, interactionMonitorId)
        XCTAssertFalse(fixture.handler.state.isWarping)
        XCTAssertNil(fixture.handler.state.cooldownTimer)
    }

    func testContainmentWarpErrorAdvancesSampleWithoutWarpState() throws {
        let fixture = makeFixture()
        var warpCalls = 0
        var postCalls = 0
        fixture.handler.warpCursor = { _ in
            warpCalls += 1
            return .failure
        }
        fixture.handler.postMouseMovedEvent = { _ in postCalls += 1 }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        let sourceSampleAt = Date(timeIntervalSinceNow: -0.5)
        fixture.handler.state.lastSampleAt = sourceSampleAt
        let sourceMonitorId = fixture.handler.state.lastMonitorId
        let interactionMonitorId = fixture.controller.workspaceManager.interactionMonitorId

        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)

        let failedSampleAt = try XCTUnwrap(fixture.handler.state.lastSampleAt)
        XCTAssertEqual(warpCalls, 1)
        XCTAssertEqual(postCalls, 0)
        XCTAssertGreaterThan(failedSampleAt, sourceSampleAt)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, sourceMonitorId)
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, interactionMonitorId)
        XCTAssertFalse(fixture.handler.state.isWarping)
        XCTAssertNil(fixture.handler.state.cooldownTimer)
    }

    func testProgrammaticCursorMoveWhitelistsStalePreWarpSample() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.noteProgrammaticCursorMove(to: fixture.top.frame.center)
        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)

        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testStaleBaselineAdoptsDestinationWithoutWalling() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.handler.state.lastSampleAt = Date(timeIntervalSinceNow: -2)
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)

        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testContainmentGatesDoNotWall() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.settings.cursorContainmentEnabled = false
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertTrue(warped.isEmpty)

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.settings.cursorContainmentEnabled = true
        fixture.settings.monitorRoutingMode = .macOS
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertTrue(warped.isEmpty)

        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)
        fixture.settings.monitorRoutingMode = .custom
        fixture.settings.mouseWarpEnabled = false
        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        XCTAssertTrue(warped.isEmpty)
    }

    func testOuterBoundaryLocationOnNoMonitorDoesNotWall() {
        let fixture = makeFixture()
        var warped: [CGPoint] = []
        fixture.handler.warpCursor = {
            warped.append($0)
            return .success
        }
        fixture.handler.postMouseMovedEvent = { _ in }
        defer { fixture.handler.resetTransientState() }

        fixture.handler.handleMouseWarpMoved(at: fixture.top.frame.center)
        fixture.handler.handleMouseWarpMoved(at: CGPoint(x: fixture.top.frame.midX, y: fixture.top.frame.maxY))

        XCTAssertTrue(warped.isEmpty)
        XCTAssertEqual(fixture.handler.state.lastMonitorId, fixture.top.id)
    }

    func testResetTransientStateClearsContainmentState() {
        let fixture = makeFixture()
        fixture.handler.handleMouseWarpMoved(at: fixture.bottom.frame.center)

        fixture.handler.resetTransientState()

        XCTAssertNil(fixture.handler.state.lastMonitorId)
        XCTAssertNil(fixture.handler.state.lastSampleAt)
        XCTAssertFalse(fixture.handler.state.isWarping)
    }

    private func assertPoint(
        _ point: CGPoint,
        _ expected: CGPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(point.x, expected.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: 0.0001, file: file, line: line)
    }
}
