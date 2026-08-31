// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AppTerminationFocusRecoveryTests: XCTestCase {
    private final class OperationRecorder {
        var operations: [String] = []
        var factPIDs: [pid_t] = []
    }

    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let finderToken: WindowToken
        let fallbackToken: WindowToken
        let departingToken: WindowToken
        let finderRef: AXWindowRef
        let fallbackRef: AXWindowRef
        let finderNode: NiriWindow
        let fallbackNode: NiriWindow
        let recorder: OperationRecorder
    }

    func testTerminationFirstSuppressesNativeFallbackAndPreservesNiriViewport() throws {
        let fixture = try makeFixture(suffix: 1)
        defer { stop(fixture) }
        let settledViewport = fixture.controller.workspaceManager.niriViewportState(
            for: fixture.workspaceId
        )

        fixture.controller.serviceLifecycleManager.handleAppTerminated(
            pid: fixture.departingToken.pid,
            frontmostPID: fixture.finderToken.pid
        )

        XCTAssertNil(fixture.controller.workspaceManager.entry(for: fixture.departingToken))
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.token,
            fixture.fallbackToken
        )
        let operationsAfterRecovery = fixture.recorder.operations

        XCTAssertFalse(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.finderToken.pid,
                source: .workspaceDidActivateApplication
            )
        )
        XCTAssertFalse(fixture.recorder.factPIDs.contains(fixture.finderToken.pid))
        XCTAssertEqual(fixture.recorder.operations, operationsAfterRecovery)

        XCTAssertTrue(
            fixture.controller.eventIntake.enqueue(
                .axFocusedWindowChanged(
                    pid: fixture.fallbackToken.pid,
                    callbackGeneration: nil
                )
            )
        )
        XCTAssertTrue(
            fixture.controller.eventIntake.enqueue(
                .appActivated(pid: fixture.finderToken.pid)
            )
        )
        fixture.controller.eventIntake.drainNow()
        XCTAssertNotEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.finderToken)
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.fallbackToken)
        let recoveredViewport = fixture.controller.workspaceManager.niriViewportState(
            for: fixture.workspaceId
        )
        XCTAssertEqual(recoveredViewport.selectedNodeId, settledViewport.selectedNodeId)
        XCTAssertEqual(recoveredViewport.activeColumnIndex, settledViewport.activeColumnIndex)
        XCTAssertEqual(recoveredViewport.viewOffset, settledViewport.viewOffset, accuracy: 0.5)

        let retiring = try XCTUnwrap(
            fixture.controller.intentLedger.openAppTerminationFocusRecovery()
        )
        XCTAssertFalse(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.finderToken.pid,
                source: .cgsFrontAppChanged
            )
        )
        fixture.controller.serviceLifecycleManager.handleAppTerminated(
            pid: fixture.departingToken.pid,
            frontmostPID: fixture.finderToken.pid
        )
        XCTAssertEqual(fixture.recorder.operations, operationsAfterRecovery)

        fixture.controller.deadlineWheel.cancel(intentId: retiring.intent.id)
        fixture.controller.axEventHandler.handleIntentExpired(retiring.intent.id)
        XCTAssertNil(fixture.controller.intentLedger.openAppTerminationFocusRecovery())

        XCTAssertTrue(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.finderToken.pid,
                source: .workspaceDidActivateApplication
            )
        )
        fixture.controller.eventIntake.drainNow()
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.finderToken)
    }

    func testActivationFirstTerminationRecoversBeforeAcceptingFallback() throws {
        let fixture = try makeFixture(suffix: 2)
        defer { stop(fixture) }
        fixture.controller.axEventHandler.applicationIsTerminatedProvider = {
            $0 == fixture.departingToken.pid
        }

        XCTAssertFalse(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.finderToken.pid,
                source: .workspaceDidActivateApplication
            )
        )
        let verifying = try XCTUnwrap(
            fixture.controller.intentLedger.openAppTerminationFocusRecovery()
        )
        fixture.controller.deadlineWheel.cancel(intentId: verifying.intent.id)
        fixture.controller.axEventHandler.handleIntentExpired(verifying.intent.id)
        fixture.controller.eventIntake.drainNow()

        XCTAssertNil(fixture.controller.workspaceManager.entry(for: fixture.departingToken))
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.token,
            fixture.fallbackToken
        )
        XCTAssertFalse(fixture.recorder.factPIDs.contains(fixture.finderToken.pid))

        XCTAssertTrue(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.fallbackToken.pid,
                source: .focusedWindowChanged
            )
        )
        fixture.controller.eventIntake.drainNow()
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.fallbackToken)
    }

    func testTerminationRecoversWhenDepartingEntryWasAlreadyRemoved() throws {
        let fixture = try makeFixture(suffix: 9)
        defer { stop(fixture) }

        XCTAssertFalse(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.finderToken.pid,
                source: .workspaceDidActivateApplication
            )
        )
        XCTAssertNotNil(fixture.controller.intentLedger.openAppTerminationFocusRecovery())
        XCTAssertNotNil(
            fixture.controller.workspaceManager.removeWindow(
                pid: fixture.departingToken.pid,
                windowId: fixture.departingToken.windowId
            )
        )

        fixture.controller.serviceLifecycleManager.handleAppTerminated(
            pid: fixture.departingToken.pid,
            frontmostPID: fixture.finderToken.pid
        )

        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.token,
            fixture.fallbackToken
        )
        XCTAssertEqual(
            fixture.controller.intentLedger.openAppTerminationFocusRecovery()?.payload.terminationHandled,
            true
        )
        XCTAssertFalse(fixture.recorder.factPIDs.contains(fixture.finderToken.pid))
    }

    func testLivingFloatingAppReplaysDeferredNativeSwitchOnNextIntakeTurn() throws {
        let fixture = try makeFixture(suffix: 3)
        defer { stop(fixture) }
        fixture.controller.axEventHandler.applicationIsTerminatedProvider = { _ in false }

        XCTAssertFalse(
            fixture.controller.axEventHandler.handleAppActivation(
                pid: fixture.finderToken.pid,
                source: .workspaceDidActivateApplication
            )
        )
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.departingToken)
        let verifying = try XCTUnwrap(
            fixture.controller.intentLedger.openAppTerminationFocusRecovery()
        )

        fixture.controller.deadlineWheel.cancel(intentId: verifying.intent.id)
        fixture.controller.axEventHandler.handleIntentExpired(verifying.intent.id)
        fixture.controller.eventIntake.drainNow()

        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: fixture.departingToken))
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.finderToken)
        XCTAssertNil(fixture.controller.intentLedger.openAppTerminationFocusRecovery())
    }

    func testFailedPreferredRecoveryAcceptsStillFrontmostFallbackAtDeadline() throws {
        let fixture = try makeFixture(suffix: 7)
        defer { stop(fixture) }
        fixture.controller.axEventHandler.frontmostApplicationPIDProvider = {
            fixture.finderToken.pid
        }

        fixture.controller.serviceLifecycleManager.handleAppTerminated(
            pid: fixture.departingToken.pid,
            frontmostPID: fixture.finderToken.pid
        )
        let recovery = try XCTUnwrap(
            fixture.controller.intentLedger.openAppTerminationFocusRecovery()
        )
        fixture.controller.deadlineWheel.cancel(intentId: recovery.intent.id)
        fixture.controller.axEventHandler.handleIntentExpired(recovery.intent.id)
        fixture.controller.eventIntake.drainNow()

        XCTAssertNil(fixture.controller.intentLedger.openAppTerminationFocusRecovery())
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.finderToken)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testRecoveryIntentRekeysExactTokensAndCancelsAcrossPID() throws {
        let fixture = try makeFixture(suffix: 8)
        defer { stop(fixture) }
        fixture.controller.serviceLifecycleManager.handleAppTerminated(
            pid: fixture.departingToken.pid,
            frontmostPID: fixture.finderToken.pid
        )
        let replacement = WindowToken(
            pid: fixture.fallbackToken.pid,
            windowId: fixture.fallbackToken.windowId + 1
        )

        fixture.controller.intentLedger.rekeyManagedRequest(
            from: fixture.fallbackToken,
            to: replacement
        )

        XCTAssertEqual(
            fixture.controller.intentLedger.openAppTerminationFocusRecovery()?.payload.preferredTiledToken,
            replacement
        )
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.token,
            replacement
        )

        fixture.controller.intentLedger.rekeyManagedRequest(
            from: replacement,
            to: WindowToken(pid: replacement.pid + 1, windowId: replacement.windowId + 1)
        )

        XCTAssertNil(fixture.controller.intentLedger.openAppTerminationFocusRecovery())
    }

    func testDwindleTerminationRestoresRetainedTiledFocus() throws {
        let recorder = OperationRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMAppTerminationFocusRecoveryDwindleTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { recorder.operations.append("activate:\($0)") },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append("focus:\(pid):\(windowId)")
                },
                raiseWindow: { _ in recorder.operations.append("raise") },
                orderWindow: { recorder.operations.append("order:\($0)") }
            )
        )
        defer {
            controller.eventIntake.close()
            controller.deadlineWheel.stop()
            controller.layoutRefreshController.resetState()
            controller.hasStartedServices = false
        }
        let monitor = Monitor(
            id: .init(displayId: 780_200),
            displayId: 780_200,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "App Termination Dwindle Recovery"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: "91",
                layoutType: .dwindle,
                controller: controller
            )
        )
        _ = controller.workspaceManager.focusWorkspace(named: "91")
        controller.dwindleLayoutHandler.enableDwindleLayout()

        let finderToken = WindowToken(pid: 780_201, windowId: 780_202)
        let fallbackToken = WindowToken(pid: 780_203, windowId: 780_204)
        let departingToken = WindowToken(pid: 780_205, windowId: 780_206)
        let finderRef = addWindow(
            finderToken,
            mode: .tiling,
            workspaceId: workspaceId,
            controller: controller
        )
        let fallbackRef = addWindow(
            fallbackToken,
            mode: .tiling,
            workspaceId: workspaceId,
            controller: controller
        )
        _ = addWindow(
            departingToken,
            mode: .floating,
            workspaceId: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.dwindleEngine)
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            _ = engine.addWindow(token: finderToken, to: workspaceId, activeWindowFrame: nil)
            _ = engine.addWindow(token: fallbackToken, to: workspaceId, activeWindowFrame: nil)
            _ = engine.activateWindow(fallbackToken, in: workspaceId)
        }
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                fallbackToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                departingToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.factResolver.factProvider = { pid in
            if pid == finderToken.pid {
                return FocusedWindowFact(
                    axRef: finderRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            }
            if pid == fallbackToken.pid {
                return FocusedWindowFact(
                    axRef: fallbackRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            }
            return nil
        }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)
        recorder.operations.removeAll()

        controller.serviceLifecycleManager.handleAppTerminated(
            pid: departingToken.pid,
            frontmostPID: finderToken.pid
        )

        XCTAssertEqual(engine.projectedActiveToken(in: workspaceId), fallbackToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, fallbackToken)
        XCTAssertFalse(
            controller.axEventHandler.handleAppActivation(
                pid: finderToken.pid,
                source: .workspaceDidActivateApplication
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.handleAppActivation(
                pid: fallbackToken.pid,
                source: .focusedWindowChanged
            )
        )
        controller.eventIntake.drainNow()

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, fallbackToken)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
    }

    func testMouseAndManagedFocusIntentBypassTerminationProbe() throws {
        let mouseFixture = try makeFixture(suffix: 4)
        defer { stop(mouseFixture) }
        mouseFixture.controller.axEventHandler.applicationIsTerminatedProvider = { _ in false }
        mouseFixture.controller.axEventHandler.noteMouseFocusIntent(token: mouseFixture.finderToken)

        XCTAssertTrue(
            mouseFixture.controller.axEventHandler.handleAppActivation(
                pid: mouseFixture.finderToken.pid,
                source: .workspaceDidActivateApplication
            )
        )
        mouseFixture.controller.eventIntake.drainNow()
        XCTAssertEqual(mouseFixture.controller.workspaceManager.selectedManagedToken, mouseFixture.finderToken)
        XCTAssertNil(mouseFixture.controller.intentLedger.openAppTerminationFocusRecovery())

        let managedFixture = try makeFixture(suffix: 5)
        defer { stop(managedFixture) }
        managedFixture.controller.axEventHandler.applicationIsTerminatedProvider = { _ in false }
        let request = managedFixture.controller.intentLedger.beginManagedRequest(
            token: managedFixture.finderToken,
            workspaceId: managedFixture.workspaceId
        )
        XCTAssertTrue(
            managedFixture.controller.workspaceManager.beginManagedFocusRequest(
                managedFixture.finderToken,
                in: managedFixture.workspaceId,
                requestId: request.requestId
            )
        )

        XCTAssertTrue(
            managedFixture.controller.axEventHandler.handleAppActivation(
                pid: managedFixture.finderToken.pid,
                source: .focusedWindowChanged
            )
        )
        managedFixture.controller.eventIntake.drainNow()
        XCTAssertEqual(managedFixture.controller.workspaceManager.selectedManagedToken, managedFixture.finderToken)
        XCTAssertNil(managedFixture.controller.intentLedger.openAppTerminationFocusRecovery())

        let delayedMouseFixture = try makeFixture(suffix: 6)
        defer { stop(delayedMouseFixture) }
        delayedMouseFixture.controller.axEventHandler.applicationIsTerminatedProvider = { _ in true }

        XCTAssertFalse(
            delayedMouseFixture.controller.axEventHandler.handleAppActivation(
                pid: delayedMouseFixture.finderToken.pid,
                source: .workspaceDidActivateApplication
            )
        )
        let verifying = try XCTUnwrap(
            delayedMouseFixture.controller.intentLedger.openAppTerminationFocusRecovery()
        )
        delayedMouseFixture.controller.axEventHandler.noteMouseFocusIntent(
            token: delayedMouseFixture.finderToken
        )
        delayedMouseFixture.controller.deadlineWheel.cancel(intentId: verifying.intent.id)
        delayedMouseFixture.controller.axEventHandler.handleIntentExpired(verifying.intent.id)
        delayedMouseFixture.controller.eventIntake.drainNow()

        XCTAssertNotNil(
            delayedMouseFixture.controller.workspaceManager.entry(for: delayedMouseFixture.departingToken)
        )
        XCTAssertEqual(
            delayedMouseFixture.controller.workspaceManager.selectedManagedToken,
            delayedMouseFixture.finderToken
        )
        XCTAssertNil(
            delayedMouseFixture.controller.intentLedger.openAppTerminationFocusRecovery()
        )
    }

    private func makeFixture(suffix: Int) throws -> Fixture {
        let recorder = OperationRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMAppTerminationFocusRecoveryTests\(suffix)",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { recorder.operations.append("activate:\($0)") },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append("focus:\(pid):\(windowId)")
                },
                raiseWindow: { _ in recorder.operations.append("raise") },
                orderWindow: { recorder.operations.append("order:\($0)") }
            )
        )
        let monitor = Monitor(
            id: .init(displayId: CGDirectDisplayID(780_100 + suffix)),
            displayId: CGDirectDisplayID(780_100 + suffix),
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "App Termination Focus Recovery"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let finderToken = WindowToken(pid: pid_t(780_000 + suffix * 10), windowId: 780_001 + suffix * 10)
        let fallbackToken = WindowToken(pid: pid_t(780_002 + suffix * 10), windowId: 780_003 + suffix * 10)
        let departingToken = WindowToken(pid: pid_t(780_004 + suffix * 10), windowId: 780_005 + suffix * 10)
        let finderRef = addWindow(finderToken, mode: .tiling, workspaceId: workspaceId, controller: controller)
        let fallbackRef = addWindow(
            fallbackToken,
            mode: .tiling,
            workspaceId: workspaceId,
            controller: controller
        )
        _ = addWindow(
            departingToken,
            mode: .floating,
            workspaceId: workspaceId,
            controller: controller
        )

        let engine = try XCTUnwrap(controller.niriEngine)
        let finderNode = engine.addWindow(token: finderToken, to: workspaceId, afterSelection: nil)
        let fallbackNode = engine.addWindow(
            token: fallbackToken,
            to: workspaceId,
            afterSelection: finderNode.id,
            focusedToken: finderToken
        )
        engine.column(of: finderNode)?.cachedWidth = 700
        engine.column(of: fallbackNode)?.cachedWidth = 700
        let monitorId = controller.workspaceManager.monitorId(for: workspaceId)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: fallbackNode.id,
            focusedToken: fallbackToken,
            in: workspaceId,
            onMonitor: monitorId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                fallbackToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                departingToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        var viewport = controller.workspaceManager.niriViewportState(for: workspaceId)
        controller.niriLayoutHandler.activateNode(
            fallbackNode,
            in: workspaceId,
            state: &viewport,
            options: .init(
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        controller.workspaceManager.updateNiriViewportState(viewport, for: workspaceId)

        controller.factResolver.factProvider = { pid in
            recorder.factPIDs.append(pid)
            if pid == finderToken.pid {
                return FocusedWindowFact(
                    axRef: finderRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            }
            if pid == fallbackToken.pid {
                return FocusedWindowFact(
                    axRef: fallbackRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            }
            return nil
        }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)
        recorder.operations.removeAll()
        recorder.factPIDs.removeAll()

        return Fixture(
            controller: controller,
            workspaceId: workspaceId,
            finderToken: finderToken,
            fallbackToken: fallbackToken,
            departingToken: departingToken,
            finderRef: finderRef,
            fallbackRef: fallbackRef,
            finderNode: finderNode,
            fallbackNode: fallbackNode,
            recorder: recorder
        )
    }

    @discardableResult
    private func addWindow(
        _ token: WindowToken,
        mode: TrackedWindowMode,
        workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> AXWindowRef {
        let ref = WindowAdmissionTestSupport.axRef(for: token)
        _ = controller.workspaceManager.addWindow(
            ref,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: mode
        )
        return ref
    }

    private func stop(_ fixture: Fixture) {
        fixture.controller.eventIntake.close()
        fixture.controller.deadlineWheel.stop()
        fixture.controller.layoutRefreshController.resetState()
        fixture.controller.hasStartedServices = false
    }
}
