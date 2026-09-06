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
        let displays = monitors(count: 2)
        let routing = MonitorRouting.seedLayout(from: displays)
        let workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
        settings.monitorRoutingMode = .macOS
        settings.mouseWarpEnabled = true

        settings.applyMonitorSetup(
            routingSettings: routing,
            monitors: displays,
            mouseWarpEnabled: false,
            workspaceConfigurations: workspaceConfigurations
        )

        XCTAssertEqual(settings.monitorArrangements.map(\.monitors), [routing])
        XCTAssertEqual(settings.monitorRoutingMode, .custom)
        XCTAssertFalse(settings.mouseWarpEnabled)
        XCTAssertEqual(settings.workspaceConfigurations, workspaceConfigurations)
    }

    func testApplyMonitorSetupCreatesExactSubsetWithoutChangingLargerArrangement() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettingsStore(root: root)
        let displays = monitors(count: 3)
        let fullRouting = MonitorRouting.seedLayout(from: displays)
        settings.applyMonitorSetup(
            routingSettings: fullRouting,
            monitors: displays,
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )
        let original = try XCTUnwrap(settings.monitorArrangements.first)
        let connected = Array(displays.prefix(2))
        var subsetRouting = MonitorRouting.seedLayout(from: connected)
        subsetRouting[1].gridColumn = 0
        subsetRouting[1].gridRow = 1

        settings.applyMonitorSetup(
            routingSettings: subsetRouting,
            monitors: connected,
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        XCTAssertEqual(settings.monitorArrangements.count, 2)
        XCTAssertEqual(settings.monitorArrangements[0], original)
        XCTAssertEqual(settings.monitorArrangements[1].monitors, subsetRouting)
        XCTAssertNotEqual(settings.monitorArrangements[1].id, original.id)

        let subsetID = settings.monitorArrangements[1].id
        let resetRouting = MonitorRouting.seedLayout(from: connected)
        settings.applyMonitorSetup(
            routingSettings: resetRouting,
            monitors: connected,
            mouseWarpEnabled: false,
            workspaceConfigurations: []
        )

        XCTAssertEqual(settings.monitorArrangements.count, 2)
        XCTAssertEqual(settings.monitorArrangements[0], original)
        XCTAssertEqual(settings.monitorArrangements[1].id, subsetID)
        XCTAssertEqual(settings.monitorArrangements[1].monitors, resetRouting)
        XCTAssertFalse(settings.mouseWarpEnabled)
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
