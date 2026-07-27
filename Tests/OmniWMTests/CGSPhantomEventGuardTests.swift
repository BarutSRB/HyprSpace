// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class CGSPhantomEventGuardTests: XCTestCase {
    func testCGSDestroyForParkedTrackedWindowIsIgnored() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(941_001), windowId: 941_101),
            pid: 941_001, windowId: 941_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            for: token
        )

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: UInt32(token.windowId), spaceId: 0)
        )

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNotNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSDestroyForLiveTrackedWindowIsIgnored() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let windowId: UInt32 = 945_101
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(945_001), windowId: Int(windowId)),
            pid: 945_001, windowId: Int(windowId), to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        controller.axEventHandler.windowInfoProvider = { id in
            guard id == windowId else { return nil }
            return WindowServerInfo(
                id: id,
                pid: token.pid,
                level: 0,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
        }

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: windowId, spaceId: 0)
        )

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNotNil(controller.niriEngine?.findNode(for: token, in: workspaceId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSCloseRemovesParkedTrackedWindowDespiteStaleWindowServerInfo() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let windowId: UInt32 = 946_101
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(946_001), windowId: Int(windowId)),
            pid: 946_001, windowId: Int(windowId), to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            for: token
        )
        controller.axEventHandler.windowInfoProvider = { id in
            guard id == windowId else { return nil }
            return WindowServerInfo(
                id: id,
                pid: token.pid,
                level: 0,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
        }

        controller.axEventHandler.handleCGSEvent(.closed(windowId: windowId))

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertNil(controller.niriEngine?.findNode(for: token, in: workspaceId))

        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: windowId, spaceId: 0)
        )

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.niriEngine?.findNode(for: token, in: workspaceId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testNativeFullscreenCGSCloseRetiresAfterTransientDestroy() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        let pid: pid_t = 947_001
        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 947_101),
            pid: pid,
            windowId: 947_101,
            to: workspaceId
        )
        let peerToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 947_102),
            pid: pid,
            windowId: 947_102,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let targetNode = engine.addWindow(token: targetToken, to: workspaceId, afterSelection: nil)
        _ = engine.addWindow(
            token: peerToken,
            to: workspaceId,
            afterSelection: targetNode.id,
            focusedToken: targetToken
        )
        let targetColumn = try XCTUnwrap(engine.column(of: targetNode))
        let targetHandle = try XCTUnwrap(controller.workspaceManager.handle(for: targetToken))
        let originalColumnTokens = targetColumn.windowNodes.map(\.token)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: targetNode.id,
            focusedToken: targetToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        XCTAssertTrue(
            controller.workspaceManager.setManagedFocus(
                targetToken,
                in: workspaceId,
                onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
            )
        )
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: workspaceId))
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(targetToken))

        let fullscreenSpaceId: UInt64 = 94_700
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    SpaceTopology.DisplaySpaces(
                        displayIdentifier: "test-display",
                        spaceIds: [fullscreenSpaceId],
                        currentSpaceId: fullscreenSpaceId
                    )
                ],
                activeSpaceId: fullscreenSpaceId,
                fullscreenSpaceIds: [fullscreenSpaceId],
                windowSpace: [targetToken.windowId: fullscreenSpaceId]
            )
        )

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: UInt32(targetToken.windowId), spaceId: fullscreenSpaceId)
        )

        let preservedNode = try XCTUnwrap(engine.findNode(for: targetToken, in: workspaceId))
        XCTAssertEqual(preservedNode.id, targetNode.id)
        XCTAssertTrue(controller.workspaceManager.handle(for: targetToken) === targetHandle)
        XCTAssertTrue(engine.column(of: preservedNode) === targetColumn)
        XCTAssertEqual(targetColumn.windowNodes.map(\.token), originalColumnTokens)
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: targetToken)?.transition,
            .suspended
        )
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: targetToken), .nativeFullscreen)
        XCTAssertTrue(controller.workspaceManager.showsNativeFullscreenPlaceholder(for: targetToken))
        XCTAssertTrue(controller.workspaceManager.spaceTopology.isFullscreenSpace(fullscreenSpaceId))
        XCTAssertNil(controller.workspaceManager.spaceTopology.spaceForWindow(targetToken.windowId))

        controller.axEventHandler.handleCGSEvent(.closed(windowId: UInt32(targetToken.windowId)))

        XCTAssertNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertNil(engine.findNode(for: targetToken, in: workspaceId))
        XCTAssertFalse(
            engine.columns(in: workspaceId)
                .flatMap(\.windowNodes)
                .contains(where: { $0.token == targetToken })
        )
        XCTAssertFalse(controller.workspaceManager.showsNativeFullscreenPlaceholder(for: targetToken))
        XCTAssertFalse(
            WorldView(controller: controller)
                .nativeFullscreenPlaceholders()
                .contains(where: { $0.token == targetToken })
        )
        XCTAssertNotEqual(controller.workspaceManager.focusedToken, targetToken)
        XCTAssertNotEqual(controller.workspaceManager.pendingFocusedToken, targetToken)
        XCTAssertNotNil(controller.workspaceManager.entry(for: peerToken))
        XCTAssertNotNil(engine.findNode(for: peerToken, in: workspaceId))
        XCTAssertTrue(controller.workspaceManager.spaceTopology.isFullscreenSpace(fullscreenSpaceId))

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: UInt32(targetToken.windowId), spaceId: fullscreenSpaceId)
        )
        controller.axEventHandler.handleCGSEvent(.closed(windowId: UInt32(targetToken.windowId)))

        XCTAssertNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: peerToken))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testNativeFullscreenCGSCloseRetiresAfterUnmatchedManagedReplacementReplay() async throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        let pid: pid_t = 948_001
        let frame = CGRect(x: 160, y: 120, width: 720, height: 520)
        let metadata = Self.managedReplacementMetadata(
            workspaceId: workspaceId,
            pid: pid,
            frame: frame
        )
        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 948_101),
            pid: pid,
            windowId: 948_101,
            to: workspaceId,
            managedReplacementMetadata: metadata
        )
        let peerToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 948_102),
            pid: pid,
            windowId: 948_102,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let targetNode = engine.addWindow(token: targetToken, to: workspaceId, afterSelection: nil)
        _ = engine.addWindow(
            token: peerToken,
            to: workspaceId,
            afterSelection: targetNode.id,
            focusedToken: targetToken
        )

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: UInt32(targetToken.windowId), spaceId: 0)
        )
        XCTAssertNotNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(targetToken))

        controller.axEventHandler.handleCGSEvent(.closed(windowId: UInt32(targetToken.windowId)))

        XCTAssertNotNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertNotNil(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertTrue(
            controller.axEventHandler.managedReplacementTraceDump()
                .contains("deadlineReset: false")
        )

        let removed = try await Self.waitForRemoval(of: targetToken, controller: controller)

        XCTAssertTrue(removed)
        XCTAssertNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertNil(engine.findNode(for: targetToken, in: workspaceId))
        XCTAssertFalse(controller.workspaceManager.showsNativeFullscreenPlaceholder(for: targetToken))
        XCTAssertFalse(
            WorldView(controller: controller)
                .nativeFullscreenPlaceholders()
                .contains(where: { $0.token == targetToken })
        )
        XCTAssertNotEqual(controller.workspaceManager.focusedToken, targetToken)
        XCTAssertNotEqual(controller.workspaceManager.pendingFocusedToken, targetToken)
        XCTAssertNotNil(controller.workspaceManager.entry(for: peerToken))
        XCTAssertNotNil(engine.findNode(for: peerToken, in: workspaceId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSCloseStillRekeysMatchedManagedReplacement() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        let pid: pid_t = 949_001
        let frame = CGRect(x: 160, y: 120, width: 720, height: 520)
        let metadata = Self.managedReplacementMetadata(
            workspaceId: workspaceId,
            pid: pid,
            frame: frame
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 949_101),
            pid: pid,
            windowId: 949_101,
            to: workspaceId,
            managedReplacementMetadata: metadata
        )
        let peerToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 949_102),
            pid: pid,
            windowId: 949_102,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let oldNode = engine.addWindow(token: oldToken, to: workspaceId, afterSelection: nil)
        _ = engine.addWindow(
            token: peerToken,
            to: workspaceId,
            afterSelection: oldNode.id,
            focusedToken: oldToken
        )
        let oldHandle = try XCTUnwrap(controller.workspaceManager.handle(for: oldToken))
        let oldColumn = try XCTUnwrap(engine.column(of: oldNode))
        let originalColumnCount = engine.columns(in: workspaceId).count
        let originalColumnTokens = oldColumn.windowNodes.map(\.token)

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: UInt32(oldToken.windowId), spaceId: 0)
        )
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(oldToken))
        controller.axEventHandler.handleCGSEvent(.closed(windowId: UInt32(oldToken.windowId)))
        XCTAssertNotNil(controller.workspaceManager.entry(for: oldToken))

        let newToken = WindowToken(pid: pid, windowId: 949_103)
        let newAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: newToken.windowId
        )
        controller.axEventHandler.enqueueManagedReplacementCreate(
            .init(
                windowId: UInt32(newToken.windowId),
                token: newToken,
                axRef: newAXRef,
                ruleEffects: .none,
                admissionHints: .none,
                replacementMetadata: metadata,
                structuralReplacementMatch: nil,
                requiresPostCreateLifecycleVerification: false
            )
        )

        XCTAssertNil(controller.workspaceManager.entry(for: oldToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: newToken))
        XCTAssertTrue(controller.workspaceManager.handle(for: newToken) === oldHandle)
        let newNode = try XCTUnwrap(engine.findNode(for: newToken, in: workspaceId))
        XCTAssertTrue(newNode === oldNode)
        XCTAssertTrue(engine.column(of: newNode) === oldColumn)
        XCTAssertEqual(engine.columns(in: workspaceId).count, originalColumnCount)
        XCTAssertEqual(
            oldColumn.windowNodes.map(\.token),
            originalColumnTokens.map { $0 == oldToken ? newToken : $0 }
        )
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: newToken)?.currentToken,
            newToken
        )
        XCTAssertTrue(controller.workspaceManager.showsNativeFullscreenPlaceholder(for: newToken))
        XCTAssertFalse(controller.workspaceManager.showsNativeFullscreenPlaceholder(for: oldToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: peerToken))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSCreateForTrackedWindowVerifiesIdentityWithoutMutation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(942_001), windowId: 942_101),
            pid: 942_001, windowId: 942_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let entryBefore = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        controller.axEventHandler.handleCGSEvent(
            .created(windowId: UInt32(token.windowId), spaceId: 0)
        )

        let entryAfter = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertTrue(CFEqual(entryAfter.axRef.element, entryBefore.axRef.element))
        XCTAssertEqual(entryAfter.workspaceId, entryBefore.workspaceId)
        XCTAssertEqual(entryAfter.mode, entryBefore.mode)
        XCTAssertEqual(entryAfter.hiddenState, entryBefore.hiddenState)
        let trace = controller.axEventHandler.createFocusTraceDump()
        XCTAssertTrue(trace.contains("create_seen window=\(token.windowId)"))
        XCTAssertFalse(trace.contains("create_retry_scheduled"))
        XCTAssertFalse(trace.contains("admission_rejected"))
        XCTAssertNil(controller.axEventHandler.pendingCreatePlacementContext(for: token.windowId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSCreateForOwnProcessWindowSchedulesNoRetry() throws {
        let controller = Self.controller()
        let windowId: UInt32 = 943_101
        controller.axEventHandler.windowInfoProvider = { id in
            guard id == windowId else { return nil }
            return WindowServerInfo(
                id: id,
                pid: getpid(),
                level: 0,
                frame: CGRect(x: 0, y: 0, width: 400, height: 300)
            )
        }

        controller.axEventHandler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))

        let trace = controller.axEventHandler.createFocusTraceDump()
        XCTAssertTrue(trace.contains("create_seen window=\(windowId)"))
        XCTAssertFalse(trace.contains("create_retry_scheduled"))
        XCTAssertNil(controller.axEventHandler.pendingCreatePlacementContext(for: Int(windowId)))
        XCTAssertNil(controller.workspaceManager.entry(forWindowId: Int(windowId)))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSDestroyForUnmanagedWindowDoesNotScheduleFullRescan() {
        let controller = Self.controller()
        let windowId: UInt32 = 944_101
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: windowId, spaceId: 0)
        )

        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    private static func managedReplacementMetadata(
        workspaceId: WorkspaceDescriptor.ID,
        pid: pid_t,
        frame: CGRect
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: "com.omniwm.tests.close-evidence.\(pid)",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "replacement",
            windowLevel: 0,
            parentWindowId: nil,
            frame: frame
        )
    }

    private static func waitForRemoval(
        of token: WindowToken,
        controller: WMController
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if controller.workspaceManager.entry(for: token) == nil {
                return true
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        return controller.workspaceManager.entry(for: token) == nil
    }

    private static func controller() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCGSPhantomTests-\(UUID().uuidString)", isDirectory: true)
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
}
