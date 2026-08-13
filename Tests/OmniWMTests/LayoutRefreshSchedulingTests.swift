// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class LayoutRefreshSchedulingTests: XCTestCase {
    func testVisibilityRefreshesDuringFullRescanCoalesceIntoOnePendingCycle() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
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
    }
}
