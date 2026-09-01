// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NativeTitleBarDragTests: NiriInteractionTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
        let otherToken: WindowToken
        let frame: CGRect

        @MainActor var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        @MainActor var entry: WindowState {
            controller.workspaceManager.entry(for: token)!
        }
    }

    func testTinyDisplacementQueuesOneWorkspaceScopedTerminalCorrectionWithoutMutatingAuthority() throws {
        let fixture = try makeFixture(pid: 561_001)
        let displacedFrame = fixture.frame.offsetBy(dx: 5, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in displacedFrame }
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let modeBefore = fixture.entry.mode
        let overrideBefore = fixture.entry.manualLayoutOverride
        let workspaceBefore = fixture.entry.workspaceId
        let orderBefore = windowOrder(fixture.engine, in: fixture.workspaceId)
        let worldSeqBefore = fixture.controller.workspaceManager.worldSeq

        beginPlainDrag(fixture)
        for _ in 0 ..< 12 {
            XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        }

        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertTrue(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))

        fixture.handler.dispatchMouseUp(at: displacedFrame.center)

        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])
        XCTAssertEqual(fixture.entry.mode, modeBefore)
        XCTAssertEqual(fixture.entry.manualLayoutOverride, overrideBefore)
        XCTAssertEqual(fixture.entry.workspaceId, workspaceBefore)
        XCTAssertEqual(windowOrder(fixture.engine, in: fixture.workspaceId), orderBefore)
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeqBefore)
        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))
        if case .awaitingCorrection? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("terminal correction must remain represented until a verified frame write")
        }
    }

    func testFrameWriteIsExcludedOnlyWhileExactNativeDragIsActiveAndReconciledOnMouseUp() throws {
        let fixture = try makeFixture(pid: 561_002)
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame }
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        beginPlainDrag(fixture)

        XCTAssertTrue(
            fixture.controller.axManager.excludeFrameWriteForNativeTitleBarDrag(
                pid: fixture.token.pid,
                windowId: fixture.token.windowId
            )
        )
        XCTAssertFalse(
            fixture.controller.axManager.excludeFrameWriteForNativeTitleBarDrag(
                pid: fixture.otherToken.pid,
                windowId: fixture.otherToken.windowId
            )
        )

        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertTrue(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))

        fixture.handler.dispatchMouseUp(at: fixture.frame.center)

        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
            [fixture.workspaceId]
        )
    }

    func testFinalFrameAfterMouseUpInvalidatesCachedTargetAndCannotDropWhileRefreshIsBusy() throws {
        let fixture = try makeFixture(pid: 561_003)
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame }
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        beginPlainDrag(fixture)

        fixture.handler.dispatchMouseUp(at: fixture.frame.center)

        if case .awaitingFrameChange? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("mouse-up must retain one exact obligation for a delayed native frame")
        }
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        let displacedFrame = fixture.frame.offsetBy(dx: 5, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in displacedFrame }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))

        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])
        XCTAssertTrue(RefreshReason.axWindowChanged.relayoutSchedulingPolicy.shouldDropWhileBusy)
    }

    func testDelayedExternalFrameDuringTerminalWriteRequestsOneTrailingCorrectionButEchoDoesNot() throws {
        let fixture = try makeFixture(pid: 561_004)
        let initialDisplacement = fixture.frame.offsetBy(dx: 5, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in initialDisplacement }
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        beginPlainDrag(fixture)
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        fixture.handler.dispatchMouseUp(at: initialDisplacement.center)
        XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)

        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        let delayedDisplacement = fixture.frame.offsetBy(dx: 11, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in delayedDisplacement }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)

        let firstResult = AXFrameApplyResult(
            requestId: 1,
            pid: fixture.token.pid,
            windowId: fixture.token.windowId,
            expectedWindow: fixture.entry.axRef,
            targetFrame: fixture.frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: fixture.frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
        fixture.handler.handleNativeTitleBarDragFrameApplySucceeded(firstResult)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
            [fixture.workspaceId]
        )

        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame }
        let secondResult = AXFrameApplyResult(
            requestId: 2,
            pid: fixture.token.pid,
            windowId: fixture.token.windowId,
            expectedWindow: fixture.entry.axRef,
            targetFrame: fixture.frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: fixture.frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
        fixture.handler.handleNativeTitleBarDragFrameApplySucceeded(secondResult)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        if case .awaitingFrameChange? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("verified correction must await a possible post-success native event")
        }

        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        if case .awaitingFrameChange? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("a matching corrective echo cannot retire the delayed native-frame obligation")
        }

        fixture.handler.nativeWindowFrameProvider = { _ in delayedDisplacement }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
            [fixture.workspaceId]
        )
    }

    func testPlainClickWithoutDragDoesNotReadFrameOrRequestRelayout() throws {
        let fixture = try makeFixture(pid: 561_005)
        var frameReadCount = 0
        fixture.handler.nativeWindowFrameProvider = { _ in
            frameReadCount += 1
            return fixture.frame
        }

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.frame.center,
                modifiers: [],
                windowIdUnderPointer: fixture.token.windowId
            )
        )
        fixture.handler.dispatchMouseUp(at: fixture.frame.center)

        XCTAssertEqual(frameReadCount, 0)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testSettledDragRetiresAtNextInputWithoutInvalidatingAppliedFrame() throws {
        let fixture = try makeFixture(pid: 561_016)
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame }
        beginPlainDrag(fixture)
        fixture.handler.dispatchMouseUp(at: fixture.frame.center)
        if case .awaitingFrameChange? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("a settled drag must retain its delayed-frame obligation")
        }

        var frameReadCount = 0
        fixture.handler.nativeWindowFrameProvider = { _ in
            frameReadCount += 1
            return fixture.frame
        }
        XCTAssertFalse(
            fixture.handler.receiveTapMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )

        XCTAssertEqual(frameReadCount, 1)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertEqual(
            fixture.controller.axManager.lastAppliedFrame(for: fixture.token.windowId),
            fixture.frame
        )
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testOwnedClickPreservesSettledDragAndDelayedFrameCorrection() throws {
        let fixture = try makeFixture(pid: 561_017)
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame }
        beginPlainDrag(fixture)
        fixture.handler.dispatchMouseUp(at: fixture.frame.center)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let surfaceId = "native-title-bar-drag-owned-\(fixture.token.windowId)"
        let ownedFrame = CGRect(x: -800, y: -800, width: 40, height: 40)
        fixture.controller.ownedWindowRegistry.registerWindowNumber(
            surfaceId: surfaceId,
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            ),
            windowNumber: fixture.token.windowId + 10_000,
            frameProvider: { ownedFrame },
            visibilityProvider: { true }
        )
        defer { fixture.controller.ownedWindowRegistry.unregister(surfaceId: surfaceId) }

        var frameReadCount = 0
        fixture.handler.nativeWindowFrameProvider = { _ in
            frameReadCount += 1
            return fixture.frame
        }
        XCTAssertFalse(
            fixture.handler.receiveTapMouseDown(
                at: ownedFrame.center,
                modifiers: []
            )
        )

        XCTAssertEqual(frameReadCount, 0)
        if case .awaitingFrameChange? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("owned input cannot retire another window's delayed-frame obligation")
        }
        XCTAssertEqual(
            fixture.controller.axManager.lastAppliedFrame(for: fixture.token.windowId),
            fixture.frame
        )

        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame.offsetBy(dx: 5, dy: 0) }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
            [fixture.workspaceId]
        )
    }

    func testQueuedDelayedFrameDrainsBeforeNextInputRetiresSettledDrag() throws {
        let fixture = try makeFixture(pid: 561_018)
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame }
        beginPlainDrag(fixture)
        fixture.handler.dispatchMouseUp(at: fixture.frame.center)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.eventIntake.open(sink: fixture.controller.eventInterpreter)
        defer { fixture.controller.eventIntake.close() }
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame.offsetBy(dx: 5, dy: 0) }
        XCTAssertTrue(
            fixture.controller.eventIntake.enqueue(
                .cgs(.frameChanged(windowId: UInt32(fixture.token.windowId)))
            )
        )

        XCTAssertFalse(
            fixture.handler.receiveTapMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )

        XCTAssertFalse(fixture.controller.eventIntake.hasPendingEvents)
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])
    }

    func testNextInputWithLiveDisplacementQueuesWorkspaceCorrectionBeforeRetirement() throws {
        let fixture = try makeFixture(pid: 561_025)
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame }
        beginPlainDrag(fixture)
        fixture.handler.dispatchMouseUp(at: fixture.frame.center)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame.offsetBy(dx: 5, dy: 0) }

        XCTAssertFalse(
            fixture.handler.receiveTapMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )

        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: fixture.token.windowId))
    }

    func testNextInputMergesTrailingCorrectionForUnresolvedFrameWrite() throws {
        let fixture = try makeFixture(pid: 561_026)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        var drag = MouseEventHandler.State.NativeTitleBarDrag(token: fixture.token)
        drag.phase = .awaitingFrameWrite
        drag.receivedFrameChange = true
        fixture.handler.state.nativeTitleBarDrag = drag

        XCTAssertFalse(
            fixture.handler.receiveTapMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )

        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
    }

    func testFloatingWindowIsNeverClaimedByNativeTiledDragLifecycle() throws {
        let fixture = try makeFixture(pid: 561_006)
        let floatingToken = WindowToken(pid: 561_106, windowId: 561_206)
        _ = fixture.controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: floatingToken),
            pid: floatingToken.pid,
            windowId: floatingToken.windowId,
            to: fixture.workspaceId,
            mode: .floating
        )

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )
        fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: floatingToken.windowId)
        fixture.handler.dispatchMouseDragged(at: fixture.frame.center)

        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: floatingToken))
        XCTAssertEqual(fixture.controller.workspaceManager.entry(for: floatingToken)?.mode, .floating)

        let movedFrame = fixture.frame.offsetBy(dx: 75, dy: 40)
        let floatingEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: floatingToken))
        fixture.controller.axEventHandler.updateFloatingWindowGeometryAndMonitorMembership(
            entry: floatingEntry,
            frame: movedFrame
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.floatingState(for: floatingToken)?.lastFrame,
            movedFrame
        )
    }

    func testAnnotatedDragTargetArmsExactTiledWindowWhenDownTapHasNoWindowId() throws {
        let fixture = try makeFixture(pid: 561_009)
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertTrue(fixture.handler.state.awaitsNativeTitleBarDragTarget)

        fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: fixture.token.windowId)

        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, fixture.token)
        XCTAssertTrue(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))
        fixture.handler.cleanup()
    }

    func testFrameEventClaimsExactTiledDragWhenAnnotatedTapIsUnavailable() throws {
        let fixture = try makeFixture(pid: 561_010)
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame.offsetBy(dx: 5, dy: 0) }
        XCTAssertNil(fixture.handler.state.moveTap)

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )
        XCTAssertTrue(fixture.handler.state.awaitsNativeTitleBarDragTarget)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, fixture.token)

        let otherEntry = try XCTUnwrap(
            fixture.controller.workspaceManager.entry(for: fixture.otherToken)
        )
        XCTAssertFalse(fixture.handler.handleNativeTitleBarDragFrameChanged(for: otherEntry))
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)

        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))

        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, fixture.token)
        if case .dragging? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("the first exact frame event must recover drag ownership")
        }
        XCTAssertTrue(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))
        fixture.handler.cleanup()
    }

    func testQueuedFinalFrameAtMouseUpClaimsReleasedFallbackWhileRefreshIsBusy() throws {
        let fixture = try makeFixture(pid: 561_013)
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.nativeWindowFrameProvider = { _ in
            fixture.frame.offsetBy(dx: 5, dy: 0)
        }
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.eventIntake.open(sink: fixture.controller.eventInterpreter)
        defer { fixture.controller.eventIntake.close() }

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, fixture.token)
        XCTAssertTrue(
            fixture.controller.eventIntake.enqueue(
                .cgs(.frameChanged(windowId: UInt32(fixture.token.windowId)))
            )
        )

        fixture.handler.receiveTapMouseUp(at: fixture.frame.center)

        XCTAssertFalse(fixture.controller.eventIntake.hasPendingEvents)
        if case .awaitingCorrection? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("the released exact fallback must retain a terminal correction")
        }
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])
    }

    func testUnreadableCorrectiveEchoProducesAtMostOneConservativeTrailingWrite() throws {
        let fixture = try makeFixture(pid: 561_011)
        let displacedFrame = fixture.frame.offsetBy(dx: 5, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in displacedFrame }
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        beginPlainDrag(fixture)
        fixture.handler.dispatchMouseUp(at: displacedFrame.center)

        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        fixture.handler.nativeWindowFrameProvider = { _ in nil }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        fixture.handler.handleNativeTitleBarDragFrameApplySucceeded(
            successfulFrameResult(fixture, requestId: 1)
        )
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
            [fixture.workspaceId]
        )

        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        fixture.handler.handleNativeTitleBarDragFrameApplySucceeded(
            successfulFrameResult(fixture, requestId: 2)
        )
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        if case .awaitingFrameChange? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("unreadable echoes must retain an inert exact obligation")
        }
    }

    func testCancelledBusyFrameWriteReleasesWorkspaceScopedTerminalCorrection() throws {
        let fixture = try makeFixture(pid: 561_015)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        var drag = MouseEventHandler.State.NativeTitleBarDrag(token: fixture.token)
        drag.phase = .awaitingFrameWrite
        drag.receivedFrameChange = true
        fixture.handler.state.nativeTitleBarDrag = drag
        let cancellation = AXFrameApplyResult(
            requestId: 1,
            pid: fixture.token.pid,
            windowId: fixture.token.windowId,
            expectedWindow: fixture.entry.axRef,
            targetFrame: fixture.frame,
            currentFrameHint: fixture.frame,
            writeResult: .skipped(
                targetFrame: fixture.frame,
                currentFrameHint: fixture.frame,
                failureReason: .cancelled,
                observedFrame: fixture.frame.offsetBy(dx: 5, dy: 0)
            )
        )

        fixture.handler.handleNativeTitleBarDragPendingFrameSettled(cancellation)

        if case .awaitingCorrection? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("a non-success terminal result must release the exact correction")
        }
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])

        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        fixture.handler.handleNativeTitleBarDragFrameApplyTerminated(cancellation)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testInputSuppressionClearsExactNativeDragWithoutSchedulingWork() throws {
        let fixture = try makeFixture(pid: 561_007)
        beginPlainDrag(fixture)

        fixture.controller.isLockScreenActive = true

        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testInputSuppressionCannotCleanRetireSettledDragAtInputBoundary() throws {
        let fixture = try makeFixture(pid: 561_019)
        fixture.controller.isLockScreenActive = true
        var drag = MouseEventHandler.State.NativeTitleBarDrag(token: fixture.token)
        drag.phase = .awaitingFrameChange
        fixture.handler.state.nativeTitleBarDrag = drag
        var frameReadCount = 0
        fixture.handler.nativeWindowFrameProvider = { _ in
            frameReadCount += 1
            return fixture.frame
        }

        XCTAssertFalse(
            fixture.handler.receiveTapMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )

        XCTAssertEqual(frameReadCount, 0)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: fixture.token.windowId))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testAppVisibilityChangeConservativelyClearsSettledDrag() throws {
        let fixture = try makeFixture(pid: 561_020)
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame }
        beginPlainDrag(fixture)
        fixture.handler.dispatchMouseUp(at: fixture.frame.center)

        fixture.handler.handleAppVisibilityChanged()

        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))
        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: fixture.token.windowId))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testTerminalFrameFailureRetriesOnceAndDuplicateDeliveryIsInert() throws {
        let fixture = try makeFixture(pid: 561_021)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        var drag = MouseEventHandler.State.NativeTitleBarDrag(token: fixture.token)
        drag.phase = .awaitingCorrection
        fixture.handler.state.nativeTitleBarDrag = drag
        let firstFailure = failedFrameResult(fixture, requestId: 71)

        fixture.handler.handleNativeTitleBarDragFrameApplyTerminated(firstFailure)

        XCTAssertEqual(
            fixture.handler.state.nativeTitleBarDrag?.terminalFailureRetryRequestId,
            firstFailure.requestId
        )
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
            [fixture.workspaceId]
        )

        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        fixture.handler.handleNativeTitleBarDragFrameApplyTerminated(firstFailure)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)

        fixture.handler.handleNativeTitleBarDragFrameApplyTerminated(
            failedFrameResult(fixture, requestId: 72)
        )
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testNormalFrameApplicationTerminalFailureReleasesWorkspaceCorrection() async throws {
        let fixture = try makeFixture(pid: 561_024)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        var drag = MouseEventHandler.State.NativeTitleBarDrag(token: fixture.token)
        drag.phase = .awaitingCorrection
        fixture.handler.state.nativeTitleBarDrag = drag
        let terminated = expectation(description: "normal frame application terminated")
        fixture.controller.axManager.onFrameApplyTerminated = { [weak controller = fixture.controller] result in
            controller?.mouseEventHandler.handleNativeTitleBarDragFrameApplyTerminated(result)
            terminated.fulfill()
        }
        defer { fixture.controller.axManager.onFrameApplyTerminated = nil }
        fixture.controller.axManager.forceApplyNextFrame(for: fixture.token.windowId)

        fixture.controller.axManager.applyFramesParallel([
            AXFrameApplicationTarget(
                pid: fixture.token.pid,
                window: fixture.entry.axRef,
                frame: fixture.frame
            )
        ])
        await fulfillment(of: [terminated], timeout: 2)

        XCTAssertNotNil(fixture.handler.state.nativeTitleBarDrag?.terminalFailureRetryRequestId)
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])
    }

    func testNewDragGetsIndependentTerminalFailureRecoveryBudget() throws {
        let fixture = try makeFixture(pid: 561_022)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        var oldDrag = MouseEventHandler.State.NativeTitleBarDrag(token: fixture.token)
        oldDrag.phase = .awaitingCorrection
        oldDrag.terminalFailureRetryRequestId = 81
        fixture.handler.state.nativeTitleBarDrag = oldDrag
        fixture.handler.handleNativeTitleBarDragFrameApplyTerminated(
            failedFrameResult(fixture, requestId: 82)
        )
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)

        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        fixture.handler.nativeWindowFrameProvider = { _ in fixture.frame.offsetBy(dx: 5, dy: 0) }
        beginPlainDrag(fixture)
        fixture.handler.dispatchMouseUp(at: fixture.frame.center)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.terminalFailureRetryRequestId)
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

        fixture.handler.handleNativeTitleBarDragFrameApplyTerminated(
            failedFrameResult(fixture, requestId: 83)
        )
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.terminalFailureRetryRequestId, 83)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
            [fixture.workspaceId]
        )
    }

    func testStaleAXIncarnationTerminalResultsCannotMutateCurrentDrag() throws {
        let fixture = try makeFixture(pid: 561_023)
        var drag = MouseEventHandler.State.NativeTitleBarDrag(token: fixture.token)
        drag.phase = .awaitingCorrection
        fixture.handler.state.nativeTitleBarDrag = drag
        let staleWindow = AXWindowRef(
            element: AXUIElementCreateApplication(fixture.token.pid + 1),
            windowId: fixture.token.windowId
        )

        fixture.handler.handleNativeTitleBarDragFrameApplyTerminated(
            failedFrameResult(fixture, requestId: 91, expectedWindow: staleWindow)
        )
        fixture.handler.handleNativeTitleBarDragFrameApplySucceeded(
            successfulFrameResult(fixture, requestId: 92, expectedWindow: staleWindow)
        )

        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, fixture.token)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.terminalFailureRetryRequestId)
        XCTAssertEqual(
            fixture.controller.axManager.lastAppliedFrame(for: fixture.token.windowId),
            fixture.frame
        )
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testAppTerminationClearsExactNativeDragOwnership() throws {
        let fixture = try makeFixture(pid: 561_008)
        beginPlainDrag(fixture)

        fixture.controller.serviceLifecycleManager.handleAppTerminated(pid: fixture.token.pid)

        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.token))
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: fixture.token))
    }

    func testAppTerminationClearsReleasedFallbackOwnership() throws {
        let fixture = try makeFixture(pid: 561_014)
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.frame.center,
                modifiers: []
            )
        )
        fixture.handler.dispatchMouseUp(at: fixture.frame.center)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, fixture.token)
        XCTAssertTrue(fixture.handler.state.nativeTitleBarDragFallbackReleased)

        fixture.controller.serviceLifecycleManager.handleAppTerminated(pid: fixture.token.pid)

        XCTAssertFalse(fixture.handler.state.awaitsNativeTitleBarDragTarget)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDragFallbackToken)
        XCTAssertFalse(fixture.handler.state.nativeTitleBarDragFallbackReleased)
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: fixture.token))
    }

    func testStaleReusedWindowIdFrameEventCannotAdvanceNativeDrag() throws {
        let fixture = try makeFixture(pid: 561_027)
        beginPlainDrag(fixture)
        var frameReadCount = 0
        fixture.handler.nativeWindowFrameProvider = { _ in
            frameReadCount += 1
            return fixture.frame.offsetBy(dx: 12, dy: 0)
        }
        fixture.controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(
                id: windowId,
                pid: fixture.token.pid + 1,
                level: 0,
                frame: fixture.frame.offsetBy(dx: 12, dy: 0)
            )
        }
        let worldSeq = fixture.controller.workspaceManager.worldSeq

        fixture.controller.axEventHandler.handleCGSEvent(
            .frameChanged(windowId: UInt32(fixture.token.windowId))
        )

        XCTAssertEqual(frameReadCount, 0)
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, fixture.token)
        if case .dragging? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("a stale reused-window event cannot advance the active drag")
        }
    }

    func testServiceCleanupCannotRestoreStaleAppliedFrameDeduplication() throws {
        let fixture = try makeFixture(pid: 561_012)
        beginPlainDrag(fixture)
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry))

        fixture.handler.cleanup()
        fixture.controller.axManager.cleanup()

        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: fixture.token.windowId))
    }

    private func beginPlainDrag(_ fixture: Fixture) {
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.frame.center,
                modifiers: [],
                windowIdUnderPointer: fixture.token.windowId
            )
        )
        fixture.handler.dispatchMouseDragged(
            at: CGPoint(x: fixture.frame.center.x + 5, y: fixture.frame.center.y)
        )
        if case .dragging? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("plain native drag must become active on the first drag event")
        }
    }

    private func blockRefreshes(_ fixture: Fixture) -> Task<Void, Never> {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        return blocker
    }

    private func unblockRefreshes(_ fixture: Fixture, blocker: Task<Void, Never>) {
        blocker.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }

    private func successfulFrameResult(
        _ fixture: Fixture,
        requestId: AXFrameRequestId,
        expectedWindow: AXWindowRef? = nil
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: fixture.token.pid,
            windowId: fixture.token.windowId,
            expectedWindow: expectedWindow ?? fixture.entry.axRef,
            targetFrame: fixture.frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: fixture.frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
    }

    private func failedFrameResult(
        _ fixture: Fixture,
        requestId: AXFrameRequestId,
        expectedWindow: AXWindowRef? = nil
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: fixture.token.pid,
            windowId: fixture.token.windowId,
            expectedWindow: expectedWindow ?? fixture.entry.axRef,
            targetFrame: fixture.frame,
            currentFrameHint: fixture.frame,
            writeResult: .skipped(
                targetFrame: fixture.frame,
                currentFrameHint: fixture.frame,
                failureReason: .contextUnavailable,
                observedFrame: fixture.frame.offsetBy(dx: 5, dy: 0)
            )
        )
    }

    private func makeFixture(pid: pid_t) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "NativeTitleBarDragTests")
        addTeardownBlock { @MainActor [controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        let monitor = Monitor(
            id: .init(displayId: 56_101),
            displayId: 56_101,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Native Title Bar Drag"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let token = WindowToken(pid: pid, windowId: Int(pid) + 100)
        let otherToken = WindowToken(pid: pid, windowId: Int(pid) + 101)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(otherToken, in: workspaceId, controller: controller)
        _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        _ = engine.addWindow(token: otherToken, to: workspaceId, afterSelection: nil)
        let frames = engine.calculateLayout(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId,
            monitorFrame: controller.insetWorkingFrame(for: monitor),
            gaps: (
                horizontal: controller.innerGap(for: monitor),
                vertical: controller.innerGap(for: monitor)
            ),
            orientation: .horizontal
        )
        let frame = try XCTUnwrap(frames[token])
        controller.axEventHandler.windowInfoProvider = { windowId in
            let resolvedToken: WindowToken
            if Int(windowId) == token.windowId {
                resolvedToken = token
            } else if Int(windowId) == otherToken.windowId {
                resolvedToken = otherToken
            } else {
                return nil
            }
            return WindowServerInfo(
                id: windowId,
                pid: resolvedToken.pid,
                level: 0,
                frame: frames[resolvedToken] ?? .zero
            )
        }
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        controller.layoutRefreshController.resetState()
        controller.hasStartedServices = true
        return Fixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            token: token,
            otherToken: otherToken,
            frame: frame
        )
    }
}
