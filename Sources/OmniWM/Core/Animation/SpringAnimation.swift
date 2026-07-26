// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct SpringConfig: Equatable {
    let dampingRatio: Double
    let stiffness: Double
    let epsilon: Double
    let velocityEpsilon: Double

    init(
        dampingRatio: Double,
        stiffness: Double,
        epsilon: Double,
        velocityEpsilon: Double = 0.01
    ) {
        self.dampingRatio = max(0, dampingRatio)
        self.stiffness = max(0, stiffness)
        self.epsilon = max(0, epsilon)
        self.velocityEpsilon = max(0, velocityEpsilon)
    }

    init(duration: Double = 0.2, bounce: Double = 0.0, epsilon: Double = 0.5, velocityEpsilon: Double = 10.0) {
        let duration = max(0.001, duration)
        let dampingRatio = 1.0 - min(max(bounce, -1.0), 1.0) * 0.35
        let beta = -log(max(epsilon, 0.0001)) / duration
        self.init(
            dampingRatio: dampingRatio,
            stiffness: pow(beta / max(dampingRatio, Double.ulpOfOne), 2),
            epsilon: epsilon,
            velocityEpsilon: velocityEpsilon
        )
    }

    init(
        response: Double,
        dampingFraction: Double,
        blendDuration: Double = 0.0,
        epsilon: Double = 0.5,
        velocityEpsilon: Double = 10.0
    ) {
        let response = max(0.001, response)
        let dampingRatio = max(0, dampingFraction)
        let beta = -log(max(epsilon, 0.0001)) / response
        self.init(
            dampingRatio: dampingRatio,
            stiffness: pow(beta / max(dampingRatio, Double.ulpOfOne), 2),
            epsilon: epsilon,
            velocityEpsilon: velocityEpsilon
        )
    }

    static let niriHorizontalViewMovement = SpringConfig(
        dampingRatio: 1.0,
        stiffness: 800.0,
        epsilon: 0.0001,
        velocityEpsilon: 0.01
    )

    static let niriWindowMovement = SpringConfig(
        dampingRatio: 1.0,
        stiffness: 800.0,
        epsilon: 0.0001,
        velocityEpsilon: 0.01
    )

    static let niriWindowResize = SpringConfig(
        dampingRatio: 1.0,
        stiffness: 800.0,
        epsilon: 0.0001,
        velocityEpsilon: 0.01
    )

    static let snappy = SpringConfig.niriHorizontalViewMovement
    static let balanced = SpringConfig.niriWindowMovement
    static let gentle = SpringConfig.niriWindowMovement
    static let `default` = SpringConfig.snappy

    func with(epsilon: Double, velocityEpsilon: Double) -> SpringConfig {
        return SpringConfig(
            dampingRatio: dampingRatio,
            stiffness: stiffness,
            epsilon: epsilon,
            velocityEpsilon: velocityEpsilon
        )
    }
}

final class SpringAnimation {
    private(set) var from: Double
    private(set) var target: Double
    private let initialVelocity: Double
    private let startTime: TimeInterval
    let config: SpringConfig
    private let displayRefreshRate: Double

    private var displacement: Double
    private var duration: TimeInterval

    init(
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        startTime: TimeInterval,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0
    ) {
        self.from = from
        target = to
        self.startTime = startTime
        self.displayRefreshRate = displayRefreshRate
        self.initialVelocity = initialVelocity

        self.config = config
        displacement = to - from
        duration = Self.duration(
            from: from,
            target: to,
            initialVelocity: initialVelocity,
            config: config
        )
    }

    func value(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        if elapsed >= duration {
            return target
        }

        let value = Self.oscillate(
            elapsed,
            from: from,
            target: target,
            initialVelocity: initialVelocity,
            config: config
        )
        let range = (target - from) * 10.0
        let a = from - range
        let b = target + range

        if from <= target {
            return value.clamped(to: a ... b)
        } else {
            return value.clamped(to: b ... a)
        }
    }

    func isComplete(at time: TimeInterval) -> Bool {
        max(0, time - startTime) >= duration
    }

    func velocity(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        if elapsed >= duration {
            return 0
        }

        return Self.velocity(
            elapsed,
            from: from,
            target: displacement,
            initialVelocity: initialVelocity,
            config: config
        )
    }

    func offsetBy(_ delta: Double) {
        from += delta
        target += delta
        displacement = target - from
        duration = Self.duration(
            from: from,
            target: target,
            initialVelocity: initialVelocity,
            config: config
        )
    }

