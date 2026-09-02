// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IPCSessionEventPublicationTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let ws1: WorkspaceDescriptor.ID
        let ws2: WorkspaceDescriptor.ID
        let token: WindowToken
    }

    func testWorkspaceOnlySwitchReportsInteractionWorkspaceWithoutFocusChange() throws {
        let fixture = try makeFixture()
        let dispatcher = FocusNotificationDispatcher(controller: fixture.controller)
        dispatcher.notifyFocusChangesIfNeeded()

        XCTAssertTrue(fixture.controller.workspaceManager.setActiveWorkspace(fixture.ws2, on: fixture.monitor.id))

        XCTAssertEqual(
            dispatcher.notifyFocusChangesIfNeeded(),
            .init(focusChanged: false, workspaceChanged: true, monitorChanged: false)
        )
        XCTAssertEqual(
            dispatcher.notifyFocusChangesIfNeeded(),
            .init(focusChanged: false, workspaceChanged: false, monitorChanged: false)
        )
        XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, fixture.token)
    }

    func testClearingNativeFocusAfterEmptySwitchReportsFocusOnly() throws {
        let fixture = try makeFixture()
        let dispatcher = FocusNotificationDispatcher(controller: fixture.controller)
        XCTAssertTrue(fixture.controller.workspaceManager.setActiveWorkspace(fixture.ws2, on: fixture.monitor.id))
        dispatcher.notifyFocusChangesIfNeeded()

        XCTAssertTrue(fixture.controller.workspaceManager.clearNativeFocusOwner())

        XCTAssertEqual(
            dispatcher.notifyFocusChangesIfNeeded(),
            .init(focusChanged: true, workspaceChanged: false, monitorChanged: false)
        )
    }

    func testActiveWorkspaceSubscriptionReceivesEmptyTargetOnSwitch() async throws {
        let fixture = try makeFixture()
        let bridge = makeBridge(controller: fixture.controller)
        fixture.controller.ipcApplicationBridge = bridge
        let stream = await bridge.stream(for: .activeWorkspace)
        var iterator = stream.makeAsyncIterator()

        fixture.controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)

        let delivered = await iterator.next()
        let event = try XCTUnwrap(delivered)
        XCTAssertEqual(event.channel, .activeWorkspace)
        guard case let .activeWorkspace(result) = event.result.payload else {
            return XCTFail("unexpected payload \(event.result.payload)")
        }
        XCTAssertEqual(result.workspace?.rawName, "2")
        XCTAssertNil(result.focusedApp)
        XCTAssertNotNil(result.display)

        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        XCTAssertEqual(fixture.controller.workspaceManager.nativeFocusOwner, .none)
        await bridge.shutdown()
        let trailing = await iterator.next()
        XCTAssertNil(trailing)
    }

    func testAdoptedMonitorChangesPublishDisplaySnapshots() async throws {
        let fixture = try makeFixture()
        let bridge = makeBridge(controller: fixture.controller)
        fixture.controller.ipcApplicationBridge = bridge
        let stream = await bridge.stream(for: .displayChanged)
        var iterator = stream.makeAsyncIterator()
        let lifecycle = fixture.controller.serviceLifecycleManager
        let second = makeMonitor(displayId: 2, name: "Second", width: 1440)

        lifecycle.applyMonitorConfigurationChanged(
            currentMonitors: [fixture.monitor, second],
            performPostUpdateActions: false
        )
        let addedEvent = await iterator.next()
        let added = try displays(in: addedEvent)
        XCTAssertEqual(added.map(\.name), ["Events", "Second"])

        lifecycle.applyMonitorConfigurationChanged(
            currentMonitors: [fixture.monitor, makeMonitor(displayId: 2, name: "Second", width: 1920)],
            performPostUpdateActions: false
        )
        let reconfiguredEvent = await iterator.next()
        let reconfigured = try displays(in: reconfiguredEvent)
        XCTAssertEqual(reconfigured.map(\.name), ["Events", "Second"])
        XCTAssertNotEqual(reconfigured[1].frame, added[1].frame)

        lifecycle.applyMonitorConfigurationChanged(currentMonitors: [fixture.monitor], performPostUpdateActions: false)
        let removedEvent = await iterator.next()
        let removed = try displays(in: removedEvent)
        XCTAssertEqual(removed.map(\.name), ["Events"])

        lifecycle.applyMonitorConfigurationChanged(currentMonitors: [fixture.monitor], performPostUpdateActions: false)
        lifecycle.applyMonitorConfigurationChanged(
            currentMonitors: [fixture.monitor, makeMonitor(displayId: 3, name: "Transient", width: 1)],
            performPostUpdateActions: false
        )
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        await bridge.shutdown()
        let trailing = await iterator.next()
        XCTAssertNil(trailing)
    }

    func testIdenticalDisplaySnapshotsAreNotRepublished() async throws {
        let fixture = try makeFixture()
        let bridge = makeBridge(controller: fixture.controller)
        let stream = await bridge.stream(for: .displayChanged)
        var iterator = stream.makeAsyncIterator()

        await bridge.publishEvent(.displayChanged)
        let first = await iterator.next()
        XCTAssertEqual(first?.channel, .displayChanged)

        await bridge.publishEvent(.displayChanged)
        await bridge.shutdown()
        let trailing = await iterator.next()
        XCTAssertNil(trailing)
    }

    private func displays(in delivered: IPCEventEnvelope?) throws -> [IPCDisplayQuerySnapshot] {
        let event = try XCTUnwrap(delivered)
        XCTAssertEqual(event.channel, .displayChanged)
        guard case let .displays(result) = event.result.payload else {
            XCTFail("unexpected payload \(event.result.payload)")
            return []
        }
        return result.displays
    }

    private func makeMonitor(displayId: CGDirectDisplayID, name: String, width: CGFloat) -> Monitor {
        let frame = CGRect(x: 1600, y: 0, width: width, height: 900)
        return Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func makeBridge(controller: WMController) -> IPCApplicationBridge {
        IPCApplicationBridge(
            controller: controller,
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "IPCSessionEventPublicationTests")
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.settings.animationsEnabled = false
        controller.enableNiriLayout()
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Events"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws2 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(ws1, on: monitor.id))

        let token = WindowToken(pid: 7_301, windowId: 7_401)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: ws1
        )
        XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
            token,
            in: ws1,
            activateWorkspaceOnMonitor: false
        ))
        return Fixture(controller: controller, monitor: monitor, ws1: ws1, ws2: ws2, token: token)
    }
}
