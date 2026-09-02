// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class OverviewStructuralCommandTests: XCTestCase {
    func testOverviewGuardExemptsOnlyToggleOverview() {
        XCTAssertFalse(CommandHandler.shouldIgnoreCommand(.toggleOverview, isOverviewOpen: true))
        XCTAssertTrue(CommandHandler.shouldIgnoreCommand(.moveColumnToFirst, isOverviewOpen: true))
        XCTAssertFalse(CommandHandler.shouldIgnoreCommand(.moveColumnToFirst, isOverviewOpen: false))
    }

    func testPerformCommandToggleOverviewClosesOpenOverview() throws {
        let fixture = try makeFixture(layouts: [.niri])
        _ = try addManagedWindow(pid: 461_030, windowId: 30, to: fixture.workspaceIds[0], fixture: fixture)
        fixture.controller.toggleOverview()
        defer {
            if fixture.controller.isOverviewOpen() {
                fixture.controller.toggleOverview()
            }
        }
        XCTAssertTrue(fixture.controller.isOverviewOpen())

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.moveColumnToFirst), .ignoredOverview)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.toggleOverview), .executed)
        XCTAssertFalse(fixture.controller.isOverviewOpen())

        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")
        XCTAssertEqual(router.handle(IPCCommandRequest.toggleOverview), .executed)
        XCTAssertTrue(fixture.controller.isOverviewOpen())
        XCTAssertEqual(router.handle(IPCCommandRequest.moveColumnToFirst), .ignoredOverview)
        XCTAssertEqual(router.handle(IPCCommandRequest.toggleOverview), .executed)
        XCTAssertFalse(fixture.controller.isOverviewOpen())
    }

    private final class FocusRecorder {
        var activatedPIDs: [pid_t] = []
        var focusedTokens: [WindowToken] = []
        var raisedCount = 0

        var callCount: Int {
            activatedPIDs.count + focusedTokens.count + raisedCount
        }
    }

    private struct Fixture {
        let controller: WMController
        let workspaceIds: [WorkspaceDescriptor.ID]
        let monitor: Monitor
        let focusRecorder: FocusRecorder
    }

    func testUnassignableConsumeOrExpelCommandsHaveNoOverviewRouting() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let selected = try addManagedWindow(
            pid: 461_020,
            windowId: 22,
            to: fixture.workspaceIds[0],
            fixture: fixture
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let cases = [
            ("consumeOrExpelWindowLeft", HotkeyCommand.consumeOrExpelWindowLeft),
            ("consumeOrExpelWindowRight", .consumeOrExpelWindowRight)
        ]

        for (id, command) in cases {
            XCTAssertNil(HotkeyBindingRegistry.command(for: id))
            XCTAssertNil(
                overview.performStructuralHotkey(command, selectedHandle: selected)
            )
        }
    }

    func testSelectedOverviewHandleMovesInsteadOfLiveFocusedHandle() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(pid: 461_001, windowId: 1, to: workspaceId, fixture: fixture)
        let liveFocused = try addManagedWindow(pid: 461_001, windowId: 2, to: workspaceId, fixture: fixture)
        let trailing = try addManagedWindow(pid: 461_001, windowId: 3, to: workspaceId, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(liveFocused.id, in: workspaceId))

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(.moveColumnToLast, selectedHandle: selected)
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(
            engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) },
            [liveFocused.id, trailing.id, selected.id]
        )
        XCTAssertEqual(mutation.selectedHandle, selected)
        XCTAssertEqual(mutation.movedTokens, [selected.id])
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, liveFocused.id)
        XCTAssertEqual(fixture.controller.workspaceManager.lastFocusedToken(in: workspaceId), selected.id)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testSelectedOverviewHandleMovesToActiveAdjacentMonitorWorkspaceWithoutAXFocus() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let targetFrame = CGRect(x: 1600, y: 0, width: 1600, height: 900)
        let targetMonitor = Monitor(
            id: .init(displayId: 46_101),
            displayId: 46_101,
            frame: targetFrame,
            visibleFrame: targetFrame,
            hasNotch: false,
            name: "Overview Structural Target"
        )
        fixture.controller.settings.workspaceConfigurations.append(contentsOf: [
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: .niri
            )
        ])
        fixture.controller.workspaceManager.applyMonitorConfigurationChange([fixture.monitor, targetMonitor])
        fixture.controller.workspaceManager.applySettings()
        fixture.controller.syncMonitorsToNiriEngine()
        let inactiveTargetWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "2")
        )
        let activeTargetWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "3")
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setActiveWorkspace(
                inactiveTargetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setActiveWorkspace(
                activeTargetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setActiveWorkspace(sourceWorkspaceId, on: fixture.monitor.id)
        )

        let selected = try addManagedWindow(
            pid: 461_017,
            windowId: 20,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let liveFocused = try addManagedWindow(
            pid: 461_017,
            windowId: 21,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setManagedFocus(
                liveFocused.id,
                in: sourceWorkspaceId,
                onMonitor: fixture.monitor.id
            )
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = withBlockedLayoutRefreshes(fixture) {
            overview.executeStructuralHotkey(
                .moveWindowToMonitor(.right),
                selectedHandle: selected
            )
        }
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(mutation.sourceWorkspaceId, sourceWorkspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, activeTargetWorkspaceId)
        XCTAssertEqual(mutation.selectedHandle, selected)
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: selected.id),
            activeTargetWorkspaceId
        )
        XCTAssertNotEqual(
            fixture.controller.workspaceManager.workspace(for: selected.id),
            inactiveTargetWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: liveFocused.id),
            sourceWorkspaceId
        )
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, targetMonitor.id)
        XCTAssertEqual(overview.selectedWindowHandle, selected)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, liveFocused.id)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testPhysicalStructuralRoutingBlocksTriggerlessAndUnsupportedCommands() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(pid: 461_016, windowId: 18, to: workspaceId, fixture: fixture)
        let trailing = try addManagedWindow(pid: 461_016, windowId: 19, to: workspaceId, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(selected.id, in: workspaceId))

        fixture.controller.toggleOverview()
        defer {
            if fixture.controller.isOverviewOpen() {
                fixture.controller.toggleOverview()
            }
        }
        XCTAssertTrue(fixture.controller.isOverviewOpen())

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .moveColumnToLast,
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .executed
        )
        XCTAssertEqual(
            engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) },
            [trailing.id, selected.id]
        )

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.moveColumnToFirst),
            .ignoredOverview
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.moveColumnToFirst),
            .ignoredOverview
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .toggleFullscreen,
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .ignoredOverview
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .moveWindowToMonitor(.right),
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .executed
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(
                    command: .moveWorkspaceToMonitor(.right),
                    trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
                )
            ),
            .ignoredOverview
        )
    }

    func testCoalescedStructuralActionsRefreshUnionOfAffectedWorkspacesOnce() async throws {
        let fixture = try makeFixture(layouts: [.niri, .niri])
        let firstWorkspaceId = fixture.workspaceIds[0]
        let secondWorkspaceId = fixture.workspaceIds[1]
        let firstSelected = try addManagedWindow(
            pid: 461_014,
            windowId: 14,
            to: firstWorkspaceId,
            fixture: fixture
        )
        _ = try addManagedWindow(
            pid: 461_014,
            windowId: 15,
            to: firstWorkspaceId,
            fixture: fixture
        )
        let secondSelected = try addManagedWindow(
            pid: 461_015,
            windowId: 16,
            to: secondWorkspaceId,
            fixture: fixture
        )
        _ = try addManagedWindow(
            pid: 461_015,
            windowId: 17,
            to: secondWorkspaceId,
            fixture: fixture
        )
        var refreshedWorkspaceSets: [Set<WorkspaceDescriptor.ID>] = []
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in "Window" }
        environment.windowFrame = { _ in CGRect(x: 0, y: 0, width: 500, height: 400) }
        environment.onCachedProjectionRefreshed = { refreshedWorkspaceSets.append($0) }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)

        XCTAssertTrue(
            overview.executeStructuralHotkey(
                .moveColumnToLast,
                selectedHandle: firstSelected
            )?.didMutate == true
        )
        XCTAssertTrue(
            overview.executeStructuralHotkey(
                .moveColumnToLast,
                selectedHandle: secondSelected
            )?.didMutate == true
        )

        for _ in 0 ..< 100
            where fixture.controller.layoutRefreshController.layoutState.activeRefreshTask != nil
            || fixture.controller.layoutRefreshController.layoutState.pendingRefresh != nil
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(refreshedWorkspaceSets.count, 1)
        XCTAssertEqual(refreshedWorkspaceSets.first, [firstWorkspaceId, secondWorkspaceId])
    }

    func testCompletedWorkspaceTransferActivatesDestinationWithoutAXFocus() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let selected = try addManagedWindow(
            pid: 461_002,
            windowId: 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let liveFocused = try addManagedWindow(
            pid: 461_002,
            windowId: 2,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        _ = try addManagedWindow(
            pid: 461_003,
            windowId: 1,
            to: destinationWorkspaceId,
            fixture: fixture
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setManagedFocus(
                liveFocused.id,
                in: sourceWorkspaceId,
                onMonitor: fixture.monitor.id
            )
        )

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = withBlockedLayoutRefreshes(fixture) {
            overview.executeStructuralHotkey(.moveToWorkspace(1), selectedHandle: selected)
        }
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(mutation.sourceWorkspaceId, sourceWorkspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, destinationWorkspaceId)
        XCTAssertEqual(mutation.selectedHandle, selected)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), destinationWorkspaceId)
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
            selected.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            destinationWorkspaceId
        )
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, fixture.monitor.id)
        XCTAssertEqual(overview.selectedWindowHandle, selected)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, liveFocused.id)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testFloatingWindowTransfersAcrossNiriWorkspaces() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let pid = pid_t(461_010)
        let windowId = 10
        let token = fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: sourceWorkspaceId,
            mode: .floating
        )
        let selected = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: token))
        XCTAssertNil(fixture.controller.niriEngine?.findNode(for: token, in: sourceWorkspaceId))

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(.moveToWorkspace(1), selectedHandle: selected)
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(mutation.sourceWorkspaceId, sourceWorkspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.windowMode(for: token), .floating)
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFloatingFocusedToken(in: destinationWorkspaceId),
            token
        )
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testNiriStructuralNoOpPreservesOrderingAndRememberedFocus() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let first = try addManagedWindow(pid: 461_004, windowId: 1, to: workspaceId, fixture: fixture)
        let second = try addManagedWindow(pid: 461_004, windowId: 2, to: workspaceId, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(second.id, in: workspaceId))
        let originalOrder = engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(.moveColumnToFirst, selectedHandle: first)

        XCTAssertEqual(outcome, StructuralMutationOutcome.unchanged)
        XCTAssertEqual(engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }, originalOrder)
        XCTAssertEqual(fixture.controller.workspaceManager.lastFocusedToken(in: workspaceId), second.id)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, second.id)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testHiddenWindowCannotExecuteOverviewStructuralHotkey() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        _ = try addManagedWindow(pid: 461_030, windowId: 40, to: workspaceId, fixture: fixture)
        let selected = try addManagedWindow(
            pid: 461_031,
            windowId: 41,
            to: workspaceId,
            fixture: fixture
        )
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let originalColumns = engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: selected.pid,
            source: .service
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = overview.performStructuralHotkey(
            .moveColumnToFirst,
            selectedHandle: selected
        )

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            originalColumns
        )
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testCombinedVerticalMoveCreatesAdjacentWorkspaceAtEdge() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(
            pid: 461_009,
            windowId: 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        XCTAssertNil(fixture.controller.workspaceManager.workspaceId(named: "2"))

        XCTAssertEqual(
            fixture.controller.niriLayoutHandler.moveWindow(handle: selected, direction: .down),
            .atWorkspaceEdge
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(
            .moveWindowDownOrToWorkspaceDown,
            selectedHandle: selected
        )
        let createdWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "2")
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorId(for: createdWorkspaceId),
            fixture.monitor.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeLayoutKind(for: createdWorkspaceId),
            .niri
        )
        let mutation = try XCTUnwrap(outcome?.mutation)
        let destinationWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "2")
        )

        XCTAssertEqual(mutation.sourceWorkspaceId, sourceWorkspaceId)
        XCTAssertEqual(mutation.destinationWorkspaceId, destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), destinationWorkspaceId)
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorId(for: destinationWorkspaceId),
            fixture.monitor.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
            selected.id
        )
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testWholeColumnTransferPreservesSelectedMemberAndMovedTokens() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let selected = try addManagedWindow(
            pid: 461_005,
            windowId: 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let stacked = try addManagedWindow(
            pid: 461_005,
            windowId: 2,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let sourceRemainder = try addManagedWindow(
            pid: 461_005,
            windowId: 3,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        _ = try addManagedWindow(
            pid: 461_006,
            windowId: 1,
            to: destinationWorkspaceId,
            fixture: fixture
        )
        XCTAssertTrue(
            fixture.controller.niriLayoutHandler.consumeOrExpelWindow(
                handle: stacked,
                direction: .left
            ).didMutate
        )
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let sourceSelectedNode = try XCTUnwrap(engine.findNode(for: selected, in: sourceWorkspaceId))
        let sourceColumn = try XCTUnwrap(
            engine.findColumn(containing: sourceSelectedNode, in: sourceWorkspaceId)
        )
        XCTAssertEqual(Set(sourceColumn.windowNodes.map(\.token)), [selected.id, stacked.id])

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(
            .moveColumnToWorkspace(1),
            selectedHandle: selected
        )
        let mutation = try XCTUnwrap(outcome?.mutation)

        XCTAssertEqual(mutation.selectedHandle, selected)
        XCTAssertEqual(Set(mutation.movedTokens), [selected.id, stacked.id])
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: stacked.id), destinationWorkspaceId)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: sourceRemainder.id), sourceWorkspaceId)
        XCTAssertNil(engine.findNode(for: selected, in: sourceWorkspaceId))
        XCTAssertNil(engine.findNode(for: stacked, in: sourceWorkspaceId))
        let destinationSelectedNode = try XCTUnwrap(engine.findNode(for: selected, in: destinationWorkspaceId))
        let destinationColumn = try XCTUnwrap(
            engine.findColumn(containing: destinationSelectedNode, in: destinationWorkspaceId)
        )
        XCTAssertEqual(Set(destinationColumn.windowNodes.map(\.token)), [selected.id, stacked.id])
        XCTAssertEqual(
            fixture.controller.workspaceManager.niriViewportState(for: destinationWorkspaceId).selectedNodeId,
            destinationSelectedNode.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
            selected.id
        )
    }

    func testDwindleSourceRejectsWholeColumnTransfer() throws {
        let fixture = try makeFixture(layouts: [.dwindle, .niri])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let selected = try addManagedWindow(
            pid: 461_007,
            windowId: 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let dwindleEngine = try XCTUnwrap(fixture.controller.dwindleEngine)

        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let outcome = overview.performStructuralHotkey(
            .moveColumnToWorkspace(1),
            selectedHandle: selected
        )

        XCTAssertEqual(outcome, StructuralMutationOutcome.unchanged)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), sourceWorkspaceId)
        XCTAssertNotNil(dwindleEngine.findNode(for: selected.id, in: sourceWorkspaceId))
        XCTAssertNil(dwindleEngine.findNode(for: selected.id, in: destinationWorkspaceId))
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testDwindleOverviewRejectsMoveAndMoveContainerInEveryDirection() throws {
        let fixture = try makeFixture(layouts: [.dwindle])
        let workspaceId = fixture.workspaceIds[0]
        let first = try addManagedWindow(pid: 461_025, windowId: 31, to: workspaceId, fixture: fixture)
        let second = try addManagedWindow(pid: 461_025, windowId: 32, to: workspaceId, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        _ = fixture.controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.calculateLayout(for: workspaceId, screen: fixture.monitor.visibleFrame)
        }
        let firstNode = try XCTUnwrap(engine.findNode(for: first.id, in: workspaceId))
        let secondNode = try XCTUnwrap(engine.findNode(for: second.id, in: workspaceId))
        let parent = try XCTUnwrap(firstNode.parent)
        XCTAssertEqual(secondNode.parent?.id, parent.id)
        let originalChildIds = parent.children.map(\.id)
        let originalFirstTile = try XCTUnwrap(engine.tileSnapshot(for: first.id, in: workspaceId))
        let originalSecondTile = try XCTUnwrap(engine.tileSnapshot(for: second.id, in: workspaceId))
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )
        let assertUnchanged = {
            XCTAssertEqual(parent.children.map(\.id), originalChildIds)
            XCTAssertEqual(engine.tileSnapshot(for: first.id, in: workspaceId), originalFirstTile)
            XCTAssertEqual(engine.tileSnapshot(for: second.id, in: workspaceId), originalSecondTile)
            XCTAssertEqual(engine.tileCount(in: workspaceId), 2)
        }

        for direction in [Direction.left, .right, .up, .down] {
            XCTAssertEqual(
                overview.performStructuralHotkey(.move(direction), selectedHandle: second),
                .unchanged,
                direction.rawValue
            )
            assertUnchanged()
            XCTAssertEqual(
                overview.performStructuralHotkey(.moveColumn(direction), selectedHandle: second),
                .unchanged,
                direction.rawValue
            )
            assertUnchanged()
        }

        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testFloatingColumnMoveNoOpDoesNotCreateAdjacentWorkspace() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let pid = pid_t(461_011)
        let windowId = 11
        let token = fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let selected = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: token))
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = overview.performStructuralHotkey(
            .moveColumnToWorkspaceDown,
            selectedHandle: selected
        )

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertNil(fixture.controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), workspaceId)
    }

    func testColumnMoveDoesNotCreateIncompatibleDynamicWorkspace() throws {
        let fixture = try makeFixture(layouts: [.niri])
        fixture.controller.settings.defaultLayoutType = .dwindle
        let workspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(
            pid: 461_012,
            windowId: 12,
            to: workspaceId,
            fixture: fixture
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = overview.performStructuralHotkey(
            .moveColumnToWorkspaceDown,
            selectedHandle: selected
        )

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertNil(fixture.controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), workspaceId)
    }

    func testAdjacentCreationSkipsNumericWorkspaceOnAnotherMonitor() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let secondary = Monitor(
            id: .init(displayId: 46_101),
            displayId: 46_101,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Overview Structural Secondary"
        )
        fixture.controller.settings.workspaceConfigurations.append(
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary, layoutType: .niri)
        )
        fixture.controller.workspaceManager.applyMonitorConfigurationChange([fixture.monitor, secondary])
        fixture.controller.workspaceManager.applySettings()
        fixture.controller.syncMonitorsToNiriEngine()
        let secondaryWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "2")
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorId(for: secondaryWorkspaceId),
            secondary.id
        )
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let selected = try addManagedWindow(
            pid: 461_013,
            windowId: 13,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy
        )

        let outcome = overview.performStructuralHotkey(
            .moveWindowDownOrToWorkspaceDown,
            selectedHandle: selected
        )
        let mutation = try XCTUnwrap(outcome?.mutation)
        let destinationWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: "3")
        )

        XCTAssertEqual(mutation.destinationWorkspaceId, destinationWorkspaceId)
        XCTAssertEqual(
            fixture.controller.workspaceManager.monitorId(for: destinationWorkspaceId),
            fixture.monitor.id
        )
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: selected.id), destinationWorkspaceId)
    }

    func testRemovalCallbackObservesAuthoritativeWindowRemoval() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let handle = try addManagedWindow(pid: 461_008, windowId: 1, to: workspaceId, fixture: fixture)
        let manager = fixture.controller.workspaceManager
        var callbackTokens: [WindowToken] = []
        var callbackEntryWasPresent = true
        var callbackWorkspaceWasPresent = true
        manager.onWindowRemoved = { entry in
            callbackTokens.append(entry.token)
            callbackEntryWasPresent = manager.entry(for: entry.token) != nil
            callbackWorkspaceWasPresent = manager.workspace(for: entry.token) != nil
        }
        defer { manager.onWindowRemoved = nil }

        let removed = manager.removeWindow(pid: handle.id.pid, windowId: handle.id.windowId)

        XCTAssertEqual(removed?.token, handle.id)
        XCTAssertEqual(callbackTokens, [handle.id])
        XCTAssertFalse(callbackEntryWasPresent)
        XCTAssertFalse(callbackWorkspaceWasPresent)
        XCTAssertNil(manager.entry(for: handle.id))
        XCTAssertNil(manager.workspace(for: handle.id))
    }

    func testHiddenWindowCannotBeginOverviewDrag() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let handle = try addManagedWindow(
            pid: 461_032,
            windowId: 42,
            to: workspaceId,
            fixture: fixture
        )
        let prepared = try prepareDragOverview(fixture)
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: handle.pid,
            source: .service
        )

        prepared.overview.beginDrag(
            on: fixture.monitor.id,
            handle: handle,
            startPoint: .zero
        )

        XCTAssertFalse(prepared.overview.hasActiveDragSession)
    }

    func testDragDoesNotMutateAfterDraggedApplicationBecomesHidden() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let target = try addManagedWindow(
            pid: 461_033,
            windowId: 43,
            to: workspaceId,
            fixture: fixture
        )
        let dragged = try addManagedWindow(
            pid: 461_034,
            windowId: 44,
            to: workspaceId,
            fixture: fixture
        )
        let prepared = try prepareDragOverview(fixture)
        let targetFrame = try XCTUnwrap(prepared.layout.window(for: target)?.overviewFrame)
        let dropPoint = CGPoint(
            x: targetFrame.midX,
            y: targetFrame.maxY - targetFrame.height * 0.1
        )
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let originalColumns = engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }

        prepared.overview.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
        prepared.overview.updateDrag(on: fixture.monitor.id, at: dropPoint)
        XCTAssertTrue(prepared.overview.hasActiveDragSession)
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: dragged.pid,
            source: .service
        )
        prepared.overview.endDrag(on: fixture.monitor.id, at: dropPoint)

        XCTAssertFalse(prepared.overview.hasActiveDragSession)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            originalColumns
        )
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: dragged.id), workspaceId)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testMouseDragInsertsNiriCardBeforeTarget() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let target = try addManagedWindow(pid: 461_020, windowId: 20, to: workspaceId, fixture: fixture)
        _ = try addManagedWindow(pid: 461_020, windowId: 21, to: workspaceId, fixture: fixture)
        let dragged = try addManagedWindow(pid: 461_020, windowId: 22, to: workspaceId, fixture: fixture)
        let prepared = try prepareDragOverview(fixture)
        let targetFrame = try XCTUnwrap(prepared.layout.window(for: target)?.overviewFrame)
        let dropPoint = CGPoint(
            x: targetFrame.midX,
            y: targetFrame.maxY - targetFrame.height * 0.1
        )

        withBlockedLayoutRefreshes(fixture) {
            prepared.overview.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
            prepared.overview.updateDrag(on: fixture.monitor.id, at: dropPoint)
            prepared.overview.endDrag(on: fixture.monitor.id, at: dropPoint)
        }

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let targetNode = try XCTUnwrap(engine.findNode(for: target, in: workspaceId))
        let targetColumn = try XCTUnwrap(engine.findColumn(containing: targetNode, in: workspaceId))
        XCTAssertEqual(
            targetColumn.windowNodes.map(\.token),
            [target.id, dragged.id]
        )
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: dragged.id), workspaceId)
        XCTAssertEqual(prepared.overview.selectedWindowHandle, dragged)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testMouseDragInsertsNiriCardAfterTarget() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let target = try addManagedWindow(pid: 461_021, windowId: 23, to: workspaceId, fixture: fixture)
        _ = try addManagedWindow(pid: 461_021, windowId: 24, to: workspaceId, fixture: fixture)
        let dragged = try addManagedWindow(pid: 461_021, windowId: 25, to: workspaceId, fixture: fixture)
        let prepared = try prepareDragOverview(fixture)
        let targetFrame = try XCTUnwrap(prepared.layout.window(for: target)?.overviewFrame)
        let dropPoint = CGPoint(
            x: targetFrame.midX,
            y: targetFrame.minY + targetFrame.height * 0.1
        )

        withBlockedLayoutRefreshes(fixture) {
            prepared.overview.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
            prepared.overview.updateDrag(on: fixture.monitor.id, at: dropPoint)
            prepared.overview.endDrag(on: fixture.monitor.id, at: dropPoint)
        }

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let targetNode = try XCTUnwrap(engine.findNode(for: target, in: workspaceId))
        let targetColumn = try XCTUnwrap(engine.findColumn(containing: targetNode, in: workspaceId))
        XCTAssertEqual(
            targetColumn.windowNodes.map(\.token),
            [dragged.id, target.id]
        )
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: dragged.id), workspaceId)
        XCTAssertEqual(prepared.overview.selectedWindowHandle, dragged)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testMouseDragInsertsNiriWindowAtExactColumnGap() throws {
        let fixture = try makeFixture(layouts: [.niri])
        let workspaceId = fixture.workspaceIds[0]
        let first = try addManagedWindow(pid: 461_022, windowId: 26, to: workspaceId, fixture: fixture)
        let second = try addManagedWindow(pid: 461_022, windowId: 27, to: workspaceId, fixture: fixture)
        let dragged = try addManagedWindow(pid: 461_022, windowId: 28, to: workspaceId, fixture: fixture)
        let prepared = try prepareDragOverview(fixture)
        let gap = try XCTUnwrap(
            prepared.layout.niriColumnDropZonesByWorkspace[workspaceId]?
                .first(where: { $0.insertIndex == 1 })
        )
        let dropPoint = CGPoint(x: gap.frame.midX, y: gap.frame.midY)

        withBlockedLayoutRefreshes(fixture) {
            prepared.overview.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
            prepared.overview.updateDrag(on: fixture.monitor.id, at: dropPoint)
            prepared.overview.endDrag(on: fixture.monitor.id, at: dropPoint)
        }

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            [[first.id], [dragged.id], [second.id]]
        )
        XCTAssertEqual(prepared.overview.selectedWindowHandle, dragged)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testMouseDragOntoDwindleCardUsesWorkspaceOnlyPlacement() async throws {
        let fixture = try makeFixture(layouts: [.dwindle, .dwindle])
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let dragged = try addManagedWindow(
            pid: 461_023,
            windowId: 29,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let destination = try addManagedWindow(
            pid: 461_024,
            windowId: 30,
            to: destinationWorkspaceId,
            fixture: fixture
        )
        let prepared = try prepareDragOverview(fixture)
        let destinationFrame = try XCTUnwrap(prepared.layout.window(for: destination)?.overviewFrame)
        let dropPoint = CGPoint(x: destinationFrame.midX, y: destinationFrame.midY)

        prepared.overview.beginDrag(on: fixture.monitor.id, handle: dragged, startPoint: .zero)
        prepared.overview.updateDrag(on: fixture.monitor.id, at: dropPoint)
        prepared.overview.endDrag(on: fixture.monitor.id, at: dropPoint)
        try await waitForLayoutRefreshes(fixture)

        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        XCTAssertNil(engine.findNode(for: dragged.id, in: sourceWorkspaceId))
        XCTAssertNotNil(engine.findNode(for: dragged.id, in: destinationWorkspaceId))
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: dragged.id),
            destinationWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            destinationWorkspaceId
        )
        XCTAssertEqual(prepared.overview.selectedWindowHandle, dragged)
        XCTAssertEqual(fixture.focusRecorder.callCount, 0)
    }

    func testDeferredColumnInsertIndexPreservesOriginalGap() {
        XCTAssertEqual(
            OverviewController.deferredColumnInsertIndex(
                requestedIndex: 0,
                admittedColumnIndex: 2
            ),
            0
        )
        XCTAssertEqual(
            OverviewController.deferredColumnInsertIndex(
                requestedIndex: 1,
                admittedColumnIndex: 0
            ),
            2
        )
        XCTAssertEqual(
            OverviewController.deferredColumnInsertIndex(
                requestedIndex: 1,
                admittedColumnIndex: 1
            ),
            1
        )
        XCTAssertEqual(
            OverviewController.deferredColumnInsertIndex(
                requestedIndex: 3,
                admittedColumnIndex: 0
            ),
            4
        )
        XCTAssertEqual(
            OverviewController.deferredColumnInsertIndex(
                requestedIndex: 3,
                admittedColumnIndex: nil
            ),
            3
        )
    }

    private func makeFixture(layouts: [LayoutType]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewStructuralCommandTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.animationsEnabled = false
        settings.workspaceConfigurations = layouts.enumerated().map { index, layout in
            WorkspaceConfiguration(name: String(index + 1), monitorAssignment: .main, layoutType: layout)
        }
        let focusRecorder = FocusRecorder()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { focusRecorder.activatedPIDs.append($0) },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in focusRecorder.raisedCount += 1 }
            )
        )
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 46_100),
            displayId: 46_100,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Overview Structural Tests"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()

        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()

        let dwindleEngine = DwindleLayoutEngine()
        dwindleEngine.animationClock = controller.animationClock
        controller.dwindleEngine = dwindleEngine

        let workspaceIds = try layouts.indices.map { index in
            try XCTUnwrap(
                controller.workspaceManager.workspaceId(for: String(index + 1), createIfMissing: false)
            )
        }
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceIds[0], on: monitor.id))

        return Fixture(
            controller: controller,
            workspaceIds: workspaceIds,
            monitor: monitor,
            focusRecorder: focusRecorder
        )
    }

    private func prepareDragOverview(
        _ fixture: Fixture
    ) throws -> (overview: OverviewController, layout: OverviewLayout) {
        let workspaceManager = fixture.controller.workspaceManager
        var workspaces: [OverviewWorkspaceLayoutItem] = []
        var windowData: [WindowHandle: OverviewWindowLayoutData] = [:]
        var framesByToken: [WindowToken: CGRect] = [:]

        for monitor in workspaceManager.monitors {
            let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id
            for workspace in workspaceManager.workspaces(on: monitor.id) {
                workspaces.append((
                    id: workspace.id,
                    name: workspace.name,
                    isActive: workspace.id == activeWorkspaceId
                ))
                for entry in workspaceManager.entries(in: workspace.id) {
                    guard let handle = workspaceManager.handle(for: entry.token) else { continue }
                    let ordinal = CGFloat(entry.windowId % 10)
                    let frame = CGRect(
                        x: 50 + ordinal * 20,
                        y: 80 + ordinal * 15,
                        width: 520,
                        height: 360
                    )
                    framesByToken[entry.token] = frame
                    windowData[handle] = (
                        token: entry.token,
                        workspaceId: entry.workspaceId,
                        title: "Window \(entry.windowId)",
                        appName: "Test",
                        appIcon: nil,
                        frame: frame
                    )
                }
            }
        }

        var environment = OverviewEnvironment()
        environment.windowTitle = { "Window \($0.windowId)" }
        environment.windowFrame = { framesByToken[$0.token] }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)

        var niriSnapshots: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
        for workspaceId in fixture.workspaceIds
            where workspaceManager.activeLayoutKind(for: workspaceId) == .niri
        {
            niriSnapshots[workspaceId] = fixture.controller.niriEngine?.overviewSnapshot(for: workspaceId)
        }
        let layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: windowData,
            niriSnapshotsByWorkspace: niriSnapshots,
            screenFrame: OverviewLayoutCalculator.viewportFrame(for: fixture.monitor.frame),
            searchQuery: "",
            scale: OverviewLayoutCalculator.clampedScale(
                CGFloat(fixture.controller.settings.overviewZoom)
            )
        )
        return (overview, layout)
    }

    private func waitForLayoutRefreshes(_ fixture: Fixture) async throws {
        let refreshController = fixture.controller.layoutRefreshController
        for _ in 0 ..< 200 {
            if refreshController.layoutState.activeRefreshTask == nil,
               refreshController.layoutState.pendingRefresh == nil
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Layout refreshes did not settle")
    }

    private func addManagedWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture
    ) throws -> WindowHandle {
        let controller = fixture.controller
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
            case .dwindle:
                _ = controller.dwindleEngine?.addWindow(
                    token: token,
                    to: workspaceId,
                    activeWindowFrame: nil
                )
            }
        }
        return try XCTUnwrap(controller.workspaceManager.handle(for: token))
    }

    private func withBlockedLayoutRefreshes<T>(
        _ fixture: Fixture,
        _ body: () throws -> T
    ) rethrows -> T {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let refreshController = fixture.controller.layoutRefreshController
        refreshController.layoutState.activeRefreshTask = blocker
        refreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .overviewMutation,
            affectedWorkspaceIds: [fixture.workspaceIds[0]]
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
