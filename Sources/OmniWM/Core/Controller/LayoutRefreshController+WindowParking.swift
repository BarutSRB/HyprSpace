// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
extension LayoutRefreshController {
    /// Only the corner park - inactive workspaces and the scratchpad - runs into the clamp macOS
    /// puts on leaving the bottom of a display. Layout-transient hides stay on their own axis,
    /// land exactly where they are told, and have to keep following the target so scrolling
    /// animations stay in step.
    func isSettledCornerPark(
        for entry: WindowState,
        frame: CGRect,
        monitor: Monitor,
        reason: HideReason
    ) -> Bool {
        guard let controller else { return false }
        switch reason {
        case .workspaceInactive,
             .scratchpad:
            break
        case .layoutTransient:
            return false
        }

        return HiddenWindowPlacementResolver.isParked(
            frame: frame,
            baseReveal: Self.hiddenEdgeReveal(isZoomApp: isZoomApp(entry.pid)),
            scale: backingScale(for: monitor),
            monitor: HiddenPlacementMonitorContext(monitor),
            monitors: controller.workspaceManager.monitors.map(HiddenPlacementMonitorContext.init)
        )
    }

    func applyPositionPlans(_ plans: [WindowPositionPlan]) {
        guard let controller, !plans.isEmpty else { return }

        let requiresVisibleAXTokens = controller.axManager.cancelParkFrameJobs(
            plans.map { (pid: $0.entry.pid, windowId: $0.entry.windowId) },
            reason: "revealed"
        )
        controller.axManager.applyPositionsViaSkyLight(
            plans.map { (windowId: $0.entry.windowId, frame: $0.frame) },
            allowInactive: true
        )
        let visibleFrames = plans.compactMap { plan -> AXFrameApplicationTarget? in
            guard requiresVisibleAXTokens.contains(plan.entry.token) else { return nil }
            controller.axManager.markWindowActive(plan.entry.windowId)
            controller.axManager.forceApplyNextFrame(for: plan.entry.windowId)
            return .init(pid: plan.entry.pid, window: plan.entry.axRef, frame: plan.frame)
        }
        if !visibleFrames.isEmpty {
            controller.axManager.unsuppressFrameWrites(
                visibleFrames.map { (pid: $0.pid, windowId: $0.windowId) }
            )
            controller.axManager.applyFramesParallel(visibleFrames)
        }
    }

    func applyParkPositionPlans(
        _ plans: [WindowPositionPlan],
        movablePlans: [WindowPositionPlan],
        animationTick: Bool
    ) {
        guard let controller, !plans.isEmpty else { return }

        if animationTick {
            for plan in plans {
                controller.axManager.markParkPending(.init(
                    pid: plan.entry.pid,
                    window: plan.entry.axRef,
                    frame: plan.frame
                ))
            }
        }

        if !movablePlans.isEmpty {
            controller.axManager.applyPositionsViaSkyLight(
                movablePlans.map { (windowId: $0.entry.windowId, frame: $0.frame) },
                allowInactive: true
            )
        }

        for plan in plans {
            if animationTick {
                controller.axManager.recordSkyLightMove(windowId: plan.entry.windowId, origin: plan.frame.origin)
            }
            FrameApplyTrace.recordEvent(
                pid: plan.entry.pid,
                windowId: plan.entry.windowId,
                outcome: animationTick ? "outcome=sls-parked/animation" : "outcome=sls-parked/settled",
                target: plan.frame
            )
        }

        if animationTick { return }

        controller.axManager.applyParkFramesParallel(
            plans.map {
                AXFrameApplicationTarget(pid: $0.entry.pid, window: $0.entry.axRef, frame: $0.frame)
            }
        )
    }
}
