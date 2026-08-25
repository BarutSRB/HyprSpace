// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import QuartzCore

@MainActor
final class AnimationDriver {
    nonisolated static let gestureWorkingAreaMovement: Double = 1200.0

    struct GestureSessionID: Equatable {
        fileprivate let rawValue: UInt64
    }

    final class ViewportGesture {
        private static let minimumFlingVelocity: Double = 100.0

        let tracker = SwipeTracker()
        let isTrackpad: Bool
        let sessionID: GestureSessionID
        private(set) var normFactor: Double = 1.0
        private(set) var lastUpdateTime: TimeInterval

        init(
            isTrackpad: Bool,
            sessionID: GestureSessionID,
            livenessTimestamp: TimeInterval
        ) {
            self.isTrackpad = isTrackpad
            self.sessionID = sessionID
            lastUpdateTime = livenessTimestamp
        }

        var relativeOffset: Double {
            let offset = tracker.position * normFactor
            return offset.isFinite ? offset : 0
        }

        var velocity: Double {
            let scaledVelocity = tracker.velocity() * normFactor
            guard scaledVelocity.isFinite else { return 0 }
            return abs(scaledVelocity) < Self.minimumFlingVelocity ? 0 : scaledVelocity
        }

        var relativeProjectedOffset: Double {
            let projectedOffset = relativeOffset - velocity / DecelerationAnimation.decayRate
            return projectedOffset.isFinite ? projectedOffset : relativeOffset
        }

        func update(
            delta: Double,
            timestamp: TimeInterval,
            viewportWidth: Double,
            livenessTimestamp: TimeInterval
        ) {
            guard delta.isFinite,
                  timestamp.isFinite,
                  viewportWidth.isFinite,
                  livenessTimestamp.isFinite
            else { return }
            guard tracker.push(delta: delta, timestamp: timestamp) else { return }
            lastUpdateTime = livenessTimestamp
            if isTrackpad {
                let nextNormFactor = viewportWidth / AnimationDriver.gestureWorkingAreaMovement
                normFactor = nextNormFactor.isFinite ? nextNormFactor : 1
            }
        }
    }

    enum ViewportMotion {
        case gesture(ViewportGesture)
        case spring(SpringAnimation)
        case deceleration(DecelerationAnimation)
    }

    enum TickResult: Equatable {
        case inactive
        case running
        case expiredGesture(relativeOffset: Double, sessionID: GestureSessionID)

        var isRunning: Bool {
            self == .running
        }
    }

    struct GestureEndSample {
        let relativeOffset: Double
        let relativeProjectedOffset: Double
    }

    private var motions: [WorkspaceDescriptor.ID: ViewportMotion] = [:]
    private var nextGestureSessionID: UInt64 = 1
    private static let gestureLivenessInterval: TimeInterval = 1
    var gestureLivenessNow: @MainActor () -> TimeInterval = { CACurrentMediaTime() }

    func hasMotion(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        motions[workspaceId] != nil
    }

    func hasGesture(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if case .gesture = motions[workspaceId] { return true }
        return false
    }

    func trackpadGestureActive(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if case let .gesture(gesture) = motions[workspaceId] { return gesture.isTrackpad }
        return false
    }

    func liveViewOffset(
        in workspaceId: WorkspaceDescriptor.ID,
        semanticOffset: CGFloat,
        at time: TimeInterval = CACurrentMediaTime()
    ) -> CGFloat? {
        switch motions[workspaceId] {
        case let .gesture(gesture):
            semanticOffset + CGFloat(gesture.relativeOffset)
        case let .spring(animation):
            CGFloat(animation.value(at: time))
        case let .deceleration(animation):
            CGFloat(animation.value(at: time))
        case nil:
            nil
        }
    }

    func settledVisibilityOffset(
        in workspaceId: WorkspaceDescriptor.ID,
        semanticOffset: CGFloat
    ) -> CGFloat? {
        switch motions[workspaceId] {
        case .spring,
             .deceleration:
            semanticOffset
        case .gesture,
             nil:
            nil
        }
    }

    func plannedRenderOffset(
        in workspaceId: WorkspaceDescriptor.ID,
        localState: ViewportState,
        storeOffset: CGFloat,
        at time: TimeInterval = CACurrentMediaTime()
    ) -> CGFloat {
        let transition = localState.offsetTransition
        switch transition.kind {
        case .spring,
             .deceleration:
            let base = liveViewOffset(in: workspaceId, semanticOffset: storeOffset, at: time) ?? storeOffset
            return base + transition.rebaseDelta
        case .jump:
            return localState.viewOffset
        case nil:
            switch motions[workspaceId] {
            case .gesture:
                return liveViewOffset(in: workspaceId, semanticOffset: localState.viewOffset, at: time)
                    ?? localState.viewOffset
            case let .spring(animation):
                return CGFloat(animation.value(at: time)) + transition.rebaseDelta
            case let .deceleration(animation):
                return CGFloat(animation.value(at: time)) + transition.rebaseDelta
            case nil:
                return localState.viewOffset
            }
        }
    }

    @discardableResult
    func beginGesture(
        in workspaceId: WorkspaceDescriptor.ID,
        isTrackpad: Bool,
        timestamp: TimeInterval = CACurrentMediaTime()
    ) -> GestureSessionID? {
        let livenessTimestamp = gestureLivenessNow()
        guard timestamp.isFinite, livenessTimestamp.isFinite else {
            motions.removeValue(forKey: workspaceId)
            return nil
        }
        let sessionID = GestureSessionID(rawValue: nextGestureSessionID)
        nextGestureSessionID &+= 1
        let gesture = ViewportGesture(
            isTrackpad: isTrackpad,
            sessionID: sessionID,
            livenessTimestamp: livenessTimestamp
        )
        motions[workspaceId] = .gesture(gesture)
        return sessionID
    }

