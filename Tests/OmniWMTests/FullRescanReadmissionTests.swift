// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FullRescanReadmissionTests: XCTestCase {
    func testNewlyCreatedFloatingWindowTakesFocus() {
        // A user-created floating window (create-placement context present) must be focused so the
        // post-admission focus recovery does not steal focus back to the previously focused window.
        XCTAssertTrue(
            LayoutRefreshController.shouldFocusNewlyAdmittedFloatingWindow(
                isNewEntry: true,
                trackedMode: .floating,
                hasCreatePlacementContext: true
            )
        )
    }

    func testExistingOrTiledOrDiscoveredWindowsDoNotStealFocus() {
        // Already-tracked floating window seen again by a rescan must not re-grab focus.
        XCTAssertFalse(
            LayoutRefreshController.shouldFocusNewlyAdmittedFloatingWindow(
                isNewEntry: false,
                trackedMode: .floating,
                hasCreatePlacementContext: true
            )
        )
        // New tiled windows are focused through the layout path, not this floating fast path.
        XCTAssertFalse(
            LayoutRefreshController.shouldFocusNewlyAdmittedFloatingWindow(
                isNewEntry: true,
                trackedMode: .tiling,
                hasCreatePlacementContext: true
            )
        )
        // A floating window discovered during startup enumeration has no create-placement context
        // and must not yank focus from wherever the user currently is.
        XCTAssertFalse(
            LayoutRefreshController.shouldFocusNewlyAdmittedFloatingWindow(
                isNewEntry: true,
                trackedMode: .floating,
                hasCreatePlacementContext: false
            )
        )
    }

    // Integration-level coverage: drive the admission focus step through the real create-placement
    // context store and the injected focus-operation seam, not just the pure predicate.
    // `buildFullEffectPlan` itself cannot run headless (it enumerates live AX windows), so these
    // exercise the same `focusNewlyAdmittedFloatingWindow` entry point the admission loop calls.

    func testUserCreatedFloatingWindowRaisesThroughFocusOperationSeam() throws {
        let recorder = ActivationRecorder()
        let controller = makeRecordingController(recorder)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        XCTAssertTrue(
            controller.workspaceManager.visibleWorkspaceIds().contains(workspaceId),
            "precondition: the first workspace is the visible one"
        )
        controller.hasStartedServices = true

        let token = WindowToken(pid: 470_101, windowId: 470_111)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )

        // A user-created window records a create-placement context when AXWindowCreated fires.
        controller.axEventHandler.captureCreatePlacementContext(windowId: UInt32(token.windowId), spaceId: 0)
        let hasContext = controller.axEventHandler.pendingCreatePlacementContext(for: token.windowId) != nil
        XCTAssertTrue(hasContext, "create-placement context should be recorded for a user-created window")

        let raised = controller.layoutRefreshController.focusNewlyAdmittedFloatingWindow(
            token: token,
            isNewEntry: true,
            trackedMode: .floating,
            hasCreatePlacementContext: hasContext
        )

        XCTAssertTrue(raised)
        XCTAssertEqual(recorder.activatedPids, [token.pid], "the new floating window is fronted via the seam")
        XCTAssertTrue(recorder.orderedWindowIds.contains(UInt32(token.windowId)))
    }

    func testStartupDiscoveredFloatingWindowDoesNotRaiseOrStealFocus() throws {
        let recorder = ActivationRecorder()
        let controller = makeRecordingController(recorder)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.hasStartedServices = true

        let token = WindowToken(pid: 470_201, windowId: 470_211)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )

        // No create-placement context is recorded: this window was merely discovered by a rescan.
        let hasContext = controller.axEventHandler.pendingCreatePlacementContext(for: token.windowId) != nil
        XCTAssertFalse(hasContext, "a startup-discovered window has no create-placement context")

        let raised = controller.layoutRefreshController.focusNewlyAdmittedFloatingWindow(
            token: token,
            isNewEntry: true,
            trackedMode: .floating,
            hasCreatePlacementContext: hasContext
        )

        XCTAssertFalse(raised)
        XCTAssertTrue(recorder.activatedPids.isEmpty, "no window is fronted, so focus is not stolen")
        XCTAssertTrue(recorder.orderedWindowIds.isEmpty)
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

    private func makeRecordingController(_ recorder: ActivationRecorder) -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMFullRescanFocusTests-\(UUID().uuidString)", isDirectory: true)
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
                activateApp: { recorder.activatedPids.append($0) },
                focusSpecificWindow: { pid, windowId, _ in recorder.focusedWindows.append((pid, windowId)) },
                raiseWindow: { _ in recorder.raisedWindows += 1 },
                orderWindow: { recorder.orderedWindowIds.append($0) }
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
}

/// Records the focus-operation seam calls a controller makes, so tests can assert whether a window
/// was actually fronted.
@MainActor
private final class ActivationRecorder {
    var activatedPids: [pid_t] = []
    var focusedWindows: [(pid_t, UInt32)] = []
    var raisedWindows = 0
    var orderedWindowIds: [UInt32] = []
}
