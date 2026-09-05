// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DurableParkTests: XCTestCase {
    func testMatchingSkyLightFrameStaysPendingUntilVerifiedAXPark() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let axRef = AXWindowRef(element: AXUIElementCreateApplication(951_001), windowId: 951_101)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: 951_001, windowId: 951_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)

        let onscreenFrame = CGRect(x: 100, y: 16, width: 800, height: 600)
        var physicalFrame = onscreenFrame
        controller.layoutRefreshController.fastFrameProvider = { queriedToken, _ in
            queriedToken == token ? physicalFrame : nil
        }

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertNil(controller.axManager.pendingParkFrameRequest(for: token.windowId))
        XCTAssertTrue(FrameApplyTrace.shared.dump().contains("outcome=sls-parked/animation"))
        XCTAssertFalse(FrameApplyTrace.shared.dump().contains("outcome=ax-park-"))
        let parkOrigin = try XCTUnwrap(controller.axManager.skyLightLivePosition(for: token.windowId))

        FrameApplyTrace.shared.beginCapture()
        physicalFrame = CGRect(origin: parkOrigin, size: onscreenFrame.size)
        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(
                    workspaceId: workspaceId,
                    monitor: monitor,
                    token: token,
                    isAnimationTick: false
                )
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertNil(controller.axManager.verifiedParkFrame(for: token.windowId))
        XCTAssertTrue(FrameApplyTrace.shared.dump().contains("outcome=sls-parked/settled"))
        XCTAssertTrue(FrameApplyTrace.shared.dump().contains("outcome=ax-park-failed/contextUnavailable"))

        let parkFrame = CGRect(origin: parkOrigin, size: onscreenFrame.size)
        let request = try XCTUnwrap(
            controller.axManager.prepareParkFrameApplications([
                .init(pid: token.pid, window: axRef, frame: parkFrame)
            ]).first
        )
        XCTAssertTrue(request.verify)
        XCTAssertTrue(
            controller.axManager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.successfulFrameResult(request: request)
            ]).isEmpty
        )
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertEqual(controller.axManager.verifiedParkFrame(for: token.windowId), parkFrame)
        XCTAssertTrue(FrameApplyTrace.shared.dump().contains("outcome=ax-park-confirmed"))
        XCTAssertNotNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testShowClearsPendingPark() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let axRef = AXWindowRef(element: AXUIElementCreateApplication(952_001), windowId: 952_101)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: 952_001, windowId: 952_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let visibleFrame = CGRect(x: 100, y: 16, width: 800, height: 600)
        controller.layoutRefreshController.fastFrameProvider = { queriedToken, _ in
            queriedToken == token ? visibleFrame : nil
        }
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: visibleFrame)

        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(workspaceId: workspaceId, monitor: monitor, token: token)
            )
        )
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))

        let parkFrame = CGRect(
            x: monitor.frame.maxX - 1,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
        let pendingRequest = try XCTUnwrap(
            controller.axManager.prepareParkFrameApplications([
                .init(pid: token.pid, window: axRef, frame: parkFrame)
            ]).first
        )
        controller.axManager.markParkPending(
            .init(pid: token.pid, window: axRef, frame: parkFrame)
        )
        XCTAssertNil(controller.axManager.pendingParkFrameRequest(for: token.windowId))

        var showDiff = WorkspaceLayoutDiff()
        showDiff.visibilityChanges.append(.show(token))
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.plan(workspaceId: workspaceId, monitor: monitor, diff: showDiff)
            )
        )
        XCTAssertTrue(FrameApplyTrace.shared.dump().contains("outcome=ax-park-cancelled/revealed"))
        XCTAssertTrue(FrameApplyTrace.shared.dump().contains("outcome=skip/contextUnavailable"))
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertNil(controller.axManager.pendingParkFrameRequest(for: token.windowId))
        XCTAssertNil(controller.axManager.verifiedParkFrame(for: token.windowId))
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: visibleFrame)

        XCTAssertTrue(
            controller.axManager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.successfulFrameResult(request: pendingRequest)
            ]).isEmpty
        )
        XCTAssertNil(controller.axManager.verifiedParkFrame(for: token.windowId))
        XCTAssertEqual(controller.axManager.lastAppliedFrame(for: token.windowId), visibleFrame)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testLayoutTransientShowUsesCurrentLayoutFrameInsteadOfHistoricalRestore() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        let pid: pid_t = 967_001
        let windowId = 967_101
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let historicalFrame = CGRect(x: 1304, y: 16, width: 1256, height: 1378)
        let plannedFrame = CGRect(x: 2559, y: 16, width: 1256, height: 1378)
        let proportionalPosition = controller.layoutRefreshController.proportionalPosition(
            topLeft: historicalFrame.topLeftCorner,
            in: monitor.frame
        )
        let hiddenState = HiddenState(
            proportionalPosition: proportionalPosition,
            referenceMonitorId: monitor.id,
            reason: .layoutTransient(.right)
        )
        XCTAssertEqual(
            LayoutDiffExecutor.frameBackedLayoutTransientRestoreFrame(
                hiddenState: hiddenState,
                frameChange: plannedFrame
            ),
            plannedFrame
        )
        XCTAssertNotEqual(
            LayoutDiffExecutor.frameBackedLayoutTransientRestoreFrame(
                hiddenState: hiddenState,
                frameChange: plannedFrame
            ),
            historicalFrame
        )
        for reason in [HiddenReason.workspaceInactive, .scratchpad] {
            XCTAssertNil(
                LayoutDiffExecutor.frameBackedLayoutTransientRestoreFrame(
                    hiddenState: HiddenState(
                        proportionalPosition: proportionalPosition,
                        referenceMonitorId: monitor.id,
                        reason: reason
                    ),
                    frameChange: plannedFrame
                )
            )
        }
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        controller.layoutRefreshController.fastFrameProvider = { queriedToken, _ in
            queriedToken == token ? plannedFrame : nil
        }
        let parkRequest = try XCTUnwrap(
            controller.axManager.prepareParkFrameApplications([
                AXFrameApplicationTarget(pid: pid, window: axRef, frame: plannedFrame)
            ]).first
        )
        XCTAssertTrue(
            controller.axManager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.successfulFrameResult(request: parkRequest)
            ]).isEmpty
        )
        XCTAssertEqual(controller.axManager.verifiedParkFrame(for: windowId), plannedFrame)

        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges.append(.show(token))
        diff.frameChanges.append(
            LayoutFrameChange(token: token, frame: plannedFrame, forceApply: false)
        )
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        XCTAssertTrue(
            controller.layoutRefreshController.executeLayoutPlan(
                Self.plan(workspaceId: workspaceId, monitor: monitor, diff: diff)
            )
        )

        let trace = FrameApplyTrace.shared.dump()
        XCTAssertFalse(trace.contains("target=\(TraceFormat.rect(historicalFrame))"))
        XCTAssertTrue(trace.contains("target=\(TraceFormat.rect(plannedFrame))"))
        let plannedApplications = trace.split(separator: "\n").filter {
            $0.contains("win=\(windowId) ")
                && $0.contains("outcome=skip/contextUnavailable")
                && $0.contains("target=\(TraceFormat.rect(plannedFrame))")
        }
        XCTAssertEqual(plannedApplications.count, 1)
        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(windowId))
    }

    func testPendingRevealSuccessClearsParkRemarkedByOrdinaryWriteCallback() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        let pid: pid_t = 964_001
        let windowId = 964_101
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: monitor.id,
            reason: .scratchpad
        )
        let visibleFrame = CGRect(x: 100, y: 16, width: 800, height: 600)
        controller.workspaceManager.setScratchpadMembership(token, to: 1)
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let transactionId = try XCTUnwrap(
            controller.layoutRefreshController.beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: visibleFrame,
                monitor: monitor
            )
        )
        let result = AXFrameApplyResult(
            pid: pid,
            windowId: windowId,
            expectedWindow: axRef,
            targetFrame: visibleFrame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: visibleFrame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
        controller.axManager.onFrameApplySucceeded = { result in
            controller.layoutRefreshController.completePendingRevealTransaction(
                with: result,
                transactionId: transactionId
            )
        }

        controller.axManager.handleAcceptedFrameApplySuccess(result)

        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(windowId))
        XCTAssertNil(controller.axManager.pendingParkFrameRequest(for: windowId))
        XCTAssertNil(controller.axManager.verifiedParkFrame(for: windowId))
    }

    func testAcceptedOrdinaryWriteInvalidatesVerifiedPark() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        let axRef = AXWindowRef(element: AXUIElementCreateApplication(954_001), windowId: 954_101)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: 954_001, windowId: 954_101, to: workspaceId
        )
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.right)
            ),
            for: token
        )
        let parkFrame = CGRect(x: monitor.frame.maxX - 1, y: 16, width: 800, height: 600)
        let parkRequest = try XCTUnwrap(
            controller.axManager.prepareParkFrameApplications([
                .init(pid: token.pid, window: axRef, frame: parkFrame)
            ]).first
        )
        XCTAssertTrue(
            controller.axManager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.successfulFrameResult(request: parkRequest)
            ]).isEmpty
        )
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertEqual(controller.axManager.verifiedParkFrame(for: token.windowId), parkFrame)

        let stragglerFrame = CGRect(x: -857, y: 16, width: 1256, height: 1378)
        let acceptedResult = AXFrameApplyResult(
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: axRef,
            targetFrame: stragglerFrame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: stragglerFrame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
        controller.axManager.handleAcceptedFrameApplySuccess(acceptedResult)
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertNil(controller.axManager.verifiedParkFrame(for: token.windowId))

        controller.workspaceManager.setHiddenState(nil, for: token)
        controller.axManager.clearParkPending(for: token.windowId, pid: token.pid, reason: "test")
        controller.axManager.handleAcceptedFrameApplySuccess(acceptedResult)
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(token.windowId))
    }

    func testFailedParkRetriesOnceAndRemainsPendingForLaterSettlement() throws {
        let controller = Self.controller()
        let manager = controller.axManager
        let pid: pid_t = 955_001
        let windowId = 955_101
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let parkFrame = CGRect(x: 2559, y: 16, width: 800, height: 600)
        let target = AXFrameApplicationTarget(
            pid: pid,
            window: axRef,
            frame: parkFrame
        )
        manager.markWindowInactive(windowId)
        manager.suppressFrameWrites([(pid: pid, windowId: windowId)])

        let firstRequest = try XCTUnwrap(manager.prepareParkFrameApplications([target]).first)
        XCTAssertFalse(manager.hasPendingFrameWrite(for: windowId))
        let retries = manager.processParkFrameApplyResults([
            WindowAdmissionTestSupport.frameResult(
                request: firstRequest,
                observed: CGRect(x: 2558, y: 16, width: 800, height: 600),
                failure: .verificationMismatch
            )
        ])
        let retryRequest = try XCTUnwrap(retries.first)
        XCTAssertEqual(retries.count, 1)
        XCTAssertNotEqual(retryRequest.requestId, firstRequest.requestId)
        XCTAssertEqual(manager.pendingParkFrameRequest(for: windowId), retryRequest)

        XCTAssertTrue(
            manager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.frameResult(
                    request: retryRequest,
                    observed: parkFrame,
                    failure: .readbackFailed
                )
            ]).isEmpty
        )
        XCTAssertNil(manager.pendingParkFrameRequest(for: windowId))
        XCTAssertNil(manager.verifiedParkFrame(for: windowId))
        XCTAssertTrue(manager.pendingParkWindowIds.contains(windowId))

        let laterRequest = try XCTUnwrap(manager.prepareParkFrameApplications([target]).first)
        XCTAssertNotEqual(laterRequest.requestId, retryRequest.requestId)
    }

    func testAnimationSupersessionStillRequiresVisibleAXSettlementOnReveal() throws {
        let manager = AXManager()
        defer { manager.cleanup() }
        let pid: pid_t = 965_001
        let windowId = 965_101
        let token = WindowToken(pid: pid, windowId: windowId)
        let target = AXFrameApplicationTarget(
            pid: pid,
            window: AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: windowId
            ),
            frame: CGRect(x: 2559, y: 16, width: 800, height: 600)
        )
        let staleRequest = try XCTUnwrap(manager.prepareParkFrameApplications([target]).first)

        manager.markParkPending(target)

        XCTAssertNil(manager.pendingParkFrameRequest(for: windowId))
        XCTAssertTrue(manager.pendingParkWindowIds.contains(windowId))
        XCTAssertEqual(
            manager.cancelParkFrameJobs([(pid: pid, windowId: windowId)], reason: "revealed"),
            [token]
        )
        XCTAssertFalse(manager.pendingParkWindowIds.contains(windowId))
        XCTAssertTrue(
            manager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.successfulFrameResult(request: staleRequest)
            ]).isEmpty
        )
        XCTAssertNil(manager.verifiedParkFrame(for: windowId))
    }

    func testVerifiedParkStillRequiresVisibleAXSettlementOnReveal() throws {
        let manager = AXManager()
        defer { manager.cleanup() }
        let pid: pid_t = 966_001
        let windowId = 966_101
        let token = WindowToken(pid: pid, windowId: windowId)
        let target = AXFrameApplicationTarget(
            pid: pid,
            window: AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: windowId
            ),
            frame: CGRect(x: 2559, y: 16, width: 800, height: 600)
        )
        let request = try XCTUnwrap(manager.prepareParkFrameApplications([target]).first)
        XCTAssertTrue(
            manager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.successfulFrameResult(request: request)
            ]).isEmpty
        )
        XCTAssertEqual(manager.verifiedParkFrame(for: windowId), target.frame)

        XCTAssertEqual(
            manager.cancelParkFrameJobs([(pid: pid, windowId: windowId)], reason: "revealed"),
            [token]
        )
        XCTAssertNil(manager.verifiedParkFrame(for: windowId))
    }

    func testVerifiedParkDeduplicatesOnlyExactIdentityAndTargetWithoutTouchingFrameLedger() throws {
        let controller = Self.controller()
        let manager = controller.axManager
        let pid: pid_t = 957_001
        let windowId = 957_101
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let visibleFrame = CGRect(x: 100, y: 16, width: 800, height: 600)
        let parkFrame = CGRect(x: 2559, y: 16, width: 800, height: 600)
        let target = AXFrameApplicationTarget(pid: pid, window: axRef, frame: parkFrame)

        manager.markWindowInactive(windowId)
        manager.suppressFrameWrites([(pid: pid, windowId: windowId)])
        manager.confirmFrameWrite(for: windowId, frame: visibleFrame)

        let request = try XCTUnwrap(manager.prepareParkFrameApplications([target]).first)
        XCTAssertTrue(request.verify)
        XCTAssertEqual(request.currentFrameHint, visibleFrame)
        XCTAssertTrue(
            manager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.successfulFrameResult(request: request)
            ]).isEmpty
        )
        XCTAssertEqual(manager.verifiedParkFrame(for: windowId), parkFrame)
        XCTAssertEqual(manager.lastAppliedFrame(for: windowId), visibleFrame)
        XCTAssertFalse(manager.hasPendingFrameWrite(for: windowId))
        XCTAssertTrue(manager.prepareParkFrameApplications([target]).isEmpty)

        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: windowId
        )
        let identityRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([
                .init(pid: pid, window: replacementRef, frame: parkFrame)
            ]).first
        )
        XCTAssertNotEqual(identityRequest.requestId, request.requestId)

        let changedFrame = parkFrame.offsetBy(dx: -1, dy: 0)
        let targetRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([
                .init(pid: pid, window: replacementRef, frame: changedFrame)
            ]).first
        )
        XCTAssertNotEqual(targetRequest.requestId, identityRequest.requestId)
        XCTAssertEqual(manager.pendingParkFrameRequest(for: windowId), targetRequest)
    }

    func testWorkspaceInactiveAndScratchpadFloatingHidesRemainPendingWithoutAXConfirmation() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let cases: [(LayoutRefreshController.HideReason, HiddenReason)] = [
            (.workspaceInactive, .workspaceInactive),
            (.scratchpad, .scratchpad)
        ]

        for (index, testCase) in cases.enumerated() {
            let pid = pid_t(958_001 + index)
            let windowId = 958_101 + index
            let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
            let token = controller.workspaceManager.addWindow(
                axRef,
                pid: pid,
                windowId: windowId,
                to: workspaceId,
                mode: .floating
            )
            let frame = CGRect(x: 100 + CGFloat(index * 20), y: 16, width: 800, height: 600)
            controller.layoutRefreshController.fastFrameProvider = { queriedToken, _ in
                queriedToken == token ? frame : nil
            }
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))

            controller.layoutRefreshController.hideWindow(
                entry,
                monitor: monitor,
                side: .right,
                reason: testCase.0
            )

            XCTAssertEqual(controller.workspaceManager.hiddenState(for: token)?.reason, testCase.1)
            XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(windowId))
            XCTAssertNil(controller.axManager.verifiedParkFrame(for: windowId))
        }
    }

    func testNiriAndDwindleTerminalLayoutTransientHidesCoverTiledAndFloatingWindows() throws {
        let cases: [(usesDwindle: Bool, mode: TrackedWindowMode)] = [
            (false, .tiling),
            (false, .floating),
            (true, .tiling),
            (true, .floating)
        ]

        for (index, testCase) in cases.enumerated() {
            let controller = Self.controller()
            let monitor = Self.monitor()
            controller.workspaceManager.applyMonitorConfigurationChange([monitor])
            let workspaceId = try XCTUnwrap(
                controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
            )
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            if testCase.usesDwindle {
                controller.dwindleLayoutHandler.enableDwindleLayout()
            } else {
                controller.niriLayoutHandler.enableNiriLayout()
            }

            let pid = pid_t(960_001 + index)
            let windowId = 960_101 + index
            let token = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId,
                mode: testCase.mode
            )
            if testCase.mode == .tiling {
                controller.workspaceManager.withEngineMutationScope {
                    if testCase.usesDwindle {
                        _ = controller.dwindleEngine?.addWindow(
                            token: token,
                            to: workspaceId,
                            activeWindowFrame: nil
                        )
                    } else {
                        _ = controller.niriEngine?.addWindow(
                            token: token,
                            to: workspaceId,
                            afterSelection: nil
                        )
                    }
                }
            }
            let frame = CGRect(x: 100, y: 16, width: 800, height: 600)
            controller.layoutRefreshController.fastFrameProvider = { queriedToken, _ in
                queriedToken == token ? frame : nil
            }

            FrameApplyTrace.shared.beginCapture()
            let executed = controller.layoutRefreshController.executeLayoutPlan(
                Self.hidePlan(
                    workspaceId: workspaceId,
                    monitor: monitor,
                    token: token,
                    isAnimationTick: false
                )
            )
            let trace = FrameApplyTrace.shared.dump()
            FrameApplyTrace.shared.endCapture()

            let label = "\(testCase.usesDwindle ? "Dwindle" : "Niri")/\(testCase.mode)"
            XCTAssertTrue(executed, label)
            XCTAssertEqual(
                controller.workspaceManager.hiddenState(for: token)?.reason,
                .layoutTransient(.right),
                label
            )
            XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(windowId), label)
            XCTAssertTrue(trace.contains("outcome=sls-parked/settled"), label)
            XCTAssertTrue(trace.contains("outcome=ax-park-failed/contextUnavailable"), label)
        }
    }

    func testRekeyCancelsOldParkCompletionAndReissuesForNewIdentity() throws {
        let controller = Self.controller()
        let manager = controller.axManager
        let pid: pid_t = 959_001
        let oldWindowId = 959_101
        let newWindowId = 959_102
        let oldRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: oldWindowId
        )
        let newRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: newWindowId
        )
        let parkFrame = CGRect(x: 2559, y: 16, width: 800, height: 600)
        let staleRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([
                .init(pid: pid, window: oldRef, frame: parkFrame)
            ]).first
        )

        manager.commitFrameApplicationStateForRebind(
            from: AXManagedWindowIdentity(
                token: WindowToken(pid: pid, windowId: oldWindowId),
                axRef: oldRef
            ),
            to: AXManagedWindowIdentity(
                token: WindowToken(pid: pid, windowId: newWindowId),
                axRef: newRef
            )
        )

        XCTAssertFalse(manager.pendingParkWindowIds.contains(oldWindowId))
        XCTAssertNil(manager.pendingParkFrameRequest(for: oldWindowId))
        XCTAssertNil(manager.verifiedParkFrame(for: oldWindowId))
        XCTAssertTrue(manager.pendingParkWindowIds.contains(newWindowId))
        XCTAssertNil(manager.verifiedParkFrame(for: newWindowId))
        XCTAssertTrue(
            manager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.successfulFrameResult(request: staleRequest)
            ]).isEmpty
        )
        XCTAssertNil(manager.verifiedParkFrame(for: oldWindowId))
        XCTAssertNil(manager.verifiedParkFrame(for: newWindowId))

        let reissuedRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([
                .init(pid: pid, window: newRef, frame: parkFrame)
            ]).first
        )
        XCTAssertEqual(reissuedRequest.windowId, newWindowId)
        XCTAssertEqual(reissuedRequest.frame, parkFrame)
        XCTAssertTrue(sameAXWindowIdentity(reissuedRequest.expectedWindow, newRef))
    }

    func testHiddenRekeyReissuesRetainedTargetAfterRetryExhaustion() throws {
        let manager = AXManager()
        let pid: pid_t = 962_001
        let oldWindowId = 962_101
        let newWindowId = 962_102
        let oldRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: oldWindowId
        )
        let newRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: newWindowId
        )
        let parkFrame = CGRect(x: 2559, y: 16, width: 800, height: 600)
        let firstRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([
                .init(pid: pid, window: oldRef, frame: parkFrame)
            ]).first
        )
        let retryRequest = try XCTUnwrap(
            manager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.frameResult(
                    request: firstRequest,
                    observed: parkFrame.offsetBy(dx: -1, dy: 0),
                    failure: .verificationMismatch
                )
            ]).first
        )
        XCTAssertTrue(
            manager.processParkFrameApplyResults([
                WindowAdmissionTestSupport.frameResult(
                    request: retryRequest,
                    observed: parkFrame,
                    failure: .readbackFailed
                )
            ]).isEmpty
        )
        XCTAssertTrue(manager.pendingParkWindowIds.contains(oldWindowId))
        XCTAssertNil(manager.pendingParkFrameRequest(for: oldWindowId))

        FrameApplyTrace.shared.beginCapture()
        defer {
            FrameApplyTrace.shared.endCapture()
            manager.cleanup()
        }
        let retainedParkTarget = manager.commitFrameApplicationStateForRebind(
            from: AXManagedWindowIdentity(
                token: WindowToken(pid: pid, windowId: oldWindowId),
                axRef: oldRef
            ),
            to: AXManagedWindowIdentity(
                token: WindowToken(pid: pid, windowId: newWindowId),
                axRef: newRef
            )
        )

        XCTAssertFalse(manager.pendingParkWindowIds.contains(oldWindowId))
        XCTAssertTrue(manager.pendingParkWindowIds.contains(newWindowId))
        XCTAssertNil(manager.pendingParkFrameRequest(for: newWindowId))
        XCTAssertNotNil(retainedParkTarget)
        XCTAssertEqual(retainedParkTarget?.frame, parkFrame)
        XCTAssertEqual(retainedParkTarget?.pid, pid)
        let laterRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([
                .init(pid: pid, window: newRef, frame: parkFrame)
            ]).first
        )
        XCTAssertEqual(laterRequest.frame, parkFrame)
        XCTAssertTrue(sameAXWindowIdentity(laterRequest.expectedWindow, newRef))
    }

    func testAnimationOnlyParkRetainsTargetAcrossHiddenRekey() throws {
        let manager = AXManager()
        let pid: pid_t = 963_001
        let oldWindowId = 963_101
        let newWindowId = 963_102
        let oldRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: oldWindowId
        )
        let newRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: newWindowId
        )
        let parkFrame = CGRect(x: 2559, y: 16, width: 800, height: 600)
        manager.markParkPending(
            .init(pid: pid, window: oldRef, frame: parkFrame)
        )
        XCTAssertTrue(manager.pendingParkWindowIds.contains(oldWindowId))
        XCTAssertNil(manager.pendingParkFrameRequest(for: oldWindowId))

        FrameApplyTrace.shared.beginCapture()
        defer {
            FrameApplyTrace.shared.endCapture()
            manager.cleanup()
        }
        let retainedParkTarget = manager.commitFrameApplicationStateForRebind(
            from: AXManagedWindowIdentity(
                token: WindowToken(pid: pid, windowId: oldWindowId),
                axRef: oldRef
            ),
            to: AXManagedWindowIdentity(
                token: WindowToken(pid: pid, windowId: newWindowId),
                axRef: newRef
            )
        )

        XCTAssertFalse(manager.pendingParkWindowIds.contains(oldWindowId))
        XCTAssertTrue(manager.pendingParkWindowIds.contains(newWindowId))
        XCTAssertNotNil(retainedParkTarget)
        XCTAssertEqual(retainedParkTarget?.frame, parkFrame)
        XCTAssertEqual(retainedParkTarget?.pid, pid)
        let laterRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([
                .init(pid: pid, window: newRef, frame: parkFrame)
            ]).first
        )
        XCTAssertEqual(laterRequest.frame, parkFrame)
        XCTAssertTrue(sameAXWindowIdentity(laterRequest.expectedWindow, newRef))
    }

    func testFrameChangedSkipsWindowServerQueryWhileScrollAnimating() throws {
        let controller = Self.controller()
        let monitor = Self.monitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(956_001), windowId: 956_101),
            pid: 956_001, windowId: 956_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)

        var providerCalls = 0
        controller.axEventHandler.windowInfoProvider = { _ in
            providerCalls += 1
            return nil
        }

        controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] = workspaceId
        controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(token.windowId)))
        XCTAssertEqual(providerCalls, 0)

        controller.niriLayoutHandler.scrollAnimationByDisplay.removeAll()
        controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(token.windowId)))
        XCTAssertGreaterThan(providerCalls, 0)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testRemovingWindowsClearsPendingAndVerifiedParkState() throws {
        let controller = Self.controller()
        let axManager = controller.axManager
        let pid: pid_t = 953_001
        let verifiedWindowId = 42
        let pendingWindowId = 43
        let verifiedTarget = AXFrameApplicationTarget(
            pid: pid,
            window: AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: verifiedWindowId
            ),
            frame: CGRect(x: 2559, y: 16, width: 800, height: 600)
        )
        let pendingTarget = AXFrameApplicationTarget(
            pid: pid,
            window: AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: pendingWindowId
            ),
            frame: CGRect(x: 2559, y: 32, width: 800, height: 600)
        )
        let verifiedRequest = try XCTUnwrap(
            axManager.prepareParkFrameApplications([verifiedTarget]).first
        )
        _ = axManager.processParkFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: verifiedRequest)
        ])
        XCTAssertEqual(
            axManager.verifiedParkFrame(for: verifiedWindowId),
            verifiedTarget.frame
        )
        XCTAssertNotNil(axManager.prepareParkFrameApplications([pendingTarget]).first)

        axManager.removeWindowLedgerState(pid: pid, windowId: verifiedWindowId)
        axManager.removeWindowLedgerState(pid: pid, windowId: pendingWindowId)

        XCTAssertFalse(axManager.pendingParkWindowIds.contains(verifiedWindowId))
        XCTAssertFalse(axManager.pendingParkWindowIds.contains(pendingWindowId))
        XCTAssertNil(axManager.pendingParkFrameRequest(for: verifiedWindowId))
        XCTAssertNil(axManager.pendingParkFrameRequest(for: pendingWindowId))
        XCTAssertNil(axManager.verifiedParkFrame(for: verifiedWindowId))
        XCTAssertNil(axManager.verifiedParkFrame(for: pendingWindowId))
    }

    func testCleanupClearsAllParkStateBeforeShutdown() throws {
        let manager = AXManager()
        let pid: pid_t = 961_001
        let verifiedTarget = AXFrameApplicationTarget(
            pid: pid,
            window: AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: 961_101
            ),
            frame: CGRect(x: 2559, y: 16, width: 800, height: 600)
        )
        let pendingTarget = AXFrameApplicationTarget(
            pid: pid,
            window: AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: 961_102
            ),
            frame: CGRect(x: 2559, y: 32, width: 800, height: 600)
        )
        let verifiedRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([verifiedTarget]).first
        )
        _ = manager.processParkFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: verifiedRequest)
        ])
        XCTAssertNotNil(manager.prepareParkFrameApplications([pendingTarget]).first)

        manager.cleanup()

        XCTAssertTrue(manager.pendingParkWindowIds.isEmpty)
        XCTAssertNil(manager.pendingParkFrameRequest(for: verifiedTarget.windowId))
        XCTAssertNil(manager.pendingParkFrameRequest(for: pendingTarget.windowId))
        XCTAssertNil(manager.verifiedParkFrame(for: verifiedTarget.windowId))
        XCTAssertNil(manager.verifiedParkFrame(for: pendingTarget.windowId))
    }

    func testFrameChangedRepairsVerifiedInactiveParkWithoutChangingWorldOrRestoreGeometry() throws {
        let fixture = try Self.parkDriftFixture()
        let controller = fixture.controller
        let worldSeq = controller.workspaceManager.worldSeq
        let focusedToken = controller.workspaceManager.nativeManagedFocusToken
        var fastFrameReads = 0
        controller.layoutRefreshController.fastFrameProvider = { _, _ in
            fastFrameReads += 1
            return nil
        }
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        Self.sendFrameEvent(fixture, observedFrame: fixture.visibleFrame)

        let trace = FrameApplyTrace.shared.dump()
        XCTAssertNil(controller.axManager.verifiedParkFrame(for: fixture.token.windowId))
        XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(fixture.token.windowId))
        XCTAssertTrue(trace.contains("outcome=sls-parked/settled"), trace)
        XCTAssertTrue(trace.contains("outcome=ax-park-failed/contextUnavailable"), trace)
        XCTAssertTrue(trace.contains("target=\(TraceFormat.rect(fixture.parkFrame))"), trace)
        XCTAssertEqual(fastFrameReads, 0)
        XCTAssertEqual(controller.workspaceManager.worldSeq, worldSeq)
        XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, focusedToken)
        XCTAssertEqual(controller.workspaceManager.workspace(for: fixture.token), fixture.workspaceId)
        XCTAssertEqual(controller.workspaceManager.hiddenState(for: fixture.token), fixture.hiddenState)
        XCTAssertNil(controller.axManager.lastAppliedFrame(for: fixture.token.windowId))
        XCTAssertFalse(controller.axManager.hasPendingFrameWrite(for: fixture.token.windowId))
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testInactiveNativeSpaceDriftWaitsForMovableOrAlreadyHiddenSettlement() throws {
        for alreadyHidden in [false, true] {
            let fixture = try Self.parkDriftFixture()
            let controller = fixture.controller
            Self.setNativeDesktopCurrent(false, fixture: fixture)
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            Self.sendFrameEvent(fixture, observedFrame: fixture.visibleFrame)

            XCTAssertNil(controller.axManager.verifiedParkFrame(for: fixture.token.windowId))
            XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(fixture.token.windowId))
            XCTAssertNil(controller.axManager.pendingParkFrameRequest(for: fixture.token.windowId))
            XCTAssertEqual(FrameApplyTrace.shared.dump(), "none")
            XCTAssertEqual(controller.axManager.lastAppliedFrame(for: fixture.token.windowId), fixture.visibleFrame)
            Self.setNativeDesktopCurrent(true, fixture: fixture)
            var fastFrameReads = 0
            controller.layoutRefreshController.fastFrameProvider = { _, _ in
                fastFrameReads += 1
                return nil
            }
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: fixture.token))

            XCTAssertTrue(controller.layoutRefreshController.hideWindow(
                entry,
                monitor: fixture.monitor,
                side: .right,
                reason: .workspaceInactive,
                observedFrame: alreadyHidden ? fixture.parkFrame : fixture.visibleFrame
            ))

            let trace = FrameApplyTrace.shared.dump()
            XCTAssertTrue(trace.contains("outcome=ax-park-failed/contextUnavailable"), trace)
            XCTAssertFalse(trace.contains("park-ledger-noop/verified/terminal"), trace)
            XCTAssertEqual(fastFrameReads, 0)
            XCTAssertEqual(controller.workspaceManager.hiddenState(for: fixture.token), fixture.hiddenState)
            XCTAssertNil(controller.axManager.lastAppliedFrame(for: fixture.token.windowId))
        }
    }

    func testParkFrameEventsInvalidateOnlyAtOrBeyondFrameWriteTolerance() throws {
        for offset in [
            CGPoint.zero,
            CGPoint(x: -0.5, y: 0),
            CGPoint(x: 0, y: 0.5),
            CGPoint(x: -1, y: 0),
            CGPoint(x: 0, y: 1)
        ] {
            let fixture = try Self.parkDriftFixture()
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }
            Self.sendFrameEvent(
                fixture,
                observedFrame: fixture.parkFrame.offsetBy(dx: offset.x, dy: offset.y)
            )
            if abs(offset.x) >= 1 || abs(offset.y) >= 1 {
                XCTAssertNil(fixture.controller.axManager.verifiedParkFrame(for: fixture.token.windowId))
                XCTAssertTrue(fixture.controller.axManager.pendingParkWindowIds.contains(fixture.token.windowId))
                XCTAssertTrue(FrameApplyTrace.shared.dump().contains("outcome=ax-park-failed/contextUnavailable"))
            } else {
                XCTAssertEqual(
                    fixture.controller.axManager.verifiedParkFrame(for: fixture.token.windowId),
                    fixture.parkFrame
                )
                XCTAssertFalse(fixture.controller.axManager.pendingParkWindowIds.contains(fixture.token.windowId))
                XCTAssertEqual(FrameApplyTrace.shared.dump(), "none")
            }
        }
    }

    func testRepeatedFrameEventsAndSettledMovesPreservePendingParkRequest() throws {
        let fixture = try Self.parkDriftFixture()
        let manager = fixture.controller.axManager
        manager.markParkPending(for: fixture.token.windowId, pid: fixture.token.pid)
        let pending = try XCTUnwrap(manager.prepareParkFrameApplications([fixture.target]).first)
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        Self.sendFrameEvent(fixture, observedFrame: fixture.visibleFrame)
        Self.sendFrameEvent(fixture, observedFrame: fixture.visibleFrame)

        XCTAssertEqual(FrameApplyTrace.shared.dump(), "none")
        XCTAssertEqual(manager.pendingParkFrameRequest(for: fixture.token.windowId), pending)
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: fixture.token))
        let plan = LayoutRefreshController.WindowPositionPlan(entry: entry, frame: fixture.parkFrame)
        fixture.controller.layoutRefreshController.applyParkPositionPlans(
            [plan], movablePlans: [plan], animationTick: false
        )

        XCTAssertEqual(manager.pendingParkFrameRequest(for: fixture.token.windowId), pending)
        XCTAssertFalse(FrameApplyTrace.shared.dump().contains("outcome=ax-park-failed"))
        XCTAssertTrue(manager.processParkFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: pending)
        ]).isEmpty)
        XCTAssertEqual(manager.verifiedParkFrame(for: fixture.token.windowId), fixture.parkFrame)
    }

    func testSettledMovableParkInvalidatesVerificationWithoutFrameEvent() throws {
        let fixture = try Self.parkDriftFixture()
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: fixture.token))
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        XCTAssertTrue(fixture.controller.layoutRefreshController.hideWindow(
            entry,
            monitor: fixture.monitor,
            side: .right,
            reason: .workspaceInactive,
            observedFrame: fixture.visibleFrame
        ))

        XCTAssertNil(fixture.controller.axManager.verifiedParkFrame(for: fixture.token.windowId))
        XCTAssertTrue(FrameApplyTrace.shared.dump().contains("outcome=ax-park-failed/contextUnavailable"))
        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: fixture.token.windowId))
    }

    func testParkFrameCorrectionHonorsWorkspaceLayoutAndAppVisibilityExclusions() throws {
        for exclusion in [
            "active-workspace",
            "native-fullscreen",
            "layout-transient",
            "scratchpad",
            "app-hidden",
            "ax-hidden"
        ] {
            let fixture = try Self.parkDriftFixture()
            let controller = fixture.controller
            switch exclusion {
            case "active-workspace":
                _ = controller.workspaceManager.focusWorkspace(named: "2")
            case "native-fullscreen":
                controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: fixture.token)
            case "layout-transient",
                 "scratchpad":
                controller.workspaceManager.setHiddenState(
                    HiddenState(
                        proportionalPosition: fixture.hiddenState.proportionalPosition,
                        referenceMonitorId: fixture.monitor.id,
                        reason: exclusion == "scratchpad" ? .scratchpad : .layoutTransient(.right)
                    ),
                    for: fixture.token
                )
            case "app-hidden":
                controller.workspaceManager.setAppHidden(true, pid: fixture.token.pid, source: .service)
            default:
                controller.axManager.setMacOSAppHidden(
                    true,
                    pid: fixture.token.pid,
                    entries: [(pid: fixture.token.pid, windowId: fixture.token.windowId)]
                )
            }
            defer {
                controller.axManager.setMacOSAppHidden(
                    false,
                    pid: fixture.token.pid,
                    entries: [(pid: fixture.token.pid, windowId: fixture.token.windowId)]
                )
            }
            try Self.verifyPark(fixture)
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            Self.sendFrameEvent(fixture, observedFrame: fixture.visibleFrame)

            XCTAssertEqual(FrameApplyTrace.shared.dump(), "none", exclusion)
            if exclusion == "app-hidden" || exclusion == "ax-hidden" {
                XCTAssertNil(controller.axManager.verifiedParkFrame(for: fixture.token.windowId), exclusion)
                XCTAssertTrue(controller.axManager.pendingParkWindowIds.contains(fixture.token.windowId), exclusion)
            } else {
                XCTAssertEqual(
                    controller.axManager.verifiedParkFrame(for: fixture.token.windowId),
                    fixture.parkFrame,
                    exclusion
                )
            }
        }
    }

    private struct ParkDriftFixture {
        let controller: WMController
        let monitor: Monitor
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let hiddenState: HiddenState
        let visibleFrame: CGRect
        let target: AXFrameApplicationTarget

        var parkFrame: CGRect {
            target.frame
        }
    }

    private static func parkDriftFixture() throws -> ParkDriftFixture {
        let controller = controller()
        let monitor = monitor()
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let activeId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let inactiveId = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        _ = manager.focusWorkspace(named: "1")
        let active = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(963_001), windowId: 963_101),
            pid: 963_001, windowId: 963_101, to: activeId
        )
        XCTAssertTrue(manager.setManagedFocus(active, in: activeId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(963_002), windowId: 963_102)
        let token = manager.addWindow(axRef, pid: 963_002, windowId: 963_102, to: inactiveId)
        let hidden = HiddenState(
            proportionalPosition: CGPoint(x: 0.25, y: 0.5),
            referenceMonitorId: monitor.id,
            reason: .workspaceInactive
        )
        manager.setHiddenState(hidden, for: token)
        let visibleFrame = CGRect(x: 100, y: 16, width: 800, height: 600)
        controller.axManager.markWindowInactive(token.windowId)
        controller.axManager.suppressFrameWrites([(pid: token.pid, windowId: token.windowId)])
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: visibleFrame)
        let fixture = ParkDriftFixture(
            controller: controller,
            monitor: monitor,
            token: token,
            workspaceId: inactiveId,
            hiddenState: hidden,
            visibleFrame: visibleFrame,
            target: AXFrameApplicationTarget(
                pid: token.pid,
                window: axRef,
                frame: CGRect(x: monitor.visibleFrame.maxX - 1, y: 16, width: 800, height: 600)
            )
        )
        try verifyPark(fixture)
        return fixture
    }

    private static func verifyPark(_ fixture: ParkDriftFixture) throws {
        let manager = fixture.controller.axManager
        guard manager.verifiedParkFrame(for: fixture.token.windowId) == nil else { return }
        let request = try XCTUnwrap(manager.prepareParkFrameApplications([fixture.target]).first)
        XCTAssertTrue(manager.processParkFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: request)
        ]).isEmpty)
    }

    private static func sendFrameEvent(_ fixture: ParkDriftFixture, observedFrame: CGRect) {
        let pid = fixture.token.pid
        let frame = ScreenCoordinateSpace.toWindowServer(rect: observedFrame)
        fixture.controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(id: windowId, pid: pid, level: 0, frame: frame)
        }
        fixture.controller.axEventHandler.handleCGSEvent(
            .frameChanged(windowId: UInt32(fixture.token.windowId))
        )
    }

    private static func setNativeDesktopCurrent(_ current: Bool, fixture: ParkDriftFixture) {
        fixture.controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [.init(
                    displayIdentifier: String(fixture.monitor.displayId),
                    spaceIds: [1, 2],
                    currentSpaceId: current ? 1 : 2
                )],
                activeSpaceId: current ? 1 : 2,
                fullscreenSpaceIds: [2],
                windowSpace: [fixture.token.windowId: 1]
            )
        )
    }

    private static func hidePlan(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        token: WindowToken,
        isAnimationTick: Bool = true
    ) -> WorkspaceLayoutPlan {
        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges.append(.hide(token, side: .right))
        return plan(workspaceId: workspaceId, monitor: monitor, diff: diff, isAnimationTick: isAnimationTick)
    }

    private static func plan(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        diff: WorkspaceLayoutDiff,
        isAnimationTick: Bool = true
    ) -> WorkspaceLayoutPlan {
        WorkspaceLayoutPlan(
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
            isAnimationTick: isAnimationTick
        )
    }

    private static func monitor() -> Monitor {
        Monitor(
            id: .init(displayId: 77),
            displayId: 77,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
            hasNotch: false,
            name: "DurablePark"
        )
    }

    private static func controller() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDurableParkTests-\(UUID().uuidString)", isDirectory: true)
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
