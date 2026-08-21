// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class LayoutDiffFrameOnlyTests: XCTestCase {
    func testFrameOnlyClassificationRejectsEveryVisibilityPath() {
        let token = WindowToken(pid: 72_001, windowId: 1)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [
            LayoutFrameChange(token: token, frame: .zero, forceApply: false)
        ]
        XCTAssertTrue(LayoutDiffExecutor.isFrameOnly(diff))

        diff.visibilityChanges = [.show(token)]
        XCTAssertFalse(LayoutDiffExecutor.isFrameOnly(diff))
        diff.visibilityChanges = []

        diff.restoreChanges = [
            LayoutRestoreChange(
                token: token,
                hiddenState: HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: nil,
                    reason: .layoutTransient(.left)
                )
            )
        ]
        XCTAssertFalse(LayoutDiffExecutor.isFrameOnly(diff))
        diff.restoreChanges = []

        diff.deferredHides = [
            LayoutDeferredHide(token: token, side: .left, revealToken: token)
        ]
        XCTAssertFalse(LayoutDiffExecutor.isFrameOnly(diff))
    }

    @MainActor
    func testFrameOnlyPreparationPreservesOrderingRecoveryAndExactAXRefs() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let firstRef = AXWindowRef(
            element: AXUIElementCreateApplication(72_101),
            windowId: 101
        )
        let secondRef = AXWindowRef(
            element: AXUIElementCreateApplication(72_102),
            windowId: 102
        )
        let fullscreenRef = AXWindowRef(
            element: AXUIElementCreateApplication(72_103),
            windowId: 103
        )
        let first = controller.workspaceManager.addWindow(
            firstRef,
            pid: 72_101,
            windowId: 101,
            to: workspaceId
        )
        let second = controller.workspaceManager.addWindow(
            secondRef,
            pid: 72_102,
            windowId: 102,
            to: workspaceId
        )
        let fullscreen = controller.workspaceManager.addWindow(
            fullscreenRef,
            pid: 72_103,
            windowId: 103,
            to: workspaceId
        )
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: fullscreen)
        let firstFrame = CGRect(x: 10, y: 20, width: 300, height: 400)
        let secondFrame = CGRect(x: 320, y: 20, width: 300, height: 400)
        let executor = LayoutDiffExecutor(refreshController: controller.layoutRefreshController)

        let preparation = executor.prepareFrameOnlyUpdates(
            [
                LayoutFrameChange(token: first, frame: firstFrame, forceApply: false),
                LayoutFrameChange(
                    token: second,
                    frame: secondFrame,
                    forceApply: false,
                    allowsTerminalRecovery: true
                ),
                LayoutFrameChange(token: fullscreen, frame: .zero, forceApply: false)
            ],
            controller: controller
        )

        XCTAssertEqual(preparation.frameUpdates.count, 1)
        XCTAssertEqual(preparation.frameUpdates[0].pid, 72_101)
        XCTAssertEqual(preparation.frameUpdates[0].expectedWindow.windowId, firstRef.windowId)
        XCTAssertTrue(CFEqual(preparation.frameUpdates[0].expectedWindow.element, firstRef.element))
        XCTAssertEqual(preparation.frameUpdates[0].frame, firstFrame)
        XCTAssertEqual(preparation.terminalRecoveryFrameUpdates.count, 1)
        XCTAssertEqual(preparation.terminalRecoveryFrameUpdates[0].pid, 72_102)
        XCTAssertEqual(
            preparation.terminalRecoveryFrameUpdates[0].expectedWindow.windowId,
            secondRef.windowId
        )
        XCTAssertTrue(
            CFEqual(preparation.terminalRecoveryFrameUpdates[0].expectedWindow.element, secondRef.element)
        )
        XCTAssertEqual(preparation.terminalRecoveryFrameUpdates[0].frame, secondFrame)
    }

    @MainActor
    func testAnimationFrameOnlyPlanUsesOrdinaryAXLane() throws {
        let controller = makeController()
        defer { controller.axManager.cleanup() }
        let monitor = Monitor(
            id: .init(displayId: 72_201),
            displayId: 72_201,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 960),
            hasNotch: false,
            name: "Animation AX Lane"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 72_202
        let windowId = 202
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let token = controller.workspaceManager.addWindow(
            window,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let target = CGRect(x: 40, y: 50, width: 600, height: 800)
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges = [
            LayoutFrameChange(
                token: token,
                frame: target,
                components: .position,
                forceApply: false
            )
        ]
        let plan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: LayoutMonitorSnapshot(
                monitorId: monitor.id,
                displayId: monitor.displayId,
                frame: monitor.frame,
                visibleFrame: monitor.visibleFrame,
                workingFrame: monitor.visibleFrame,
                fullscreenLayoutFrame: monitor.visibleFrame,
                scale: 1,
                orientation: monitor.autoOrientation
            ),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId, viewportState: nil),
            diff: diff,
            isAnimationTick: true
        )

        LayoutDiffExecutor(refreshController: controller.layoutRefreshController).execute(plan)

        XCTAssertEqual(controller.axManager.recentFrameWriteFailure(for: windowId), .contextUnavailable)
        XCTAssertEqual(controller.axManager.recentFrameWriteFailureComponents(for: windowId), .position)
    }

    @MainActor
    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMLayoutDiffFrameOnlyTests-\(UUID().uuidString)",
            isDirectory: true
        )
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
