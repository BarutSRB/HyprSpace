// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

final class DecelerationAnimation {
    static let decelerationRate = 0.997
    static let decayRate = 1000.0 * log(decelerationRate)

    private(set) var from: Double
    private let initialVelocity: Double
    private let startTime: TimeInterval
    private let velocityEpsilon: Double

    private var restingValue: Double = 0
    private var decelerationEnd: TimeInterval = 0

    init(
        from: Double,
        velocity: Double,
        startTime: TimeInterval,
        velocityEpsilon: Double = 1.0
    ) {
        let inputsAreValid = from.isFinite
            && velocity.isFinite
            && startTime.isFinite
            && velocityEpsilon.isFinite
            && velocityEpsilon > 0
        self.from = from.isFinite ? from : 0
        initialVelocity = inputsAreValid ? velocity : 0
        self.startTime = startTime.isFinite ? startTime : 0
        self.velocityEpsilon = inputsAreValid ? velocityEpsilon : 1
        recompute()
    }

    var restingOffset: Double {
        restingValue
    }

    func value(at time: TimeInterval) -> Double {
        guard time.isFinite else { return restingValue }
        let elapsed = max(0, time - startTime)
        if elapsed >= decelerationEnd { return restingValue }
        return from + initialVelocity * (exp(Self.decayRate * elapsed) - 1) / Self.decayRate
    }

    func velocity(at time: TimeInterval) -> Double {
        guard time.isFinite else { return 0 }
        let elapsed = max(0, time - startTime)
        if elapsed >= decelerationEnd { return 0 }
        return initialVelocity * exp(Self.decayRate * elapsed)
    }

    func isComplete(at time: TimeInterval) -> Bool {
        guard time.isFinite else { return true }
        return time - startTime >= decelerationEnd
    }

    func offsetBy(_ delta: Double) {
        guard delta.isFinite, (from + delta).isFinite else {
            decelerationEnd = 0
            return
        }
        from += delta
        recompute()
    }

    private func recompute() {
        guard from.isFinite,
              initialVelocity.isFinite,
              velocityEpsilon.isFinite,
              velocityEpsilon > 0
        else {
            restingValue = from.isFinite ? from : 0
            decelerationEnd = 0
            return
        }
        let restingValue = from - initialVelocity / Self.decayRate
        let decelerationEnd = abs(initialVelocity) <= velocityEpsilon
            ? 0
            : log(velocityEpsilon / abs(initialVelocity)) / Self.decayRate
        guard restingValue.isFinite, decelerationEnd.isFinite, decelerationEnd >= 0 else {
            self.restingValue = from
            self.decelerationEnd = 0
            return
        }
        self.restingValue = restingValue
        self.decelerationEnd = decelerationEnd
    }
}
