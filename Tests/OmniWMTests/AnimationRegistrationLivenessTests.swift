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

    func testRejectedPlanDoesNotPublishDwindleAnimationTarget() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        let candidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [:]
        )
        controller.workspaceManager.invalidateLayout(for: [workspaceId])
        let plannedSeq = controller.workspaceManager.worldSeq
        controller.workspaceManager.invalidateLayout(for: [workspaceId])

        let accepted = controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
            makePlan(
                controller: controller,
                workspaceId: workspaceId,
                plannedSeq: plannedSeq,
                disposition: .replace(candidate)
            )
        )

        XCTAssertNil(accepted)
        XCTAssertTrue(controller.dwindleLayoutHandler.animationSessionByDisplay.isEmpty)
    }

    func testLayoutOperationInvalidatesDwindleAnimationGeneration() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let plannedSeq = controller.workspaceManager.worldSeq

        controller.workspaceManager.recordLayoutOperation(.sizesBalanced, in: workspaceId)

        XCTAssertFalse(
            controller.workspaceManager.isSeqCurrent(
                plannedSeq,
                for: workspaceId,
                domains: .layoutCommit
            )
        )
    }

    func testAcceptedPlanPublishesAndRetargetsSameWorkspaceSession() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let token = WindowToken(pid: 981_109, windowId: 981_209)
        let firstTarget = CGRect(x: 10, y: 20, width: 300, height: 200)
        let firstCandidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [token: firstTarget]
        )

        XCTAssertNotNil(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
                makePlan(
                    controller: controller,
                    workspaceId: workspaceId,
                    disposition: .replace(firstCandidate),
                    startAnimation: true
                )
            )
        )
        XCTAssertEqual(
            controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId]?.0,
            workspaceId
        )

        let secondTarget = CGRect(x: 40, y: 50, width: 500, height: 350)
        let secondCandidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [token: secondTarget]
        )
        XCTAssertNotNil(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
                makePlan(
                    controller: controller,
                    workspaceId: workspaceId,
                    disposition: .replace(secondCandidate),
                    startAnimation: true
                )
            )
        )

        XCTAssertEqual(
            controller.dwindleLayoutHandler.animationSessionByDisplay[monitor.displayId]?
                .targetFrames[token],
            secondTarget
        )
        XCTAssertEqual(
            controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId]?.0,
            workspaceId
        )
    }

    func testAcceptedDwindleSessionUsesPostEffectLayoutSequence() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        let token = WindowToken(pid: 981_112, windowId: 981_212)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            for: token
        )
        let candidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [:]
        )
        let plannedSeq = controller.workspaceManager.worldSeq
        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges.append(.show(token))

        XCTAssertNotNil(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
                makePlan(
                    controller: controller,
                    workspaceId: workspaceId,
                    plannedSeq: plannedSeq,
                    disposition: .replace(candidate),
                    diff: diff
                )
            )
        )

        let session = try XCTUnwrap(
            controller.dwindleLayoutHandler.animationSessionByDisplay[candidate.geometry.displayId]
        )
        XCTAssertGreaterThan(session.plannedSeq, plannedSeq)
        XCTAssertEqual(session.plannedSeq, controller.workspaceManager.worldSeq)
        XCTAssertTrue(
            controller.workspaceManager.isSeqCurrent(
                session.plannedSeq,
                for: workspaceId,
                domains: .layoutCommit
            )
        )
    }

    func testInactiveDwindleRelayoutDoesNotDisplaceActiveDisplaySession() throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.settings.workspaceConfigurations = controller.settings.workspaceConfigurations.map {
            $0.name == "1" || $0.name == "2" ? $0.with(layoutType: .dwindle) : $0
        }
        controller.workspaceManager.applySettings()
        let activeWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let inactiveWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: activeWorkspaceId))
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                activeWorkspaceId,
                on: monitor.id,
                updateInteractionMonitor: false
            )
        )
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        let activeToken = WindowToken(pid: 981_113, windowId: 981_213)
        let inactiveToken = WindowToken(pid: 981_114, windowId: 981_214)
        _ = WindowAdmissionTestSupport.track(activeToken, in: activeWorkspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(inactiveToken, in: inactiveWorkspaceId, controller: controller)
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: activeToken, to: activeWorkspaceId, activeWindowFrame: nil)
            let inactiveNode = engine.addWindow(
                token: inactiveToken,
                to: inactiveWorkspaceId,
                activeWindowFrame: nil
            )
            inactiveNode.animateFrom(
                oldFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                newFrame: CGRect(x: 100, y: 100, width: 500, height: 400),
                startTime: CACurrentMediaTime(),
                config: engine.windowMovementAnimationConfig,
                animated: true
            )
        }
        let activeCandidate = try makeCandidate(
            controller: controller,
            workspaceId: activeWorkspaceId,
            engine: engine,
            targetFrames: [activeToken: CGRect(x: 0, y: 0, width: 800, height: 600)]
        )
        _ = controller.dwindleLayoutHandler.acceptAnimationTarget(
            .replace(activeCandidate),
            workspaceId: activeWorkspaceId,
            displayId: monitor.displayId,
            plannedSeq: controller.workspaceManager.worldSeq
        )
        XCTAssertTrue(
            controller.dwindleLayoutHandler.registerDwindleAnimation(
                activeWorkspaceId,
                monitor: monitor,
                on: monitor.displayId
            )
        )

        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.dwindleLayoutHandler.layoutWithDwindleEngine(
                activeWorkspaces: [inactiveWorkspaceId]
            )
        }
        let plan = try XCTUnwrap(plans.first)
        XCTAssertFalse(plan.isActiveWorkspace)
        XCTAssertTrue(plan.animationDirectives.isEmpty)
        let disposition = try XCTUnwrap(plan.dwindleAnimationTargetDisposition)
        guard case .clear = disposition else {
            return XCTFail("inactive relayout must clear rather than publish an animation target")
        }
        XCTAssertNotNil(controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(plan))

        XCTAssertEqual(
            controller.dwindleLayoutHandler.animationSessionByDisplay[monitor.displayId]?.workspaceId,
            activeWorkspaceId
        )
        XCTAssertEqual(
            controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId]?.0,
            activeWorkspaceId
        )
        XCTAssertFalse(engine.hasActiveAnimations(in: inactiveWorkspaceId, at: CACurrentMediaTime()))
    }

    func testAcceptedClearRemovesDwindleSessionAndRegistration() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        let candidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [:]
        )
        XCTAssertNotNil(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
                makePlan(
                    controller: controller,
                    workspaceId: workspaceId,
                    disposition: .replace(candidate)
                )
            )
        )
        XCTAssertTrue(
            controller.dwindleLayoutHandler.registerDwindleAnimation(
                workspaceId,
                monitor: monitor,
                on: monitor.displayId
            )
        )

        XCTAssertNotNil(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
                makePlan(
                    controller: controller,
                    workspaceId: workspaceId,
                    disposition: .clear(
                        engineIdentifier: ObjectIdentifier(engine),
                        geometry: candidate.geometry
                    )
                )
            )
        )

        XCTAssertTrue(controller.dwindleLayoutHandler.animationSessionByDisplay.isEmpty)
        XCTAssertTrue(controller.dwindleLayoutHandler.dwindleAnimationByDisplay.isEmpty)
    }

    func testReplacingDwindleEngineClearsAcceptedAnimationState() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        let candidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [:]
        )
        XCTAssertNotNil(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
                makePlan(
                    controller: controller,
                    workspaceId: workspaceId,
                    disposition: .replace(candidate)
                )
            )
        )

        controller.dwindleEngine = DwindleLayoutEngine()

        XCTAssertTrue(controller.dwindleLayoutHandler.animationSessionByDisplay.isEmpty)
        XCTAssertTrue(controller.dwindleLayoutHandler.dwindleAnimationByDisplay.isEmpty)
    }

    func testStaleDwindleTickSuspendsOnceAndPreservesCurve() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        _ = controller.workspaceManager.setActiveWorkspace(
            workspaceId,
            on: monitor.id,
            updateInteractionMonitor: false
        )
        XCTAssertEqual(controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id, workspaceId)
        let token = WindowToken(pid: 981_110, windowId: 981_210)
        let engine = seedDwindleMotion(
            controller: controller,
            workspaceId: workspaceId,
            token: token
        )
        let candidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [token: CGRect(x: 100, y: 100, width: 500, height: 400)]
        )
        _ = controller.dwindleLayoutHandler.acceptAnimationTarget(
            .replace(candidate),
            workspaceId: workspaceId,
            displayId: monitor.displayId,
            plannedSeq: controller.workspaceManager.worldSeq
        )
        XCTAssertTrue(
            controller.dwindleLayoutHandler.registerDwindleAnimation(
                workspaceId,
                monitor: monitor,
                on: monitor.displayId
            )
        )
        controller.workspaceManager.invalidateLayout(for: [workspaceId])

        controller.dwindleLayoutHandler.tickDwindleAnimation(
            targetTime: CACurrentMediaTime(),
            displayId: monitor.displayId
        )

        XCTAssertNil(controller.dwindleLayoutHandler.animationSessionByDisplay[monitor.displayId])
        XCTAssertNil(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId])
        XCTAssertTrue(engine.hasActiveAnimations(in: workspaceId, at: CACurrentMediaTime()))
        XCTAssertFalse(
            controller.dwindleLayoutHandler.suspendStaleAnimation(
                workspaceId: workspaceId,
                displayId: monitor.displayId
            )
        )
        _ = controller.dwindleLayoutHandler.removeAllAnimationState()
        XCTAssertTrue(
            controller.dwindleLayoutHandler.suspendStaleAnimation(
                workspaceId: workspaceId,
                displayId: monitor.displayId
            )
        )
    }

    func testOngoingDwindleTickUsesPositionOnlyForTrustedSameSizeFrame() throws {
        let oldFrame = CGRect(x: 0, y: 0, width: 500, height: 400)
        XCTAssertEqual(
            try ongoingDwindleTickComponents(
                token: WindowToken(pid: 981_118, windowId: 981_218),
                oldFrame: oldFrame,
                targetFrame: oldFrame.offsetBy(dx: 100, dy: 100)
            ),
            .position
        )
    }

    func testOngoingDwindleTickUsesFullFrameWhenPresentedSizeChanges() throws {
        XCTAssertEqual(
            try ongoingDwindleTickComponents(
                token: WindowToken(pid: 981_119, windowId: 981_219),
                oldFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                targetFrame: CGRect(x: 100, y: 100, width: 500, height: 400)
            ),
            .all
        )
    }

    func testTerminalDwindleTickSubmitsOneFullFramePlan() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        _ = controller.workspaceManager.setActiveWorkspace(
            workspaceId,
            on: monitor.id,
            updateInteractionMonitor: false
        )
        let token = WindowToken(pid: 981_115, windowId: 981_215)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let engine = seedDwindleMotion(
            controller: controller,
            workspaceId: workspaceId,
            token: token
        )
        let target = CGRect(x: 100, y: 100, width: 500, height: 400)
        let candidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [token: target]
        )
        _ = controller.dwindleLayoutHandler.acceptAnimationTarget(
            .replace(candidate),
            workspaceId: workspaceId,
            displayId: monitor.displayId,
            plannedSeq: controller.workspaceManager.worldSeq
        )
        XCTAssertTrue(
            controller.dwindleLayoutHandler.registerDwindleAnimation(
                workspaceId,
                monitor: monitor,
                on: monitor.displayId
            )
        )
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        controller.dwindleLayoutHandler.tickDwindleAnimation(
            targetTime: CACurrentMediaTime() + 10,
            displayId: monitor.displayId
        )

        XCTAssertNil(controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId])
        let applications = FrameApplyTrace.shared.dump().split(separator: "\n").filter {
            $0.contains("win=\(token.windowId) ")
                && $0.contains("event=outcome=skip/contextUnavailable")
        }
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(
            applications.filter { $0.contains("target=\(TraceFormat.rect(target))") }.count,
            1
        )
        XCTAssertEqual(
            controller.axManager.recentFrameWriteFailureComponents(for: token.windowId),
            .all
        )
    }

    func testTerminalDwindleTickReassertsHiddenGroupMember() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        _ = controller.workspaceManager.setActiveWorkspace(
            workspaceId,
            on: monitor.id,
            updateInteractionMonitor: false
        )
        let inactiveToken = WindowToken(pid: 981_116, windowId: 981_216)
        let activeToken = WindowToken(pid: 981_117, windowId: 981_217)
        _ = WindowAdmissionTestSupport.track(inactiveToken, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(activeToken, in: workspaceId, controller: controller)
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        let targetFrames = controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            _ = engine.addWindow(token: inactiveToken, to: workspaceId, activeWindowFrame: nil)
            let activeNode = engine.addWindow(token: activeToken, to: workspaceId, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspaceId, screen: monitor.visibleFrame)
            XCTAssertTrue(engine.groupWindow(direction: .left, in: workspaceId))
            let frames = engine.calculateLayout(for: workspaceId, screen: monitor.visibleFrame)
            let target = frames[activeToken] ?? monitor.visibleFrame
            activeNode.animateFrom(
                oldFrame: target.offsetBy(dx: -30, dy: 0),
                newFrame: target,
                startTime: CACurrentMediaTime(),
                config: engine.windowMovementAnimationConfig,
                animated: true
            )
            return frames
        }
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            for: inactiveToken
        )
        controller.axManager.confirmFrameWrite(
            for: inactiveToken.windowId,
            frame: CGRect(x: 100, y: 100, width: 500, height: 400)
        )
        let candidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: targetFrames
        )
        _ = controller.dwindleLayoutHandler.acceptAnimationTarget(
            .replace(candidate),
            workspaceId: workspaceId,
            displayId: monitor.displayId,
            plannedSeq: controller.workspaceManager.worldSeq
        )
        XCTAssertTrue(
            controller.dwindleLayoutHandler.registerDwindleAnimation(
                workspaceId,
                monitor: monitor,
                on: monitor.displayId
            )
        )
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        controller.dwindleLayoutHandler.tickDwindleAnimation(
            targetTime: CACurrentMediaTime() + 10,
            displayId: monitor.displayId
        )

        let parkFailures = FrameApplyTrace.shared.dump().split(separator: "\n").filter {
            $0.contains("win=\(inactiveToken.windowId) ")
                && $0.contains("event=outcome=ax-park-failed/contextUnavailable")
        }
        XCTAssertFalse(parkFailures.isEmpty)
    }

    func testDwindleLayoutDiffProjectsCurveWithoutMutatingTargetBuffer() throws {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 981_111, windowId: 981_211)
        let engine = DwindleLayoutEngine()
        let node = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
        let oldFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let targetFrame = CGRect(x: 100, y: 120, width: 500, height: 400)
        node.animateFrom(
            oldFrame: oldFrame,
            newFrame: targetFrame,
            startTime: 10,
            config: engine.windowMovementAnimationConfig,
            animated: true
        )
        let targetFrames = [token: targetFrame]
        let handler = DwindleLayoutHandler(controller: nil)

        let diff = handler.layoutDiff(
            windows: [
                LayoutWindowSnapshot(
                    token: token,
                    constraints: .unconstrained,
                    hiddenState: nil,
                    layoutReason: .standard
                )
            ],
            frames: targetFrames,
            engine: engine,
            workspaceId: workspaceId,
            preferredHideSide: .right,
            canRestoreHiddenWorkspaceWindows: true,
            scale: 1,
            reassertHidden: false,
            pendingParkWindowIds: [],
            animationTime: 10
        )

        XCTAssertEqual(try XCTUnwrap(diff.frameChanges.first).frame, oldFrame)
        XCTAssertEqual(targetFrames[token], targetFrame)
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

    private func makeCandidate(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine,
        targetFrames: [WindowToken: CGRect]
    ) throws -> DwindleAnimationTargetCandidate {
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let monitorSnapshot = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor)
        return DwindleAnimationTargetCandidate(
            workspaceId: workspaceId,
            engineIdentifier: ObjectIdentifier(engine),
            geometry: DwindleAnimationGeometryContext(
                monitorId: monitorSnapshot.monitorId,
                displayId: monitorSnapshot.displayId,
                workingFrame: monitorSnapshot.workingFrame,
                fullscreenLayoutFrame: monitorSnapshot.fullscreenLayoutFrame,
                scale: monitorSnapshot.scale,
                settings: controller.settings.resolvedDwindleSettings(for: monitor),
                tabRailWidth: TabRailManager.tabIndicatorWidth
            ),
            targetFrames: targetFrames
        )
    }

    private func makePlan(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        plannedSeq: UInt64? = nil,
        disposition: DwindleAnimationTargetDisposition,
        startAnimation: Bool = false,
        diff: WorkspaceLayoutDiff = WorkspaceLayoutDiff()
    ) -> WorkspaceLayoutPlan {
        let monitor = controller.workspaceManager.monitor(for: workspaceId)!
        return WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: workspaceId,
                plannedSeq: plannedSeq ?? controller.workspaceManager.worldSeq
            ),
            diff: diff,
            animationDirectives: startAnimation
                ? [.startDwindleAnimation(workspaceId: workspaceId, monitorId: monitor.id)]
                : [],
            dwindleAnimationTargetDisposition: disposition
        )
    }

    private func ongoingDwindleTickComponents(
        token: WindowToken,
        oldFrame: CGRect,
        targetFrame: CGRect
    ) throws -> FrameMutationComponents {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        _ = controller.workspaceManager.setActiveWorkspace(
            workspaceId,
            on: monitor.id,
            updateInteractionMonitor: false
        )
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        let targetTime = CACurrentMediaTime()
        let startTime = targetTime - engine.windowMovementAnimationConfig.duration / 2
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            let node = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            node.animateFrom(
                oldFrame: oldFrame,
                newFrame: targetFrame,
                startTime: startTime,
                config: engine.windowMovementAnimationConfig,
                animated: true
            )
        }
        XCTAssertTrue(engine.hasActiveAnimations(in: workspaceId, at: targetTime))
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: oldFrame)
        let candidate = try makeCandidate(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            targetFrames: [token: targetFrame]
        )
        _ = controller.dwindleLayoutHandler.acceptAnimationTarget(
            .replace(candidate),
            workspaceId: workspaceId,
            displayId: monitor.displayId,
            plannedSeq: controller.workspaceManager.worldSeq
        )
        XCTAssertTrue(
            controller.dwindleLayoutHandler.registerDwindleAnimation(
                workspaceId,
                monitor: monitor,
                on: monitor.displayId
            )
        )
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        controller.dwindleLayoutHandler.tickDwindleAnimation(
            targetTime: targetTime,
            displayId: monitor.displayId
        )

        XCTAssertEqual(
            controller.dwindleLayoutHandler.dwindleAnimationByDisplay[monitor.displayId]?.0,
            workspaceId
        )
        let applications = FrameApplyTrace.shared.dump().split(separator: "\n").filter {
            $0.contains("win=\(token.windowId) ")
                && $0.contains("event=outcome=skip/contextUnavailable")
        }
        XCTAssertEqual(applications.count, 1)
        return try XCTUnwrap(
            controller.axManager.recentFrameWriteFailureComponents(for: token.windowId)
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
