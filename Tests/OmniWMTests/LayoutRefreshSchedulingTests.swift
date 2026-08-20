// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class LayoutRefreshSchedulingTests: XCTestCase {
    func testAllRefreshKindsRemainMergedAcrossActorDrainsAndExecuteOnceAfterUnlock() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer {
            refreshController.resetState()
            controller.isLockScreenActive = false
        }
        let workspaceId = WorkspaceDescriptor.ID()
        let refreshes = [
            LayoutRefreshController.ScheduledRefresh(
                kind: .fullRescan,
                reason: .startup
            ),
            LayoutRefreshController.ScheduledRefresh(
                kind: .relayout,
                reason: .layoutConfigChanged,
                affectedWorkspaceIds: [workspaceId]
            ),
            LayoutRefreshController.ScheduledRefresh(
                kind: .immediateRelayout,
                reason: .layoutCommand,
                affectedWorkspaceIds: [workspaceId]
            ),
            LayoutRefreshController.ScheduledRefresh(
                kind: .visibilityRefresh,
                reason: .appHidden,
                affectedWorkspaceIds: [workspaceId]
            ),
            LayoutRefreshController.ScheduledRefresh(
                kind: .windowRemoval,
                reason: .windowDestroyed,
                affectedWorkspaceIds: [workspaceId]
            )
        ]

        refreshController.beginPerformanceCapture()
        controller.isLockScreenActive = true
        for refresh in refreshes {
            refreshController.enqueueRefresh(refresh)
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        XCTAssertNil(refreshController.layoutState.activeRefresh)
        XCTAssertNil(refreshController.layoutState.activeRefreshTask)
        XCTAssertEqual(refreshController.layoutState.pendingRefresh?.kind, .fullRescan)
        let lockedMetrics = try XCTUnwrap(refreshController.performanceSnapshot())
        XCTAssertEqual(lockedMetrics.refreshesEnqueued, 5)
        XCTAssertEqual(lockedMetrics.refreshesMerged, 4)
        XCTAssertEqual(lockedMetrics.refreshesStarted, 0)
        XCTAssertEqual(lockedMetrics.lockedRefreshDeferrals, 5)

        controller.isLockScreenActive = false
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertTrue(refreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertTrue(refreshController.layoutState.isAwaitingPostUnlockTopologySample)
        XCTAssertEqual(refreshController.performanceSnapshot()?.refreshesStarted, 0)

        refreshController.resumeAfterPostUnlockTopologySample()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        let unlockedMetrics = try XCTUnwrap(refreshController.endPerformanceCapture())
        XCTAssertEqual(unlockedMetrics.refreshesStarted, 1)
        XCTAssertEqual(unlockedMetrics.refreshesCompleted, 1)
        XCTAssertEqual(unlockedMetrics.refreshesIncomplete, 0)
        XCTAssertNil(refreshController.layoutState.activeRefresh)
        XCTAssertNil(refreshController.layoutState.pendingRefresh)
    }

    func testLockSuspendsAndMergesRefreshesUntilUnlock() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let firstWorkspaceId = WorkspaceDescriptor.ID()
        let secondWorkspaceId = WorkspaceDescriptor.ID()
        defer {
            refreshController.resetState()
            controller.isLockScreenActive = false
        }

        refreshController.beginPerformanceCapture()
        controller.isLockScreenActive = true
        refreshController.requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: [firstWorkspaceId]
        )
        refreshController.requestImmediateRelayout(
            reason: .interactiveGesture,
            affectedWorkspaceIds: [secondWorkspaceId]
        )

        XCTAssertTrue(refreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertNil(refreshController.layoutState.activeRefresh)
        XCTAssertNil(refreshController.layoutState.activeRefreshTask)
        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(
            pending.affectedWorkspaceIds,
            [firstWorkspaceId, secondWorkspaceId]
        )

        controller.isLockScreenActive = false

        XCTAssertTrue(refreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertTrue(refreshController.layoutState.isAwaitingPostUnlockTopologySample)
        XCTAssertNil(refreshController.layoutState.activeRefresh)
        XCTAssertEqual(refreshController.performanceSnapshot()?.refreshesStarted, 0)

        refreshController.resumeAfterPostUnlockTopologySample()

        XCTAssertFalse(refreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertFalse(refreshController.layoutState.isAwaitingPostUnlockTopologySample)
        XCTAssertEqual(refreshController.layoutState.activeRefresh?.kind, .immediateRelayout)
        XCTAssertNil(refreshController.layoutState.pendingRefresh)
        let metrics = try XCTUnwrap(refreshController.endPerformanceCapture())
        XCTAssertEqual(metrics.refreshesEnqueued, 2)
        XCTAssertEqual(metrics.refreshesMerged, 1)
        XCTAssertEqual(metrics.refreshesStarted, 1)
        XCTAssertEqual(metrics.lockedRefreshDeferrals, 2)
    }

    func testRelockInvalidatesPriorPostUnlockTopologySample() {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer {
            refreshController.resetState()
            controller.isLockScreenActive = false
        }
        refreshController.beginPerformanceCapture()
        controller.isLockScreenActive = true
        refreshController.requestImmediateRelayout(reason: .layoutCommand)

        controller.isLockScreenActive = false
        XCTAssertTrue(refreshController.layoutState.isAwaitingPostUnlockTopologySample)
        controller.isLockScreenActive = true
        XCTAssertFalse(refreshController.layoutState.isAwaitingPostUnlockTopologySample)

        refreshController.resumeAfterPostUnlockTopologySample()
        XCTAssertTrue(refreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertEqual(refreshController.performanceSnapshot()?.refreshesStarted, 0)

        controller.isLockScreenActive = false
        refreshController.resumeAfterPostUnlockTopologySample()

        XCTAssertFalse(refreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertEqual(refreshController.performanceSnapshot()?.refreshesStarted, 1)
        _ = refreshController.endPerformanceCapture()
    }

    func testVisibilityRefreshesDuringFullRescanCoalesceIntoOnePendingCycle() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }
        var actionRefreshKinds: [LayoutRefreshController.ScheduledRefreshKind] = []
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [901], nativeSpaceIds: [])
        )
        defer { refreshController.resetState() }

        refreshController.startNextRefreshIfNeeded()
        refreshController.enqueueRefresh(
            .init(
                kind: .visibilityRefresh,
                reason: .appHidden,
                postLayout: RefreshPostLayoutAction(action: {
                    if let kind = refreshController.layoutState.activeRefresh?.kind {
                        actionRefreshKinds.append(kind)
                    }
                })
            )
        )
        refreshController.enqueueRefresh(
            .init(
                kind: .visibilityRefresh,
                reason: .appUnhidden,
                postLayout: RefreshPostLayoutAction(action: {
                    if let kind = refreshController.layoutState.activeRefresh?.kind {
                        actionRefreshKinds.append(kind)
                    }
                })
            )
        )

        let active = try XCTUnwrap(refreshController.layoutState.activeRefresh)
        XCTAssertEqual(active.kind, .fullRescan)
        XCTAssertTrue(active.postLayoutActions.isEmpty)
        XCTAssertFalse(active.needsVisibilityReconciliation)

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .visibilityRefresh)
        XCTAssertEqual(pending.reason, .appUnhidden)
        XCTAssertEqual(pending.postLayoutActions.count, 2)

        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(actionRefreshKinds, [.visibilityRefresh, .visibilityRefresh])
        XCTAssertNil(refreshController.layoutState.activeRefresh)
        XCTAssertNil(refreshController.layoutState.pendingRefresh)
        let trace = AppVisibilityTrace.shared.dump()
        XCTAssertTrue(trace.contains("event=refresh visibility=hidden outcome=queued"))
        XCTAssertTrue(trace.contains("event=refresh visibility=visible outcome=coalesced"))
        XCTAssertTrue(trace.contains("event=refresh visibility=visible outcome=started"))
        XCTAssertTrue(trace.contains("event=refresh visibility=visible outcome=completed"))
    }
}
