// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriSingleWindowRemovalTests: XCTestCase {
    func testRemovalIntoSingleWindowFitDoesNotSeedStaleMoveOffset() throws {
        let controller = makeController()
        controller.settings.niriSingleWindowFit = .fullScreen
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let firstToken = addWindow(pid: 891_001, windowId: 891_101, to: workspaceId, controller: controller)
        let closingToken = addWindow(pid: 891_002, windowId: 891_102, to: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        let closingNode = engine.addWindow(
            token: closingToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )

        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let fullscreenFrame = controller.fullscreenLayoutFrame(for: monitor)
        let halfWidth = fullscreenFrame.width / 2
        let oldFirstFrame = CGRect(
            x: fullscreenFrame.minX - halfWidth,
            y: fullscreenFrame.minY,
            width: halfWidth,
            height: fullscreenFrame.height
        )
        let oldClosingFrame = CGRect(
            x: fullscreenFrame.midX,
            y: fullscreenFrame.minY,
            width: halfWidth,
            height: fullscreenFrame.height
        )
        firstNode.frame = oldFirstFrame
        firstNode.renderedFrame = oldFirstFrame
        closingNode.frame = oldClosingFrame
        closingNode.renderedFrame = oldClosingFrame

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = closingNode.id
        state.activeColumnIndex = 1
        state.viewOffset = -halfWidth
        state.activatePrevColumnOnRemoval = 0
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: closingToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        // A stale engine alone is insufficient: while both windows still
        // participate in world state, activation must preserve the viewport.
        var multiWindowFocusState = state
        controller.niriLayoutHandler.activateNode(
            firstNode,
            in: workspaceId,
            state: &multiWindowFocusState,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                preserveViewportAnchor: true,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        XCTAssertEqual(multiWindowFocusState.activeColumnIndex, 1)
        XCTAssertEqual(multiWindowFocusState.viewOffset, -halfWidth)

        _ = controller.workspaceManager.removeWindow(
            pid: closingToken.pid,
            windowId: closingToken.windowId
        )

        // Focus recovery can happen before the removal layout pass removes the
        // closing node from the engine. The world model is already authoritative.
        var preLayoutFocusState = state
        controller.niriLayoutHandler.activateNode(
            firstNode,
            in: workspaceId,
            state: &preLayoutFocusState,
            options: .init(
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        XCTAssertEqual(preLayoutFocusState.activeColumnIndex, 0)
        XCTAssertEqual(preLayoutFocusState.viewOffset, 0)
        XCTAssertFalse(preLayoutFocusState.hasPendingOffsetAnimation)
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: preLayoutFocusState,
                rememberedFocusToken: firstToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let plan = try XCTUnwrap(
            controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(
                    activeWorkspaces: [workspaceId],
                    useScrollAnimationPath: true,
                    removalSeeds: [
                        workspaceId: NiriWindowRemovalSeed(
                            removedNodeIds: [closingNode.id],
                            oldFrames: [
                                firstToken: oldFirstFrame,
                                closingToken: oldClosingFrame
                            ],
                            removedColumn: true
                        )
                    ]
                ).first
            }
        )

        let remainingNode = try XCTUnwrap(engine.findNode(for: firstToken, in: workspaceId))
        XCTAssertFalse(remainingNode.hasMoveAnimationsRunning)
        XCTAssertNil(engine.columns(in: workspaceId).first?.moveAnimation)
        XCTAssertEqual(plan.sessionPatch.viewportState?.activeColumnIndex, 0)
        XCTAssertEqual(plan.sessionPatch.viewportState?.viewOffset, 0)

        let frameChange = try XCTUnwrap(plan.diff.frameChanges.first { $0.token == firstToken })
        XCTAssertEqual(frameChange.frame, fullscreenFrame)
        XCTAssertFalse(plan.animationDirectives.contains { directive in
            if case let .startNiriScroll(directiveWorkspaceId) = directive {
                return directiveWorkspaceId == workspaceId
            }
            return false
        })

        // AX focus confirmation activates the fallback window after removal. It
        // must not reintroduce a viewport spring for a single-window-fit layout.
        var focusState = try XCTUnwrap(plan.sessionPatch.viewportState)
        focusState.viewOffset = -halfWidth
        focusState.clearOffsetTransition()
        controller.niriLayoutHandler.activateNode(
            remainingNode,
            in: workspaceId,
            state: &focusState,
            options: .init(
                ensureVisible: false,
                preserveViewportAnchor: true,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        XCTAssertEqual(focusState.activeColumnIndex, 0)
        XCTAssertEqual(focusState.viewOffset, 0)
        XCTAssertFalse(focusState.hasPendingOffsetAnimation)
    }

    func testColumnWidthRemovalRestartsPendingViewportAnimation() throws {
        let controller = makeController()
        controller.settings.niriSingleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let firstToken = addWindow(pid: 891_011, windowId: 891_111, to: workspaceId, controller: controller)
        let closingToken = addWindow(pid: 891_012, windowId: 891_112, to: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        let closingNode = engine.addWindow(
            token: closingToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )

        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let halfWidth = workingFrame.width / 2
        let oldFirstFrame = workingFrame.offsetBy(dx: -halfWidth, dy: 0)
        let oldClosingFrame = CGRect(
            x: workingFrame.midX,
            y: workingFrame.minY,
            width: halfWidth,
            height: workingFrame.height
        )
        firstNode.frame = oldFirstFrame
        firstNode.renderedFrame = oldFirstFrame
        closingNode.frame = oldClosingFrame
        closingNode.renderedFrame = oldClosingFrame
        if let column = engine.column(of: firstNode) {
            column.width = .proportion(1)
            column.cachedWidth = workingFrame.width
            column.hasManualSingleWindowWidthOverride = true
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = closingNode.id
        state.activeColumnIndex = 1
        state.viewOffset = -halfWidth
        state.activatePrevColumnOnRemoval = 0
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: closingToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        _ = controller.workspaceManager.removeWindow(pid: closingToken.pid, windowId: closingToken.windowId)

        // Container-primary-span remains viewport-driven even while world
        // membership is ahead of the stale two-column engine topology.
        var preLayoutFocusState = state
        controller.niriLayoutHandler.activateNode(
            firstNode,
            in: workspaceId,
            state: &preLayoutFocusState,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                preserveViewportAnchor: true,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        XCTAssertEqual(preLayoutFocusState.activeColumnIndex, 1)
        XCTAssertEqual(preLayoutFocusState.viewOffset, -halfWidth)

        let plan = try XCTUnwrap(
            controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(
                    activeWorkspaces: [workspaceId],
                    useScrollAnimationPath: true,
                    removalSeeds: [
                        workspaceId: NiriWindowRemovalSeed(
                            removedNodeIds: [closingNode.id],
                            oldFrames: [firstToken: oldFirstFrame, closingToken: oldClosingFrame],
                            removedColumn: true
                        )
                    ]
                ).first
            }
        )

        let viewportState = try XCTUnwrap(plan.sessionPatch.viewportState)
        XCTAssertTrue(viewportState.hasPendingOffsetAnimation)
        XCTAssertTrue(plan.animationDirectives.contains { directive in
            if case let .startNiriScroll(directiveWorkspaceId) = directive {
                return directiveWorkspaceId == workspaceId
            }
            return false
        })
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNiriSingleWindowRemovalTests-\(UUID().uuidString)", isDirectory: true)
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
