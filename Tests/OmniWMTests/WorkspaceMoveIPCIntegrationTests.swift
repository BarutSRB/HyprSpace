// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WorkspaceMoveIPCIntegrationTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let left: Monitor
        let center: Monitor
        let right: Monitor
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let centerWorkspaceId: WorkspaceDescriptor.ID
        let interactionWorkspaceId: WorkspaceDescriptor.ID
    }

    private struct MovedFloatingWindow {
        let token: WindowToken
        let sourceFrame: CGRect
        let relocation: WorkspaceFloatingRelocation
        let outcome: WorkspaceMonitorMoveOutcome
    }

    func testBridgeMapsWorkspaceAssignmentConflict() {
        let response = IPCApplicationBridge.response(
            for: .workspaceAssignmentConflict,
            id: "workspace-move",
            kind: .workspace
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "workspace-move")
        XCTAssertEqual(response.kind, .workspace)
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.code, .workspaceAssignmentConflict)
    }

    func testBridgeMapsWorkspaceStateConflict() {
        let response = IPCApplicationBridge.response(
            for: .workspaceStateConflict,
            id: "workspace-move",
            kind: .workspace
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "workspace-move")
        XCTAssertEqual(response.kind, .workspace)
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.code, .workspaceStateConflict)
    }

    func testBridgeMapsNoChangeToIgnoredStatus() {
        let response = IPCApplicationBridge.response(for: .noChange, id: "switch", kind: .command)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "switch")
        XCTAssertEqual(response.status, .ignored)
        XCTAssertEqual(response.code, .noChange)
    }

    func testHotkeyMovesActiveConfiguredWorkspaceWithRuntimeOverrideWithoutSwap() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let manager = controller.workspaceManager
        _ = manager.setInteractionMonitor(fixture.left.id)

        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.sourceWorkspaceId)
        XCTAssertNil(manager.descriptor(for: fixture.sourceWorkspaceId)?.runtimeMonitorOverride)

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .moveWorkspaceToMonitor(.right),
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .executed
        )

        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.center.id
        )
        XCTAssertEqual(
            manager.descriptor(for: fixture.sourceWorkspaceId)?.runtimeMonitorOverride,
            OutputId(from: fixture.center)
        )
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.centerWorkspaceId)?.id,
            fixture.center.id
        )
        XCTAssertEqual(
            manager.activeWorkspace(on: fixture.center.id)?.id,
            fixture.sourceWorkspaceId
        )
        XCTAssertEqual(
            controller.settings.workspaceConfigurations
                .first { $0.name == "1" }?
                .monitorAssignment,
            .specificDisplay(OutputId(from: fixture.left))
        )
    }

    func testHotkeyMoveAtMonitorEdgeDoesNotWrapOrMutate() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let manager = controller.workspaceManager
        _ = manager.setInteractionMonitor(fixture.left.id)
        let worldSeq = manager.worldSeq
        let visibleWorkspaces = manager.activeVisibleWorkspaceMap()

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .moveWorkspaceToMonitor(.left),
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .executed
        )

        XCTAssertEqual(manager.worldSeq, worldSeq)
        XCTAssertEqual(manager.activeVisibleWorkspaceMap(), visibleWorkspaces)
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.left.id
        )
        XCTAssertNil(manager.descriptor(for: fixture.sourceWorkspaceId)?.runtimeMonitorOverride)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testRouterResolvesDirectionFromNamedWorkspaceAndHonorsForce() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")
        let request = IPCWorkspaceRequest.moveToMonitor(
            target: .displayName("Slack"),
            direction: .right
        )

        XCTAssertEqual(router.handle(request), .workspaceAssignmentConflict)
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.left.id
        )

        XCTAssertEqual(
            router.handle(
                .moveToMonitor(
                    target: .displayName("Slack"),
                    direction: .right,
                    force: true
                )
            ),
            .executed
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.center.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.center.id)?.id,
            fixture.sourceWorkspaceId
        )
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, fixture.right.id)
    }

    func testRouterReturnsNotFoundWhenSelectedWorkspaceHasNoAdjacentMonitor() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")

        XCTAssertEqual(
            router.handle(
                .moveToMonitor(
                    target: .displayName("Slack"),
                    direction: .left,
                    force: true
                )
            ),
            .notFound
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.left.id
        )
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, fixture.right.id)
    }

    func testRouterReturnsStateConflictForUnsafeManagedFocus() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let manager = fixture.controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(941_201), windowId: 941_301),
            pid: 941_201,
            windowId: 941_301,
            to: fixture.sourceWorkspaceId,
            mode: .tiling
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                token,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.left.id
            )
        )
        manager.setLayoutReason(.nativeFullscreen, for: token)
        let initialSeq = manager.worldSeq
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")

        XCTAssertEqual(
            router.handle(
                .moveToMonitor(
                    target: .displayName("Slack"),
                    direction: .right,
                    force: true
                )
            ),
            .workspaceStateConflict
        )
        XCTAssertEqual(manager.worldSeq, initialSeq)
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.left.id
        )
    }

    func testRouterRejectsAmbiguousCaseInsensitiveDisplayNameWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        var configurations = fixture.controller.settings.workspaceConfigurations
        configurations[1].displayName = "sLaCk"
        fixture.controller.settings.workspaceConfigurations = configurations
        fixture.controller.workspaceManager.applySettings()
        let manager = fixture.controller.workspaceManager
        let initialSeq = manager.worldSeq
        let initialMonitorId = manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")

        XCTAssertEqual(
            router.handle(
                .moveToMonitor(
                    target: .displayName("SLACK"),
                    direction: .right,
                    force: true
                )
            ),
            .invalidArguments
        )
        XCTAssertEqual(manager.worldSeq, initialSeq)
        XCTAssertEqual(manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id, initialMonitorId)
    }

    func testForcedMoveSchedulesOnlyVisibleFloatingRelocations() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let visibleFrame = CGRect(x: 100, y: 120, width: 320, height: 240)
        let hiddenFrame = CGRect(x: 460, y: 180, width: 300, height: 220)
        let visibleToken = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(941_001), windowId: 941_101),
            pid: 941_001,
            windowId: 941_101,
            to: fixture.sourceWorkspaceId,
            mode: .floating
        )
        let hiddenToken = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(941_002), windowId: 941_102),
            pid: 941_002,
            windowId: 941_102,
            to: fixture.sourceWorkspaceId,
            mode: .floating
        )
        manager.updateFloatingGeometry(
            frame: visibleFrame,
            for: visibleToken,
            referenceMonitor: fixture.left
        )
        manager.updateFloatingGeometry(
            frame: hiddenFrame,
            for: hiddenToken,
            referenceMonitor: fixture.left
        )
        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: fixture.left.id,
                reason: .workspaceInactive
            ),
            for: hiddenToken
        )
        controller.layoutRefreshController.resetState()

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.centerWorkspaceId) {
            let router = IPCCommandRouter(controller: controller, sessionToken: "test")

            XCTAssertEqual(
                router.handle(
                    .moveToMonitor(
                        target: .displayName("Slack"),
                        direction: .right,
                        force: true
                    )
                ),
                .executed
            )

            let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
            let expectedVisibleFrame = try XCTUnwrap(manager.floatingState(for: visibleToken)?.lastFrame)
            XCTAssertEqual(pending.kind, .immediateRelayout)
            XCTAssertEqual(pending.reason, .workspaceTransition)
            XCTAssertTrue(pending.suppressesWindowActivation)
            XCTAssertEqual(
                pending.workspaceMonitorRelocations[visibleToken]?.frame,
                expectedVisibleFrame
            )
            XCTAssertNil(pending.workspaceMonitorRelocations[hiddenToken])
            XCTAssertTrue(pending.affectedWorkspaceIds.contains(fixture.sourceWorkspaceId))
        }
    }

    func testWorkspaceMoveRefreshCoalescingKeepsLatestRelocationAndSuppression() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let token = WindowToken(pid: 942_001, windowId: 942_101)
        let firstFrame = CGRect(x: 20, y: 30, width: 300, height: 200)
        let latestFrame = CGRect(x: 1020, y: 40, width: 360, height: 240)

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            controller.layoutRefreshController.commitWorkspaceMonitorTransition(
                WorkspaceMonitorMoveOutcome(
                    status: .executed,
                    affectedWorkspaces: [fixture.sourceWorkspaceId],
                    floatingRelocations: [
                        WorkspaceFloatingRelocation(
                            workspaceId: fixture.sourceWorkspaceId,
                            token: token,
                            frame: firstFrame
                        )
                    ]
                )
            )
            controller.layoutRefreshController.commitWorkspaceMonitorTransition(
                WorkspaceMonitorMoveOutcome(
                    status: .executed,
                    affectedWorkspaces: [
                        fixture.sourceWorkspaceId,
                        fixture.centerWorkspaceId
                    ],
                    floatingRelocations: [
                        WorkspaceFloatingRelocation(
                            workspaceId: fixture.sourceWorkspaceId,
                            token: token,
                            frame: latestFrame
                        )
                    ]
                )
            )

            let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
            XCTAssertEqual(pending.kind, .immediateRelayout)
            XCTAssertEqual(pending.reason, .workspaceTransition)
            XCTAssertEqual(
                pending.affectedWorkspaceIds,
                [fixture.sourceWorkspaceId, fixture.centerWorkspaceId]
            )
            XCTAssertEqual(pending.workspaceMonitorRelocations[token]?.frame, latestFrame)
            XCTAssertTrue(pending.suppressesWindowActivation)
        }
    }

    func testStaleQueuedRelocationIsRejectedAfterConfigurationReapply() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(943_001), windowId: 943_101),
            pid: 943_001,
            windowId: 943_101,
            to: fixture.sourceWorkspaceId,
            mode: .floating
        )
        manager.updateFloatingGeometry(
            frame: CGRect(x: 120, y: 140, width: 320, height: 240),
            for: token,
            referenceMonitor: fixture.left
        )
        controller.layoutRefreshController.resetState()

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.centerWorkspaceId) {
            let router = IPCCommandRouter(controller: controller, sessionToken: "test")
            XCTAssertEqual(
                router.handle(
                    .moveToMonitor(
                        target: .displayName("Slack"),
                        direction: .right,
                        force: true
                    )
                ),
                .executed
            )

            let staleRelocation = try XCTUnwrap(
                controller.layoutRefreshController.layoutState
                    .pendingRefresh?
                    .workspaceMonitorRelocations[token]
            )
            manager.applySettings()
            let currentState = try XCTUnwrap(manager.floatingState(for: token))
            XCTAssertEqual(currentState.referenceMonitorId, fixture.left.id)
            XCTAssertNotEqual(currentState.lastFrame, staleRelocation.frame)

            var plan = EffectPlan(
                workspacePlans: [
                    WorkspaceLayoutPlan(
                        workspaceId: fixture.sourceWorkspaceId,
                        monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.left),
                        sessionPatch: WorkspaceSessionPatch(
                            workspaceId: fixture.sourceWorkspaceId,
                            plannedSeq: manager.worldSeq
                        ),
                        diff: WorkspaceLayoutDiff()
                    )
                ]
            )
            controller.layoutRefreshController.applyWorkspaceMonitorRelocations(
                [token: staleRelocation],
                to: &plan
            )

            XCTAssertTrue(plan.workspacePlans[0].diff.frameChanges.isEmpty)
        }
    }

    func testConfigurationReapplyRebuildsVisibleFloatingRelocationFromDurableState() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(943_002), windowId: 943_102),
            pid: 943_002,
            windowId: 943_102,
            to: fixture.sourceWorkspaceId,
            mode: .floating
        )
        manager.updateFloatingGeometry(
            frame: CGRect(x: 120, y: 140, width: 320, height: 240),
            for: token,
            referenceMonitor: fixture.left
        )

        let move = manager.moveWorkspaceToMonitor(
            fixture.sourceWorkspaceId,
            to: fixture.center.id,
            force: true
        )
        XCTAssertEqual(move.status, .executed)
        let movedFrame = try XCTUnwrap(manager.floatingState(for: token)?.lastFrame)
        manager.updateFloatingGeometry(
            frame: movedFrame,
            for: token,
            referenceMonitor: fixture.center
        )

        manager.applySettings()
        let homeFrame = try XCTUnwrap(manager.floatingState(for: token)?.lastFrame)
        XCTAssertNotEqual(homeFrame, movedFrame)

        var plan = EffectPlan(
            workspacePlans: [
                WorkspaceLayoutPlan(
                    workspaceId: fixture.sourceWorkspaceId,
                    monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.left),
                    sessionPatch: WorkspaceSessionPatch(
                        workspaceId: fixture.sourceWorkspaceId,
                        plannedSeq: manager.worldSeq
                    ),
                    diff: WorkspaceLayoutDiff()
                )
            ]
        )
        controller.layoutRefreshController.applyWorkspaceMonitorRelocations(
            [:],
            reconcileDurableState: true,
            to: &plan
        )

        let frameChange = try XCTUnwrap(plan.workspacePlans[0].diff.frameChanges.first)
        XCTAssertEqual(frameChange.token, token)
        XCTAssertEqual(frameChange.frame, homeFrame)
        XCTAssertFalse(frameChange.forceApply)
        XCTAssertFalse(frameChange.allowsTerminalRecovery)
    }

    func testInitialFloatingRelocationMarksOneTerminalRecovery() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let movedWindow = try makeMovedFloatingWindow(
            fixture,
            pid: 943_201,
            windowId: 943_301
        )
        controller.layoutRefreshController.resetState()

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            controller.layoutRefreshController.commitWorkspaceMonitorTransition(movedWindow.outcome)

            let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
            let scheduled = try XCTUnwrap(pending.workspaceMonitorRelocations[movedWindow.token])
            XCTAssertTrue(scheduled.allowsTerminalRecovery)

            var plan = workspaceMoveEffectPlan(fixture)
            controller.layoutRefreshController.applyWorkspaceMonitorRelocations(
                pending.workspaceMonitorRelocations,
                to: &plan
            )

            let frameChange = try XCTUnwrap(plan.workspacePlans[0].diff.frameChanges.first)
            XCTAssertEqual(frameChange.token, movedWindow.token)
            XCTAssertEqual(frameChange.frame, movedWindow.relocation.frame)
            XCTAssertTrue(frameChange.forceApply)
            XCTAssertTrue(frameChange.allowsTerminalRecovery)
        }
    }

    func testTerminalFloatingRelocationFailureRequeuesCurrentDurableTargetOnce() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let movedWindow = try makeMovedFloatingWindow(
            fixture,
            pid: 943_202,
            windowId: 943_302
        )
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: movedWindow.token))
        controller.layoutRefreshController.resetState()

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            handleTerminalRelocationResult(
                frameApplyResult(
                    entry: entry,
                    targetFrame: movedWindow.relocation.frame,
                    observedFrame: movedWindow.sourceFrame,
                    failureReason: .staleElement
                ),
                fixture: fixture
            )

            let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
            XCTAssertEqual(pending.kind, .immediateRelayout)
            XCTAssertEqual(pending.reason, .workspaceTransition)
            XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.sourceWorkspaceId])
            XCTAssertTrue(pending.suppressesWindowActivation)
            let scheduled = try XCTUnwrap(pending.workspaceMonitorRelocations[movedWindow.token])
            XCTAssertEqual(scheduled.frame, movedWindow.relocation.frame)
            XCTAssertFalse(scheduled.allowsTerminalRecovery)

            var plan = workspaceMoveEffectPlan(fixture)
            controller.layoutRefreshController.applyWorkspaceMonitorRelocations(
                pending.workspaceMonitorRelocations,
                to: &plan
            )

            let frameChange = try XCTUnwrap(plan.workspacePlans[0].diff.frameChanges.first)
            XCTAssertTrue(frameChange.forceApply)
            XCTAssertFalse(frameChange.allowsTerminalRecovery)
        }
    }

    func testTerminalFloatingRelocationNonRecoverableResultsDoNotRequeue() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let movedWindow = try makeMovedFloatingWindow(
            fixture,
            pid: 943_203,
            windowId: 943_303
        )
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: movedWindow.token))
        controller.layoutRefreshController.resetState()

        withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            let results = [
                frameApplyResult(
                    entry: entry,
                    targetFrame: movedWindow.relocation.frame,
                    observedFrame: movedWindow.relocation.frame,
                    failureReason: nil
                ),
                frameApplyResult(
                    entry: entry,
                    targetFrame: movedWindow.relocation.frame,
                    observedFrame: movedWindow.sourceFrame,
                    failureReason: .cancelled
                ),
                frameApplyResult(
                    entry: entry,
                    targetFrame: movedWindow.relocation.frame,
                    observedFrame: movedWindow.sourceFrame,
                    failureReason: .suppressed
                )
            ]

            for result in results {
                handleTerminalRelocationResult(result, fixture: fixture)
                XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
            }
        }
    }

    func testTerminalFloatingRelocationFailureRejectsHiddenStaleTargetAndAXIdentity() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let movedWindow = try makeMovedFloatingWindow(
            fixture,
            pid: 943_204,
            windowId: 943_304
        )
        let entry = try XCTUnwrap(manager.entry(for: movedWindow.token))
        controller.layoutRefreshController.resetState()

        withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            let replacementWindow = AXWindowRef(
                element: AXUIElementCreateApplication(entry.pid + 1),
                windowId: entry.windowId
            )
            handleTerminalRelocationResult(
                frameApplyResult(
                    entry: entry,
                    expectedWindow: replacementWindow,
                    targetFrame: movedWindow.relocation.frame,
                    observedFrame: movedWindow.sourceFrame,
                    failureReason: .verificationMismatch
                ),
                fixture: fixture
            )
            XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)

            manager.setHiddenState(
                HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: fixture.center.id,
                    reason: .workspaceInactive
                ),
                for: movedWindow.token
            )
            handleTerminalRelocationResult(
                frameApplyResult(
                    entry: entry,
                    targetFrame: movedWindow.relocation.frame,
                    observedFrame: movedWindow.sourceFrame,
                    failureReason: .verificationMismatch
                ),
                fixture: fixture
            )
            XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
            manager.setHiddenState(nil, for: movedWindow.token)

            let userFrame = CGRect(
                x: movedWindow.relocation.frame.minX + 80,
                y: movedWindow.relocation.frame.minY + 60,
                width: movedWindow.relocation.frame.width,
                height: movedWindow.relocation.frame.height
            )
            manager.updateFloatingGeometry(
                frame: userFrame,
                for: movedWindow.token,
                referenceMonitor: fixture.center
            )
            handleTerminalRelocationResult(
                frameApplyResult(
                    entry: entry,
                    targetFrame: movedWindow.relocation.frame,
                    observedFrame: movedWindow.sourceFrame,
                    failureReason: .verificationMismatch
                ),
                fixture: fixture
            )
            XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        }
    }

    func testTerminalFloatingRelocationFailureRejectsSameFrameLaterWorkspaceMove() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let movedWindow = try makeMovedFloatingWindow(
            fixture,
            pid: 943_206,
            windowId: 943_306
        )
        let originalEntry = try XCTUnwrap(manager.entry(for: movedWindow.token))
        let failedResult = frameApplyResult(
            entry: originalEntry,
            targetFrame: movedWindow.relocation.frame,
            observedFrame: movedWindow.sourceFrame,
            failureReason: .verificationMismatch
        )

        XCTAssertTrue(
            controller.workspaceNavigationHandler.moveWindow(
                handle: WindowHandle(id: movedWindow.token),
                toWorkspaceId: fixture.centerWorkspaceId
            ).didMutate
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                fixture.centerWorkspaceId,
                on: fixture.center.id,
                updateInteractionMonitor: false
            )
        )
        let currentEntry = try XCTUnwrap(manager.entry(for: movedWindow.token))
        XCTAssertEqual(currentEntry.workspaceId, fixture.centerWorkspaceId)
        XCTAssertEqual(currentEntry.floatingState?.lastFrame, movedWindow.relocation.frame)
        XCTAssertEqual(currentEntry.floatingState?.referenceMonitorId, fixture.center.id)
        controller.layoutRefreshController.resetState()

        withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            handleTerminalRelocationResult(failedResult, fixture: fixture)
            XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        }
    }

    func testNewWorkspaceMoveSupersedesQueuedTerminalRetryAndRestoresRecovery() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let movedWindow = try makeMovedFloatingWindow(
            fixture,
            pid: 943_205,
            windowId: 943_305
        )
        let entry = try XCTUnwrap(manager.entry(for: movedWindow.token))
        controller.layoutRefreshController.resetState()

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            handleTerminalRelocationResult(
                frameApplyResult(
                    entry: entry,
                    targetFrame: movedWindow.relocation.frame,
                    observedFrame: movedWindow.sourceFrame,
                    failureReason: .verificationMismatch
                ),
                fixture: fixture
            )
            XCTAssertFalse(
                try XCTUnwrap(
                    controller.layoutRefreshController.layoutState.pendingRefresh?
                        .workspaceMonitorRelocations[movedWindow.token]
                ).allowsTerminalRecovery
            )

            let latestFrame = CGRect(
                x: movedWindow.relocation.frame.minX + 40,
                y: movedWindow.relocation.frame.minY + 30,
                width: movedWindow.relocation.frame.width,
                height: movedWindow.relocation.frame.height
            )
            manager.updateFloatingGeometry(
                frame: latestFrame,
                for: movedWindow.token,
                referenceMonitor: fixture.center
            )
            controller.layoutRefreshController.commitWorkspaceMonitorTransition(
                WorkspaceMonitorMoveOutcome(
                    status: .executed,
                    affectedWorkspaces: [fixture.sourceWorkspaceId],
                    floatingRelocations: [
                        WorkspaceFloatingRelocation(
                            workspaceId: fixture.sourceWorkspaceId,
                            token: movedWindow.token,
                            frame: latestFrame
                        )
                    ]
                )
            )

            let latest = try XCTUnwrap(
                controller.layoutRefreshController.layoutState.pendingRefresh?
                    .workspaceMonitorRelocations[movedWindow.token]
            )
            XCTAssertEqual(latest.frame, latestFrame)
            XCTAssertTrue(latest.allowsTerminalRecovery)
        }
    }

    func testCancelledRefreshPreservesNewestRelocationAndRecoveryBudget() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let token = WindowToken(pid: 943_207, windowId: 943_307)
        let olderFrame = CGRect(x: 1040, y: 80, width: 320, height: 240)
        let newerFrame = CGRect(x: 1120, y: 140, width: 360, height: 280)
        let cancelledRefresh = LayoutRefreshController.ScheduledRefresh(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [fixture.sourceWorkspaceId],
            workspaceMonitorRelocations: [
                LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
                    relocation: WorkspaceFloatingRelocation(
                        workspaceId: fixture.sourceWorkspaceId,
                        token: token,
                        frame: olderFrame
                    ),
                    allowsTerminalRecovery: false
                )
            ]
        )
        controller.layoutRefreshController.layoutState.pendingRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [fixture.sourceWorkspaceId],
            workspaceMonitorRelocations: [
                LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
                    relocation: WorkspaceFloatingRelocation(
                        workspaceId: fixture.sourceWorkspaceId,
                        token: token,
                        frame: newerFrame
                    ),
                    allowsTerminalRecovery: true
                )
            ]
        )
        defer { controller.layoutRefreshController.resetState() }

        controller.layoutRefreshController.preserveCancelledRefreshState(cancelledRefresh)

        let preserved = try XCTUnwrap(
            controller.layoutRefreshController.layoutState.pendingRefresh?
                .workspaceMonitorRelocations[token]
        )
        XCTAssertEqual(preserved.frame, newerFrame)
        XCTAssertTrue(preserved.allowsTerminalRecovery)
    }

    func testFullRescanUpgradePreservesDurableWorkspaceMonitorReconciliation() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            controller.layoutRefreshController.requestRelayout(reason: .workspaceConfigChanged)
            controller.layoutRefreshController.requestFullRescan(reason: .appLaunched)

            let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
            XCTAssertEqual(pending.kind, .fullRescan)
            XCTAssertEqual(pending.reason, .appLaunched)
            XCTAssertTrue(pending.reconcilesWorkspaceMonitorState)
        }
    }

    func testWindowRemovalMergeDefersWorkspaceRelocationToFollowUpOnly() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let token = WindowToken(pid: 943_003, windowId: 943_103)
        let frame = CGRect(x: 1120, y: 140, width: 320, height: 240)

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            controller.layoutRefreshController.commitWorkspaceMonitorTransition(
                WorkspaceMonitorMoveOutcome(
                    status: .executed,
                    affectedWorkspaces: [fixture.sourceWorkspaceId],
                    floatingRelocations: [
                        WorkspaceFloatingRelocation(
                            workspaceId: fixture.sourceWorkspaceId,
                            token: token,
                            frame: frame
                        )
                    ]
                )
            )
            controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: fixture.centerWorkspaceId,
                layoutType: .niri,
                removedNodeId: nil,
                removedNiriColumn: false,
                niriOldFrames: [:],
                shouldRecoverFocus: false
            )

            let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
            XCTAssertEqual(pending.kind, .windowRemoval)
            XCTAssertTrue(pending.workspaceMonitorRelocations.isEmpty)
            XCTAssertEqual(
                pending.followUpRefresh?.workspaceMonitorRelocations[token]?.frame,
                frame
            )
            XCTAssertTrue(
                try XCTUnwrap(
                    pending.followUpRefresh?.workspaceMonitorRelocations[token]
                ).allowsTerminalRecovery
            )
        }
    }

    func testFullRescanKeepsDeferredWorkspaceRelocationInFollowUp() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let token = WindowToken(pid: 943_004, windowId: 943_104)
        let frame = CGRect(x: 1120, y: 140, width: 320, height: 240)

        try withBlockedRefreshes(controller, affectedWorkspaceId: fixture.interactionWorkspaceId) {
            controller.layoutRefreshController.commitWorkspaceMonitorTransition(
                WorkspaceMonitorMoveOutcome(
                    status: .executed,
                    affectedWorkspaces: [fixture.sourceWorkspaceId],
                    floatingRelocations: [
                        WorkspaceFloatingRelocation(
                            workspaceId: fixture.sourceWorkspaceId,
                            token: token,
                            frame: frame
                        )
                    ]
                )
            )
            controller.layoutRefreshController.requestWindowRemoval(
                workspaceId: fixture.centerWorkspaceId,
                layoutType: .niri,
                removedNodeId: nil,
                removedNiriColumn: false,
                niriOldFrames: [:],
                shouldRecoverFocus: false
            )
            controller.layoutRefreshController.requestFullRescan(reason: .appLaunched)

            let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
            XCTAssertEqual(pending.kind, .fullRescan)
            XCTAssertTrue(pending.workspaceMonitorRelocations.isEmpty)
            XCTAssertEqual(
                pending.followUpRefresh?.workspaceMonitorRelocations[token]?.frame,
                frame
            )
            XCTAssertTrue(
                try XCTUnwrap(
                    pending.followUpRefresh?.workspaceMonitorRelocations[token]
                ).allowsTerminalRecovery
            )
            XCTAssertTrue(pending.suppressesWindowActivation)
            XCTAssertTrue(pending.affectedWorkspaceIds.isEmpty)
        }
    }

    func testForcedAssignmentSurvivesTargetMonitorReconnect() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager

        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                fixture.sourceWorkspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.center.id
        )

        manager.applyMonitorConfigurationChange([fixture.left])
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.left.id
        )

        manager.applyMonitorConfigurationChange([fixture.left, fixture.center])
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.center.id
        )
    }

    func testReconnectRestoresOverrideWhenTargetSortsBeforeHome() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager

        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                fixture.centerWorkspaceId,
                to: fixture.left.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.centerWorkspaceId)?.id,
            fixture.left.id
        )

        manager.applyMonitorConfigurationChange([fixture.center, fixture.right])
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.centerWorkspaceId)?.id,
            fixture.center.id
        )

        manager.applyMonitorConfigurationChange([fixture.left, fixture.center, fixture.right])
        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.centerWorkspaceId)?.id,
            fixture.left.id
        )
    }

    func testApplyingSettingsClearsForcedAssignmentAndRestoresVisibleWorkspaceHome() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager

        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                fixture.sourceWorkspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertEqual(
            manager.activeWorkspace(on: fixture.center.id)?.id,
            fixture.sourceWorkspaceId
        )

        manager.applySettings()

        XCTAssertEqual(
            manager.monitorForWorkspace(fixture.sourceWorkspaceId)?.id,
            fixture.left.id
        )
        XCTAssertEqual(
            manager.activeWorkspace(on: fixture.left.id)?.id,
            fixture.sourceWorkspaceId
        )
    }

    private func makeFixture() throws -> Fixture {
        let left = makeMonitor(
            displayId: 94_001,
            name: "Left",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let center = makeMonitor(
            displayId: 94_002,
            name: "Center",
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
        )
        let right = makeMonitor(
            displayId: 94_003,
            name: "Right",
            frame: CGRect(x: 2000, y: 0, width: 1000, height: 800)
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMWorkspaceMoveIPCIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                displayName: "Slack",
                monitorAssignment: .specificDisplay(OutputId(from: left)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: center)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: right)),
                layoutType: .niri
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([left, center, right])
        manager.applySettings()
        let sourceWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let centerWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let interactionWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertTrue(
            manager.setActiveWorkspace(
                sourceWorkspaceId,
                on: left.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                centerWorkspaceId,
                on: center.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                interactionWorkspaceId,
                on: right.id,
                updateInteractionMonitor: false
            )
        )
        _ = manager.setInteractionMonitor(right.id)
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            left: left,
            center: center,
            right: right,
            sourceWorkspaceId: sourceWorkspaceId,
            centerWorkspaceId: centerWorkspaceId,
            interactionWorkspaceId: interactionWorkspaceId
        )
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        frame: CGRect
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func makeMovedFloatingWindow(
        _ fixture: Fixture,
        pid: pid_t,
        windowId: Int
    ) throws -> MovedFloatingWindow {
        let manager = fixture.controller.workspaceManager
        let sourceFrame = CGRect(x: 120, y: 140, width: 320, height: 240)
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: fixture.sourceWorkspaceId,
            mode: .floating
        )
        manager.updateFloatingGeometry(
            frame: sourceFrame,
            for: token,
            referenceMonitor: fixture.left
        )
        let outcome = manager.moveWorkspaceToMonitor(
            fixture.sourceWorkspaceId,
            to: fixture.center.id,
            force: true
        )
        XCTAssertEqual(outcome.status, .executed)
        let relocation = try XCTUnwrap(outcome.floatingRelocations.first { $0.token == token })
        return MovedFloatingWindow(
            token: token,
            sourceFrame: sourceFrame,
            relocation: relocation,
            outcome: outcome
        )
    }

    private func workspaceMoveEffectPlan(_ fixture: Fixture) -> EffectPlan {
        EffectPlan(
            workspacePlans: [
                WorkspaceLayoutPlan(
                    workspaceId: fixture.sourceWorkspaceId,
                    monitor: fixture.controller.layoutRefreshController.buildMonitorSnapshot(
                        for: fixture.center
                    ),
                    sessionPatch: WorkspaceSessionPatch(
                        workspaceId: fixture.sourceWorkspaceId,
                        plannedSeq: fixture.controller.workspaceManager.worldSeq
                    ),
                    diff: WorkspaceLayoutDiff()
                )
            ]
        )
    }

    private func frameApplyResult(
        entry: WindowState,
        expectedWindow: AXWindowRef? = nil,
        targetFrame: CGRect,
        observedFrame: CGRect?,
        failureReason: AXFrameWriteFailureReason?
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            pid: entry.pid,
            windowId: entry.windowId,
            expectedWindow: expectedWindow ?? entry.axRef,
            targetFrame: targetFrame,
            currentFrameHint: observedFrame,
            writeResult: AXFrameWriteResult(
                observedFrame: observedFrame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: failureReason
            )
        )
    }

    private func handleTerminalRelocationResult(
        _ result: AXFrameApplyResult,
        fixture: Fixture
    ) {
        fixture.controller.layoutRefreshController.handleWorkspaceMonitorRelocationTerminalResult(
            result,
            workspaceId: fixture.sourceWorkspaceId,
            monitorId: fixture.center.id
        )
    }

    private func withBlockedRefreshes<T>(
        _ controller: WMController,
        affectedWorkspaceId: WorkspaceDescriptor.ID,
        _ body: () throws -> T
    ) rethrows -> T {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let refreshController = controller.layoutRefreshController
        refreshController.layoutState.activeRefreshTask = blocker
        refreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [affectedWorkspaceId]
        )
        defer {
            blocker.cancel()
            refreshController.layoutState.activeRefreshTask = nil
            refreshController.layoutState.activeRefresh = nil
            refreshController.layoutState.pendingRefresh = nil
        }
        return try body()
    }
}
