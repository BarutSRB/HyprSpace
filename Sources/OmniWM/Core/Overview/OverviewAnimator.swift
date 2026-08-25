// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor
final class OverviewDisplayLinkCallbackProxy: NSObject {
    weak var animator: OverviewAnimator?
    let displayId: CGDirectDisplayID
    let generation: UInt64

    init(animator: OverviewAnimator, displayId: CGDirectDisplayID, generation: UInt64) {
        self.animator = animator
        self.displayId = displayId
        self.generation = generation
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        animator?.displayLinkFired(
            displayLink,
            displayId: displayId,
            generation: generation
        )
    }
}

enum OverviewDisplayLinkHandle {
    case live(CADisplayLink)
    case manual
}

@MainActor
final class OverviewAnimator {
    typealias DisplayLinkFactory = @MainActor (
        CGDirectDisplayID,
        OverviewDisplayLinkCallbackProxy
    ) -> OverviewDisplayLinkHandle?

    typealias MediaTimeProvider = @MainActor () -> CFTimeInterval

    private enum Transition {
        case opening
        case closing(targetWindow: WindowHandle?)
    }

    private final class DisplaySession {
        let callbackProxy: OverviewDisplayLinkCallbackProxy
        let handle: OverviewDisplayLinkHandle
        var endpointScheduled = false
        var traceCaptureGeneration: UInt64 = 0
        var traceSequence: UInt64 = 0

        init(
            callbackProxy: OverviewDisplayLinkCallbackProxy,
            handle: OverviewDisplayLinkHandle
        ) {
            self.callbackProxy = callbackProxy
            self.handle = handle
        }
    }

    private weak var controller: OverviewController?
    private let displayLinkFactory: DisplayLinkFactory
    private let mediaTimeProvider: MediaTimeProvider
    private let animationConfig: SpringConfig = .balanced

    private var animation: SpringAnimation?
    private var transition: Transition?
    private var sessions: [CGDirectDisplayID: DisplaySession] = [:]
    private var lastProgress = 0.0
    private var completionDelivered = false

    private(set) var generation: UInt64 = 0
    private(set) var completedGeneration: UInt64?
    private(set) var completionCount: UInt64 = 0

    var isAnimating: Bool {
        animation != nil
    }

    var currentProgress: Double {
        animation?.value(at: mediaTimeProvider()) ?? lastProgress
    }

    var currentVelocity: Double {
        animation?.velocity(at: mediaTimeProvider()) ?? 0
    }

    var activeDisplayIds: Set<CGDirectDisplayID> {
        Set(sessions.keys)
    }

    init(
        controller: OverviewController,
        displayLinkFactory: @escaping DisplayLinkFactory = OverviewAnimator.makeLiveDisplayLink,
        mediaTimeProvider: @escaping MediaTimeProvider = CACurrentMediaTime
    ) {
        self.controller = controller
        self.displayLinkFactory = displayLinkFactory
        self.mediaTimeProvider = mediaTimeProvider
    }

    func startOpenAnimation(displayIds: [CGDirectDisplayID]) {
        let now = mediaTimeProvider()
        let animation = SpringAnimation(
            from: self.animation?.value(at: now) ?? 0,
            to: 1,
            initialVelocity: self.animation?.velocity(at: now) ?? 0,
            startTime: now,
            config: animationConfig
        )
        beginTransition(
            .opening,
            animation: animation,
            displayIds: displayIds
        )
    }

    func startCloseAnimation(
        targetWindow: WindowHandle?,
        displayIds: [CGDirectDisplayID]
    ) {
        let now = mediaTimeProvider()
        let from = animation?.value(at: now) ?? 1
        let velocity = animation?.velocity(at: now) ?? 0
        let animation = SpringAnimation(
            from: from,
            to: 0,
            initialVelocity: velocity,
            startTime: now,
            config: animationConfig
        )
        beginTransition(
            .closing(targetWindow: targetWindow),
            animation: animation,
            displayIds: displayIds
        )
    }

    func cancelAnimation() {
        if let animation {
            lastProgress = animation.value(at: mediaTimeProvider())
        }
        generation &+= 1
        invalidateAllSessions()
        animation = nil
        transition = nil
        completionDelivered = false
    }

    func tickForTests(
        displayId: CGDirectDisplayID,
        generation: UInt64,
        timestamp: CFTimeInterval,
        targetTimestamp: CFTimeInterval
    ) {
        tick(
            displayId: displayId,
            generation: generation,
            timestamp: timestamp,
            targetTimestamp: targetTimestamp
        )
    }

    func targetWindow() -> WindowHandle? {
        guard case let .closing(targetWindow) = transition else { return nil }
        return targetWindow
    }

    func displayLinkFired(
        _ displayLink: CADisplayLink,
        displayId: CGDirectDisplayID,
        generation: UInt64
    ) {
        tick(
            displayId: displayId,
            generation: generation,
            timestamp: displayLink.timestamp,
            targetTimestamp: displayLink.targetTimestamp
        )
    }