    private static func params(_ config: SpringConfig) -> (beta: Double, omega0: Double) {
        let mass = 1.0
        let criticalDamping = 2.0 * sqrt(mass * config.stiffness)
        let damping = config.dampingRatio * criticalDamping
        return (
            beta: damping / (2.0 * mass),
            omega0: sqrt(config.stiffness / mass)
        )
    }

    private static func oscillate(
        _ t: TimeInterval,
        from: Double,
        target: Double,
        initialVelocity: Double,
        config: SpringConfig
    ) -> Double {
        let (beta, omega0) = params(config)
        let x0 = from - target
        let envelope = exp(-beta * t)
        let betaX0PlusV0 = beta * x0 + initialVelocity

        if abs(beta - omega0) <= Double(Float.ulpOfOne) {
            return target + envelope * (x0 + betaX0PlusV0 * t)
        } else if beta < omega0 {
            let omega1 = sqrt(omega0 * omega0 - beta * beta)
            return target + envelope * (
                x0 * cos(omega1 * t) + (betaX0PlusV0 / omega1) * sin(omega1 * t)
            )
        } else {
            let omega2 = sqrt(beta * beta - omega0 * omega0)
            return target + envelope * (
                x0 * cosh(omega2 * t) + (betaX0PlusV0 / omega2) * sinh(omega2 * t)
            )
        }
    }

    private static func velocity(
        _ t: TimeInterval,
        from: Double,
        target displacement: Double,
        initialVelocity: Double,
        config: SpringConfig
    ) -> Double {
        let to = from + displacement
        let (beta, omega0) = params(config)
        let x0 = from - to
        let envelope = exp(-beta * t)
        let betaX0PlusV0 = beta * x0 + initialVelocity

        if abs(beta - omega0) <= Double(Float.ulpOfOne) {
            let f = x0 + betaX0PlusV0 * t
            return envelope * (betaX0PlusV0 - beta * f)
        } else if beta < omega0 {
            let omega1 = sqrt(omega0 * omega0 - beta * beta)
            let b = betaX0PlusV0 / omega1
            let f = x0 * cos(omega1 * t) + b * sin(omega1 * t)
            let fPrime = -x0 * omega1 * sin(omega1 * t) + b * omega1 * cos(omega1 * t)
            return envelope * (fPrime - beta * f)
        } else {
            let omega2 = sqrt(beta * beta - omega0 * omega0)
            let b = betaX0PlusV0 / omega2
            let f = x0 * cosh(omega2 * t) + b * sinh(omega2 * t)
            let fPrime = x0 * omega2 * sinh(omega2 * t) + b * omega2 * cosh(omega2 * t)
            return envelope * (fPrime - beta * f)
        }
    }

    private static func duration(
        from: Double,
        target: Double,
        initialVelocity: Double,
        config: SpringConfig
    ) -> TimeInterval {
        let delta: Double = 0.001
        let (beta, omega0) = params(config)

        if beta.magnitude <= Double.ulpOfOne || beta < 0 {
            return .greatestFiniteMagnitude
        }

        if abs(target - from) <= Double.ulpOfOne {
            return 0
        }

        let epsilon = max(config.epsilon, Double.leastNonzeroMagnitude)
        var x0 = -log(epsilon) / beta

        if abs(beta - omega0) <= Double(Float.ulpOfOne) || beta < omega0 {
            return x0
        }

        var y0 = oscillate(x0, from: from, target: target, initialVelocity: initialVelocity, config: config)
        var slope = (
            oscillate(x0 + delta, from: from, target: target, initialVelocity: initialVelocity, config: config) - y0
        ) / delta

        guard slope.isFinite, abs(slope) > Double.ulpOfOne else {
            return x0
        }

        var x1 = (target - y0 + slope * x0) / slope
        var y1 = oscillate(x1, from: from, target: target, initialVelocity: initialVelocity, config: config)

        var iterations = 0
        while abs(target - y1) > config.epsilon {
            if iterations > 1000 {
                return 0
            }

            x0 = x1
            y0 = y1
            slope = (
                oscillate(x0 + delta, from: from, target: target, initialVelocity: initialVelocity, config: config) - y0
            ) / delta

            guard slope.isFinite, abs(slope) > Double.ulpOfOne else {
                return x0
            }

            x1 = (target - y0 + slope * x0) / slope
            y1 = oscillate(x1, from: from, target: target, initialVelocity: initialVelocity, config: config)

            if !y1.isFinite {
                return x0
            }

            iterations += 1
        }

        return max(0, x1)
    }
}
