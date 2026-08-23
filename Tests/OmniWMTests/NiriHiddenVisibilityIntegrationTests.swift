// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriHiddenVisibilityIntegrationTests: XCTestCase {
    func testSelectionDrivenCommandUsesVisibleFallbackBeforeRelayout() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let firstToken = addWindow(pid: 880_041, windowId: 880_141, to: workspaceId, controller: controller)
        let hiddenToken = addWindow(pid: 880_042, windowId: 880_142, to: workspaceId, controller: controller)
        let thirdToken = addWindow(pid: 880_043, windowId: 880_143, to: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        let hiddenNode = engine.addWindow(
            token: hiddenToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        _ = engine.addWindow(
            token: thirdToken,
            to: workspaceId,
            afterSelection: hiddenNode.id,
            focusedToken: hiddenToken
        )
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.activeColumnIndex = 1
        state.selectedNodeId = hiddenNode.id
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: hiddenToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .ax)

        controller.niriLayoutHandler.moveColumnToLast()

        XCTAssertEqual(
            engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) },
            [hiddenToken, thirdToken, firstToken]
        )
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            firstNode.id
        )
    }

    func testExplicitStructuralMutationsRejectHiddenHandles() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let visibleToken = addWindow(pid: 880_051, windowId: 880_151, to: workspaceId, controller: controller)
        let hiddenToken = addWindow(pid: 880_052, windowId: 880_152, to: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let visibleNode = engine.addWindow(token: visibleToken, to: workspaceId, afterSelection: nil)
        _ = engine.addWindow(
            token: hiddenToken,
            to: workspaceId,
            afterSelection: visibleNode.id,
            focusedToken: visibleToken
        )
        let visibleHandle = try XCTUnwrap(controller.workspaceManager.handle(for: visibleToken))
        let hiddenHandle = try XCTUnwrap(controller.workspaceManager.handle(for: hiddenToken))
        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .ax)
        let originalColumns = engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }

        XCTAssertEqual(
            controller.niriLayoutHandler.moveColumnToLast(containing: hiddenHandle),
            .unchanged
        )
        XCTAssertFalse(
            controller.niriLayoutHandler.insertWindow(
                handle: visibleHandle,
                targetHandle: hiddenHandle,
                position: .after,
                in: workspaceId
            )
        )
        XCTAssertFalse(
            controller.niriLayoutHandler.insertWindowInNewColumn(
                handle: hiddenHandle,
                insertIndex: 0,
                in: workspaceId
            )
        )
        XCTAssertEqual(
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) },
            originalColumns
        )
    }

    func testExplicitNavigationUsesProjectedViewportWhenAnotherAppIsHidden() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let firstToken = addWindow(pid: 880_061, windowId: 880_161, to: workspaceId, controller: controller)
        let hiddenToken = addWindow(pid: 880_062, windowId: 880_162, to: workspaceId, controller: controller)
        let targetToken = addWindow(pid: 880_063, windowId: 880_163, to: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        let hiddenNode = engine.addWindow(
            token: hiddenToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        let targetNode = engine.addWindow(
            token: targetToken,
            to: workspaceId,
            afterSelection: hiddenNode.id,
            focusedToken: hiddenToken
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .ax)
        var expectedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        expectedState.selectedNodeId = targetNode.id
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gap = controller.innerGap(for: monitor)
        let orientation = controller.settings.effectiveOrientation(for: monitor)
        controller.workspaceManager.withEngineMutationScope {
            engine.resolvePrimaryContainerSpans(
                in: workspaceId,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation
            )
            engine.ensureProjectedSelectionVisible(
                node: targetNode,
                in: workspaceId,
                motion: .disabled,
                state: &expectedState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation,
                animationConfig: nil,
                fromContainerIndex: nil
            )
        }

        XCTAssertTrue(
            controller.windowActionHandler.navigateToWindowInternal(
                token: targetToken,
                workspaceId: workspaceId
            )
        )

        let actualState = controller.workspaceManager.niriViewportState(for: workspaceId)
        XCTAssertEqual(actualState.selectedNodeId, targetNode.id)
        XCTAssertEqual(actualState.activeColumnIndex, expectedState.activeColumnIndex)
        XCTAssertEqual(actualState.viewOffset, expectedState.viewOffset, accuracy: 0.001)
    }

    func testNativeFullscreenCommandRejectsPreservedHiddenFocus() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = addWindow(pid: 880_071, windowId: 880_171, to: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        var fullscreenWrites = 0
        controller.commandHandler.nativeFullscreenStateProvider = { _ in false }
        controller.commandHandler.nativeFullscreenSetter = { _, _ in
            fullscreenWrites += 1
            return true
        }
        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .ax)

        XCTAssertEqual(controller.commandHandler.performCommand(.toggleNativeFullscreen), .executed)
        XCTAssertEqual(fullscreenWrites, 0)
        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: token))
    }

    func testNativeFullscreenCommandRejectsReusedStableOriginalTokenWithoutAXWrite() throws {
        let controller = makeController()
        let firstWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let secondWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let originalToken = addWindow(
            pid: 880_072,
            windowId: 880_172,
            to: firstWorkspaceId,
            controller: controller
        )
        XCTAssertTrue(
            controller.workspaceManager.markNativeFullscreenSuspended(
                originalToken,
                ownsNonManagedFocus: false
            )
        )
        let replacementToken = WindowToken(pid: originalToken.pid, windowId: 880_173)
        XCTAssertNotNil(
            controller.workspaceManager.rekeyWindow(
                from: originalToken,
                to: replacementToken,
                newAXRef: AXWindowRef(
                    element: AXUIElementCreateApplication(replacementToken.pid),
                    windowId: replacementToken.windowId
                )
            )
        )
        let reusedToken = addWindow(
            pid: originalToken.pid,
            windowId: originalToken.windowId,
            to: secondWorkspaceId,
            controller: controller
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                reusedToken,
                in: secondWorkspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        var fullscreenWrites = 0
        controller.commandHandler.nativeFullscreenStateProvider = { _ in false }
        controller.commandHandler.nativeFullscreenSetter = { _, _ in
            fullscreenWrites += 1
            return true
        }

        XCTAssertEqual(controller.commandHandler.performCommand(.toggleNativeFullscreen), .executed)

        XCTAssertEqual(fullscreenWrites, 0)
        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: reusedToken))
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: replacementToken)?.currentToken,
            replacementToken
        )
    }

    func testNativeFullscreenCommandRetriesAcceptedUnchangedEnterRequest() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = addWindow(pid: 880_073, windowId: 880_174, to: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId))
        let generation = controller.workspaceManager.nativeFullscreenRecord(for: token)?.transitionGeneration
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId))
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: token)?.transitionGeneration,
            generation
        )
        var fullscreenWrites = 0
        controller.commandHandler.nativeFullscreenStateProvider = { _ in false }
        controller.commandHandler.nativeFullscreenSetter = { _, fullscreen in
            XCTAssertTrue(fullscreen)
            fullscreenWrites += 1
            return true
        }

        XCTAssertEqual(controller.commandHandler.performCommand(.toggleNativeFullscreen), .executed)

        XCTAssertEqual(fullscreenWrites, 1)
        XCTAssertEqual(controller.workspaceManager.nativeFullscreenRecord(for: token)?.transition, .enterRequested)
    }

    func testNativeFullscreenExitCommandRejectsReusedStableOriginalTokenWithoutAXWrite() throws {
        let controller = makeController()
        let firstWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let secondWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let originalToken = addWindow(
            pid: 880_074,
            windowId: 880_175,
            to: firstWorkspaceId,
            controller: controller
        )
        XCTAssertTrue(
            controller.workspaceManager.markNativeFullscreenSuspended(
                originalToken,
                ownsNonManagedFocus: false
            )
        )
        let replacementToken = WindowToken(pid: originalToken.pid, windowId: 880_176)
        XCTAssertNotNil(
            controller.workspaceManager.rekeyWindow(
                from: originalToken,
                to: replacementToken,
                newAXRef: AXWindowRef(
                    element: AXUIElementCreateApplication(replacementToken.pid),
                    windowId: replacementToken.windowId
                )
            )
        )
        let reusedToken = addWindow(
            pid: originalToken.pid,
            windowId: originalToken.windowId,
            to: secondWorkspaceId,
            controller: controller
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                reusedToken,
                in: secondWorkspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        var fullscreenWrites = 0
        controller.commandHandler.nativeFullscreenStateProvider = { _ in true }
        controller.commandHandler.nativeFullscreenSetter = { _, _ in
            fullscreenWrites += 1
            return true
        }

        XCTAssertEqual(controller.commandHandler.performCommand(.toggleNativeFullscreen), .executed)

        XCTAssertEqual(fullscreenWrites, 0)
        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: reusedToken))
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: replacementToken)?.currentToken,
            replacementToken
        )
    }

    func testNativeFullscreenCommandRetriesAcceptedUnchangedExitRequest() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = addWindow(pid: 880_075, windowId: 880_177, to: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.markNativeFullscreenSuspended(
                token,
                ownsNonManagedFocus: false
            )
        )
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenExit(token))
        let generation = controller.workspaceManager.nativeFullscreenRecord(for: token)?.transitionGeneration
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenExit(token))
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: token)?.transitionGeneration,
            generation
        )
        var fullscreenWrites = 0
        controller.commandHandler.nativeFullscreenStateProvider = { _ in true }
        controller.commandHandler.nativeFullscreenSetter = { _, fullscreen in
            XCTAssertFalse(fullscreen)
            fullscreenWrites += 1
            return true
        }

        XCTAssertEqual(controller.commandHandler.performCommand(.toggleNativeFullscreen), .executed)

        XCTAssertEqual(fullscreenWrites, 1)
        XCTAssertEqual(controller.workspaceManager.nativeFullscreenRecord(for: token)?.transition, .exitRequested)
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NiriHiddenVisibilityIntegrationTests-\(UUID().uuidString)", isDirectory: true)
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
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
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
