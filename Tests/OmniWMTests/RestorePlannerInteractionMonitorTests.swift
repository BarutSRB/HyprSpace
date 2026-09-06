// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class RestorePlannerInteractionMonitorTests: XCTestCase {
    func testMissingInteractionSelectsPrimaryBelowSecondary() {
        let (primary, secondary) = monitors(secondaryOrigin: CGPoint(x: 0, y: 1440))

        for monitors in [[primary, secondary], [secondary, primary]] {
            let plan = plan(monitors: monitors)

            XCTAssertEqual(plan.interactionMonitorId, primary.id)
            XCTAssertNil(plan.previousInteractionMonitorId)
        }
    }

    func testMissingInteractionSelectsPrimaryRightOfSecondary() {
        let (primary, secondary) = monitors(secondaryOrigin: CGPoint(x: -3440, y: 0))

        for monitors in [[primary, secondary], [secondary, primary]] {
            XCTAssertEqual(plan(monitors: monitors).interactionMonitorId, primary.id)
        }
    }

    func testStaleInteractionSelectsPrimaryAndPreservesConnectedPrevious() {
        for origin in [CGPoint(x: 0, y: 1440), CGPoint(x: -3440, y: 0)] {
            let (primary, secondary) = monitors(secondaryOrigin: origin)
            let plan = plan(
                monitors: [secondary, primary],
                interactionMonitorId: Monitor.ID(displayId: primary.displayId &+ 2),
                previousInteractionMonitorId: secondary.id
            )

            XCTAssertEqual(plan.interactionMonitorId, primary.id)
            XCTAssertEqual(plan.previousInteractionMonitorId, secondary.id)
        }
    }

    func testConnectedSecondaryInteractionAndPreviousArePreserved() {
        let (primary, secondary) = monitors(secondaryOrigin: CGPoint(x: 0, y: 1440))
        let plan = plan(
            monitors: [primary, secondary],
            interactionMonitorId: secondary.id,
            previousInteractionMonitorId: primary.id
        )

        XCTAssertEqual(plan.interactionMonitorId, secondary.id)
        XCTAssertEqual(plan.previousInteractionMonitorId, primary.id)
    }

    func testStalePreviousInteractionIsCleared() {
        let (primary, secondary) = monitors(secondaryOrigin: CGPoint(x: 0, y: 1440))
        let plan = plan(
            monitors: [primary, secondary],
            interactionMonitorId: secondary.id,
            previousInteractionMonitorId: Monitor.ID(displayId: primary.displayId &+ 2)
        )

        XCTAssertEqual(plan.interactionMonitorId, secondary.id)
        XCTAssertNil(plan.previousInteractionMonitorId)
    }

    func testAbsentPrimaryUsesGeometricOrderRegardlessOfInputOrder() {
        let primaryDisplayId = CGMainDisplayID()
        let lower = monitor(displayId: primaryDisplayId &+ 1, origin: .zero)
        let upper = monitor(displayId: primaryDisplayId &+ 2, origin: CGPoint(x: 0, y: 1440))

        for monitors in [[lower, upper], [upper, lower]] {
            XCTAssertEqual(plan(monitors: monitors).interactionMonitorId, upper.id)
        }
    }

    private func plan(
        monitors: [Monitor],
        interactionMonitorId: Monitor.ID? = nil,
        previousInteractionMonitorId: Monitor.ID? = nil
    ) -> RestorePlanner.EventPlan {
        let sessions = Dictionary(uniqueKeysWithValues: monitors.map {
            ($0.id, MonitorSession(visibleWorkspaceId: WorkspaceDescriptor.ID(), previousVisibleWorkspaceId: nil))
        })
        return RestorePlanner().planEvent(
            .init(
                event: .visibleWorkspacesChanged(sessions: sessions, source: .workspaceManager),
                snapshot: ReconcileSnapshot(
                    topologyProfile: TopologyProfile(monitors: monitors),
                    focusSession: FocusSessionSnapshot(
                        interactionMonitorId: interactionMonitorId,
                        previousInteractionMonitorId: previousInteractionMonitorId
                    ),
                    windows: []
                ),
                monitors: monitors
            )
        )
    }

    private func monitors(secondaryOrigin: CGPoint) -> (Monitor, Monitor) {
        let primaryDisplayId = CGMainDisplayID()
        return (
            monitor(displayId: primaryDisplayId, origin: .zero),
            monitor(displayId: primaryDisplayId &+ 1, origin: secondaryOrigin)
        )
    }

    private func monitor(displayId: CGDirectDisplayID, origin: CGPoint) -> Monitor {
        let frame = CGRect(origin: origin, size: CGSize(width: 3440, height: 1440))
        return Monitor(
            id: Monitor.ID(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Display \(displayId)"
        )
    }
}
