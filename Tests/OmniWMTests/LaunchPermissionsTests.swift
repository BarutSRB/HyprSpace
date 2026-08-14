// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class LaunchPermissionsTests: XCTestCase {
    private final class State {
        var accessibilityGranted = false
        var inputMonitoringGranted = false
        var screenRecordingGranted = false
        var requested: [LaunchPermissionKind] = []
    }

    func testRequiredPermissionMatrix() {
        for accessibilityGranted in [false, true] {
            for inputMonitoringGranted in [false, true] {
                let snapshot = LaunchPermissionSnapshot(
                    accessibilityGranted: accessibilityGranted,
                    inputMonitoringGranted: inputMonitoringGranted,
                    screenRecordingGranted: false
                )
                XCTAssertEqual(
                    snapshot.requiredGranted,
                    accessibilityGranted && inputMonitoringGranted
                )
            }
        }
    }

    func testScreenRecordingIsOptional() {
        let snapshot = LaunchPermissionSnapshot(
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            screenRecordingGranted: false
        )

        XCTAssertTrue(snapshot.requiredGranted)
        XCTAssertFalse(snapshot.allGranted)
    }

    func testRequestRoutesToSelectedPermissionAndRefreshes() {
        let state = State()
        let model = LaunchPermissionsModel(environment: environment(state))

        model.request(.inputMonitoring)
        XCTAssertEqual(state.requested, [.inputMonitoring])
        XCTAssertFalse(model.snapshot.inputMonitoringGranted)

        state.inputMonitoringGranted = true
        model.refresh()
        XCTAssertTrue(model.snapshot.inputMonitoringGranted)
    }

    func testPrimaryActionDescribesOptionalDegradation() {
        let state = State()
        state.accessibilityGranted = true
        state.inputMonitoringGranted = true
        let model = LaunchPermissionsModel(environment: environment(state))

        XCTAssertEqual(model.primaryActionTitle, "Continue Without Screen Recording")

        state.screenRecordingGranted = true
        model.refresh()
        XCTAssertEqual(model.primaryActionTitle, "Start OmniWM")
    }

    private func environment(_ state: State) -> LaunchPermissionEnvironment {
        LaunchPermissionEnvironment(
            accessibilityGranted: { state.accessibilityGranted },
            requestAccessibility: { state.requested.append(.accessibility) },
            inputMonitoringGranted: { state.inputMonitoringGranted },
            requestInputMonitoring: { state.requested.append(.inputMonitoring) },
            screenRecordingGranted: { state.screenRecordingGranted },
            requestScreenRecording: { state.requested.append(.screenRecording) }
        )
    }
}