    func gestureSessionID(in workspaceId: WorkspaceDescriptor.ID) -> GestureSessionID? {
        guard case let .gesture(gesture) = motions[workspaceId] else { return nil }
        return gesture.sessionID
    }

    func updateGesture(
        in workspaceId: WorkspaceDescriptor.ID,
        delta: Double,
        timestamp: TimeInterval,
        isTrackpad: Bool,
        viewportWidth: Double
    ) {
        guard case let .gesture(gesture) = motions[workspaceId], gesture.isTrackpad == isTrackpad else { return }
        gesture.update(
            delta: delta,
            timestamp: timestamp,
            viewportWidth: viewportWidth,
            livenessTimestamp: gestureLivenessNow()
        )
    }

    func sampleGestureEnd(
        in workspaceId: WorkspaceDescriptor.ID,
        isTrackpad: Bool? = nil,
        viewportWidth: Double,
        timestamp: TimeInterval?
    ) -> GestureEndSample? {
        guard case let .gesture(gesture) = motions[workspaceId] else { return nil }
        if let isTrackpad, gesture.isTrackpad != isTrackpad { return nil }
        gesture.update(
            delta: 0,
            timestamp: timestamp ?? CACurrentMediaTime(),
            viewportWidth: viewportWidth,
            livenessTimestamp: gestureLivenessNow()
        )
        return GestureEndSample(
            relativeOffset: gesture.relativeOffset,
            relativeProjectedOffset: gesture.relativeProjectedOffset
        )
    }

    func reconcileViewportCommit(
        workspaceId: WorkspaceDescriptor.ID,
        previous: ViewportState?,
        next: ViewportState,
        transition: OffsetTransition
    ) {
        recordViewportCommitTrace(
            workspaceId: workspaceId,
            previous: previous,
            next: next,
            transition: transition
        )
        let rebaseDelta = Double(transition.rebaseDelta)
        if rebaseDelta != 0 {
            switch motions[workspaceId] {
            case let .spring(animation):
                animation.offsetBy(rebaseDelta)
            case let .deceleration(animation):
                animation.offsetBy(rebaseDelta)
            default:
                break
            }
        }

        let time = CACurrentMediaTime()
        let origin = gestureCommitOrigin(
            workspaceId: workspaceId,
            previous: previous,
            next: next,
            rebaseDelta: rebaseDelta,
            at: time
        )

        switch transition.kind {
        case nil:
            break

        case .jump:
            motions.removeValue(forKey: workspaceId)

        case let .spring(config):
            motions[workspaceId] = .spring(
                SpringAnimation(
                    from: origin.from,
                    to: Double(next.viewOffset),
                    initialVelocity: origin.velocity,
                    startTime: time,
                    config: config,
                    displayRefreshRate: next.displayRefreshRate
                )
            )

        case .deceleration:
            motions[workspaceId] = .deceleration(
                DecelerationAnimation(
                    from: origin.from,
                    velocity: origin.velocity,
                    startTime: time
                )
            )
        }
    }

    private func recordViewportCommitTrace(
        workspaceId: WorkspaceDescriptor.ID,
        previous: ViewportState?,
        next: ViewportState,
        transition: OffsetTransition
    ) {
        guard transition.kind != nil || transition.rebaseDelta != 0 else { return }
        let kind = switch transition.kind {
        case .jump: "jump"
        case .spring: "spring"
        case .deceleration: "decelerate"
        case nil: "rebase"
        }
        NiriLayoutTrace.record(
            .viewport,
            workspaceId: workspaceId,
            "\(kind) \(Int(previous?.viewOffset ?? next.viewOffset))→\(Int(next.viewOffset)) col=\(next.activeColumnIndex) rebase=\(Int(transition.rebaseDelta))"
        )
    }

    private func gestureCommitOrigin(
        workspaceId: WorkspaceDescriptor.ID,
        previous: ViewportState?,
        next: ViewportState,
        rebaseDelta: Double,
        at time: TimeInterval
    ) -> (from: Double, velocity: Double) {
        switch motions[workspaceId] {
        case let .gesture(gesture):
            (Double(previous?.viewOffset ?? next.viewOffset) + rebaseDelta + gesture.relativeOffset, gesture.velocity)
        case let .spring(animation):
            (animation.value(at: time), animation.velocity(at: time))
        case let .deceleration(animation):
            (animation.value(at: time), animation.velocity(at: time))
        case nil:
            (Double(previous?.viewOffset ?? next.viewOffset) + rebaseDelta, 0)
        }
    }

    func tickResult(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> TickResult {
        switch motions[workspaceId] {
        case let .gesture(gesture):
            guard time.isFinite,
                  time >= gesture.lastUpdateTime,
                  time - gesture.lastUpdateTime < Self.gestureLivenessInterval
            else {
                let relativeOffset = gesture.relativeOffset
                motions.removeValue(forKey: workspaceId)
                return .expiredGesture(
                    relativeOffset: relativeOffset,
                    sessionID: gesture.sessionID
                )
            }
            return .running
        case let .spring(animation):
            if animation.isComplete(at: time) {
                motions.removeValue(forKey: workspaceId)
                return .inactive
            }
            return .running
        case let .deceleration(animation):
            if animation.isComplete(at: time) {
                motions.removeValue(forKey: workspaceId)
                return .inactive
            }
            return .running
        case nil:
            return .inactive
        }
    }

    func tick(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        tickResult(in: workspaceId, at: time).isRunning
    }

    func removeMotions<S: Sequence>(for workspaceIds: S) where S.Element == WorkspaceDescriptor.ID {
        for workspaceId in workspaceIds {
            motions.removeValue(forKey: workspaceId)
        }
    }
}
