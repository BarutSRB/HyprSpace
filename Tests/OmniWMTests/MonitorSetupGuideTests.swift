// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class MonitorSetupGuideTests: XCTestCase {
    func testDisplaysSettingsLinkMatchesExistingDeepLink() {
        XCTAssertEqual(
            MonitorSetupSystemSettings.displaysURLString,
            "x-apple.systempreferences:com.apple.preference.displays"
        )
    }

    func testMacOSAssessmentAcceptsCornerToCornerStaircase() {
        let monitors = [
            monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 900)),
            monitor(id: 2, frame: CGRect(x: 1600, y: 900, width: 1200, height: 700)),
            monitor(id: 3, frame: CGRect(x: 2800, y: 1600, width: 900, height: 600))
        ]

        XCTAssertNil(MonitorSetupMacOSAssessment.warning(for: monitors))
    }

    func testMacOSAssessmentWarnsForSideBySideOverlapAndTransientGeometry() {
        let sideBySide = [
            monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 900)),
            monitor(id: 2, frame: CGRect(x: 1600, y: 0, width: 1200, height: 700))
        ]
        let overlapping = [
            monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 900)),
            monitor(id: 2, frame: CGRect(x: 800, y: 200, width: 1200, height: 700))
        ]
        let transient = [
            monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1, height: 900)),
            monitor(id: 2, frame: CGRect(x: 1, y: 900, width: 1200, height: 700))
        ]

        XCTAssertTrue(MonitorSetupMacOSAssessment.warning(for: sideBySide)?.contains("share an edge") == true)
        XCTAssertTrue(MonitorSetupMacOSAssessment.warning(for: overlapping)?.contains("overlap") == true)
        XCTAssertTrue(MonitorSetupMacOSAssessment.warning(for: transient)?.contains("updating") == true)
    }

    func testDraftEditsDoNotMutateSettingsBeforeFinish() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: root.appendingPathComponent("config")),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state"),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let monitors = [
            monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 900)),
            monitor(id: 2, frame: CGRect(x: 1600, y: 0, width: 1200, height: 700))
        ]
        let disconnected = monitor(id: 3, frame: CGRect(x: 2800, y: 0, width: 1000, height: 700))
        settings.monitorRoutingMode = .custom
        settings.monitorArrangements = [
            MonitorArrangement(monitors: MonitorRouting.seedLayout(from: monitors + [disconnected]))
        ]
        let initialMode = settings.monitorRoutingMode
        let initialArrangements = settings.monitorArrangements
        let initialMouseWarp = settings.mouseWarpEnabled
        let initialWorkspaceConfigurations = settings.workspaceConfigurations
        var draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: settings.monitorRoutingMode,
            arrangements: settings.monitorArrangements,
            mouseWarpEnabled: settings.mouseWarpEnabled,
            workspaceConfigurations: settings.workspaceConfigurations
        )

        draft.move(monitors[1].id, direction: .down)
        draft.mouseWarpEnabled.toggle()
        if let workspaceID = draft.workspaceConfigurations.first?.id {
            draft.setMonitorAssignment(.secondary, for: workspaceID)
        }
        draft.addWorkspace(for: monitors[1])

        XCTAssertEqual(settings.monitorRoutingMode, initialMode)
        XCTAssertEqual(settings.monitorArrangements, initialArrangements)
        XCTAssertEqual(settings.mouseWarpEnabled, initialMouseWarp)
        XCTAssertEqual(settings.workspaceConfigurations, initialWorkspaceConfigurations)
    }

    func testGuideBuildsAtMinimumSettingsWindowSize() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: root.appendingPathComponent("config")),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state"),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        let monitors = [
            monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 900)),
            monitor(id: 2, frame: CGRect(x: 1600, y: 0, width: 1200, height: 700))
        ]
        let hostingView = NSHostingView(rootView: MonitorSetupGuide(
            settings: settings,
            controller: controller,
            monitors: monitors,
            onFinish: {},
            onSkip: {}
        ))

        hostingView.frame = CGRect(x: 0, y: 0, width: 760, height: 560)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testIdentificationOverlayCleanupIsIdempotent() {
        let controller = MonitorIdentificationOverlayController()

        controller.hide()
        controller.hide()

        XCTAssertEqual(controller.visibleCount, 0)
    }

    private func monitor(id: CGDirectDisplayID, frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: id),
            displayId: id,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Display \(id)",
            displayUUID: String(format: "00000000-0000-4000-8000-%012d", id)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-monitor-setup-\(UUID().uuidString)", isDirectory: true)
    }
}
