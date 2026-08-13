// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AppVisibilityLifecycleTraceTests: XCTestCase {
    func testIntakeDispatchPreservesServiceSourceAndSequence() throws {
        let fixture = try makeFixture(pid: 92_000, windowId: 92_100, withMonitor: false)
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }

        fixture.controller.eventInterpreter.handleIntakeEvent(
            StampedIntakeEvent(
                seq: 77,
                event: .appHidden(pid: fixture.token.pid)
            )
        )

        let dump = AppVisibilityTrace.shared.dump()
        assertOrdered(
            [
                "event=intake pid=92000 visibility=hidden outcome=dispatched intake_seq=77 source=service",
                "event=ax_fence pid=92000 visibility=hidden outcome=enabled",
                "event=state_transition pid=92000 visibility=hidden outcome=applied"
            ],
            in: dump
        )
        XCTAssertTrue(dump.contains("source=service"))
    }

    func testHideTraceOrdersAXFenceBeforeWorldTransitionAndRecordsDuplicate() throws {
        let fixture = try makeFixture(pid: 92_001, windowId: 92_101, withMonitor: true)
        let activeWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        XCTAssertNotNil(fixture.controller.workspaceManager.focusWorkspace(id: activeWorkspaceId))
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }

        fixture.controller.axEventHandler.handleAppHidden(pid: fixture.token.pid, source: .service)
        fixture.controller.axEventHandler.handleAppHidden(pid: fixture.token.pid, source: .service)

        let dump = AppVisibilityTrace.shared.dump()
        assertOrdered(
            [
                "event=ax_fence pid=92001 visibility=hidden outcome=enabled",
                "event=state_transition pid=92001 visibility=hidden outcome=applied",
                "event=refresh pid=92001 visibility=hidden outcome=skipped",
                "event=state_transition pid=92001 visibility=hidden outcome=duplicate"
            ],
            in: dump
        )
        XCTAssertTrue(dump.contains("managed_windows=1"))
        XCTAssertTrue(dump.contains("reason=no_active_workspace"))
        XCTAssertEqual(dump.components(separatedBy: "event=ax_fence").count - 1, 1)
    }

    func testExternalUnhideTraceCompletesRefreshWithoutRevealIntent() async throws {
        let fixture = try makeFixture(pid: 92_002, windowId: 92_102, withMonitor: false)
        fixture.controller.axEventHandler.handleAppHidden(pid: fixture.token.pid, source: .service)
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }

        fixture.controller.axEventHandler.handleAppUnhidden(pid: fixture.token.pid, source: .service)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let dump = AppVisibilityTrace.shared.dump()
        assertOrdered(
            [
                "event=state_transition pid=92002 visibility=visible outcome=applied",
                "event=ax_fence pid=92002 visibility=visible outcome=disabled",
                "event=refresh pid=92002 visibility=visible outcome=requested",
                "event=refresh visibility=visible outcome=started",
                "event=refresh visibility=visible outcome=completed"
            ],
            in: dump
        )
        XCTAssertFalse(dump.contains("event=reveal"))
    }

    func testExplicitRevealTraceRecordsNewestFocusRejection() throws {
        let fixture = try makeFixture(pid: 92_003, windowId: 92_103, withMonitor: true)
        let handler = WindowActionHandler(
            controller: fixture.controller,
            visibleWindowInfoProvider: { [] },
            visibleOwnedWindowsProvider: { [] },
            frontOwnedWindow: { _ in },
            unhideApplication: { _ in true }
        )
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }

        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))
        let intentId = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)?.intent.id
        )
        _ = fixture.controller.intentLedger.beginManagedRequest(
            token: fixture.token,
            workspaceId: fixture.workspaceId
        )
        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertFalse(handler.completeAppRevealFocus(intentId: intentId))

        let dump = AppVisibilityTrace.shared.dump()
        assertOrdered(
            [
                "event=reveal pid=92003 outcome=issued",
                "event=reveal pid=92003 outcome=succeeded",
                "event=reveal pid=92003 outcome=cancelled",
                "event=reveal pid=92003 outcome=rejected"
            ],
            in: dump
        )
        XCTAssertTrue(dump.contains("reason=newer_focus_intent"))
        XCTAssertTrue(dump.contains("destination=window"))
    }

    func testExplicitRevealTraceRecordsConfirmation() throws {
        let fixture = try makeFixture(pid: 92_004, windowId: 92_104, withMonitor: true)
        let handler = WindowActionHandler(
            controller: fixture.controller,
            visibleWindowInfoProvider: { [] },
            visibleOwnedWindowsProvider: { [] },
            frontOwnedWindow: { _ in },
            unhideApplication: { _ in true }
        )
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }

        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))
        let intentId = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)?.intent.id
        )
        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertTrue(
            handler.completeAppRevealFocus(intentId: intentId),
            AppVisibilityTrace.shared.dump()
        )

        let dump = AppVisibilityTrace.shared.dump()
        assertOrdered(
            [
                "event=reveal pid=92004 outcome=issued",
                "event=reveal pid=92004 outcome=succeeded",
                "event=reveal pid=92004 outcome=confirmed",
                "event=reveal pid=92004 outcome=completed"
            ],
            in: dump
        )
        XCTAssertTrue(dump.contains("intent_generation=1"))
        XCTAssertTrue(dump.contains("generation=2"))
        XCTAssertFalse(dump.contains("outcome=rejected"))
    }

    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
        let handle: WindowHandle
    }

    private func makeFixture(pid: pid_t, windowId: Int, withMonitor: Bool) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "AppVisibilityLifecycleTraceTests")
        controller.settings.workspaceConfigurations = controller.settings.workspaceConfigurations.map {
            $0.name == "1" ? $0.with(layoutType: .dwindle) : $0
        }
        controller.workspaceManager.applySettings()
        if withMonitor {
            let monitor = Monitor(
                id: .init(displayId: 92_000),
                displayId: 92_000,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
                hasNotch: false,
                name: "App Visibility Trace Test"
            )
            controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        if withMonitor {
            _ = controller.workspaceManager.focusWorkspace(named: "1")
        }
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: windowId
            ),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: token))
        return Fixture(
            controller: controller,
            workspaceId: workspaceId,
            token: token,
            handle: handle
        )
    }

    private func assertOrdered(
        _ fragments: [String],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var remaining = text[...]
        for fragment in fragments {
            guard let range = remaining.range(of: fragment) else {
                XCTFail("missing or out-of-order trace fragment: \(fragment)\n\(text)", file: file, line: line)
                return
            }
            remaining = remaining[range.upperBound...]
        }
    }
}