    private func beginTransition(
        _ transition: Transition,
        animation: SpringAnimation,
        displayIds: [CGDirectDisplayID]
    ) {
        generation &+= 1
        invalidateAllSessions()
        completionDelivered = false
        completedGeneration = nil
        self.transition = transition
        lastProgress = animation.from
        self.animation = animation

        let targetDisplayIds = Set(displayIds)
        for displayId in targetDisplayIds {
            startSession(displayId: displayId, generation: generation, endpoint: animation.target)
        }
        if sessions.isEmpty {
            completeTransition(generation: generation)
        }
    }

    private func startSession(
        displayId: CGDirectDisplayID,
        generation: UInt64,
        endpoint: Double
    ) {
        let callbackProxy = OverviewDisplayLinkCallbackProxy(
            animator: self,
            displayId: displayId,
            generation: generation
        )
        guard let handle = displayLinkFactory(displayId, callbackProxy) else {
            controller?.updateAnimationProgress(
                endpoint,
                on: displayId,
                generation: generation,
                sequence: 0
            )
            return
        }

        sessions[displayId] = DisplaySession(
            callbackProxy: callbackProxy,
            handle: handle
        )
        if case let .live(displayLink) = handle {
            displayLink.add(to: .main, forMode: .common)
        }
    }

    private func tick(
        displayId: CGDirectDisplayID,
        generation: UInt64,
        timestamp: CFTimeInterval,
        targetTimestamp: CFTimeInterval
    ) {
        guard generation == self.generation,
              let session = sessions[displayId],
              let animation
        else { return }

        let traceCaptureGeneration = OverviewFrameTrace.shared.captureGeneration
        let traceActive = traceCaptureGeneration != 0
        let startTime = traceActive ? CACurrentMediaTime() : 0
        if traceActive {
            if session.traceCaptureGeneration != traceCaptureGeneration {
                session.traceCaptureGeneration = traceCaptureGeneration
                session.traceSequence = 0
            }
            session.traceSequence &+= 1
        }
        let sequence = session.traceSequence
        let endpointWasScheduled = session.endpointScheduled
        let progress = animation.value(at: targetTimestamp)
        controller?.updateAnimationProgress(
            progress,
            on: displayId,
            generation: generation,
            sequence: sequence
        )

        let endpointIsScheduled = animation.isComplete(at: targetTimestamp)
        if endpointIsScheduled {
            session.endpointScheduled = true
        }

        let sessionCompleted = endpointWasScheduled && animation.isComplete(at: timestamp)
        if sessionCompleted {
            retireSession(displayId, generation: generation)
        }

        guard traceActive else { return }
        let endTime = CACurrentMediaTime()
        OverviewFrameTrace.shared.record(
            OverviewFrameTrace.Record(
                event: .callback,
                mediaTime: endTime,
                displayId: displayId,
                generation: generation,
                sequence: sequence,
                progress: progress,
                durationMs: (endTime - startTime) * 1000,
                waitMs: 0,
                targetLeadMs: (targetTimestamp - timestamp) * 1000,
                pendingInvalidations: 0,
                endpointScheduled: session.endpointScheduled,
                sessionCompleted: sessionCompleted
            )
        )
    }

    private func retireSession(_ displayId: CGDirectDisplayID, generation: UInt64) {
        guard generation == self.generation,
              let session = sessions.removeValue(forKey: displayId)
        else { return }
        invalidate(session)
        if sessions.isEmpty {
            completeTransition(generation: generation)
        }
    }

    private func completeTransition(generation: UInt64) {
        guard generation == self.generation,
              !completionDelivered,
              sessions.isEmpty,
              let transition
        else { return }

        completionDelivered = true
        completedGeneration = generation
        completionCount &+= 1
        animation = nil
        self.transition = nil

        switch transition {
        case .opening:
            lastProgress = 1
            controller?.onAnimationComplete(state: .open)
        case let .closing(targetWindow):
            lastProgress = 0
            controller?.completeCloseTransition(targetWindow: targetWindow)
        }
    }

    private func invalidateAllSessions() {
        for session in sessions.values {
            invalidate(session)
        }
        sessions.removeAll(keepingCapacity: true)
    }

    private func invalidate(_ session: DisplaySession) {
        guard case let .live(displayLink) = session.handle else { return }
        displayLink.remove(from: .main, forMode: .common)
        displayLink.invalidate()
    }

    static func makeLiveDisplayLink(
        displayId: CGDirectDisplayID,
        callbackProxy: OverviewDisplayLinkCallbackProxy
    ) -> OverviewDisplayLinkHandle? {
        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        return .live(
            screen.displayLink(
                target: callbackProxy,
                selector: #selector(OverviewDisplayLinkCallbackProxy.tick(_:))
            )
        )
    }

    deinit {
        MainActor.assumeIsolated {
            invalidateAllSessions()
        }
    }
}
