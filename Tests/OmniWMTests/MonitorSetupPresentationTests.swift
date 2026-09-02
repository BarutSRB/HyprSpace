// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class MonitorSetupPresentationTests: XCTestCase {
    func testMissingRuntimeStatusDefaultsToNotPresented() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"hasSeenIssueWalkthrough":true}"#.utf8)
            .write(to: root.appendingPathComponent(RuntimeStateStore.fileName))

        let runtimeState = RuntimeStateStore(directory: root, deferSaves: false)

        XCTAssertEqual(runtimeState.monitorSetupStatus, .notPresented)
    }

    func testRuntimeStatusRoundTripsDismissedAndCompleted() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = RuntimeStateStore(directory: root, deferSaves: false)

        writer.monitorSetupStatus = .dismissed
        XCTAssertEqual(
            RuntimeStateStore(directory: root, deferSaves: false).monitorSetupStatus,
            .dismissed
        )

        writer.monitorSetupStatus = .completed
        XCTAssertEqual(
            RuntimeStateStore(directory: root, deferSaves: false).monitorSetupStatus,
            .completed
        )
    }

    func testSettingsStorePersistsMonitorSetupStatus() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettingsStore(root: root)

        settings.monitorSetupStatus = .completed

        let reloaded = RuntimeStateStore(
            directory: root.appendingPathComponent("state", isDirectory: true),
            deferSaves: false
        )
        XCTAssertEqual(reloaded.monitorSetupStatus, .completed)
    }

    func testApplyMonitorSetupCommitsRoutingMouseWarpAndWorkspaces() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettingsStore(root: root)
        let routing = [
            MonitorRoutingSettings(
                monitorName: "Primary",
                monitorDisplayId: 1,
                gridColumn: 0,
                gridRow: 0
            ),
            MonitorRoutingSettings(
                monitorName: "Secondary",
                monitorDisplayId: 2,
                gridColumn: 1,
                gridRow: 0
            )
        ]
        let workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
        settings.monitorRoutingMode = .macOS
        settings.mouseWarpEnabled = true

        settings.applyMonitorSetup(
            routingSettings: routing,
            mouseWarpEnabled: false,
            workspaceConfigurations: workspaceConfigurations
        )

        XCTAssertEqual(settings.monitorRoutingSettings, routing)
        XCTAssertEqual(settings.monitorRoutingMode, .custom)
        XCTAssertFalse(settings.mouseWarpEnabled)
        XCTAssertEqual(settings.workspaceConfigurations, workspaceConfigurations)
    }

    func testNavigationRequestIsConsumedOnceAndSelectsMonitors() {
        let navigation = SettingsNavigationModel()

        navigation.requestMonitorSetupPresentation()

        XCTAssertEqual(navigation.section, .monitors)
        XCTAssertTrue(navigation.hasPendingMonitorSetupPresentation)
        XCTAssertTrue(navigation.consumeMonitorSetupPresentationRequest())
        XCTAssertFalse(navigation.hasPendingMonitorSetupPresentation)
        XCTAssertFalse(navigation.consumeMonitorSetupPresentationRequest())
    }

    func testPresentationPolicyRequiresTwoDisplaysAfterOverlay() {
        XCTAssertFalse(
            MonitorSetupPresentationPolicy.shouldAutomaticallyPresent(
                status: .notPresented,
                monitors: monitors(count: 2),
                launchOverlayFinished: false
            )
        )
        XCTAssertFalse(
            MonitorSetupPresentationPolicy.shouldAutomaticallyPresent(
                status: .notPresented,
                monitors: monitors(count: 1),
                launchOverlayFinished: true
            )
        )
        XCTAssertTrue(
            MonitorSetupPresentationPolicy.shouldAutomaticallyPresent(
                status: .notPresented,
                monitors: monitors(count: 2),
                launchOverlayFinished: true
            )
        )
    }

    func testPresentationPolicyWaitsForTransientDisplayGeometry() {
        var displays = monitors(count: 2)
        displays[1] = Monitor(
            id: .init(displayId: 2),
            displayId: 2,
            frame: CGRect(x: 0, y: 0, width: 1, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1, height: 900),
            hasNotch: false,
            name: "Display 2"
        )

        XCTAssertFalse(
            MonitorSetupPresentationPolicy.shouldAutomaticallyPresent(
                status: .notPresented,
                monitors: displays,
                launchOverlayFinished: true
            )
        )
    }

    func testPresentationPolicyStopsAfterAutomaticDismissalOrCompletion() {
        for status in [MonitorSetupStatus.dismissed, .completed] {
            XCTAssertFalse(
                MonitorSetupPresentationPolicy.shouldAutomaticallyPresent(
                    status: status,
                    monitors: monitors(count: 3),
                    launchOverlayFinished: true
                )
            )
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMMonitorSetup-\(UUID().uuidString)", isDirectory: true)
    }

    private func monitors(count: Int) -> [Monitor] {
        (0 ..< count).map { index in
            let displayID = CGDirectDisplayID(index + 1)
            let x = CGFloat(index) * 1_000
            return Monitor(
                id: .init(displayId: displayID),
                displayId: displayID,
                frame: CGRect(x: x, y: 0, width: 1_000, height: 900),
                visibleFrame: CGRect(x: x, y: 0, width: 1_000, height: 900),
                hasNotch: false,
                name: "Display \(index + 1)"
            )
        }
    }

    private func makeSettingsStore(root: URL) -> SettingsStore {
        SettingsStore(
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
}
