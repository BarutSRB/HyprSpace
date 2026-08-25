// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class ProcessResourceSnapshotTests: XCTestCase {
    func testLiveProcessResourceSnapshotIsAvailable() throws {
        let snapshot = try XCTUnwrap(ProcessResourceSnapshot.capture())

        XCTAssertGreaterThan(snapshot.capturedAt, 0)
        XCTAssertGreaterThan(snapshot.userTime + snapshot.systemTime, 0)
        XCTAssertGreaterThan(snapshot.residentSize, 0)
        XCTAssertGreaterThan(snapshot.physicalFootprint, 0)
    }

    func testDeltaConvertsEnergyAndMonotonicCounters() throws {
        let start = makeSnapshot(capturedAt: 1, energy: 100, base: 10, resident: 1_000, footprint: 2_000)
        let end = makeSnapshot(
            capturedAt: 1_000_000_001,
            energy: 1_000_000_100,
            base: 20,
            resident: 1_500,
            footprint: 2_500
        )

        let delta = try XCTUnwrap(start.delta(to: end))

        XCTAssertEqual(try XCTUnwrap(delta.energyJoules), 1, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(delta.averageMilliwatts),
            1_000 / delta.elapsedSeconds,
            accuracy: 0.000_001
        )
        XCTAssertEqual(delta.packageIdleWakeups, 10)
        XCTAssertEqual(delta.interruptWakeups, 10)
        XCTAssertEqual(delta.instructions, 10)
        XCTAssertEqual(delta.cycles, 10)
        XCTAssertEqual(delta.residentSizeStart, 1_000)
        XCTAssertEqual(delta.residentSizeEnd, 1_500)
        XCTAssertEqual(delta.physicalFootprintStart, 2_000)
        XCTAssertEqual(delta.physicalFootprintEnd, 2_500)
    }

    func testZeroEnergyIsReportedUnavailable() throws {
        let start = makeSnapshot(capturedAt: 1, energy: 0, base: 10)
        let end = makeSnapshot(capturedAt: 1_000_000_001, energy: 100, base: 20)

        let delta = try XCTUnwrap(start.delta(to: end))

        XCTAssertNil(delta.energyNanojoules)
        XCTAssertNil(delta.energyJoules)
        XCTAssertNil(delta.averageMilliwatts)
        XCTAssertTrue(delta.formatted().contains("energy=unavailable"))
    }

    func testRegressedCountersRejectTheDelta() {
        let start = makeSnapshot(capturedAt: 10, energy: 100, base: 20)
        let end = makeSnapshot(capturedAt: 20, energy: 200, base: 10)

        XCTAssertNil(start.delta(to: end))
    }

    func testRegressedEnergyDoesNotDiscardOtherResourceDeltas() throws {
        let start = makeSnapshot(capturedAt: 1, energy: 200, base: 10)
        let end = makeSnapshot(capturedAt: 1_000_000_001, energy: 100, base: 20)

        let delta = try XCTUnwrap(start.delta(to: end))

        XCTAssertNil(delta.energyNanojoules)
        XCTAssertEqual(delta.instructions, 10)
    }

    private func makeSnapshot(
        capturedAt: UInt64,
        energy: UInt64,
        base: UInt64,
        resident: UInt64 = 1_000,
        footprint: UInt64 = 2_000
    ) -> ProcessResourceSnapshot {
        ProcessResourceSnapshot(
            capturedAt: capturedAt,
            energyNanojoules: energy,
            userTime: base,
            systemTime: base,
            runnableTime: base,
            packageIdleWakeups: base,
            interruptWakeups: base,
            qosTime: .init(
                background: base,
                maintenance: base,
                utility: base,
                default: base,
                userInitiated: base,
                userInteractive: base,
                legacy: base
            ),
            instructions: base,
            cycles: base,
            pageIns: base,
            diskBytesRead: base,
            diskBytesWritten: base,
            residentSize: resident,
            physicalFootprint: footprint,
            intervalMaxPhysicalFootprint: footprint
        )
    }
}
