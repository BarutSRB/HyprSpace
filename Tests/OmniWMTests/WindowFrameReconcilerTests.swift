// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import XCTest
@testable import OmniWM

@MainActor
final class WindowFrameReconcilerTests: XCTestCase {
    func testHighFrequencyBurstActivation() {
        let reconciler = WindowFrameReconciler()
        XCTAssertFalse(reconciler.isHighFrequencyActive)

        reconciler.triggerHighFrequencyBurst(durationSeconds: 10.0)
        XCTAssertTrue(reconciler.isHighFrequencyActive)
    }

    func testHighFrequencyBurstExpiration() {
        let reconciler = WindowFrameReconciler()
        reconciler.triggerHighFrequencyBurst(durationSeconds: -1.0)
        XCTAssertFalse(reconciler.isHighFrequencyActive)
    }
}
