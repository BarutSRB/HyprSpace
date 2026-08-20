// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class AnimationRegistrationLivenessTests: XCTestCase {
    func testNiriTickRemovesRegistrationWhenControllerIsGone() {
        let handler = NiriLayoutHandler(controller: nil)
        let displayId: CGDirectDisplayID = 981_001
        handler.scrollAnimationByDisplay[displayId] = WorkspaceDescriptor.ID()

        handler.tickScrollAnimation(targetTime: 0, displayId: displayId)

        XCTAssertNil(handler.scrollAnimationByDisplay[displayId])
    }

    func testDwindleTickRemovesRegistrationWhenControllerIsGone() {
        let handler = DwindleLayoutHandler(controller: nil)
        let displayId: CGDirectDisplayID = 981_002
        let monitor = Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            hasNotch: false,
            name: "Display"
        )
        handler.dwindleAnimationByDisplay[displayId] = (WorkspaceDescriptor.ID(), monitor)

        handler.tickDwindleAnimation(targetTime: 0, displayId: displayId)

        XCTAssertNil(handler.dwindleAnimationByDisplay[displayId])
    }

    func testDwindleTickCancelsEngineMotionWhenMonitorIsMissing() {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = makeMonitor(displayId: 981_003)
        let engine = seedDwindleMotion(
            controller: controller,
            workspaceId: workspaceId,
            token: WindowToken(pid: 981_103, windowId: 981_203)
        )
        controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId] = (
            workspaceId,
            monitor
        )

        controller.dwindleLayoutHandler.tickDwindleAnimation(
            targetTime: CACurrentMediaTime(),
            displayId: monitor.displayId
        )

        XCTAssertNil(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId])
        XCTAssertFalse(engine.hasActiveAnimations(in: workspaceId, at: CACurrentMediaTime()))
    }

    func testDwindleTickCancelsEngineMotionWhenWorkspaceIsInactive() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let monitor = makeMonitor(displayId: 981_004)
        let animatedWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let activeWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                activeWorkspaceId,
                on: monitor.id,
                updateInteractionMonitor: false
            )
        )
        let engine = seedDwindleMotion(
            controller: controller,
            workspaceId: animatedWorkspaceId,
            token: WindowToken(pid: 981_104, windowId: 981_204)
        )
        controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId] = (
            animatedWorkspaceId,
            monitor
        )

        controller.dwindleLayoutHandler.tickDwindleAnimation(
            targetTime: CACurrentMediaTime(),
            displayId: monitor.displayId
        )

        XCTAssertNil(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId])
        XCTAssertFalse(engine.hasActiveAnimations(in: animatedWorkspaceId, at: CACurrentMediaTime()))
    }

    func testMonitorDisconnectCancelsDwindleEngineMotion() {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = makeMonitor(displayId: 981_005)
        let engine = seedDwindleMotion(
            controller: controller,
            workspaceId: workspaceId,
            token: WindowToken(pid: 981_105, windowId: 981_205)
        )
        controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId] = (
            workspaceId,
            monitor
        )

        controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: monitor.displayId,
            migrateAnimations: false
        )

        XCTAssertNil(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId])
        XCTAssertFalse(engine.hasActiveAnimations(in: workspaceId, at: CACurrentMediaTime()))
    }

    func testInactiveDwindleStartCancelsUnregisteredEngineMotion() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let monitor = makeMonitor(displayId: 981_006)
        let animatedWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let activeWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                activeWorkspaceId,
                on: monitor.id,
                updateInteractionMonitor: false
            )
        )
        let engine = seedDwindleMotion(
            controller: controller,
            workspaceId: animatedWorkspaceId,
            token: WindowToken(pid: 981_106, windowId: 981_206)
        )

        controller.layoutRefreshController.startDwindleAnimation(
            for: animatedWorkspaceId,
            monitor: monitor
        )

        XCTAssertTrue(controller.dwindleLayoutHandler.dwindleAnimationByDisplay.isEmpty)
        XCTAssertFalse(engine.hasActiveAnimations(in: animatedWorkspaceId, at: CACurrentMediaTime()))
    }

    func testResetCancelsRegisteredNiriAndDwindleMotion() {
        let controller = WindowAdmissionTestSupport.controller()
        let niriWorkspaceId = WorkspaceDescriptor.ID()
        let dwindleWorkspaceId = WorkspaceDescriptor.ID()
        let niriMonitor = makeMonitor(displayId: 981_007)
        let dwindleMonitor = makeMonitor(displayId: 981_008)
        let niriEngine = NiriLayoutEngine()
        controller.niriEngine = niriEngine
        let niriWindow = controller.workspaceManager.withEngineMutationScope(in: niriWorkspaceId) {
            niriEngine.addWindow(
                token: WindowToken(pid: 981_107, windowId: 981_207),
                to: niriWorkspaceId,
                afterSelection: nil
            )
        }
        niriWindow.animateMoveFrom(
            displacement: CGPoint(x: 50, y: 0),
            clock: nil,
            animated: true
        )
        controller.workspaceManager.animationDriver.beginGesture(
            in: niriWorkspaceId,
            isTrackpad: true
        )
        controller.niriLayoutHandler.scrollAnimationByDisplay[niriMonitor.displayId] = niriWorkspaceId

        let dwindleEngine = seedDwindleMotion(
            controller: controller,
            workspaceId: dwindleWorkspaceId,
            token: WindowToken(pid: 981_108, windowId: 981_208)
        )
        controller.dwindleLayoutHandler.dwindleAnimationByDisplay[dwindleMonitor.displayId] = (
            dwindleWorkspaceId,
            dwindleMonitor
        )

        controller.layoutRefreshController.resetDisplayLinkAndAnimationState()

        XCTAssertTrue(controller.niriLayoutHandler.scrollAnimationByDisplay.isEmpty)
        XCTAssertTrue(controller.dwindleLayoutHandler.dwindleAnimationByDisplay.isEmpty)
        XCTAssertFalse(controller.workspaceManager.animationDriver.hasMotion(in: niriWorkspaceId))
        XCTAssertFalse(niriWindow.hasMoveAnimationsRunning)
        XCTAssertFalse(dwindleEngine.hasActiveAnimations(in: dwindleWorkspaceId, at: CACurrentMediaTime()))
    }

    private func makeMonitor(displayId: CGDirectDisplayID) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            hasNotch: false,
            name: "Display"
        )
    }

    private func seedDwindleMotion(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        token: WindowToken
    ) -> DwindleLayoutEngine {
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            let node = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            node.animateFrom(
                oldFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                newFrame: CGRect(x: 100, y: 100, width: 500, height: 400),
                startTime: CACurrentMediaTime(),
                config: engine.windowMovementAnimationConfig,
                animated: true
            )
        }
        XCTAssertTrue(engine.hasActiveAnimations(in: workspaceId, at: CACurrentMediaTime()))
        return engine
    }
}
