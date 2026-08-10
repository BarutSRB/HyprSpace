// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class ParkingEdgeMaskTests: XCTestCase {
    func testDerivesOnePointMasksFromVisibleFrame() throws {
        let visibleFrame = CGRect(x: -1900, y: -40, width: 1840, height: 1010)
        let monitor = makeMonitor(
            displayId: 91,
            frame: CGRect(x: -1920, y: -80, width: 1920, height: 1080),
            visibleFrame: visibleFrame
        )

        let masks = SurfaceDerivation.deriveParkingEdgeMasks(monitors: [monitor])
        let left = try XCTUnwrap(masks.first { $0.key.side == .left })
        let right = try XCTUnwrap(masks.first { $0.key.side == .right })

        XCTAssertEqual(masks.count, 2)
        XCTAssertEqual(left.key.monitorId, monitor.id)
        XCTAssertEqual(left.frame, CGRect(x: -1900, y: -40, width: 1, height: 1010))
        XCTAssertEqual(right.key.monitorId, monitor.id)
        XCTAssertEqual(right.frame, CGRect(x: -61, y: -40, width: 1, height: 1010))
    }

    func testDerivesBothEdgesForEveryMonitor() {
        let first = makeMonitor(
            displayId: 92,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        let second = makeMonitor(
            displayId: 93,
            frame: CGRect(x: 1440, y: 100, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1440, y: 100, width: 2560, height: 1415)
        )

        let masks = SurfaceDerivation.deriveParkingEdgeMasks(monitors: [first, second])

        XCTAssertEqual(masks.count, 4)
        XCTAssertEqual(
            Set(masks.map(\.key)),
            Set([
                ParkingEdgeMaskKey(monitorId: first.id, side: .left),
                ParkingEdgeMaskKey(monitorId: first.id, side: .right),
                ParkingEdgeMaskKey(monitorId: second.id, side: .left),
                ParkingEdgeMaskKey(monitorId: second.id, side: .right)
            ])
        )
    }

    func testSkipsDegenerateVisibleFrames() {
        let monitor = makeMonitor(
            displayId: 94,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 1, height: 100)
        )

        XCTAssertTrue(SurfaceDerivation.deriveParkingEdgeMasks(monitors: [monitor]).isEmpty)
    }

    @MainActor
    func testManagerRegistersReusesAndRemovesClickThroughMask() throws {
        let manager = ParkingEdgeMaskManager()
        let key = ParkingEdgeMaskKey(
            monitorId: Monitor.ID(displayId: 95_001),
            side: .left
        )
        let surfaceId = "parking-edge-mask-95001-left"
        let firstFrame = CGRect(x: 91_000, y: 92_000, width: 1, height: 700)
        let secondFrame = CGRect(x: 91_100, y: 92_100, width: 1, height: 800)

        manager.apply([DesiredParkingEdgeMask(key: key, frame: firstFrame)])

        let firstInfo = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == surfaceId }
        )
        let firstWindow = try XCTUnwrap(firstInfo.window)
        XCTAssertEqual(firstInfo.kind, .parkingEdgeMask)
        XCTAssertEqual(firstInfo.hitTestPolicy, .passthrough)
        XCTAssertEqual(firstInfo.capturePolicy, .excluded)
        XCTAssertFalse(firstInfo.suppressesManagedFocusRecovery)
        XCTAssertEqual(firstInfo.frame, firstFrame)
        XCTAssertEqual(firstWindow.level, .statusBar)
        XCTAssertTrue(firstWindow.ignoresMouseEvents)

        manager.apply([DesiredParkingEdgeMask(key: key, frame: secondFrame)])

        let secondInfo = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == surfaceId }
        )
        XCTAssertTrue(firstWindow === secondInfo.window)
        XCTAssertEqual(secondInfo.frame, secondFrame)

        manager.apply([])

        XCTAssertFalse(SurfaceCoordinator.shared.visibleSurfaceIDs().contains(surfaceId))
        manager.removeAll()
        XCTAssertFalse(SurfaceCoordinator.shared.visibleSurfaceIDs().contains(surfaceId))
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: visibleFrame,
            hasNotch: false,
            name: "Display \(displayId)"
        )
    }
}
