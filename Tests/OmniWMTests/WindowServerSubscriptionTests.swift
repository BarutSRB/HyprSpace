// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class WindowServerSubscriptionTests: XCTestCase {
    func testRuleReevaluationAdmissionReplacesTheCompleteManagedSetExactlyOnce() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let existing = WindowToken(pid: 809_991, windowId: 809_992)
        let newlyManaged = WindowToken(pid: 809_993, windowId: 809_994)
        _ = WindowAdmissionTestSupport.track(existing, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(newlyManaged, in: workspaceId, controller: controller)
        let handler = controller.axEventHandler
        var submissions: [[UInt32]] = []
        handler.windowSubscriptionProvider = {
            submissions.append($0)
            return true
        }

        handler.finishRuleReevaluationAfterTracking(
            windowId: UInt32(newlyManaged.windowId),
            wasNewlyManaged: true
        )
        handler.finishRuleReevaluationAfterTracking(
            windowId: UInt32(existing.windowId),
            wasNewlyManaged: false
        )

        XCTAssertEqual(submissions, [[UInt32(existing.windowId), UInt32(newlyManaged.windowId)]])
        XCTAssertEqual(handler.windowSubscriptionIdentityRevision, 1)
        XCTAssertEqual(
            handler.lastSuccessfulWindowSubscriptionIds,
            [UInt32(existing.windowId), UInt32(newlyManaged.windowId)]
        )
    }

    func testCompleteSetRetainsHiddenAndNativeFullscreenManagedWindowsAndPreparedAdmissions() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let hidden = WindowToken(pid: 810_001, windowId: 810_030)
        let visible = WindowToken(pid: 810_002, windowId: 810_020)
        let nativeFullscreen = WindowToken(pid: 810_003, windowId: 810_040)
        _ = WindowAdmissionTestSupport.track(hidden, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(visible, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(nativeFullscreen, in: workspaceId, controller: controller)
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: hidden
        )
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: nativeFullscreen)

        let handler = controller.axEventHandler
        var submissions: [[UInt32]] = []
        handler.windowSubscriptionProvider = {
            submissions.append($0)
            return true
        }

        handler.retainPreparedWindowSubscription(810_010)
        handler.retainPreparedWindowSubscription(UInt32(visible.windowId))

        XCTAssertEqual(submissions.last, [810_010, 810_020, 810_030, 810_040])
        XCTAssertEqual(
            handler.lastSuccessfulWindowSubscriptionIds,
            [810_010, 810_020, 810_030, 810_040]
        )
        XCTAssertTrue(handler.desiredWindowSubscriptionIds().contains(UInt32(hidden.windowId)))
        XCTAssertTrue(
            handler.desiredWindowSubscriptionIds().contains(UInt32(nativeFullscreen.windowId))
        )
    }

    func testEmptyDesiredSetNeverIssuesCountZeroSubscription() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let handler = controller.axEventHandler
        var submissions = 0
        handler.windowSubscriptionProvider = { _ in
            submissions += 1
            return true
        }

        handler.refreshWindowSubscriptions()
        handler.noteManagedWindowSubscriptionIdentityChanged()

        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(handler.lastSuccessfulWindowSubscriptionIds.isEmpty)
        XCTAssertNil(handler.lastSuccessfulWindowSubscriptionRevision)
    }

    func testFailureKeepsSuccessfulCacheAndRetriesOnlyAfterLifecycleRevision() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 810_101, windowId: 810_102)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let handler = controller.axEventHandler
        var attempts = 0
        handler.windowSubscriptionProvider = { _ in
            attempts += 1
            return attempts > 1
        }

        handler.refreshWindowSubscriptions()
        let failedRevision = handler.windowSubscriptionIdentityRevision
        handler.refreshWindowSubscriptions()

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(handler.lastSuccessfulWindowSubscriptionIds.isEmpty)
        XCTAssertEqual(handler.lastWindowSubscriptionFailureRevision, failedRevision)

        handler.noteManagedWindowSubscriptionIdentityChanged()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(handler.lastSuccessfulWindowSubscriptionIds, [UInt32(token.windowId)])
        XCTAssertNil(handler.lastWindowSubscriptionFailureRevision)
    }

    func testIdentityRevisionResubmitsAnUnchangedWindowIdSet() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 810_201, windowId: 810_202)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let handler = controller.axEventHandler
        var submissions: [[UInt32]] = []
        handler.windowSubscriptionProvider = {
            submissions.append($0)
            return true
        }

        handler.refreshWindowSubscriptions()
        handler.noteManagedWindowSubscriptionIdentityChanged()

        XCTAssertEqual(submissions, [
            [UInt32(token.windowId)],
            [UInt32(token.windowId)]
        ])
        XCTAssertEqual(handler.lastSuccessfulWindowSubscriptionRevision, 1)
    }

    func testOverlappingPreparedIncarnationsRetainTheSharedWindowIdUntilBothFinish() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let handler = controller.axEventHandler
        var submissions: [[UInt32]] = []
        handler.windowSubscriptionProvider = {
            submissions.append($0)
            return true
        }

        handler.retainPreparedWindowSubscription(810_250)
        handler.retainPreparedWindowSubscription(810_250)
        handler.releasePreparedWindowSubscription(810_250)

        XCTAssertEqual(handler.preparedWindowSubscriptionRetainCounts[810_250], 1)
        XCTAssertEqual(handler.desiredWindowSubscriptionIds(), [810_250])
        XCTAssertEqual(submissions, [[810_250], [810_250], [810_250]])

        handler.releasePreparedWindowSubscription(810_250)

        XCTAssertNil(handler.preparedWindowSubscriptionRetainCounts[810_250])
        XCTAssertTrue(handler.desiredWindowSubscriptionIds().isEmpty)
        XCTAssertEqual(submissions.count, 3)
    }

    func testRejectedDuplicatePreparationReleasesOnlyItsOwnRetain() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let handler = controller.axEventHandler
        handler.windowSubscriptionProvider = { _ in true }

        handler.retainPreparedWindowSubscription(810_260)
        handler.retainPreparedWindowSubscription(810_260)
        handler.releasePreparedWindowSubscription(810_260)

        XCTAssertEqual(handler.preparedWindowSubscriptionRetainCounts[810_260], 1)
        XCTAssertEqual(handler.desiredWindowSubscriptionIds(), [810_260])

        handler.releasePreparedWindowSubscription(810_260)

        XCTAssertNil(handler.preparedWindowSubscriptionRetainCounts[810_260])
        XCTAssertTrue(handler.desiredWindowSubscriptionIds().isEmpty)
    }

    func testRetirementReplacesTheCompleteSetWithoutTheRemovedWindow() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let first = WindowToken(pid: 810_301, windowId: 810_302)
        let second = WindowToken(pid: 810_303, windowId: 810_304)
        _ = WindowAdmissionTestSupport.track(first, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(second, in: workspaceId, controller: controller)
        let handler = controller.axEventHandler
        var submissions: [[UInt32]] = []
        handler.windowSubscriptionProvider = {
            submissions.append($0)
            return true
        }
        handler.refreshWindowSubscriptions()

        XCTAssertNotNil(
            controller.workspaceManager.removeWindow(pid: first.pid, windowId: first.windowId)
        )
        handler.noteManagedWindowSubscriptionIdentityChanged()

        XCTAssertEqual(submissions.last, [UInt32(second.windowId)])
    }

    func testAppTerminationAdvancesFailedRevisionOnceAndRetriesRemainingCompleteSet() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let terminated = WindowToken(pid: 810_351, windowId: 810_352)
        let remaining = WindowToken(pid: 810_353, windowId: 810_354)
        _ = WindowAdmissionTestSupport.track(terminated, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(remaining, in: workspaceId, controller: controller)
        let handler = controller.axEventHandler
        var submissions: [[UInt32]] = []
        handler.windowSubscriptionProvider = {
            submissions.append($0)
            return submissions.count > 1
        }

        handler.refreshWindowSubscriptions()
        let failedRevision = handler.windowSubscriptionIdentityRevision

        controller.serviceLifecycleManager.handleAppTerminated(pid: terminated.pid)

        XCTAssertEqual(submissions, [
            [UInt32(terminated.windowId), UInt32(remaining.windowId)],
            [UInt32(remaining.windowId)]
        ])
        XCTAssertEqual(handler.windowSubscriptionIdentityRevision, failedRevision + 1)
        XCTAssertEqual(handler.lastSuccessfulWindowSubscriptionIds, [UInt32(remaining.windowId)])
        XCTAssertNil(handler.lastWindowSubscriptionFailureRevision)
        XCTAssertNil(controller.workspaceManager.entry(for: terminated))
        XCTAssertNotNil(controller.workspaceManager.entry(for: remaining))
    }

    func testStaleEventWithConfirmedPIDMismatchDoesNotFallBackToWindowId() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let tracked = WindowToken(pid: 810_401, windowId: 810_402)
        _ = WindowAdmissionTestSupport.track(tracked, in: workspaceId, controller: controller)
        let handler = controller.axEventHandler
        handler.windowInfoProvider = { windowId in
            WindowServerInfo(
                id: windowId,
                pid: 810_499,
                level: 0,
                frame: CGRect(x: 20, y: 20, width: 800, height: 600)
            )
        }

        XCTAssertNil(handler.resolveTrackedToken(UInt32(tracked.windowId)))
        let mismatchedIdentity = handler.resolveWindowServerIdentity(UInt32(tracked.windowId))
        XCTAssertNil(
            handler.resolveTrackedTokenForDestruction(
                UInt32(tracked.windowId),
                pidHint: nil,
                identityResolution: mismatchedIdentity
            )
        )

        handler.windowInfoProvider = { _ in nil }
        let unavailableIdentity = handler.resolveWindowServerIdentity(UInt32(tracked.windowId))
        XCTAssertNil(handler.resolveTrackedToken(UInt32(tracked.windowId)))
        XCTAssertEqual(
            handler.resolveTrackedTokenForDestruction(
                UInt32(tracked.windowId),
                pidHint: nil,
                identityResolution: unavailableIdentity
            ),
            tracked
        )
    }

    func testStaleTitleEventWithReusedWindowIdCannotMutateManagedStateOrScheduleSurfaceWork() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let tracked = WindowToken(pid: 810_451, windowId: 810_452)
        _ = WindowAdmissionTestSupport.track(tracked, in: workspaceId, controller: controller)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.omniwm.tests.stale-title",
                workspaceId: workspaceId,
                mode: .tiling,
                role: nil,
                subrole: nil,
                title: "Original",
                windowLevel: 0,
                parentWindowId: nil,
                frame: CGRect(x: 20, y: 20, width: 800, height: 600)
            ),
            for: tracked
        )
        controller.surfaceReconciler.reconcileNow()
        let worldSeq = controller.workspaceManager.worldSeq
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(
                id: windowId,
                pid: tracked.pid + 1,
                level: 0,
                frame: CGRect(x: 20, y: 20, width: 800, height: 600),
                title: "Reused"
            )
        }

        controller.axEventHandler.handleCGSEvent(.titleChanged(windowId: UInt32(tracked.windowId)))

        XCTAssertEqual(controller.workspaceManager.managedReplacementMetadata(for: tracked)?.title, "Original")
        XCTAssertEqual(controller.workspaceManager.worldSeq, worldSeq)
        XCTAssertNil(controller.surfaceReconciler.pendingReconcileScope)
    }

    func testOrderEventRequiresExactLiveManagedIdentityBeforeRestack() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowServerSubscriptionTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let tracked = WindowToken(pid: 810_501, windowId: 810_502)
        _ = WindowAdmissionTestSupport.track(tracked, in: workspaceId, controller: controller)
        controller.surfaceReconciler.reconcileNow()
        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(
                id: windowId,
                pid: tracked.pid + 1,
                level: 0,
                frame: CGRect(x: 20, y: 20, width: 800, height: 600)
            )
        }

        controller.axEventHandler.handleCGSEvent(.orderChanged(windowId: UInt32(tracked.windowId)))

        XCTAssertNil(controller.surfaceReconciler.pendingReconcileScope)
        XCTAssertFalse(controller.surfaceReconciler.forceOrderingOnNextReconcile)

        controller.axEventHandler.windowInfoProvider = { windowId in
            WindowServerInfo(
                id: windowId,
                pid: tracked.pid,
                level: 0,
                frame: CGRect(x: 20, y: 20, width: 800, height: 600)
            )
        }

        controller.axEventHandler.handleCGSEvent(.orderChanged(windowId: UInt32(tracked.windowId)))

        XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .borderOnly)
        XCTAssertTrue(controller.surfaceReconciler.forceOrderingOnNextReconcile)
    }
}
