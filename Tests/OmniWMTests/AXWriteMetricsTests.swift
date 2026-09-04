// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class AXWriteMetricsTests: XCTestCase {
    private let blender = AXWriteMetrics.ContextToken(pid: 4_242, callbackGeneration: 7)

    func testLiveRowsFollowTheContextWhileLifetimeTotalsOnlyGrow() throws {
        let metrics = AXWriteMetrics()
        metrics.register(blender, app: "Blender", bundleId: "org.blenderfoundation.blender")
        metrics.record(blender, lane: .ordinary, nanoseconds: 13_600_000, succeeded: true)
        metrics.record(blender, lane: .ordinary, nanoseconds: 1_400_000, succeeded: false)
        metrics.record(blender, lane: .park, nanoseconds: 2_000_000, succeeded: true)

        let live = metrics.snapshot()
        XCTAssertEqual(live.totalCount, 3)
        XCTAssertEqual(live.totalFailureCount, 1)
        XCTAssertEqual(live.totalNanoseconds, 17_000_000)
        XCTAssertEqual(live.maxNanoseconds, 13_600_000)
        XCTAssertEqual(live.buckets.map(\.lane), [.ordinary, .park])
        let ordinary = try XCTUnwrap(live.buckets.first)
        XCTAssertEqual(ordinary.pid, 4_242)
        XCTAssertEqual(ordinary.callbackGeneration, 7)
        XCTAssertEqual(ordinary.app, "Blender")
        XCTAssertEqual(ordinary.bundleId, "org.blenderfoundation.blender")
        XCTAssertEqual(ordinary.writeCount, 2)
        XCTAssertEqual(ordinary.failureCount, 1)
        XCTAssertEqual(ordinary.meanNanoseconds, 7_500_000)
        XCTAssertEqual(ordinary.maxNanoseconds, 13_600_000)

        metrics.retire(blender)

        let retired = metrics.snapshot()
        XCTAssertTrue(retired.buckets.isEmpty)
        XCTAssertEqual(retired.totalCount, 3)
        XCTAssertEqual(retired.totalFailureCount, 1)
        XCTAssertEqual(retired.totalNanoseconds, 17_000_000)
        XCTAssertEqual(retired.maxNanoseconds, 13_600_000)
    }

    func testLateRecordAfterRetirementAdvancesLifetimeWithoutRecreatingTheRow() {
        let metrics = AXWriteMetrics()
        metrics.register(blender, app: "Blender", bundleId: nil)
        metrics.record(blender, lane: .ordinary, nanoseconds: 1_000, succeeded: true)
        metrics.retire(blender)
        metrics.record(blender, lane: .ordinary, nanoseconds: 5_000, succeeded: false)
        metrics.retire(blender)

        let snapshot = metrics.snapshot()
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.totalCount, 2)
        XCTAssertEqual(snapshot.totalFailureCount, 1)
        XCTAssertEqual(snapshot.maxNanoseconds, 5_000)
    }

    func testReusedPIDKeepsItsOwnRowAndIgnoresTheOldContextsLateWrites() throws {
        let metrics = AXWriteMetrics()
        let first = AXWriteMetrics.ContextToken(pid: 100, callbackGeneration: 1)
        let second = AXWriteMetrics.ContextToken(pid: 100, callbackGeneration: 2)
        metrics.register(first, app: "First", bundleId: "example.first")
        metrics.record(first, lane: .ordinary, nanoseconds: 10, succeeded: true)
        metrics.record(first, lane: .ordinary, nanoseconds: 20, succeeded: true)
        metrics.retire(first)
        metrics.register(second, app: "Second", bundleId: "example.second")
        metrics.record(second, lane: .ordinary, nanoseconds: 30, succeeded: true)
        metrics.record(first, lane: .ordinary, nanoseconds: 40, succeeded: false)

        let snapshot = metrics.snapshot()
        let row = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertEqual(row.pid, 100)
        XCTAssertEqual(row.callbackGeneration, 2)
        XCTAssertEqual(row.app, "Second")
        XCTAssertEqual(row.writeCount, 1)
        XCTAssertEqual(row.failureCount, 0)
        XCTAssertEqual(row.totalNanoseconds, 30)
        XCTAssertEqual(snapshot.totalCount, 4)
        XCTAssertEqual(snapshot.totalFailureCount, 1)
    }

    func testRegisteringAnActiveContextAgainKeepsItsRows() {
        let metrics = AXWriteMetrics()
        metrics.register(blender, app: "Blender", bundleId: nil)
        metrics.record(blender, lane: .closing, nanoseconds: 300, succeeded: true)
        metrics.register(blender, app: "Renamed", bundleId: nil)

        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.buckets.map(\.writeCount), [1])
        XCTAssertEqual(snapshot.buckets.first?.app, "Blender")
        XCTAssertEqual(snapshot.buckets.first?.lane, .closing)
    }

    func testUnregisteredContextOnlyAdvancesTheLifetimeTotals() {
        let metrics = AXWriteMetrics()
        let unknown = AXWriteMetrics.ContextToken(pid: 9, callbackGeneration: 0)
        let value = metrics.measure(unknown, lane: .ordinary) { 41 } succeeded: { $0 == 41 }

        XCTAssertEqual(value, 41)
        XCTAssertTrue(metrics.snapshot().buckets.isEmpty)
        XCTAssertEqual(metrics.snapshot().totalCount, 1)
        XCTAssertEqual(metrics.snapshot().totalFailureCount, 0)
    }

    func testConcurrentRecordSnapshotAndRetireKeepTotalsMonotonicAndRowsScoped() {
        let metrics = AXWriteMetrics()
        let tokens = (0 ..< 8).map {
            AXWriteMetrics.ContextToken(pid: pid_t(1_000 + $0), callbackGeneration: UInt64($0 + 1))
        }
        for token in tokens {
            metrics.register(token, app: "App \(token.pid)", bundleId: nil)
        }
        let writesPerToken = 2_000
        let failuresPerToken = (0 ..< writesPerToken).count { $0 % 3 == 0 }
        let retiredTokens = Set(tokens.prefix(4))
        let snapshotsMonotonic = Atomic<Bool>(true)
        let rowsScoped = Atomic<Bool>(true)

        DispatchQueue.concurrentPerform(iterations: tokens.count + 2) { index in
            switch index {
            case 0 ..< tokens.count:
                let token = tokens[index]
                for write in 0 ..< writesPerToken {
                    metrics.record(
                        token,
                        lane: write.isMultiple(of: 2) ? .ordinary : .park,
                        nanoseconds: UInt64(write),
                        succeeded: !write.isMultiple(of: 3)
                    )
                }
            case tokens.count:
                var previousCount = 0
                var previousNanoseconds: UInt64 = 0
                for _ in 0 ..< 500 {
                    let snapshot = metrics.snapshot()
                    if snapshot.totalCount < previousCount || snapshot.totalNanoseconds < previousNanoseconds {
                        snapshotsMonotonic.store(false, ordering: .relaxed)
                    }
                    previousCount = snapshot.totalCount
                    previousNanoseconds = snapshot.totalNanoseconds
                    if snapshot.buckets.contains(where: { bucket in
                        !tokens.contains(
                            AXWriteMetrics.ContextToken(pid: bucket.pid, callbackGeneration: bucket.callbackGeneration)
                        )
                    }) {
                        rowsScoped.store(false, ordering: .relaxed)
                    }
                }
            default:
                for token in retiredTokens {
                    metrics.retire(token)
                    metrics.retire(token)
                }
            }
        }

        let final = metrics.snapshot()
        XCTAssertTrue(snapshotsMonotonic.load(ordering: .relaxed))
        XCTAssertTrue(rowsScoped.load(ordering: .relaxed))
        XCTAssertEqual(final.totalCount, tokens.count * writesPerToken)
        XCTAssertEqual(final.totalFailureCount, tokens.count * failuresPerToken)
        XCTAssertEqual(final.maxNanoseconds, UInt64(writesPerToken - 1))
        let liveTokens = Set(final.buckets.map {
            AXWriteMetrics.ContextToken(pid: $0.pid, callbackGeneration: $0.callbackGeneration)
        })
        XCTAssertEqual(liveTokens, Set(tokens).subtracting(retiredTokens))
        for bucket in final.buckets {
            XCTAssertEqual(bucket.writeCount, writesPerToken / 2, "\(bucket.pid) \(bucket.lane)")
        }
    }
}
