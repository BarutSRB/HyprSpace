// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension LayoutRefreshController {
    @discardableResult
    func applyPositionPlans(
        _ plans: [WindowPositionPlan],
        deferringVisibleAXFor deferredTokens: Set<WindowToken> = []
    ) -> Set<WindowToken> {
        guard let controller, !plans.isEmpty else { return [] }
        let plans = plans.filter { !controller.workspaceManager.isAppHidden(pid: $0.entry.pid) }
        guard !plans.isEmpty else { return [] }

        var requiresVisibleAXTokens = controller.axManager.cancelParkFrameJobs(
            plans.map { (pid: $0.entry.pid, windowId: $0.entry.windowId) },
            reason: "revealed"
        )
        controller.axManager.applyPositionsViaSkyLight(
            plans.map { (pid: $0.entry.pid, windowId: $0.entry.windowId, frame: $0.frame) },
            allowInactive: true
        )
        let visibleFrames = plans.compactMap { plan -> AXFrameApplicationTarget? in
            guard requiresVisibleAXTokens.contains(plan.entry.token) else { return nil }
            if deferredTokens.contains(plan.entry.token) {
                return nil
            }
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
        requiresVisibleAXTokens.formIntersection(deferredTokens)
        return requiresVisibleAXTokens
    }

    func applyParkPositionPlans(
        _ plans: [WindowPositionPlan],
        movablePlans: [WindowPositionPlan],
        animationTick: Bool
    ) {
        guard let controller, !plans.isEmpty else { return }
        let plans = plans.filter { !controller.workspaceManager.isAppHidden(pid: $0.entry.pid) }
        guard !plans.isEmpty else { return }
        let movablePlans = movablePlans.filter {
            !controller.workspaceManager.isAppHidden(pid: $0.entry.pid)
        }

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
                movablePlans.map { (pid: $0.entry.pid, windowId: $0.entry.windowId, frame: $0.frame) },
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
