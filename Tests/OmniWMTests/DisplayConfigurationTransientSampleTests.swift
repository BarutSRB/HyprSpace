// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DisplayConfigurationTransientSampleTests: XCTestCase {
    func testTransientUnusableResampleDoesNotTearDownPresentMonitor() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "DisplayConfigurationTransientSampleTests")
        let manager = controller.serviceLifecycleManager
        defer { controller.layoutRefreshController.resetState() }
        manager.topologyInventorySampleProvider = { nil }
        manager.topologyInventorySleeper = { _ in await Task.yield() }

        let first = makeMonitor(displayId: 1, name: "First", originX: 0, width: 1440)
        let second = makeMonitor(displayId: 2, name: "Second", originX: 1440, width: 1440)
        controller.workspaceManager.applyMonitorConfigurationChange([first, second])
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        let niriSecond = try XCTUnwrap(controller.niriEngine?.monitor(for: second.id))
        let seq = controller.workspaceManager.worldSeq

        manager.currentMonitorsProvider = { [
            first,
            self.makeMonitor(displayId: 2, name: "Second", originX: 1440, width: 1)
        ] }
        manager.handleDisplayEvent(.disconnected(second.id))

        XCTAssertTrue(controller.niriEngine?.monitor(for: second.id) === niriSecond)
        XCTAssertEqual(controller.workspaceManager.monitors, [first, second])
        XCTAssertEqual(controller.workspaceManager.worldSeq, seq)

        let moved = makeMonitor(displayId: 2, name: "Second", originX: 1540, width: 1440)
        manager.currentMonitorsProvider = { [first, moved] }
        manager.handleDisplayEvent(.reconfigured(moved))

        XCTAssertEqual(controller.workspaceManager.monitors, [first, moved])
        XCTAssertNotNil(controller.niriEngine?.monitor(for: second.id))
        XCTAssertGreaterThan(controller.workspaceManager.worldSeq, seq)
    }

    func testObserverIgnoresUnusableSampleAsBaseline() {
        let first = makeMonitor(displayId: 1, name: "First", originX: 0, width: 1440)
        let second = makeMonitor(displayId: 2, name: "Second", originX: 1440, width: 1440)
        var sample = [first, second]
        let observer = DisplayConfigurationObserver(monitorSampler: { sample })
        var events: [DisplayConfigurationObserver.DisplayEvent] = []
        observer.setEventHandler { events.append($0) }

        sample = [makeMonitor(displayId: 1, name: "First", originX: 0, width: 1), second]
        observer.sampleNow()
        sample = [first, second]
        observer.sampleNow()

        XCTAssertTrue(events.isEmpty)
    }

    private func makeMonitor(displayId: CGDirectDisplayID, name: String, originX: CGFloat, width: CGFloat) -> Monitor {
        let frame = CGRect(x: originX, y: 0, width: width, height: 900)
        return Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }
}
