// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

struct LayoutRefreshState {
    struct ClosingAnimation {
        let pid: pid_t
        let windowId: Int
        let axRef: AXWindowRef
        let fromFrame: CGRect
        let displacement: CGPoint
        let animation: SpringAnimation

        func progress(at time: TimeInterval) -> Double {
            animation.value(at: time)
        }

        func isComplete(at time: TimeInterval) -> Bool {
            animation.isComplete(at: time)
        }

        func currentFrame(at time: TimeInterval) -> CGRect {
            let clamped = min(max(progress(at: time), 0), 1)
            let offset = CGPoint(
                x: displacement.x * CGFloat(clamped),
                y: displacement.y * CGFloat(clamped)
            )
            return fromFrame.offsetBy(dx: offset.x, dy: offset.y)
        }
    }

    var activeRefreshTask: Task<Void, Never>?
    var activeRefresh: LayoutRefreshController.ScheduledRefresh?
    var pendingRefresh: LayoutRefreshController.ScheduledRefresh?
    var isRefreshSuspendedForLockScreen = false
    var isAwaitingPostUnlockTopologySample = false
    var isImmediateLayoutInProgress: Bool = false
    var isIncrementalRefreshInProgress: Bool = false
    var activeFullEnumerationCount: Int = 0
    var displayLinksByDisplay: [CGDirectDisplayID: CADisplayLink] = [:]
    var lastTickTimestampByDisplay: [CGDirectDisplayID: CFTimeInterval] = [:]
    var lastParkAuditTime: CFTimeInterval = 0
    var trailingAuditTask: Task<Void, Never>?
    var refreshRateByDisplay: [CGDirectDisplayID: Double] = [:]
    var closingAnimationsByDisplay: [CGDirectDisplayID: [Int: ClosingAnimation]] = [:]
    var screenChangeObserver: NSObjectProtocol?
    var hasCompletedInitialRefresh: Bool = false
    var didExecuteEffectPlan: Bool = false
    var refreshGeneration: UInt64 = 0
    var pendingDebounceTask: Task<Void, Never>?
    var missingConfirmationTask: Task<Void, Never>?
    var pendingMissingConfirmationScope: RescanScope?
    var consecutiveMissCountByHandle: [WindowHandle: Int] = [:]
    var inventoryStabilityBarrierActive = false
    var inventoryStabilityHoldFullRescans = false
    var inventoryStabilityHeldFullRescan: LayoutRefreshController.ScheduledRefresh?
}
