// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowServerSubscriptionLiveTests: XCTestCase {
    private final class Sink: EventIntakeSink {
        var frameChangedWindowIds: Set<UInt32> = []

        func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
            if case let .cgs(.frameChanged(windowId)) = stamped.event {
                frameChangedWindowIds.insert(windowId)
            }
        }
    }

    func testLiveSubscriptionCallReplacesThePriorCompleteSet() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_WINDOW_SUBSCRIPTION_LIVE_TESTS"] == "1" else {
            throw XCTSkip(
                "Set OMNIWM_RUN_WINDOW_SUBSCRIPTION_LIVE_TESTS=1 to run private subscription semantics"
            )
        }

        let sky = SkyLight.shared
        let candidates = sky.queryAllVisibleWindows().compactMap { info -> (UInt32, CGPoint)? in
            guard info.pid != getpid(),
                  info.level == 0,
                  info.parentId == 0,
                  info.frame.width >= 200,
                  info.frame.height >= 120,
                  let origin = sky.getWindowBounds(info.id)?.origin
            else {
                return nil
            }
            return (info.id, origin)
        }
        guard candidates.count >= 2 else {
            throw XCTSkip("Two movable foreign level-0 windows are required")
        }
        let (first, firstOrigin) = candidates[0]
        let (second, secondOrigin) = candidates[1]
        defer {
            _ = sky.moveWindow(first, to: firstOrigin)
            _ = sky.moveWindow(second, to: secondOrigin)
        }

        let intake = EventIntake()
        let sink = Sink()
        intake.open(sink: sink)
        defer { intake.close() }
        CGSEventObserver.shared.start()
        defer { CGSEventObserver.shared.stop() }

        XCTAssertTrue(CGSEventObserver.shared.subscribeToWindows([first, second]))
        guard sky.moveWindow(first, to: CGPoint(x: firstOrigin.x + 4, y: firstOrigin.y + 4)),
              sky.moveWindow(second, to: CGPoint(x: secondOrigin.x + 4, y: secondOrigin.y + 4))
        else {
            throw XCTSkip("SkyLight could not move both foreign test windows")
        }
        let observedCompleteSet = await waitUntil {
            sink.frameChangedWindowIds.contains(first)
                && sink.frameChangedWindowIds.contains(second)
        }
        guard observedCompleteSet else {
            throw XCTSkip("The test host did not deliver baseline WindowServer movement events")
        }

        try await Task.sleep(for: .milliseconds(50))
        intake.drainNow()
        sink.frameChangedWindowIds.removeAll()

        XCTAssertTrue(CGSEventObserver.shared.subscribeToWindows([second]))
        XCTAssertTrue(sky.moveWindow(first, to: CGPoint(x: firstOrigin.x + 8, y: firstOrigin.y + 8)))
        XCTAssertTrue(sky.moveWindow(second, to: CGPoint(x: secondOrigin.x + 8, y: secondOrigin.y + 8)))
        let observedReplacementSet = await waitUntil { sink.frameChangedWindowIds.contains(second) }
        XCTAssertTrue(observedReplacementSet)
        try await Task.sleep(for: .milliseconds(100))
        intake.drainNow()

        XCTAssertFalse(sink.frameChangedWindowIds.contains(first))
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
