// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    private enum DisplayLinkStopReason {
        case idle
        case noWork
        case monitorDisconnect
        case reset
    }

    func setup() {
        detectRefreshRates()
        layoutState.screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    private func getOrCreateDisplayLink(for displayId: CGDirectDisplayID) -> CADisplayLink? {
        if let existing = layoutState.displayLinksByDisplay[displayId] {
            return existing
        }
        if displayLinkCreationAllowedForTests?(displayId) == false {
            return nil
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        layoutState.displayLinksByDisplay[displayId] = link
        if var counters = performanceCounters {
            counters.displayLinksCreated &+= 1
            counters.activeDisplayLinks = layoutState.displayLinksByDisplay.count
            counters.activeDisplayLinkHighWater = max(
                counters.activeDisplayLinkHighWater,
                counters.activeDisplayLinks
            )
            performanceCounters = counters
        }
        return link
    }

    private func handleScreenParametersChanged() {
        detectRefreshRates()
        controller?.syncMonitorsToNiriEngine()
        controller?.surfaceReconciler.noteWorldChanged()
    }

    func cleanupForMonitorDisconnect(displayId: CGDirectDisplayID, migrateAnimations: Bool) {
        if let workspaceId = niriHandler.scrollAnimationByDisplay[displayId] {
            niriHandler.terminateViewportGesture(
                for: workspaceId,
                disposition: .settleLiveOffset
            )
        }
        invalidateDisplayLink(for: displayId, reason: .monitorDisconnect)

        if let animations = layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId) {
            for animation in animations.values {
                forgetClosingAnimation(animation)
            }
        }

        if migrateAnimations {
            if let workspaceId = niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId) {
                startScrollAnimation(for: workspaceId)
            }
        } else if let workspaceId = niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId) {
            niriHandler.cancelAnimationMotion(for: workspaceId)
        }
        stopDwindleAnimation(for: displayId)
    }

    private func detectRefreshRates() {
        layoutState.refreshRateByDisplay.removeAll()
        for screen in NSScreen.screens {
            guard let displayId = screen.displayId else { continue }
            layoutState.refreshRateByDisplay[displayId] = Monitor.refreshRate(for: displayId)
        }
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        guard let displayId = layoutState.displayLinksByDisplay.first(where: { $0.value === displayLink })?.key
        else { return }
        performanceCounters?.displayLinkCallbacks &+= 1
        guard hasDisplayLinkWork(for: displayId) else {
            performanceCounters?.noWorkDisplayLinkCallbacks &+= 1
            stopDisplayLinkIfIdle(for: displayId, reason: .noWork)
            return
        }
        performanceCounters?.meaningfulDisplayLinkCallbacks &+= 1

        let traceActive = AnimationTickTrace.shared.isActive
        let startTime = traceActive ? CACurrentMediaTime() : 0
        var scrollEndTime: CFTimeInterval = 0
        var dwindleEndTime: CFTimeInterval = 0
        var closingEndTime: CFTimeInterval = 0

        SkyLight.shared.withTransactionScope {
            niriHandler.tickScrollAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
            scrollEndTime = traceActive ? CACurrentMediaTime() : 0
            dwindleHandler.tickDwindleAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
            dwindleEndTime = traceActive ? CACurrentMediaTime() : 0
            tickClosingAnimations(targetTime: displayLink.targetTimestamp, displayId: displayId)
            closingEndTime = traceActive ? CACurrentMediaTime() : 0
            controller?.surfaceReconciler.reconcileAnimationTick()
        }
        stopDisplayLinkIfIdle(for: displayId)
        auditParkVisibility(displayId: displayId)

        guard traceActive else { return }
        let endTime = CACurrentMediaTime()
        let previousTimestamp = layoutState.lastDisplayLinkTimestampByDisplay[displayId]
        layoutState.lastDisplayLinkTimestampByDisplay[displayId] = displayLink.timestamp

        let expectedMs = displayLink.duration * 1000
        let intervalMs = previousTimestamp.map { (displayLink.timestamp - $0) * 1000 } ?? 0
        let totalMs = (endTime - startTime) * 1000
        let dropped = previousTimestamp != nil && intervalMs > 1.5 * expectedMs
            || expectedMs > 0 && totalMs > expectedMs

        AnimationTickTrace.shared.record(
            AnimationTickTrace.Record(
                mediaTime: endTime,
                displayId: displayId,
                intervalMs: intervalMs,
                expectedMs: expectedMs,
                scrollMs: (scrollEndTime - startTime) * 1000,
                dwindleMs: (dwindleEndTime - scrollEndTime) * 1000,
                closingMs: (closingEndTime - dwindleEndTime) * 1000,
                reconcileMs: (endTime - closingEndTime) * 1000,
                totalMs: totalMs,
                dropped: dropped
            )
        )
    }

    func startScrollAnimation(for workspaceId: WorkspaceDescriptor.ID, forGesture: Bool = false) {
        guard forGesture || controller?.motionPolicy.animationsEnabled != false else { return }
        guard let controller else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else {
            niriHandler.cancelActiveAnimations(for: workspaceId)
            return
        }
        let targetDisplayId = monitor.displayId

        let registrationChanged = niriHandler.registerScrollAnimation(workspaceId, on: targetDisplayId)
        if displayLinkActivationForTests?(targetDisplayId) == true {
            return
        }
        if !registrationChanged, layoutState.displayLinksByDisplay[targetDisplayId] != nil {
            return
        }
        guard let displayLink = getOrCreateDisplayLink(for: targetDisplayId) else {
            niriHandler.cancelAnimationMotion(for: workspaceId, gestureDisposition: .settleLiveOffset)
            niriHandler.scrollAnimationByDisplay.removeValue(forKey: targetDisplayId)
            return
        }
        displayLink.add(to: .main, forMode: .common)
    }

    func stopScrollAnimation(for displayId: CGDirectDisplayID) {
        if let workspaceId = niriHandler.scrollAnimationByDisplay[displayId] {
            niriHandler.terminateViewportGesture(
                for: workspaceId,
                disposition: .settleLiveOffset
            )
        }
        niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllScrollAnimations() {
        let displayIds = Array(niriHandler.scrollAnimationByDisplay.keys)
        for workspaceId in Set(niriHandler.scrollAnimationByDisplay.values) {
            niriHandler.terminateViewportGesture(
                for: workspaceId,
                disposition: .settleLiveOffset
            )
        }
        niriHandler.scrollAnimationByDisplay.removeAll()
        for displayId in displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func acceptDwindleAnimationTarget(
        _ disposition: DwindleAnimationTargetDisposition,
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        plannedSeq: UInt64
    ) {
        let detachedDisplayIds = dwindleHandler.acceptAnimationTarget(
            disposition,
            workspaceId: workspaceId,
            displayId: displayId,
            plannedSeq: plannedSeq
        )
        for detachedDisplayId in detachedDisplayIds {
            stopDisplayLinkIfIdle(for: detachedDisplayId)
        }
    }

    func suspendStaleDwindleAnimation(
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID
    ) {
        let shouldRequestRelayout = dwindleHandler.suspendStaleAnimation(
            workspaceId: workspaceId,
            displayId: displayId
        )
        stopDisplayLinkIfIdle(for: displayId)
        guard shouldRequestRelayout else { return }
        requestRelayout(
            reason: .staleLayoutPlan,
            affectedWorkspaceIds: [workspaceId]
        )
    }

    func startDwindleAnimation(for workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        let targetDisplayId = monitor.displayId
        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId else {
            for displayId in dwindleHandler.animationDisplayIds(for: workspaceId) {
                stopDwindleAnimation(for: displayId)
            }
            controller.dwindleEngine?.cancelAnimations(in: workspaceId)
            return
        }
        guard controller.motionPolicy.animationsEnabled else {
            stopDwindleAnimation(for: targetDisplayId)
            return
        }
        guard dwindleHandler.animationSessionByDisplay[targetDisplayId]?.workspaceId == workspaceId else {
            stopDwindleAnimation(for: targetDisplayId)
            controller.dwindleEngine?.cancelAnimations(in: workspaceId)
            return
        }

        let registrationChanged = dwindleHandler.registerDwindleAnimation(
            workspaceId,
            monitor: monitor,
            on: targetDisplayId
        )
        if displayLinkActivationForTests?(targetDisplayId) == true {
            return
        }
        if !registrationChanged, layoutState.displayLinksByDisplay[targetDisplayId] != nil {
            return
        }

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        } else {
            stopDwindleAnimation(for: targetDisplayId)
        }
    }

    func startWindowCloseAnimation(entry: WindowState, monitor: Monitor) {
        guard controller?.motionPolicy.animationsEnabled != false else { return }
        guard entry.interactionPolicy.mayWriteFrame else { return }
        guard let controller else { return }
        guard !controller.workspaceManager.isAppHidden(entry.token) else { return }
        guard let frame = fastFrame(for: entry.token, axRef: entry.axRef) else { return }

        let displacement = CGPoint(x: 0, y: -12)
        let animation = SpringAnimation(
            from: 0,
            to: 1,
            startTime: CACurrentMediaTime(),
            config: .balanced.with(epsilon: 0.01, velocityEpsilon: 0.1),
            displayRefreshRate: layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0
        )

        var animations = layoutState.closingAnimationsByDisplay[monitor.displayId] ?? [:]
        guard animations[entry.windowId] == nil else { return }
        animations[entry.windowId] = LayoutRefreshState.ClosingAnimation(
            pid: entry.pid,
            windowId: entry.windowId,
            axRef: entry.axRef,
            fromFrame: frame,
            displacement: displacement,
            animation: animation
        )
        _ = closingAnimationId(for: animation)
        layoutState.closingAnimationsByDisplay[monitor.displayId] = animations

        guard let displayLink = getOrCreateDisplayLink(for: monitor.displayId) else {
            rollbackClosingAnimationRegistration(windowId: entry.windowId, displayId: monitor.displayId)
            return
        }
        displayLink.add(to: .main, forMode: .common)
    }

    func cancelFrameAnimations(forPID pid: pid_t) {
        let displayIds = Array(layoutState.closingAnimationsByDisplay.keys)
        for displayId in displayIds {
            guard var animations = layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
            else { continue }
            let removedWindowIds = animations.compactMap { windowId, animation in
                animation.pid == pid ? windowId : nil
            }
            for windowId in removedWindowIds {
                if let animation = animations.removeValue(forKey: windowId) {
                    forgetClosingAnimation(animation)
                }
            }
            if animations.isEmpty {
                layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
                stopDisplayLinkIfIdle(for: displayId)
            } else {
                layoutState.closingAnimationsByDisplay[displayId] = animations
            }
        }
    }

    func stopDwindleAnimation(for displayId: CGDirectDisplayID) {
        for workspaceId in dwindleHandler.removeAnimationState(for: displayId) {
            controller?.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllDwindleAnimations() {
        let removed = dwindleHandler.removeAllAnimationState()
        for workspaceId in removed.workspaceIds {
            controller?.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        for displayId in removed.displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleHandler.hasDwindleAnimationRunning(in: workspaceId)
    }

    func resetDisplayLinkAndAnimationState() {
        let niriWorkspaceIds = Set(niriHandler.scrollAnimationByDisplay.values)
        let removedDwindleState = dwindleHandler.removeAllAnimationState()
        for workspaceId in niriWorkspaceIds {
            niriHandler.cancelAnimationMotion(
                for: workspaceId,
                gestureDisposition: .settleLiveOffsetWithoutRelayout
            )
        }
        for displayId in Array(layoutState.displayLinksByDisplay.keys) {
            invalidateDisplayLink(for: displayId, reason: .reset)
        }
        niriHandler.scrollAnimationByDisplay.removeAll()
        for workspaceId in removedDwindleState.workspaceIds {
            controller?.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        layoutState.closingAnimationsByDisplay.removeAll()
        closingAnimationIdsByObjectId.removeAll(keepingCapacity: true)
        lastSubmittedClosingFramesByAnimationId.removeAll(keepingCapacity: true)
    }

    private func rollbackClosingAnimationRegistration(windowId: Int, displayId: CGDirectDisplayID) {
        var animations = layoutState.closingAnimationsByDisplay[displayId] ?? [:]
        if let animation = animations.removeValue(forKey: windowId) {
            forgetClosingAnimation(animation)
        }
        if animations.isEmpty {
            layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
        } else {
            layoutState.closingAnimationsByDisplay[displayId] = animations
        }
    }

    private func stopDisplayLinkIfIdle(
        for displayId: CGDirectDisplayID,
        reason: DisplayLinkStopReason = .idle
    ) {
        if niriHandler.scrollAnimationByDisplay[displayId] == nil,
           dwindleHandler.dwindleAnimationByDisplay[displayId] == nil,
           layoutState.closingAnimationsByDisplay[displayId].map({ $0.isEmpty }) ?? true
        {
            invalidateDisplayLink(for: displayId, reason: reason)
            scheduleTrailingParkAudits(displayId: displayId)
        }
    }

    private func invalidateDisplayLink(
        for displayId: CGDirectDisplayID,
        reason: DisplayLinkStopReason
    ) {
        guard let link = layoutState.displayLinksByDisplay.removeValue(forKey: displayId) else { return }
        link.invalidate()
        layoutState.lastDisplayLinkTimestampByDisplay.removeValue(forKey: displayId)
        performanceCounters?.displayLinksInvalidated &+= 1
        performanceCounters?.activeDisplayLinks = layoutState.displayLinksByDisplay.count
        switch reason {
        case .idle:
            performanceCounters?.displayLinkIdleStops &+= 1
        case .noWork:
            performanceCounters?.displayLinkNoWorkStops &+= 1
        case .monitorDisconnect:
            performanceCounters?.displayLinkMonitorDisconnectStops &+= 1
        case .reset:
            performanceCounters?.displayLinkResetStops &+= 1
        }
    }

    private func hasDisplayLinkWork(for displayId: CGDirectDisplayID) -> Bool {
        niriHandler.scrollAnimationByDisplay[displayId] != nil
            || dwindleHandler.dwindleAnimationByDisplay[displayId] != nil
            || !(layoutState.closingAnimationsByDisplay[displayId]?.isEmpty ?? true)
    }

    private func scheduleTrailingParkAudits(displayId: CGDirectDisplayID) {
        guard ParkVisibilityAudit.shared.isActive else { return }
        layoutState.trailingAuditTask?.cancel()
        layoutState.trailingAuditTask = Task { @MainActor [weak self] in
            for _ in 0 ..< 30 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.auditParkVisibility(displayId: displayId)
            }
        }
    }

    private func closingAnimationId(for animation: SpringAnimation) -> UUID {
        let objectId = ObjectIdentifier(animation)
        if let animationId = closingAnimationIdsByObjectId[objectId] {
            return animationId
        }
        let animationId = UUID()
        closingAnimationIdsByObjectId[objectId] = animationId
        return animationId
    }

    private func forgetClosingAnimation(_ animation: LayoutRefreshState.ClosingAnimation) {
        guard let animationId = closingAnimationIdsByObjectId.removeValue(
            forKey: ObjectIdentifier(animation.animation)
        ) else {
            return
        }
        lastSubmittedClosingFramesByAnimationId.removeValue(forKey: animationId)
    }

    private func tickClosingAnimations(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard var animations = layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId),
              !animations.isEmpty
        else {
            return
        }

        var completedWindowIds: [Int] = []
        completedWindowIds.reserveCapacity(animations.count)
        var targets: [AXClosingFrameTarget] = []
        targets.reserveCapacity(animations.count)

        for (windowId, animation) in animations {
            if controller?.workspaceManager.isAppHidden(pid: animation.pid) == true {
                completedWindowIds.append(windowId)
                continue
            }
            let frame = animation.currentFrame(at: targetTime)
            let animationId = closingAnimationId(for: animation.animation)
            targets.append(
                AXClosingFrameTarget(
                    animationId: animationId,
                    pid: animation.pid,
                    expectedWindow: animation.axRef,
                    frame: frame,
                    currentFrameHint: lastSubmittedClosingFramesByAnimationId[animationId]
                        ?? animation.fromFrame
                )
            )
            lastSubmittedClosingFramesByAnimationId[animationId] = frame
            if animation.isComplete(at: targetTime) {
                completedWindowIds.append(windowId)
            }
        }

        controller?.axManager.applyClosingFrames(targets)

        for windowId in completedWindowIds {
            if let animation = animations.removeValue(forKey: windowId) {
                forgetClosingAnimation(animation)
            }
        }

        if animations.isEmpty {
            stopDisplayLinkIfIdle(for: displayId)
        } else {
            layoutState.closingAnimationsByDisplay[displayId] = animations
        }
    }
}
