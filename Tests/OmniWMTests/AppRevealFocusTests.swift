// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AppRevealFocusTests: XCTestCase {
    func testHiddenSelectionOnlyRequestsUnhideBeforeAuthoritativeNotification() throws {
        let fixture = try makeFixture(pid: 91_001, windowId: 91_101)
        var unhiddenPIDs: [pid_t] = []
        let handler = makeHandler(controller: fixture.controller) { pid in
            unhiddenPIDs.append(pid)
            return true
        }
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )
        let plannedSeq = fixture.controller.workspaceManager.worldSeq
        let focusedToken = fixture.controller.workspaceManager.focusedToken
        let pendingToken = fixture.controller.workspaceManager.pendingFocusedToken
        let activeWorkspaceId = fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id

        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))

        XCTAssertEqual(unhiddenPIDs, [fixture.token.pid])
        XCTAssertTrue(fixture.controller.workspaceManager.isAppHidden(pid: fixture.token.pid))
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, plannedSeq)
        XCTAssertEqual(fixture.controller.workspaceManager.focusedToken, focusedToken)
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, pendingToken)
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            activeWorkspaceId
        )
        let open = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)
        )
        XCTAssertEqual(open.payload.token, fixture.token)
        XCTAssertEqual(open.payload.workspaceId, fixture.workspaceId)
        XCTAssertEqual(open.payload.handleIdentity, ObjectIdentifier(fixture.handle))
    }

    func testStaleSameTokenHandleCannotRequestUnhide() throws {
        let fixture = try makeFixture(pid: 91_002, windowId: 91_102)
        let staleHandle = WindowHandle(id: fixture.token)
        var unhideCount = 0
        let handler = makeHandler(controller: fixture.controller) { _ in
            unhideCount += 1
            return true
        }
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }

        XCTAssertFalse(handler.navigateToExplicitlySelectedWindow(handle: staleHandle))
        XCTAssertEqual(unhideCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid))
        XCTAssertTrue(AppVisibilityTrace.shared.dump().contains("reason=handle_identity_changed"))
    }

    func testNewestExplicitRevealWins() {
        let ledger = IntentLedger()
        let firstToken = WindowToken(pid: 91_003, windowId: 91_103)
        let secondToken = WindowToken(pid: 91_004, windowId: 91_104)
        let first = ledger.beginAppRevealFocus(
            token: firstToken,
            workspaceId: UUID(),
            handleIdentity: ObjectIdentifier(WindowHandle(id: firstToken)),
            appVisibilityGeneration: 2,
            focusFingerprint: emptyFocusFingerprint()
        )
        let second = ledger.beginAppRevealFocus(
            token: secondToken,
            workspaceId: UUID(),
            handleIdentity: ObjectIdentifier(WindowHandle(id: secondToken)),
            appVisibilityGeneration: 4,
            focusFingerprint: emptyFocusFingerprint()
        )

        XCTAssertEqual(ledger.intent(id: first.id)?.phase, .superseded)
        XCTAssertEqual(ledger.intent(id: second.id)?.phase, .pending)
        XCTAssertNil(ledger.openAppRevealFocusIntent(pid: firstToken.pid))
        XCTAssertEqual(ledger.openAppRevealFocusIntent(pid: secondToken.pid)?.intent.id, second.id)
    }

    func testExternalFocusFingerprintChangeRejectsRevealContinuation() throws {
        let fixture = try makeFixture(pid: 91_005, windowId: 91_105)
        let handler = makeHandler(controller: fixture.controller) { _ in true }
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )
        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))
        let intentId = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)?.intent.id
        )
        _ = fixture.controller.workspaceManager.enterNonManagedFocus(
            preserveFocusedToken: true,
            target: WindowToken(pid: 99_999, windowId: 99_999)
        )
        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertFalse(handler.completeAppRevealFocus(intentId: intentId))
        XCTAssertEqual(fixture.controller.intentLedger.intent(id: intentId)?.phase, .cancelled)
    }

    func testAuthoritativeVisibilityGenerationAllowsExactRevealContinuation() throws {
        let fixture = try makeFixture(pid: 91_009, windowId: 91_109)
        let handler = makeHandler(controller: fixture.controller) { _ in true }
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )
        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))
        let intentId = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)?.intent.id
        )
        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertTrue(handler.completeAppRevealFocus(intentId: intentId))
        XCTAssertEqual(fixture.controller.intentLedger.intent(id: intentId)?.phase, .confirmed)
    }

    func testClosedTargetRejectsRevealContinuation() throws {
        let fixture = try makeFixture(pid: 91_006, windowId: 91_106)
        let handler = makeHandler(controller: fixture.controller) { _ in true }
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )
        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))
        let intentId = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)?.intent.id
        )
        _ = fixture.controller.workspaceManager.removeWindow(
            pid: fixture.token.pid,
            windowId: fixture.token.windowId
        )
        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertFalse(handler.completeAppRevealFocus(intentId: intentId))
        XCTAssertEqual(fixture.controller.intentLedger.intent(id: intentId)?.phase, .cancelled)
    }

    func testRevealIntentRekeysOnlyWithinSamePIDAndTerminationCancels() throws {
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }
        let ledger = IntentLedger()
        let oldToken = WindowToken(pid: 91_007, windowId: 91_107)
        let samePIDToken = WindowToken(pid: oldToken.pid, windowId: 91_108)
        let handle = WindowHandle(id: oldToken)
        let fingerprint = AppRevealFocusFingerprint(
            focusedToken: oldToken,
            pendingFocusedToken: oldToken,
            pendingFocusedWorkspaceId: nil,
            isNonManagedFocusActive: true,
            nonManagedFocusToken: oldToken,
            interactionMonitorId: nil,
            activeWorkspaceIdsByMonitor: [:]
        )
        let samePIDIntent = ledger.beginAppRevealFocus(
            token: oldToken,
            workspaceId: UUID(),
            handleIdentity: ObjectIdentifier(handle),
            appVisibilityGeneration: 8,
            focusFingerprint: fingerprint
        )

        ledger.rekeyManagedRequest(from: oldToken, to: samePIDToken)

        let rekeyed = try XCTUnwrap(ledger.openAppRevealFocusIntent(pid: oldToken.pid))
        XCTAssertEqual(rekeyed.payload.token, samePIDToken)
        XCTAssertEqual(rekeyed.payload.handleIdentity, ObjectIdentifier(handle))
        XCTAssertEqual(rekeyed.payload.focusFingerprint.focusedToken, samePIDToken)
        XCTAssertEqual(rekeyed.payload.focusFingerprint.pendingFocusedToken, samePIDToken)
        XCTAssertEqual(rekeyed.payload.focusFingerprint.nonManagedFocusToken, samePIDToken)
        XCTAssertEqual(ledger.intent(id: samePIDIntent.id)?.phase, .pending)

        ledger.cancelAppRevealFocus(pid: samePIDToken.pid)
        XCTAssertEqual(ledger.intent(id: samePIDIntent.id)?.phase, .cancelled)
        ledger.rekeyManagedRequest(
            from: samePIDToken,
            to: WindowToken(pid: samePIDToken.pid, windowId: 91_109)
        )

        let crossPIDIntent = ledger.beginAppRevealFocus(
            token: oldToken,
            workspaceId: UUID(),
            handleIdentity: ObjectIdentifier(handle),
            appVisibilityGeneration: 10,
            focusFingerprint: emptyFocusFingerprint()
        )
        ledger.rekeyManagedRequest(
            from: oldToken,
            to: WindowToken(pid: 91_008, windowId: oldToken.windowId)
        )
        XCTAssertEqual(ledger.intent(id: crossPIDIntent.id)?.phase, .cancelled)
        let trace = AppVisibilityTrace.shared.dump()
        XCTAssertTrue(trace.contains("outcome=rekeyed"))
        XCTAssertEqual(trace.components(separatedBy: "outcome=rekeyed").count - 1, 1)
        XCTAssertTrue(trace.contains("outcome=cancelled"))
        XCTAssertTrue(trace.contains("reason=pid_changed"))
    }

    func testNewerWorkspaceSelectionRejectsRevealContinuation() throws {
        let fixture = try makeFixture(pid: 91_010, windowId: 91_110)
        let handler = makeHandler(controller: fixture.controller) { _ in true }
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )
        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))
        let intentId = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)?.intent.id
        )
        let otherWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        XCTAssertNotNil(fixture.controller.workspaceManager.focusWorkspace(id: otherWorkspaceId))
        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertFalse(handler.completeAppRevealFocus(intentId: intentId))
        XCTAssertEqual(fixture.controller.intentLedger.intent(id: intentId)?.phase, .cancelled)
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            otherWorkspaceId
        )
    }

    func testHiddenNativeFullscreenSelectionRequestsAndCompletesReveal() throws {
        let fixture = try makeFixture(pid: 91_011, windowId: 91_111)
        let handler = makeHandler(controller: fixture.controller) { _ in true }
        XCTAssertTrue(
            fixture.controller.workspaceManager.requestNativeFullscreenEnter(
                fixture.token,
                in: fixture.workspaceId
            )
        )
        XCTAssertTrue(fixture.controller.workspaceManager.markNativeFullscreenSuspended(fixture.token))
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))
        let intentId = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)?.intent.id
        )
        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertTrue(handler.completeAppRevealFocus(intentId: intentId))
        XCTAssertEqual(fixture.controller.intentLedger.intent(id: intentId)?.phase, .confirmed)
    }

    func testHiddenScratchpadSelectionDefersScratchpadMutationUntilUnhide() throws {
        let fixture = try makeFixture(pid: 91_012, windowId: 91_112)
        let handler = makeHandler(controller: fixture.controller) { _ in true }
        XCTAssertTrue(fixture.controller.workspaceManager.setScratchpadToken(fixture.token))
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: fixture.monitor.id,
            reason: .scratchpad
        )
        fixture.controller.workspaceManager.setHiddenState(hiddenState, for: fixture.token)
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertTrue(
            handler.revealScratchpadFromBar(
                handle: fixture.handle,
                monitorId: fixture.monitor.id
            )
        )

        let open = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)
        )
        XCTAssertEqual(open.payload.destination, .scratchpad(monitorId: fixture.monitor.id))
        XCTAssertEqual(fixture.controller.workspaceManager.hiddenState(for: fixture.token), hiddenState)
        XCTAssertTrue(fixture.controller.workspaceManager.isAppHidden(pid: fixture.token.pid))
    }

    func testCommandPaletteSelectionUsesScratchpadRevealDestination() throws {
        let fixture = try makeFixture(pid: 91_014, windowId: 91_114)
        let handler = makeHandler(controller: fixture.controller) { _ in true }
        XCTAssertTrue(fixture.controller.workspaceManager.setScratchpadToken(fixture.token))
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: fixture.monitor.id,
            reason: .scratchpad
        )
        fixture.controller.workspaceManager.setHiddenState(hiddenState, for: fixture.token)
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: fixture.handle))

        let open = try XCTUnwrap(
            fixture.controller.intentLedger.openAppRevealFocusIntent(pid: fixture.token.pid)
        )
        XCTAssertEqual(open.payload.destination, .scratchpad(monitorId: nil))
        XCTAssertEqual(fixture.controller.workspaceManager.hiddenState(for: fixture.token), hiddenState)
    }

    func testScratchpadCommandDoesNotClearStateForMacOSHiddenApp() throws {
        let fixture = try makeFixture(pid: 91_013, windowId: 91_113)
        XCTAssertTrue(fixture.controller.workspaceManager.setScratchpadToken(fixture.token))
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: fixture.monitor.id,
            reason: .scratchpad
        )
        fixture.controller.workspaceManager.setHiddenState(hiddenState, for: fixture.token)
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: fixture.token.pid,
            source: .service
        )

        XCTAssertEqual(fixture.controller.toggleScratchpadWindow(), .notFound)
        XCTAssertEqual(fixture.controller.workspaceManager.hiddenState(for: fixture.token), hiddenState)
    }

    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
        let handle: WindowHandle
    }

    private func makeFixture(pid: pid_t, windowId: Int) throws -> Fixture {
        let settings = makeSettingsStore()
        settings.workspaceConfigurations = settings.workspaceConfigurations.map {
            $0.name == "1" ? $0.with(layoutType: .dwindle) : $0
        }
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let monitor = Monitor(
            id: .init(displayId: 91_000),
            displayId: 91_000,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "App Reveal Focus Test"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
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
            monitor: monitor,
            workspaceId: workspaceId,
            token: token,
            handle: handle
        )
    }

    private func makeHandler(
        controller: WMController,
        unhideApplication: @escaping (pid_t) -> Bool
    ) -> WindowActionHandler {
        WindowActionHandler(
            controller: controller,
            visibleWindowInfoProvider: { [] },
            visibleOwnedWindowsProvider: { [] },
            frontOwnedWindow: { _ in },
            unhideApplication: unhideApplication
        )
    }

    private func emptyFocusFingerprint() -> AppRevealFocusFingerprint {
        AppRevealFocusFingerprint(
            focusedToken: nil,
            pendingFocusedToken: nil,
            pendingFocusedWorkspaceId: nil,
            isNonManagedFocusActive: false,
            nonManagedFocusToken: nil,
            interactionMonitorId: nil,
            activeWorkspaceIdsByMonitor: [:]
        )
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMAppRevealFocusTests-\(UUID().uuidString)", isDirectory: true)
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
}
