// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import QuartzCore

struct CubicConfig {
    let duration: Double
    let controlPoint1: CGPoint
    let controlPoint2: CGPoint

    init(
        duration: Double = 0.3,
        controlPoint1: CGPoint = CGPoint(x: 0.215, y: 0.61),
        controlPoint2: CGPoint = CGPoint(x: 0.355, y: 1.0)
    ) {
        self.duration = max(0.01, duration)
        self.controlPoint1 = CGPoint(
            x: min(1.0, max(0.0, controlPoint1.x)),
            y: controlPoint1.y
        )
        self.controlPoint2 = CGPoint(
            x: min(1.0, max(0.0, controlPoint2.x)),
            y: controlPoint2.y
        )
    }

    static let `default` = CubicConfig()
    static let hyprlandDwindle = CubicConfig(
        duration: 0.2,
        controlPoint1: CGPoint(x: 0.23, y: 1.0),
        controlPoint2: CGPoint(x: 0.32, y: 1.0)
    )

    func value(at progress: Double) -> Double {
        let x = min(1.0, max(0.0, progress))
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return sampleY(solveT(for: x))
    }

    private func solveT(for x: Double) -> Double {
        var t = x
        for _ in 0 ..< 8 {
            let currentX = sampleX(t) - x
            if abs(currentX) < 0.000001 {
                return t
            }
            let derivative = sampleDerivativeX(t)
            if abs(derivative) < 0.000001 {
                break
            }
            let next = t - currentX / derivative
            if next < 0 || next > 1 {
                break
            }
            t = next
        }

        var lower = 0.0
        var upper = 1.0
        t = x
        for _ in 0 ..< 24 {
            let currentX = sampleX(t)
            if abs(currentX - x) < 0.000001 {
                return t
            }
            if currentX < x {
                lower = t
            } else {
                upper = t
            }
            t = (lower + upper) * 0.5
        }
        return t
    }

    private func sampleX(_ t: Double) -> Double {
        sampleCurve(t, a1: controlPoint1.x, a2: controlPoint2.x)
    }

    private func sampleY(_ t: Double) -> Double {
        sampleCurve(t, a1: controlPoint1.y, a2: controlPoint2.y)
    }

    private func sampleDerivativeX(_ t: Double) -> Double {
        sampleDerivative(t, a1: controlPoint1.x, a2: controlPoint2.x)
    }

    private func sampleCurve(_ t: Double, a1: CGFloat, a2: CGFloat) -> Double {
        let p1 = Double(a1)
        let p2 = Double(a2)
        let c = 3.0 * p1
        let b = 3.0 * (p2 - p1) - c
        let a = 1.0 - c - b
        return ((a * t + b) * t + c) * t
    }

    private func sampleDerivative(_ t: Double, a1: CGFloat, a2: CGFloat) -> Double {
        let p1 = Double(a1)
        let p2 = Double(a2)
        let c = 3.0 * p1
        let b = 3.0 * (p2 - p1) - c
        let a = 1.0 - c - b
        return (3.0 * a * t + 2.0 * b) * t + c
    }
}

struct CubicAnimation {
    private let from: Double
    private let target: Double
    private let startTime: TimeInterval
    let config: CubicConfig

    init(
        from: Double,
        to: Double,
        startTime: TimeInterval,
        config: CubicConfig = .default
    ) {
        self.from = from
        target = to
        self.startTime = startTime
        self.config = config
    }

    func value(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        let progress = min(1.0, elapsed / config.duration)
        let easedProgress = config.value(at: progress)
        return from + easedProgress * (target - from)
    }

    func isComplete(at time: TimeInterval) -> Bool {
        let elapsed = max(0, time - startTime)
        return elapsed >= config.duration
    }
}
