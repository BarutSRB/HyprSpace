// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FullRescanReadmissionTests: XCTestCase {
    func testFullRescanFloatingFocusCandidateRequiresNewCreateContext() {
        let token = WindowToken(pid: 9000, windowId: 1)
        let workspaceId = UUID()
        let context = createPlacementContext(createdAt: Date())

        XCTAssertNil(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: token,
                workspaceId: workspaceId,
                isNewAdmission: false,
                mode: .floating,
                interactionPolicy: .full,
                createPlacementContext: context
            )
        )
        XCTAssertNil(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: token,
                workspaceId: workspaceId,
                isNewAdmission: true,
                mode: .tiling,
                interactionPolicy: .full,
                createPlacementContext: context
            )
        )
        XCTAssertNil(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: token,
                workspaceId: workspaceId,
                isNewAdmission: true,
                mode: .floating,
                interactionPolicy: .full,
                createPlacementContext: nil
            )
        )
    }

    func testFullRescanFloatingFocusCandidateSkipsHandsOffSurfaces() {
        let token = WindowToken(pid: 9000, windowId: 4)
        let workspaceId = UUID()
        let context = createPlacementContext(createdAt: Date())

        XCTAssertNil(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: token,
                workspaceId: workspaceId,
                isNewAdmission: true,
                mode: .floating,
                interactionPolicy: .handsOffSurface,
                createPlacementContext: context
            )
        )
        XCTAssertNotNil(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: token,
                workspaceId: workspaceId,
                isNewAdmission: true,
                mode: .floating,
                interactionPolicy: .full,
                createPlacementContext: context
            )
        )
    }

    func testFullRescanFloatingFocusCandidateKeepsNewestCreate() throws {
        let olderToken = WindowToken(pid: 9000, windowId: 2)
        let newerToken = WindowToken(pid: 9000, windowId: 3)
        let workspaceId = UUID()
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)

        let older = try XCTUnwrap(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: olderToken,
                workspaceId: workspaceId,
                isNewAdmission: true,
                mode: .floating,
                interactionPolicy: .full,
                createPlacementContext: createPlacementContext(createdAt: olderDate)
            )
        )
        let earlierCandidate = try XCTUnwrap(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: newerToken,
                workspaceId: workspaceId,
                isNewAdmission: true,
                mode: .floating,
                interactionPolicy: .full,
                createPlacementContext: createPlacementContext(createdAt: olderDate.addingTimeInterval(-1))
            )
        )
        let retained = LayoutRefreshController.newestFullRescanFloatingFocusCandidate(
            older,
            considering: earlierCandidate
        )
        let newerCandidate = try XCTUnwrap(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: newerToken,
                workspaceId: workspaceId,
                isNewAdmission: true,
                mode: .floating,
                interactionPolicy: .full,
                createPlacementContext: createPlacementContext(createdAt: newerDate)
            )
        )
        let selected = LayoutRefreshController.newestFullRescanFloatingFocusCandidate(
            retained,
            considering: newerCandidate
        )

        XCTAssertEqual(retained.token, olderToken)
        XCTAssertEqual(selected.token, newerToken)
        XCTAssertEqual(selected.workspaceId, workspaceId)
        XCTAssertEqual(selected.createdAt, newerDate)
    }

    func testCrossWorkspaceFloatingFocusValidatesCandidateWorkspaceWithoutRefocusingOldWindow() throws {
        var operations: [String] = []
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMFullRescanFocusTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { operations.append("activate:\($0)") },
                focusSpecificWindow: { pid, windowId, _ in
                    operations.append("focus:\(pid):\(windowId)")
                },
                raiseWindow: { _ in operations.append("raise") },
                orderWindow: { operations.append("order:\($0)") }
            )
        )
        let leftMonitor = Monitor(
            id: .init(displayId: 90_001),
            displayId: 90_001,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Full Rescan Focus Left"
        )
        let rightMonitor = Monitor(
            id: .init(displayId: 90_002),
            displayId: 90_002,
            frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Full Rescan Focus Right"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        let leftWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let rightWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "6", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        XCTAssertTrue(controller.workspaceManager.visibleWorkspaceIds().contains(rightWorkspaceId))
        let previousToken = WindowToken(pid: 9004, windowId: 4)
        _ = controller.workspaceManager.addWindow(
            axRef(previousToken.pid, previousToken.windowId),
            pid: previousToken.pid,
            windowId: previousToken.windowId,
            to: leftWorkspaceId,
            mode: .tiling
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                previousToken,
                in: leftWorkspaceId,
                onMonitor: leftMonitor.id,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(controller.workspaceManager.enterNonManagedFocus())
        XCTAssertNil(controller.workspaceManager.focusedToken)

        let token = WindowToken(pid: 9005, windowId: 5)
        _ = controller.workspaceManager.addWindow(
            axRef(token.pid, token.windowId),
            pid: token.pid,
            windowId: token.windowId,
            to: rightWorkspaceId,
            mode: .floating
        )
        let candidate = try XCTUnwrap(
            LayoutRefreshController.FullRescanFloatingFocusCandidate(
                token: token,
                workspaceId: rightWorkspaceId,
                isNewAdmission: true,
                mode: .floating,
                interactionPolicy: .full,
                createPlacementContext: createPlacementContext(createdAt: Date())
            )
        )

        let validationWorkspaceId = controller.layoutRefreshController.focusFullRescanFloatingCandidate(
            candidate,
            fallbackWorkspaceId: leftWorkspaceId
        )
        XCTAssertEqual(validationWorkspaceId, rightWorkspaceId)
        controller.ensureFocusedTokenValid(in: try XCTUnwrap(validationWorkspaceId))
        XCTAssertEqual(
            operations,
            [
                "order:\(token.windowId)",
                "activate:\(token.pid)",
                "focus:\(token.pid):\(token.windowId)",
                "raise"
            ]
        )
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, token)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: leftWorkspaceId), previousToken)
        XCTAssertEqual(controller.focusPolicyEngine.activeLease?.owner, .ruleCreatedFloatingWindow)
        XCTAssertEqual(controller.focusPolicyEngine.activeLease?.reason, "floating_window_create")
        XCTAssertEqual(controller.focusPolicyEngine.activeLease?.suppressesFocusFollowsMouse, true)
        XCTAssertNotNil(controller.focusPolicyEngine.activeLease?.expiresAt)
    }

    func testUnchangedTrackedEntryIsNotReadmitted() throws {
        let manager = makeManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(axRef(9001, 1), pid: 9001, windowId: 1, to: workspaceId)
        let entry = try XCTUnwrap(manager.entry(for: token))

        XCTAssertFalse(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: workspaceId,
                mode: .tiling,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: false,
                appFullscreen: false
            )
        )
    }

    func testChangedStateStillReadmits() throws {
        let manager = makeManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let otherWorkspaceId = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        let token = manager.addWindow(axRef(9002, 2), pid: 9002, windowId: 2, to: workspaceId)
        let entry = try XCTUnwrap(manager.entry(for: token))

        XCTAssertTrue(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: otherWorkspaceId,
                mode: .tiling,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: false,
                appFullscreen: false
            )
        )
        XCTAssertTrue(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: workspaceId,
                mode: .floating,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: false,
                appFullscreen: false
            )
        )
        XCTAssertTrue(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: workspaceId,
                mode: .tiling,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: true,
                appFullscreen: false
            )
        )
        XCTAssertTrue(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: workspaceId,
                mode: .tiling,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: false,
                appFullscreen: true
            )
        )
    }

    private func makeManager() -> WorkspaceManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMFullRescanTests-\(UUID().uuidString)", isDirectory: true)
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
        return WorkspaceManager(settings: settings)
    }

    private func axRef(_ pid: pid_t, _ windowId: Int) -> AXWindowRef {
        AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
    }

    private func createPlacementContext(createdAt: Date) -> WindowCreatePlacementContext {
        WindowCreatePlacementContext(
            nativeSpaceMonitorId: nil,
            pendingFocusedWorkspaceId: nil,
            pendingFocusedMonitorId: nil,
            focusedWorkspaceId: nil,
            focusedMonitorId: nil,
            interactionWorkspaceId: nil,
            interactionMonitorId: nil,
            createdAt: createdAt
        )
    }
}
