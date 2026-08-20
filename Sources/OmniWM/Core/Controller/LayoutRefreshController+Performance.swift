// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

extension LayoutRefreshController {
    struct PerformanceSnapshot: Equatable, Sendable {
        let refreshesEnqueued: UInt64
        let refreshesMerged: UInt64
        let refreshesStarted: UInt64
        let refreshesCompleted: UInt64
        let refreshesIncomplete: UInt64
        let lockedRefreshDeferrals: UInt64
        let immediateRefreshRestarts: UInt64
        let maximumConsecutiveRequeues: UInt64
        let displayLinksCreated: UInt64
        let displayLinksInvalidated: UInt64
        let displayLinkCallbacks: UInt64
        let meaningfulDisplayLinkCallbacks: UInt64
        let noWorkDisplayLinkCallbacks: UInt64
        let activeDisplayLinks: Int
        let activeDisplayLinkHighWater: Int
        let displayLinkIdleStops: UInt64
        let displayLinkNoWorkStops: UInt64
        let displayLinkMonitorDisconnectStops: UInt64
        let displayLinkResetStops: UInt64
    }

    struct PerformanceCounters {
        var refreshesEnqueued: UInt64 = 0
        var refreshesMerged: UInt64 = 0
        var refreshesStarted: UInt64 = 0
        var refreshesCompleted: UInt64 = 0
        var refreshesIncomplete: UInt64 = 0
        var lockedRefreshDeferrals: UInt64 = 0
        var immediateRefreshRestarts: UInt64 = 0
        var consecutiveRequeues: UInt64 = 0
        var maximumConsecutiveRequeues: UInt64 = 0
        var displayLinksCreated: UInt64 = 0
        var displayLinksInvalidated: UInt64 = 0
        var displayLinkCallbacks: UInt64 = 0
        var meaningfulDisplayLinkCallbacks: UInt64 = 0
        var noWorkDisplayLinkCallbacks: UInt64 = 0
        var activeDisplayLinks: Int = 0
        var activeDisplayLinkHighWater: Int = 0
        var displayLinkIdleStops: UInt64 = 0
        var displayLinkNoWorkStops: UInt64 = 0
        var displayLinkMonitorDisconnectStops: UInt64 = 0
        var displayLinkResetStops: UInt64 = 0

        var snapshot: PerformanceSnapshot {
            PerformanceSnapshot(
                refreshesEnqueued: refreshesEnqueued,
                refreshesMerged: refreshesMerged,
                refreshesStarted: refreshesStarted,
                refreshesCompleted: refreshesCompleted,
                refreshesIncomplete: refreshesIncomplete,
                lockedRefreshDeferrals: lockedRefreshDeferrals,
                immediateRefreshRestarts: immediateRefreshRestarts,
                maximumConsecutiveRequeues: maximumConsecutiveRequeues,
                displayLinksCreated: displayLinksCreated,
                displayLinksInvalidated: displayLinksInvalidated,
                displayLinkCallbacks: displayLinkCallbacks,
                meaningfulDisplayLinkCallbacks: meaningfulDisplayLinkCallbacks,
                noWorkDisplayLinkCallbacks: noWorkDisplayLinkCallbacks,
                activeDisplayLinks: activeDisplayLinks,
                activeDisplayLinkHighWater: activeDisplayLinkHighWater,
                displayLinkIdleStops: displayLinkIdleStops,
                displayLinkNoWorkStops: displayLinkNoWorkStops,
                displayLinkMonitorDisconnectStops: displayLinkMonitorDisconnectStops,
                displayLinkResetStops: displayLinkResetStops
            )
        }
    }

    func beginPerformanceCapture() {
        let activeDisplayLinks = activeDisplayLinkCountForTests?()
            ?? layoutState.displayLinksByDisplay.count
        performanceCounters = PerformanceCounters(
            activeDisplayLinks: activeDisplayLinks,
            activeDisplayLinkHighWater: activeDisplayLinks
        )
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        performanceCounters?.snapshot
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceCounters?.snapshot
        performanceCounters = nil
        return snapshot
    }
}
