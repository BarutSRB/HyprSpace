// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AXManagerPIDBufferTests: XCTestCase {
    func testFrameGroupingScratchDropsHistoricalPIDKeysAndCleanupReleasesCapacity() {
        let manager = AXManager()
        manager.beginPIDBufferRuntimeCapture()
        let targets = (0 ..< 64).map { index in
            let pid = pid_t(740_000 + index)
            let windowId = 741_000 + index
            return AXFrameApplicationTarget(
                pid: pid,
                window: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: windowId
                ),
                frame: CGRect(x: index, y: index, width: 500, height: 400)
            )
        }

        manager.applyFramesParallel(targets)

        XCTAssertEqual(manager.pidBufferRuntimeSnapshot().currentSize, 0)
        XCTAssertEqual(manager.pidBufferRuntimeSnapshot().highWater, targets.count)
        XCTAssertGreaterThanOrEqual(manager.pidBufferRuntimeSnapshot().retainedCapacity, targets.count)

        manager.cleanup()

        XCTAssertEqual(manager.pidBufferRuntimeSnapshot().currentSize, 0)
        XCTAssertEqual(manager.pidBufferRuntimeSnapshot().retainedCapacity, 0)
    }
}
