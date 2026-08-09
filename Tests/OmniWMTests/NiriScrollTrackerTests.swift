// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class NiriScrollTrackerTests: XCTestCase {
    // A scroll amount that crosses the ±127-tick per-event cap must emit the capped
    // tick count and carry the surplus forward, so the deferred ticks fire on the next
    // event instead of being permanently discarded.
    func testSurplusBeyondCapCarriesForward() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(1500), 127)
        // 1500 -> emit 127 (cap), leaving 230 in the accumulator.
        // The next 5 units push it to 235, which must emit the deferred 23 ticks.
        XCTAssertEqual(tracker.accumulate(5), 23)
    }

    func testNegativeSurplusBeyondCapCarriesForward() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(-1500), -127)
        XCTAssertEqual(tracker.accumulate(-5), -23)
    }

    // Surplus accumulates across repeated capped bursts (a long fast scroll): the
    // reservoir is cumulative, not one-shot, and fully drains as later events arrive.
    func testRepeatedCapBurstsDrainCumulatively() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(1500), 127) // carry 230
        XCTAssertEqual(tracker.accumulate(1500), 127) // 230 + 1500 -> carry 460
        XCTAssertEqual(tracker.accumulate(5), 46) // 460 + 5 -> emit the deferred 46 ticks
    }

    // The real production tick (niriWheelScrollTickAmount = 120.0) must carry the same way.
    func testProductionTickCarriesSurplus() {
        var tracker = NiriScrollTracker(tick: 120)

        // 30000 -> capped at 127 * 120 = 15240, carry 14760.
        XCTAssertEqual(tracker.accumulate(30_000), 127)
        // 14760 + 120 = 14880 -> 124 ticks, draining the reservoir.
        XCTAssertEqual(tracker.accumulate(120), 124)
    }

    // Sub-tick remainders must still accumulate across calls. This guards against a
    // naive "reduce the accumulator by the clamped value" fix, which would drop the
    // fractional remainder and never combine two partial scrolls into a whole tick.
    func testSubTickRemainderCarriesAcrossCalls() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(15), 1)
        // 15 -> emit 1 tick, keep 5. The next 5 complete a second tick.
        XCTAssertEqual(tracker.accumulate(5), 1)
    }

    func testBelowTickThresholdAccumulates() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(5), 0)
        XCTAssertEqual(tracker.accumulate(5), 1)
    }

    // Hitting the cap exactly consumes the whole accumulator with no surplus to carry.
    func testExactlyAtCapCarriesNoSurplus() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(1270), 127)
        XCTAssertEqual(tracker.accumulate(9), 0)
    }

    // A direction reversal resets the accumulator, so a pending surplus from the prior
    // direction never bleeds into ticks emitted for the new direction — and the new
    // direction then carries its own surplus forward.
    func testDirectionChangeResetsThenCarriesNewSurplus() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(1500), 127) // carry +230
        XCTAssertEqual(tracker.accumulate(-1500), -127) // reset wipes the +230; carry -230
        XCTAssertEqual(tracker.accumulate(-5), -23) // the new direction's surplus carries
    }

    func testResetClearsAccumulator() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(15), 1) // carry 5
        tracker.reset()
        XCTAssertEqual(tracker.accumulate(5), 0) // reset wiped the carried 5
        XCTAssertEqual(tracker.accumulate(5), 1) // accumulation restarts fresh
    }
}
