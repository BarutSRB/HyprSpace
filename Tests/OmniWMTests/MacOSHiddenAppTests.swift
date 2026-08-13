// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class MacOSHiddenAppTests: XCTestCase {
    func testLayoutRefreshInputExcludesMacOSHiddenAppWindows() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        let hiddenByPIDToken = addWindow(pid: 880_001, windowId: 880_101, to: workspaceId, controller: controller)
        let secondHiddenToken = addWindow(pid: 880_002, windowId: 880_102, to: workspaceId, controller: controller)
        let visibleToken = addWindow(pid: 880_003, windowId: 880_103, to: workspaceId, controller: controller)
        controller.workspaceManager.setAppHidden(true, pid: hiddenByPIDToken.pid, source: .ax)
        controller.workspaceManager.setAppHidden(true, pid: secondHiddenToken.pid, source: .ax)

        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let input = try XCTUnwrap(
            controller.layoutRefreshController.buildRefreshInput(
                workspaceId: workspaceId,
                monitor: monitor,
                resolveConstraints: false,
                isActiveWorkspace: true
            )
        )

        XCTAssertEqual(input.windows.map(\.token), [visibleToken])
    }

    func testFocusResolutionSkipsPIDHiddenWindowsEvenBeforeLayoutReasonUpdates() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        let hiddenToken = addWindow(pid: 880_006, windowId: 880_106, to: workspaceId, controller: controller)
        let visibleToken = addWindow(pid: 880_007, windowId: 880_107, to: workspaceId, controller: controller)
        _ = controller.workspaceManager.rememberFocus(hiddenToken, in: workspaceId)
        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .ax)

        let resolvedToken = controller.resolveAndSetWorkspaceFocusToken(for: workspaceId)

        XCTAssertEqual(resolvedToken, visibleToken)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), visibleToken)
    }

    func testFocusWindowDoesNotActivateMacOSHiddenAppWindows() throws {
        var activatedPIDs: [pid_t] = []
        var focusedTokens: [WindowToken] = []
        let controller = makeController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { activatedPIDs.append($0) },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let hiddenToken = addWindow(pid: 880_011, windowId: 880_111, to: workspaceId, controller: controller)
        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .ax)

        controller.focusWindow(hiddenToken)

        XCTAssertTrue(activatedPIDs.isEmpty)
        XCTAssertTrue(focusedTokens.isEmpty)
    }

    func testNewAdmissionInheritsHiddenApplicationState() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 880_012
        controller.workspaceManager.setAppHidden(true, pid: pid, source: .ax)

        let token = addWindow(pid: pid, windowId: 880_112, to: workspaceId, controller: controller)

        XCTAssertTrue(controller.workspaceManager.isAppHidden(token))
        XCTAssertNil(controller.workspaceManager.resolveWorkspaceFocusToken(in: workspaceId))
    }

    func testNativeFullscreenReasonSurvivesAppHideAndUnhide() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = addWindow(pid: 880_013, windowId: 880_113, to: workspaceId, controller: controller)
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: token)

        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .ax)
        controller.workspaceManager.setAppHidden(false, pid: token.pid, source: .ax)

        XCTAssertEqual(controller.workspaceManager.layoutReason(for: token), .nativeFullscreen)
    }

    func testHiddenWorldTransitionAtomicallySuppressesManagedFocus() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = addWindow(pid: 880_016, windowId: 880_116, to: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(token, in: workspaceId, requestId: 9)

        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .ax)

        XCTAssertEqual(controller.workspaceManager.focusedToken, token)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testHiddenFocusTransitionPublishesOneSessionChange() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = addWindow(pid: 880_020, windowId: 880_120, to: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        var changes = 0
        controller.workspaceManager.onSessionStateChanged = { changes += 1 }

        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .ax)

        XCTAssertEqual(changes, 1)
    }

    func testLateActivationFactsCannotRefocusHiddenApplication() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = addWindow(pid: 880_014, windowId: 880_114, to: workspaceId, controller: controller)
        let axRef = try XCTUnwrap(controller.workspaceManager.entry(for: token)?.axRef)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppHidden(pid: token.pid)
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .workspaceDidActivateApplication,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                ),
                appVisibilityGeneration: 0
            )
        )

        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testFactsCapturedWhileHiddenCannotRefocusAfterUnhide() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = addWindow(pid: 880_017, windowId: 880_117, to: workspaceId, controller: controller)
        let axRef = try XCTUnwrap(controller.workspaceManager.entry(for: token)?.axRef)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppHidden(pid: token.pid)
        let hiddenGeneration = controller.workspaceManager.appVisibilityGeneration(for: token.pid)
        controller.axEventHandler.handleAppUnhidden(pid: token.pid)

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .workspaceDidActivateApplication,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                ),
                appVisibilityGeneration: hiddenGeneration
            )
        )

        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testPIDLifecycleInvalidationRejectsFactsFromPreviousIncarnation() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = addWindow(pid: 880_018, windowId: 880_118, to: workspaceId, controller: controller)
        let axRef = try XCTUnwrap(controller.workspaceManager.entry(for: token)?.axRef)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(controller.workspaceManager.enterNonManagedFocus(preserveFocusedToken: true))
        controller.hasStartedServices = true
        let previousIncarnationGeneration = controller.workspaceManager.appVisibilityGeneration(for: token.pid)
        controller.workspaceManager.invalidateAppVisibility(for: token.pid, source: .service)

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .workspaceDidActivateApplication,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                ),
                appVisibilityGeneration: previousIncarnationGeneration
            )
        )

        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testWorkspaceUnsuppressionCannotClearMacOSAppHideFence() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = addWindow(pid: 880_015, windowId: 880_115, to: workspaceId, controller: controller)
        let entries = [(pid: token.pid, windowId: token.windowId)]

        controller.axManager.setMacOSAppHidden(true, pid: token.pid, entries: entries)
        controller.axManager.unsuppressFrameWrites(entries)

        XCTAssertTrue(controller.axManager.macOSHiddenAppPIDs.contains(token.pid))
        XCTAssertTrue(AppAXContext.isMacOSAppHidden(pid: token.pid))
        controller.axManager.setMacOSAppHidden(false, pid: token.pid, entries: entries)
        XCTAssertFalse(controller.axManager.macOSHiddenAppPIDs.contains(token.pid))
        XCTAssertFalse(AppAXContext.isMacOSAppHidden(pid: token.pid))
    }

    func testHiddenParkPlanDoesNotPublishFalseSkyLightPosition() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = addWindow(pid: 880_019, windowId: 880_119, to: workspaceId, controller: controller)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let plan = LayoutRefreshController.WindowPositionPlan(
            entry: entry,
            frame: CGRect(x: -800, y: 40, width: 400, height: 300)
        )
        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .ax)

        controller.layoutRefreshController.applyParkPositionPlans(
            [plan],
            movablePlans: [plan],
            animationTick: true
        )

        XCTAssertNil(controller.axManager.skyLightLivePosition(for: token.windowId))
        XCTAssertNil(controller.axManager.pendingParkFrameRequest(for: token.windowId))
    }

    func testHideCancelsClosingAnimationAfterWindowLeavesWorld() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = addWindow(pid: 880_023, windowId: 880_123, to: workspaceId, controller: controller)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        controller.layoutRefreshController.layoutState.closingAnimationsByDisplay[monitor.displayId] = [
            token.windowId: LayoutRefreshState.ClosingAnimation(
                pid: token.pid,
                windowId: token.windowId,
                axRef: entry.axRef,
                fromFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                displacement: CGPoint(x: 0, y: -12),
                animation: SpringAnimation(
                    from: 0,
                    to: 1,
                    startTime: 0,
                    config: .balanced,
                    displayRefreshRate: 60
                )
            )
        ]
        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)

        controller.axEventHandler.handleAppHidden(pid: token.pid)

        XCTAssertNil(controller.layoutRefreshController.layoutState.closingAnimationsByDisplay[monitor.displayId])
    }

    func testRealLayoutPlanIsRejectedAfterVisibilityTransition() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let token = addWindow(pid: 880_024, windowId: 880_124, to: workspaceId, controller: controller)
        let plan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
        })
        XCTAssertNotEqual(plan.sessionPatch.plannedSeq, 0)
        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .ax)

        XCTAssertFalse(controller.layoutRefreshController.executeLayoutPlan(plan))
    }

    func testNiriDirectionalFocusDoesNotSelectOrFocusMacOSHiddenTargetBeforeRelayout() throws {
        var focusedTokens: [WindowToken] = []
        let controller = makeController(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let hiddenToken = addWindow(pid: 880_021, windowId: 880_121, to: workspaceId, controller: controller)
        let visibleToken = addWindow(pid: 880_022, windowId: 880_122, to: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let hiddenNode = engine.addWindow(token: hiddenToken, to: workspaceId, afterSelection: nil)
        let visibleNode = engine.addWindow(
            token: visibleToken,
            to: workspaceId,
            afterSelection: hiddenNode.id,
            focusedToken: hiddenToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: visibleNode.id,
            focusedToken: visibleToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .ax)

        let didMove = controller.niriLayoutHandler.focusNeighbor(direction: .left)

        XCTAssertFalse(didMove)
        XCTAssertTrue(focusedTokens.isEmpty)
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId, visibleNode.id)
    }

    func testNiriMacOSHiddenAppRemovalAndUnhidePreservesPlacement() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let firstToken = addWindow(pid: 880_031, windowId: 880_131, to: workspaceId, controller: controller)
        let hiddenToken = addWindow(pid: 880_032, windowId: 880_132, to: workspaceId, controller: controller)
        let thirdToken = addWindow(pid: 880_033, windowId: 880_133, to: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        let hiddenNode = engine.addWindow(
            token: hiddenToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        let thirdNode = engine.addWindow(
            token: thirdToken,
            to: workspaceId,
            afterSelection: hiddenNode.id,
            focusedToken: hiddenToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: thirdNode.id,
            focusedToken: thirdToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        controller.workspaceManager.setNiriRestorePlacements(engine.persistedPlacements(in: workspaceId))

        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .ax)
        let hidePlan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
        })
        XCTAssertTrue(controller.layoutRefreshController.executeLayoutPlan(hidePlan))
        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            [[firstToken], [thirdToken]]
        )
        XCTAssertEqual(controller.workspaceManager.restoreIntent(for: thirdToken)?.niriPlacement?.columnIndex, 2)

        controller.workspaceManager.setAppHidden(false, pid: hiddenToken.pid, source: .ax)
        _ = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }

        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            [[firstToken], [hiddenToken], [thirdToken]]
        )
    }

    private func makeController(
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
    ) -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMMacOSHiddenAppTests-\(UUID().uuidString)", isDirectory: true)
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
        return WMController(settings: settings, windowFocusOperations: windowFocusOperations)
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }
}
