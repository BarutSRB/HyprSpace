// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriLayoutBuildMetricsRegressionTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
    }

    func testScrollBuildMetricRecordsWhileDetailedTraceIsInactive() throws {
        ScrollTickTrace.shared.endCapture()
        let fixture = try makeFixture()

        XCTAssertFalse(ScrollTickTrace.shared.isActive)
        XCTAssertTrue(
            fixture.controller.layoutRefreshController.niriHandler.applyFramesOnDemand(
                wsId: fixture.workspaceId,
                state: fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId),
                engine: fixture.engine,
                monitor: fixture.monitor,
                animationTime: CACurrentMediaTime()
            )
        )

        let dump = fixture.controller.layoutRefreshController.layoutBuildMetricsDump()
        XCTAssertTrue(dump.contains("builds=1"))
        XCTAssertTrue(dump.contains("route=scrollTick ws=1 win=1-2 n=1"))
    }

    func testSettleBuildMetricRecordsWithoutDetailedTraceEntry() throws {
        let fixture = try makeFixture()
        ScrollTickTrace.shared.beginCapture()
        defer { ScrollTickTrace.shared.endCapture() }

        XCTAssertTrue(
            fixture.controller.layoutRefreshController.niriHandler.applyFramesOnDemand(
                wsId: fixture.workspaceId,
                state: fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId),
                engine: fixture.engine,
                monitor: fixture.monitor
            )
        )

        let dump = fixture.controller.layoutRefreshController.layoutBuildMetricsDump()
        XCTAssertTrue(dump.contains("builds=1"))
        XCTAssertTrue(dump.contains("route=scrollTick ws=1 win=1-2 n=1"))
        XCTAssertEqual(ScrollTickTrace.shared.dump(), "none")
    }

    private func makeFixture() throws -> Fixture {
        let controller = makeController()
        let monitor = Monitor(
            id: .init(displayId: 95_100),
            displayId: 95_100,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Niri Layout Build Metrics"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.niriLayoutHandler.enableNiriLayout()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(95_101), windowId: 9_511),
            pid: 95_101,
            windowId: 9_511,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        return Fixture(
            controller: controller,
            engine: engine,
            monitor: monitor,
            workspaceId: workspaceId
        )
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NiriLayoutBuildMetricsRegressionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let settings = SettingsStore(
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
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }
}
