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
        let hiddenByReasonToken = addWindow(pid: 880_002, windowId: 880_102, to: workspaceId, controller: controller)
        let visibleToken = addWindow(pid: 880_003, windowId: 880_103, to: workspaceId, controller: controller)
        controller.hiddenAppPIDs.insert(hiddenByPIDToken.pid)
        controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: hiddenByReasonToken)

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
        controller.hiddenAppPIDs.insert(hiddenToken.pid)

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
        controller.hiddenAppPIDs.insert(hiddenToken.pid)
        controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: hiddenToken)

        controller.focusWindow(hiddenToken)

        XCTAssertTrue(activatedPIDs.isEmpty)
        XCTAssertTrue(focusedTokens.isEmpty)
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
        controller.hiddenAppPIDs.insert(hiddenToken.pid)
        controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: hiddenToken)

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

        controller.hiddenAppPIDs.insert(hiddenToken.pid)
        controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: hiddenToken)
        let hidePlan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
        })
        XCTAssertTrue(controller.layoutRefreshController.executeLayoutPlan(hidePlan))
        XCTAssertEqual(engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }, [[firstToken], [thirdToken]])
        XCTAssertEqual(controller.workspaceManager.restoreIntent(for: thirdToken)?.niriPlacement?.columnIndex, 2)

        controller.hiddenAppPIDs.remove(hiddenToken.pid)
        XCTAssertTrue(controller.workspaceManager.restoreFromNativeState(for: hiddenToken))
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
