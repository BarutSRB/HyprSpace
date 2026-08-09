// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

/// Swift port of Niri's `input/scroll_tracker.rs` for wheel/touchpad bind ticks.
struct NiriScrollTracker {
    let tick: CGFloat
    var last: CGFloat = 0.0
    var accumulator: CGFloat = 0.0

    mutating func accumulate(_ amount: CGFloat) -> Int {
        let changedDirection = (last > 0 && amount < 0) || (last < 0 && amount > 0)
        if changedDirection {
            accumulator = 0.0
        }

        last = amount
        accumulator += amount

        guard abs(accumulator) >= tick else { return 0 }

        let clamped = accumulator.clamped(to: (-127 * tick) ... (127 * tick))
        let ticks = Int(clamped / tick)
        // Consume exactly the emitted ticks so any surplus beyond the ±127 per-event cap
        // (and the sub-tick remainder) carries forward to the next event instead of being lost.
        accumulator -= CGFloat(ticks) * tick
        return ticks
    }

    mutating func reset() {
        last = 0.0
        accumulator = 0.0
    }
}
