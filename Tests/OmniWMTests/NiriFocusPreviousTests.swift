// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriFocusPreviousTests: XCTestCase {
    private struct EngineFixture {
        let engine: NiriLayoutEngine
        let workspaceA: WorkspaceDescriptor.ID
        let workspaceB: WorkspaceDescriptor.ID
        let windowA1: NiriWindow
        let windowA2: NiriWindow
        let windowB: NiriWindow
    }

    func testGlobalMRUFindsCrossWorkspaceWindow() {
        let fixture = makeEngineFixture()
        fixture.windowA1.lastFocusedTime = timestamp(1)
        fixture.windowA2.lastFocusedTime = timestamp(2)
        fixture.windowB.lastFocusedTime = timestamp(3)

        let global = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: fixture.windowA1.id,
            in: nil
        )
        let scoped = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: fixture.windowA1.id,
            in: fixture.workspaceA
        )

        XCTAssertEqual(global?.token, fixture.windowB.token)
        XCTAssertEqual(scoped?.token, fixture.windowA2.token)
    }

    func testGlobalMRUPrefersNewerSameWorkspaceWindow() {
        let fixture = makeEngineFixture()
        fixture.windowA1.lastFocusedTime = timestamp(1)
        fixture.windowB.lastFocusedTime = timestamp(2)
        fixture.windowA2.lastFocusedTime = timestamp(3)

        let global = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: fixture.windowA1.id,
            in: nil
        )

        XCTAssertEqual(global?.token, fixture.windowA2.token)
    }

    func testUnstampedWindowsExcluded() {
        let fixture = makeEngineFixture()
        fixture.windowA1.lastFocusedTime = timestamp(1)

        let onlyExcludedStamped = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: fixture.windowA1.id,
            in: nil
        )
        let noExcludedWindow = fixture.engine.findMostRecentlyFocusedWindow(
            excluding: nil,
            in: nil
        )

        XCTAssertNil(onlyExcludedStamped)
        XCTAssertEqual(noExcludedWindow?.token, fixture.windowA1.token)
    }

    func testToggleAlternatesAcrossWorkspaces() throws {
        let fixture = makeEngineFixture()
        fixture.windowA1.lastFocusedTime = timestamp(1)
        fixture.windowB.lastFocusedTime = timestamp(2)

        let firstTarget = try XCTUnwrap(
            fixture.engine.findMostRecentlyFocusedWindow(
                excluding: fixture.windowB.id,
                in: nil
            )
        )
        fixture.windowB.lastFocusedTime = timestamp(3)
        firstTarget.lastFocusedTime = timestamp(4)

        let secondTarget = try XCTUnwrap(
            fixture.engine.findMostRecentlyFocusedWindow(
                excluding: firstTarget.id,
                in: nil
            )
        )

        XCTAssertEqual(firstTarget.token, fixture.windowA1.token)
        XCTAssertEqual(secondTarget.token, fixture.windowB.token)
    }

    func testEmptyCurrentWorkspaceFindsRemoteWindow() {
        let engine = NiriLayoutEngine()
        let emptyWorkspace = WorkspaceDescriptor.ID()
        let remoteWorkspace = WorkspaceDescriptor.ID()
        _ = engine.ensureRoot(for: emptyWorkspace)
        let remoteWindow = engine.addWindow(
            token: token(1),
            to: remoteWorkspace,
            afterSelection: nil
        )
        remoteWindow.lastFocusedTime = timestamp(1)

        let target = engine.findMostRecentlyFocusedWindow(excluding: nil, in: nil)

        XCTAssertEqual(target?.token, remoteWindow.token)
    }

    func testCommandFocusPreviousJumpsToWindowOnAnotherWorkspace() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeCommandFixture { pid, windowId, _ in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceB)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        let result = fixture.controller.commandHandler.handleHotkeyCommand(.focusPrevious)

        XCTAssertEqual(result, .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspaceA)
        XCTAssertEqual(
            fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceA).selectedNodeId,
            fixture.nodeA.id
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceB).selectedNodeId,
            fixture.nodeB.id
        )
        XCTAssertTrue(frontedTokens.isEmpty)
        let postLayout = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        XCTAssertTrue(postLayout.isCurrent(using: fixture.controller.workspaceManager))
        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
        XCTAssertEqual(frontedTokens, [fixture.tokenA])
    }

    func testCommandFocusPreviousDoesNotNavigateLocallyWithoutPriorObservedFocus() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeCommandFixture { pid, windowId, _ in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let tokenC = addWindow(
            pid: 447_004,
            windowId: 447_104,
            to: fixture.workspaceB,
            controller: fixture.controller
        )
        let nodeC = engine.addWindow(token: tokenC, to: fixture.workspaceB, afterSelection: fixture.nodeB.id)
        nodeC.lastFocusedTime = timestamp(3)
        XCTAssertNotNil(
            fixture.controller.workspaceManager.removeWindow(
                pid: fixture.tokenA.pid,
                windowId: fixture.tokenA.windowId
            )
        )
        _ = fixture.controller.workspaceManager.setManagedFocus(fixture.nodeB.token, in: fixture.workspaceB)
        fixture.controller.commandHandler.frontmostAppPidProvider = { fixture.nodeB.token.pid }
        fixture.controller.commandHandler.frontmostFocusedWindowTokenProvider = { fixture.nodeB.token }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceB)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focusPrevious),
            .executed
        )
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspaceB)
        XCTAssertEqual(
            fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceB).selectedNodeId,
            fixture.nodeB.id
        )
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertTrue(frontedTokens.isEmpty)
    }

    func testCommandFocusPreviousUsesHistoryWhenFrontmostWindowIsOutsideNiri() throws {
        var frontedTokens: [WindowToken] = []
        let controller = makeController { pid, windowId, _ in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let workspaceA = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let workspaceB = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        controller.settings.workspaceConfigurations = controller.settings.workspaceConfigurations.map { configuration in
            guard configuration.name == "1" else { return configuration }
            var configuration = configuration
            configuration.layoutType = .dwindle
            return configuration
        }
        controller.workspaceManager.applySettings()
        _ = controller.workspaceManager.focusWorkspace(named: "2")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let tokenA = addWindow(pid: 447_011, windowId: 447_111, to: workspaceA, controller: controller)
        let tokenB = addWindow(pid: 447_012, windowId: 447_112, to: workspaceB, controller: controller)
        let nodeB = engine.addWindow(token: tokenB, to: workspaceB, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: nodeB.id,
            focusedToken: tokenB,
            in: workspaceB,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceB)
        )
        _ = controller.workspaceManager.setManagedFocus(tokenA, in: workspaceA)
        _ = controller.workspaceManager.setManagedFocus(tokenB, in: workspaceB)
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        XCTAssertEqual(
            controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: tokenB),
            tokenA
        )
        controller.commandHandler.frontmostAppPidProvider = { tokenA.pid }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { tokenA }
        let blocker = blockLayoutRefresh(controller, workspaceId: workspaceB)
        defer { unblockLayoutRefresh(controller, blocker: blocker) }

        XCTAssertEqual(controller.commandHandler.handleHotkeyCommand(.focusPrevious), .executed)
        XCTAssertEqual(
            controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: tokenA),
            tokenB
        )
        let postLayoutActions = try XCTUnwrap(
            controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
        )
        XCTAssertFalse(postLayoutActions.isEmpty)
        postLayoutActions.forEach { $0.runIfCurrent(using: controller.workspaceManager) }

        XCTAssertEqual(controller.activeWorkspace()?.id, workspaceB)
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceB).selectedNodeId,
            nodeB.id
        )
        XCTAssertEqual(frontedTokens, [tokenB])
    }

    func testFocusHistoryAdvancesOnlyAfterManagedFocusConfirmation() throws {
        let controller = makeController()
        let workspaceA = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let workspaceB = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let tokenA = addWindow(pid: 447_021, windowId: 447_121, to: workspaceA, controller: controller)
        let tokenB = addWindow(pid: 447_022, windowId: 447_122, to: workspaceB, controller: controller)
        let tokenC = addWindow(pid: 447_023, windowId: 447_123, to: workspaceB, controller: controller)

        XCTAssertTrue(controller.workspaceManager.setManagedFocus(tokenA, in: workspaceA))
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(tokenB, in: workspaceB))
        XCTAssertEqual(
            controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: tokenB),
            tokenA
        )

        let requestId: UInt64 = 447
        XCTAssertTrue(
            controller.workspaceManager.beginManagedFocusRequest(
                tokenC,
                in: workspaceB,
                requestId: requestId
            )
        )
        XCTAssertEqual(
            controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: tokenB),
            tokenA
        )
        XCTAssertEqual(
            controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: tokenC),
            tokenB
        )

        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                tokenC,
                in: workspaceB,
                activateWorkspaceOnMonitor: false,
                requestId: requestId
            )
        )
        XCTAssertEqual(
            controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: tokenC),
            tokenB
        )
        XCTAssertEqual(
            controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: tokenB),
            tokenC
        )
    }

    func testCommandFocusPreviousCompletesAfterTargetLayoutInvalidation() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeCommandFixture { pid, windowId, _ in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceB)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focusPrevious),
            .executed
        )
        let postLayout = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        fixture.controller.workspaceManager.invalidateLayout(for: [fixture.workspaceA])

        XCTAssertFalse(postLayout.isCurrent(using: fixture.controller.workspaceManager))
        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
        XCTAssertEqual(frontedTokens, [fixture.tokenA])
    }

    func testNewerSameWorkspaceManagedFocusRejectsInvalidatedFocusPrevious() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeCommandFixture { pid, windowId, _ in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceB)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let newerToken = addWindow(
            pid: 447_003,
            windowId: 447_103,
            to: fixture.workspaceA,
            controller: fixture.controller
        )

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focusPrevious),
            .executed
        )
        let postLayout = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        fixture.controller.focusWindow(newerToken)

        XCTAssertFalse(postLayout.isCurrent(using: fixture.controller.workspaceManager))
        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
        XCTAssertEqual(frontedTokens, [newerToken])
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, newerToken)
    }

    func testCommandFocusPreviousSurvivesUnrelatedMonitorInvalidation() throws {
        var frontedTokens: [WindowToken] = []
        let controller = makeController { pid, windowId, _ in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let primary = Monitor(
            id: .init(displayId: 447),
            displayId: 447,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Primary"
        )
        let secondary = Monitor(
            id: .init(displayId: 448),
            displayId: 448,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Secondary"
        )
        controller.settings.workspaceConfigurations = controller.settings.workspaceConfigurations.map { configuration in
            var configuration = configuration
            configuration.monitorAssignment = ["6", "7"].contains(configuration.name)
                ? .specificDisplay(OutputId(from: secondary))
                : .specificDisplay(OutputId(from: primary))
            return configuration
        }
        controller.workspaceManager.applyMonitorConfigurationChange([primary, secondary])
        controller.workspaceManager.applySettings()
        let workspaceA = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let workspaceB = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let unrelatedWorkspace = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "6", createIfMissing: true)
        )
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceB, on: primary.id))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(unrelatedWorkspace, on: secondary.id))
        _ = controller.workspaceManager.setInteractionMonitor(primary.id)
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let tokenA = addWindow(pid: 447_011, windowId: 447_111, to: workspaceA, controller: controller)
        let tokenB = addWindow(pid: 447_012, windowId: 447_112, to: workspaceB, controller: controller)
        let nodeA = engine.addWindow(token: tokenA, to: workspaceA, afterSelection: nil)
        let nodeB = engine.addWindow(token: tokenB, to: workspaceB, afterSelection: nil)
        nodeA.lastFocusedTime = timestamp(1)
        nodeB.lastFocusedTime = timestamp(2)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: nodeB.id,
            focusedToken: tokenB,
            in: workspaceB,
            onMonitor: primary.id
        )
        let blocker = blockLayoutRefresh(controller, workspaceId: workspaceB)
        defer { unblockLayoutRefresh(controller, blocker: blocker) }

        XCTAssertEqual(controller.commandHandler.handleHotkeyCommand(.focusPrevious), .executed)
        let postLayout = try XCTUnwrap(
            controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        XCTAssertEqual(Set(postLayout.workspaceSeqs.keys), [workspaceA])
        controller.workspaceManager.invalidateLayout(for: [unrelatedWorkspace])

        XCTAssertTrue(postLayout.isCurrent(using: controller.workspaceManager))
        postLayout.runIfCurrent(using: controller.workspaceManager)
        XCTAssertEqual(frontedTokens, [tokenA])
    }

    func testCommandFocusPreviousRejectsReusedTargetToken() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeCommandFixture { pid, windowId, _ in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceB)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let originalHandle = try XCTUnwrap(
            fixture.controller.workspaceManager.handle(for: fixture.tokenA)
        )

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focusPrevious),
            .executed
        )
        let postLayout = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        XCTAssertNotNil(
            fixture.controller.workspaceManager.removeWindow(
                pid: fixture.tokenA.pid,
                windowId: fixture.tokenA.windowId
            )
        )
        let replacementToken = addWindow(
            pid: fixture.tokenA.pid,
            windowId: fixture.tokenA.windowId,
            to: fixture.workspaceA,
            controller: fixture.controller
        )
        let replacementHandle = try XCTUnwrap(
            fixture.controller.workspaceManager.handle(for: replacementToken)
        )

        XCTAssertFalse(replacementHandle === originalHandle)
        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
        XCTAssertTrue(frontedTokens.isEmpty)
    }

    private func makeEngineFixture() -> EngineFixture {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let windowA1 = engine.addWindow(token: token(1), to: workspaceA, afterSelection: nil)
        let windowA2 = engine.addWindow(token: token(2), to: workspaceA, afterSelection: windowA1.id)
        let windowB = engine.addWindow(token: token(3), to: workspaceB, afterSelection: nil)
        return EngineFixture(
            engine: engine,
            workspaceA: workspaceA,
            workspaceB: workspaceB,
            windowA1: windowA1,
            windowA2: windowA2,
            windowB: windowB
        )
    }

    private struct CommandFixture {
        let controller: WMController
        let workspaceA: WorkspaceDescriptor.ID
        let workspaceB: WorkspaceDescriptor.ID
        let tokenA: WindowToken
        let nodeA: NiriWindow
        let nodeB: NiriWindow
    }

    private func makeCommandFixture(
        focusSpecificWindow: @escaping (pid_t, UInt32, AXUIElement) -> Void
    ) throws -> CommandFixture {
        let controller = makeController(focusSpecificWindow: focusSpecificWindow)
        let workspaceA = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let workspaceB = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "2")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let tokenA = addWindow(pid: 447_001, windowId: 447_101, to: workspaceA, controller: controller)
        let tokenB = addWindow(pid: 447_002, windowId: 447_102, to: workspaceB, controller: controller)
        let nodeA = engine.addWindow(token: tokenA, to: workspaceA, afterSelection: nil)
        let nodeB = engine.addWindow(token: tokenB, to: workspaceB, afterSelection: nil)
        nodeA.lastFocusedTime = timestamp(1)
        nodeB.lastFocusedTime = timestamp(2)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: nodeB.id,
            focusedToken: tokenB,
            in: workspaceB,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceB)
        )
        _ = controller.workspaceManager.setManagedFocus(tokenA, in: workspaceA)
        _ = controller.workspaceManager.setManagedFocus(tokenB, in: workspaceB)
        return CommandFixture(
            controller: controller,
            workspaceA: workspaceA,
            workspaceB: workspaceB,
            tokenA: tokenA,
            nodeA: nodeA,
            nodeB: nodeB
        )
    }

    private func makeController(
        focusSpecificWindow: @escaping (pid_t, UInt32, AXUIElement) -> Void = { _, _, _ in }
    ) -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNiriFocusPreviousTests-\(UUID().uuidString)", isDirectory: true)
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
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: focusSpecificWindow,
                raiseWindow: { _ in }
            )
        )
    }

    private func blockLayoutRefresh(
        _ controller: WMController,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Task<Void, Never> {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [workspaceId]
        )
        return blocker
    }

    private func unblockLayoutRefresh(
        _ controller: WMController,
        blocker: Task<Void, Never>
    ) {
        blocker.cancel()
        controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        controller.layoutRefreshController.layoutState.pendingRefresh = nil
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

    private func token(_ index: Int) -> WindowToken {
        WindowToken(pid: 447, windowId: index)
    }

    private func timestamp(_ order: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 447 + order)
    }
}
