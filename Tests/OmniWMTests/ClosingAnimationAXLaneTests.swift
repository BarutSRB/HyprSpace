// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class ClosingAnimationAXLaneTests: XCTestCase {
    func testFailedDisplayLinkCreationRollsBackClosingAnimationState() throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.setAnimationsEnabled(true, persist: false)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let displayId: CGDirectDisplayID = 91_100
        controller.layoutRefreshController.displayLinkCreationAllowedForTests = { _ in false }
        let monitor = Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: "Unavailable Display"
        )
        let token = WindowToken(pid: 91_106, windowId: 91_107)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.layoutRefreshController.fastFrameProvider = { _, _ in
            CGRect(x: 20, y: 20, width: 800, height: 600)
        }

        controller.layoutRefreshController.startWindowCloseAnimation(
            entry: try XCTUnwrap(controller.workspaceManager.entry(for: token)),
            monitor: monitor
        )

        XCTAssertNil(controller.layoutRefreshController.layoutState.closingAnimationsByDisplay[displayId])
        XCTAssertTrue(controller.layoutRefreshController.closingAnimationIdsByObjectId.isEmpty)
        XCTAssertTrue(controller.layoutRefreshController.lastSubmittedClosingFramesByAnimationId.isEmpty)
    }

    func testClosingFrameWriteUsesExactElementWithoutVerificationOrRefresh() {
        let pid: pid_t = 91_001
        let windowId = 91_002
        let expectedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let replacementWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: windowId
        )
        let animationId = UUID()
        let generations = LockedClosingFrameGenerationMap()
        let targetFrame = CGRect(x: 40, y: 50, width: 600, height: 400)
        let currentFrameHint = CGRect(x: 40, y: 62, width: 600, height: 400)
        let request = AppAXClosingFrameWriteRequest(
            target: AXClosingFrameTarget(
                animationId: animationId,
                pid: pid,
                expectedWindow: expectedWindow,
                frame: targetFrame,
                currentFrameHint: currentFrameHint
            ),
            generation: generations.nextGeneration(for: animationId)
        )
        var writtenWindow: AXWindowRef?
        var receivedHint: CGRect?
        var receivedVerify: Bool?

        let outcome = applyClosingFrameWriteRequest(
            request,
            generations: generations,
            writeFrame: { window, _, hint, verify in
                writtenWindow = window
                receivedHint = hint
                receivedVerify = verify
                return AXFrameWriteResult(
                    observedFrame: nil,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            }
        )

        guard case let .attempted(result, _) = outcome else {
            return XCTFail("Expected an attempted closing write, got \(outcome)")
        }
        XCTAssertNil(result.failureReason)
        XCTAssertTrue(writtenWindow.map { sameAXWindowIdentity($0, expectedWindow) } == true)
        XCTAssertFalse(writtenWindow.map { sameAXWindowIdentity($0, replacementWindow) } == true)
        XCTAssertEqual(receivedHint, currentFrameHint)
        XCTAssertEqual(receivedVerify, false)
    }

    func testCancelledClosingWriteIsIneligibleWhileAFailedSetterIsAnAttempt() {
        let pid: pid_t = 91_010
        let animationId = UUID()
        let generations = LockedClosingFrameGenerationMap()
        let request = AppAXClosingFrameWriteRequest(
            target: AXClosingFrameTarget(
                animationId: animationId,
                pid: pid,
                expectedWindow: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 91_011),
                frame: CGRect(x: 40, y: 50, width: 600, height: 400),
                currentFrameHint: nil
            ),
            generation: generations.nextGeneration(for: animationId)
        )
        var setterCalls = 0

        let cancelled = applyClosingFrameWriteRequest(
            request,
            generations: generations,
            isCancelled: { true },
            writeFrame: { _, _, _, _ in
                setterCalls += 1
                return AXFrameWriteResult(
                    observedFrame: nil,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            }
        )
        XCTAssertEqual(cancelled, .ineligible)
        XCTAssertEqual(setterCalls, 0)

        let failed = applyClosingFrameWriteRequest(
            request,
            generations: generations,
            writeFrame: { _, frame, hint, _ in
                setterCalls += 1
                return .skipped(
                    targetFrame: frame,
                    currentFrameHint: hint,
                    failureReason: .sizeWriteFailed(.cannotComplete)
                )
            }
        )
        guard case let .attempted(result, _) = failed else {
            return XCTFail("Expected an attempted closing write, got \(failed)")
        }
        XCTAssertEqual(result.failureReason, .sizeWriteFailed(.cannotComplete))
        XCTAssertEqual(setterCalls, 1)
    }

    func testClosingFrameGenerationIsAnimationScopedAcrossSameWindowIdReuse() {
        let generations = LockedClosingFrameGenerationMap()
        let oldAnimationId = UUID()
        let replacementAnimationId = UUID()
        let oldGeneration = generations.nextGeneration(for: oldAnimationId)
        let replacementGeneration = generations.nextGeneration(for: replacementAnimationId)
        let supersedingOldGeneration = generations.nextGeneration(for: oldAnimationId)

        XCTAssertFalse(generations.isCurrent(oldGeneration, for: oldAnimationId))
        XCTAssertTrue(generations.isCurrent(supersedingOldGeneration, for: oldAnimationId))
        XCTAssertTrue(generations.isCurrent(replacementGeneration, for: replacementAnimationId))

        generations.removeIfCurrent(oldGeneration, for: oldAnimationId)

        XCTAssertTrue(generations.isCurrent(supersedingOldGeneration, for: oldAnimationId))
        XCTAssertTrue(generations.isCurrent(replacementGeneration, for: replacementAnimationId))
    }

    func testClosingLaneCancellationCannotCancelOrdinarySameWindowIdWrite() {
        let windowId = 91_003
        let ordinaryGenerations = LockedWindowGenerationMap()
        let closingGenerations = LockedClosingFrameGenerationMap()
        let animationId = UUID()
        let ordinaryGeneration = ordinaryGenerations.nextGeneration(for: windowId)
        let closingGeneration = closingGenerations.nextGeneration(for: animationId)

        closingGenerations.invalidateAll()

        XCTAssertTrue(ordinaryGenerations.isCurrent(ordinaryGeneration, for: windowId))
        XCTAssertFalse(closingGenerations.isCurrent(closingGeneration, for: animationId))
    }

    func testClosingFramesNeverEnterOrdinaryLedgerOrCallbacks() {
        let manager = AXManager()
        let pid: pid_t = 91_004
        let windowId = 91_005
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        var acceptedResults = 0
        var terminalRefusals = 0
        manager.onFrameApplySucceeded = { _ in acceptedResults += 1 }
        manager.onTerminalFrameRefusal = { _ in terminalRefusals += 1 }

        manager.applyClosingFrames([
            AXClosingFrameTarget(
                animationId: UUID(),
                pid: pid,
                expectedWindow: window,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                currentFrameHint: CGRect(x: 0, y: 12, width: 800, height: 600)
            )
        ])

        XCTAssertFalse(manager.hasPendingFrameWrite(for: windowId))
        XCTAssertNil(manager.pendingFrameWrite(for: windowId))
        XCTAssertNil(manager.recentFrameWriteFailure(for: windowId))
        XCTAssertEqual(acceptedResults, 0)
        XCTAssertEqual(terminalRefusals, 0)
    }
}
