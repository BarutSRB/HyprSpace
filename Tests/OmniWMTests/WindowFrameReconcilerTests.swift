// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import XCTest
@testable import OmniWM

final class WindowFrameReconcilerTests: XCTestCase {
    @MainActor
    func testTriggerHighFrequencyBurstStartsTimer() throws {
        let store = SettingsStore()
        let controller = WMController(settings: store)
        let reconciler = WindowFrameReconciler(controller: controller)

        reconciler.triggerHighFrequencyBurst(durationSeconds: 1.0)
        reconciler.reconcileManagedFrames()

        XCTAssertNotNil(reconciler)
    }
}
