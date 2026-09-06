// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class MonitorRoutingWorkspaceTests: XCTestCase {
    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMRoutingTests-\(UUID().uuidString)", isDirectory: true)
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

    func testMacOSModeMatchesGeometryNeighbors() {
        let manager = WorkspaceManager(settings: makeSettings())
        let left = makeMonitor(1, "L", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let right = makeMonitor(2, "R", CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        manager.applyMonitorConfigurationChange([left, right])

        XCTAssertEqual(manager.adjacentMonitor(from: left.id, direction: .right)?.id, right.id)
        XCTAssertEqual(manager.adjacentMonitor(from: right.id, direction: .left)?.id, left.id)
        XCTAssertNil(manager.adjacentMonitor(from: left.id, direction: .up))
    }

    func testMacOSModeIgnoresOffsetStackedMonitorsHorizontally() {
        let manager = WorkspaceManager(settings: makeSettings())
        let top = makeMonitor(1, "Top", CGRect(x: 100, y: 1080, width: 1920, height: 1080))
        let bottom = makeMonitor(2, "Bottom", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        manager.applyMonitorConfigurationChange([top, bottom])

        XCTAssertNil(manager.adjacentMonitor(from: top.id, direction: .left))
        XCTAssertNil(manager.adjacentMonitor(from: bottom.id, direction: .right))
        XCTAssertEqual(manager.adjacentMonitor(from: top.id, direction: .down)?.id, bottom.id)
        XCTAssertEqual(manager.adjacentMonitor(from: bottom.id, direction: .up)?.id, top.id)
    }

    func testCustomRoutingDivergesFromMacOSGeometry() {
        let settings = makeSettings()
        let manager = WorkspaceManager(settings: settings)
        let top = makeMonitor(1, "Top", CGRect(x: 0, y: 1080, width: 1920, height: 1080))
        let bottom = makeMonitor(2, "Bottom", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        manager.applyMonitorConfigurationChange([top, bottom])

        XCTAssertNil(manager.adjacentMonitor(from: top.id, direction: .right))

        settings.monitorRoutingMode = .custom
        settings.monitorArrangements = [MonitorArrangement(monitors: [
            routing(1, "Top", 0, 0),
            routing(2, "Bottom", 1, 0)
        ])]

        XCTAssertEqual(manager.adjacentMonitor(from: top.id, direction: .right)?.id, bottom.id)
        XCTAssertEqual(manager.adjacentMonitor(from: bottom.id, direction: .left)?.id, top.id)
        XCTAssertNil(manager.adjacentMonitor(from: top.id, direction: .down))
    }

    func testCustomModeFallsBackToMacOSWhenLayoutMissing() {
        let settings = makeSettings()
        let manager = WorkspaceManager(settings: settings)
        let left = makeMonitor(1, "L", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let right = makeMonitor(2, "R", CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        manager.applyMonitorConfigurationChange([left, right])

        settings.monitorRoutingMode = .custom
        settings.monitorArrangements = []

        XCTAssertEqual(manager.adjacentMonitor(from: left.id, direction: .right)?.id, right.id)
    }

    func testSeedLayoutReproducesMacOSNeighbors() {
        let topLeft = makeMonitor(1, "TL", CGRect(x: 0, y: 1080, width: 1920, height: 1080))
        let topRight = makeMonitor(2, "TR", CGRect(x: 1920, y: 1080, width: 1920, height: 1080))
        let bottomLeft = makeMonitor(3, "BL", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let bottomRight = makeMonitor(4, "BR", CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let monitors = [topLeft, topRight, bottomLeft, bottomRight]
        let layout = MonitorRouting.seedLayout(from: monitors)

        XCTAssertEqual(
            MonitorRouting.gridAdjacent(
                from: topLeft,
                direction: .right,
                layout: layout,
                monitors: monitors,
                wrapAround: false
            ),
            .monitor(topRight)
        )
        XCTAssertEqual(
            MonitorRouting.gridAdjacent(
                from: topLeft,
                direction: .down,
                layout: layout,
                monitors: monitors,
                wrapAround: false
            ),
            .monitor(bottomLeft)
        )
        XCTAssertEqual(
            MonitorRouting.gridAdjacent(
                from: bottomRight,
                direction: .up,
                layout: layout,
                monitors: monitors,
                wrapAround: false
            ),
            .monitor(topRight)
        )
    }

    func testCustomArrangementsSurviveHomeWorkHomeAndSettingsReload() throws {
        let settings = makeSettings()
        let manager = WorkspaceManager(settings: settings)
        let laptop = makeMonitor(1, "Laptop", CGRect(x: 0, y: 0, width: 1440, height: 900))
        let home = makeMonitor(2, "Home", CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let work = makeMonitor(3, "Work", CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        settings.monitorRoutingMode = .custom
        manager.applyMonitorConfigurationChange([laptop, home])
        settings.storeRoutingLayout(
            [routing(1, "Laptop", 0, 1), routing(2, "Home", 0, 0)],
            for: [laptop, home]
        )
        let homeArrangement = settings.monitorArrangements[0]
        XCTAssertEqual(manager.adjacentMonitor(from: laptop.id, direction: .up), home)
        XCTAssertNil(manager.adjacentMonitor(from: laptop.id, direction: .right))

        manager.applyMonitorConfigurationChange([laptop, work])
        XCTAssertEqual(manager.adjacentMonitor(from: laptop.id, direction: .right), work)
        XCTAssertNil(manager.adjacentMonitor(from: laptop.id, direction: .up))
        settings.storeRoutingLayout(
            [routing(1, "Laptop", 0, 0), routing(3, "Work", 1, 0)],
            for: [laptop, work]
        )
        XCTAssertEqual(settings.monitorArrangements.count, 2)
        XCTAssertEqual(settings.monitorArrangements[0], homeArrangement)
        manager.applyMonitorConfigurationChange([home, laptop])
        XCTAssertEqual(manager.adjacentMonitor(from: laptop.id, direction: .up), home)
        XCTAssertNil(manager.adjacentMonitor(from: laptop.id, direction: .right))

        let reloaded = makeSettings()
        reloaded.applyExport(try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(settings.toExport())))
        let restarted = WorkspaceManager(settings: reloaded)
        restarted.applyMonitorConfigurationChange([home, laptop])
        XCTAssertEqual(reloaded.monitorArrangements, settings.monitorArrangements)
        XCTAssertEqual(restarted.adjacentMonitor(from: laptop.id, direction: .up), home)
        restarted.applyMonitorConfigurationChange([laptop, work])
        XCTAssertEqual(restarted.adjacentMonitor(from: laptop.id, direction: .right), work)
    }
}
