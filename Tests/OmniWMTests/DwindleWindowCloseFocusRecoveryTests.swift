// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

private actor DwindleCloseFocusFactGate {
    private var fact: FocusedWindowFact?
    private var isResolved = false
    private var waiters: [CheckedContinuation<FocusedWindowFact?, Never>] = []

    func wait() async -> FocusedWindowFact? {
        if isResolved { return fact }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(_ fact: FocusedWindowFact) {
        self.fact = fact
        isResolved = true
        for waiter in waiters {
            waiter.resume(returning: fact)
        }
        waiters.removeAll()
    }
}

@MainActor
final class DwindleWindowCloseFocusRecoveryTests: XCTestCase {
    private enum LayoutPair: CaseIterable {
        case dwindleToDwindle
        case dwindleToNiri
        case niriToDwindle

        var local: LayoutType {
            self == .niriToDwindle ? .niri : .dwindle
        }

        var remote: LayoutType {
            self == .dwindleToNiri ? .niri : .dwindle
        }
    }

    private enum FocusOrder: CaseIterable {
        case focusThenDestroy
        case destroyThenFocus
    }

    private enum FocusBypass {
        case mouse
        case appActivation
        case managedRequest
    }

    private struct Fixture {
        let controller: WMController
        let localWorkspaceId: WorkspaceDescriptor.ID
        let remoteWorkspaceId: WorkspaceDescriptor.ID
        let closingToken: WindowToken
        let fallbackToken: WindowToken
        let remoteToken: WindowToken
    }

    func testDwindleCloseHoldsDwindleFocusForBothEventOrders() async throws {
        try await Self.verifyCloseRecovery(layouts: .dwindleToDwindle)
    }

    func testDwindleCloseHoldsNiriFocusForBothEventOrders() async throws {
        try await Self.verifyCloseRecovery(layouts: .dwindleToNiri)
    }

    func testNiriCloseHoldsDwindleFocusForBothEventOrders() async throws {
        try await Self.verifyCloseRecovery(layouts: .niriToDwindle)
    }

    func testDelayedFocusFactsCannotLeaveLocalWorkspaceAfterRemoval() async throws {
        for layouts in LayoutPair.allCases {
            for order in FocusOrder.allCases {
                let fixture = try Self.makeFixture(layouts: layouts)
                defer { Self.stop(fixture) }
                let controller = fixture.controller
                let gate = DwindleCloseFocusFactGate()
                let remoteEntry = try XCTUnwrap(controller.workspaceManager.entry(for: fixture.remoteToken))
                let remoteFact = FocusedWindowFact(
                    axRef: remoteEntry.axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
                controller.factResolver.factProvider = nil
                controller.factResolver.deferredFactProvider = { _ in await gate.wait() }

                if order == .destroyThenFocus { Self.closeFocusedWindow(in: fixture) }
                XCTAssertTrue(
                    controller.axEventHandler.handleAppActivation(
                        pid: fixture.closingToken.pid,
                        source: .focusedWindowChanged
                    )
                )
                if order == .focusThenDestroy { Self.closeFocusedWindow(in: fixture) }
                Self.assertPendingCloseStaysLocal(fixture)
                await Self.settleClose(fixture)
                Self.assertRecoveredLocally(fixture)

                let previousSeq = controller.eventIntake.lastSeq
                await gate.resolve(remoteFact)
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(2))
                while controller.eventIntake.lastSeq <= previousSeq, clock.now < deadline {
                    await Task.yield()
                }
                XCTAssertGreaterThan(controller.eventIntake.lastSeq, previousSeq)
                controller.eventIntake.drainNow()
                Self.assertRecoveredLocally(fixture)
            }
        }
    }

    func testSameAppFocusWithoutDestroyResolvesWhenProbeExpires() throws {
        for layouts in LayoutPair.allCases {
            let fixture = try Self.makeFixture(layouts: layouts)
            defer { Self.stop(fixture) }
            let probeId = try Self.observeRemoteFocus(in: fixture)
            Self.assertPendingCloseStaysLocal(fixture)

            Self.expireProbe(probeId, in: fixture)

            XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
            XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
            XCTAssertNil(fixture.controller.intentLedger.openSameAppCloseProbe())
            XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: fixture.closingToken))
        }
    }

    func testMouseFocusBypassesPendingDestroyAcrossLayouts() async throws {
        try await Self.verifyFocusBypass(.mouse)
    }

    func testExplicitAppActivationBypassesPendingDestroyAcrossLayouts() async throws {
        try await Self.verifyFocusBypass(.appActivation)
    }

    func testMatchingManagedRequestBypassesPendingDestroyAcrossLayouts() async throws {
        try await Self.verifyFocusBypass(.managedRequest)
    }

    private static func verifyCloseRecovery(layouts: LayoutPair) async throws {
        for order in FocusOrder.allCases {
            let fixture = try makeFixture(layouts: layouts)
            defer { stop(fixture) }
            if order == .destroyThenFocus { closeFocusedWindow(in: fixture) }
            let probeId = try observeRemoteFocus(in: fixture)
            if order == .focusThenDestroy { closeFocusedWindow(in: fixture) }
            assertPendingCloseStaysLocal(fixture)

            expireProbe(probeId, in: fixture)
            assertPendingCloseStaysLocal(fixture)
            XCTAssertNotNil(fixture.controller.intentLedger.openSameAppCloseProbe())

            await settleClose(fixture)
            assertRecoveredLocally(fixture)
        }
    }

    private static func verifyFocusBypass(_ bypass: FocusBypass) async throws {
        for layouts in LayoutPair.allCases {
            let fixture = try makeFixture(layouts: layouts)
            defer { stop(fixture) }
            let controller = fixture.controller
            closeFocusedWindow(in: fixture)
            switch bypass {
            case .mouse:
                controller.axEventHandler.noteMouseFocusIntent(token: fixture.remoteToken)
            case .appActivation:
                break
            case .managedRequest:
                let request = controller.intentLedger.beginManagedRequest(
                    token: fixture.remoteToken,
                    workspaceId: fixture.remoteWorkspaceId
                )
                _ = controller.workspaceManager.beginManagedFocusRequest(
                    fixture.remoteToken,
                    in: fixture.remoteWorkspaceId,
                    requestId: request.requestId
                )
                assertPendingCloseStaysLocal(fixture)
            }
            XCTAssertTrue(
                controller.axEventHandler.handleAppActivation(
                    pid: fixture.closingToken.pid,
                    source: bypass == .appActivation ? .workspaceDidActivateApplication : .focusedWindowChanged
                )
            )
            controller.eventIntake.drainNow()

            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
            XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
            XCTAssertNil(controller.intentLedger.openSameAppCloseProbe())
            await settleClose(fixture, confirmRecovery: false)
            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.remoteWorkspaceId)
            XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.remoteToken)
            XCTAssertNil(controller.workspaceManager.entry(for: fixture.closingToken))
            XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        }
    }

    private static func makeFixture(layouts: LayoutPair) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMDwindleCloseFocusTests")
        controller.settings.animationsEnabled = false
        let monitor = Monitor(
            id: .init(displayId: 952_001),
            displayId: 952_001,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Dwindle Close Focus"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let localWorkspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "91", layoutType: layouts.local, controller: controller
        ))
        let remoteWorkspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "92", layoutType: layouts.remote, controller: controller
        ))
        _ = controller.workspaceManager.focusWorkspace(named: "91")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        controller.layoutRefreshController.resetState()
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        let closingToken = WindowToken(pid: 952_101, windowId: 952_201)
        let fallbackToken = WindowToken(pid: 952_102, windowId: 952_202)
        let remoteToken = WindowToken(pid: closingToken.pid, windowId: 952_203)
        addWindow(fallbackToken, to: localWorkspaceId, controller: controller)
        addWindow(
            closingToken,
            to: localWorkspaceId,
            controller: controller,
            metadata: ManagedReplacementMetadata(
                bundleId: "com.omniwm.tests.dwindle-close-focus",
                workspaceId: localWorkspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "closing",
                windowLevel: 0,
                parentWindowId: nil,
                frame: CGRect(x: 720, y: 0, width: 720, height: 860)
            )
        )
        let remoteAXRef = addWindow(remoteToken, to: remoteWorkspaceId, controller: controller)
        let closingNode = controller.niriEngine?.findNode(for: closingToken, in: localWorkspaceId)
        controller.workspaceManager.withEngineMutationScope(in: localWorkspaceId) {
            if let closingNode {
                controller.niriEngine?.activateWindow(closingNode.id, in: localWorkspaceId)
            } else {
                _ = controller.dwindleEngine?.activateWindow(closingToken, in: localWorkspaceId)
            }
        }
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: closingNode?.id,
            focusedToken: closingToken,
            in: localWorkspaceId,
            onMonitor: monitor.id
        )
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(
            closingToken,
            in: localWorkspaceId,
            onMonitor: monitor.id
        ))
        controller.factResolver.factProvider = { pid in
            guard pid == closingToken.pid else { return nil }
            return FocusedWindowFact(
                axRef: remoteAXRef,
                isFullscreen: false,
                isSystemModalSurface: false
            )
        }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)
        return Fixture(
            controller: controller,
            localWorkspaceId: localWorkspaceId,
            remoteWorkspaceId: remoteWorkspaceId,
            closingToken: closingToken,
            fallbackToken: fallbackToken,
            remoteToken: remoteToken
        )
    }

    @discardableResult
    private static func addWindow(
        _ token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        metadata: ManagedReplacementMetadata? = nil
    ) -> AXWindowRef {
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            managedReplacementMetadata: metadata
        )
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
            case .dwindle:
                _ = controller.dwindleEngine?.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
        }
        return axRef
    }

    private static func observeRemoteFocus(in fixture: Fixture) throws -> IntentID {
        XCTAssertTrue(fixture.controller.axEventHandler.handleAppActivation(
            pid: fixture.closingToken.pid,
            source: .focusedWindowChanged
        ))
        fixture.controller.eventIntake.drainNow()
        assertPendingCloseStaysLocal(fixture)
        return try XCTUnwrap(fixture.controller.intentLedger.openSameAppCloseProbe()?.intent.id)
    }

    private static func closeFocusedWindow(in fixture: Fixture) {
        fixture.controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(fixture.closingToken.windowId))
        )
    }

    private static func expireProbe(_ probeId: IntentID, in fixture: Fixture) {
        fixture.controller.deadlineWheel.cancel(intentId: probeId)
        fixture.controller.axEventHandler.handleIntentExpired(probeId)
        fixture.controller.eventIntake.drainNow()
    }

    private static func assertPendingCloseStaysLocal(_ fixture: Fixture) {
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.closingToken)
        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: fixture.closingToken))
    }

    private static func settleClose(_ fixture: Fixture, confirmRecovery: Bool = true) async {
        let controller = fixture.controller
        await controller.axEventHandler.awaitPendingManagedReplacementBursts(for: [fixture.closingToken.pid])
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        guard confirmRecovery else { return }
        guard let request = controller.intentLedger.activeManagedRequest else {
            XCTFail("Closing the focused window must request focus on the surviving local window")
            return
        }
        XCTAssertEqual(request.token, fixture.fallbackToken)
        XCTAssertEqual(request.workspaceId, fixture.localWorkspaceId)
        guard request.token == fixture.fallbackToken, request.workspaceId == fixture.localWorkspaceId else { return }
        XCTAssertTrue(controller.workspaceManager.pendingManagedFocusMatches(
            token: fixture.fallbackToken,
            workspaceId: fixture.localWorkspaceId,
            requestId: request.requestId
        ))
        XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
            fixture.fallbackToken,
            in: fixture.localWorkspaceId,
            activateWorkspaceOnMonitor: false,
            requestId: request.requestId
        ))
        XCTAssertNotNil(controller.intentLedger.confirmManagedRequest(
            token: fixture.fallbackToken,
            source: .focusedWindowChanged
        ))
    }

    private static func assertRecoveredLocally(_ fixture: Fixture) {
        let controller = fixture.controller
        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.localWorkspaceId)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fixture.fallbackToken)
        XCTAssertEqual(
            controller.workspaceManager.preferredFocusToken(in: fixture.localWorkspaceId),
            fixture.fallbackToken
        )
        XCTAssertNil(controller.workspaceManager.entry(for: fixture.closingToken))
        XCTAssertNil(controller.niriEngine?.findNode(for: fixture.closingToken, in: fixture.localWorkspaceId))
        XCTAssertFalse(controller.dwindleEngine?
            .containsWindow(fixture.closingToken, in: fixture.localWorkspaceId) ?? false)
        XCTAssertNil(controller.intentLedger.openSameAppCloseProbe())
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    private static func stop(_ fixture: Fixture) {
        fixture.controller.axEventHandler.resetManagedReplacementState()
        fixture.controller.eventIntake.close()
        fixture.controller.deadlineWheel.stop()
        fixture.controller.layoutRefreshController.resetState()
        fixture.controller.hasStartedServices = false
    }
}
