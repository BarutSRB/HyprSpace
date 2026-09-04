// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class AXWriteMetricsBenchmarkTests: XCTestCase {
    private final class StopSignal: Sendable {
        private let flag = Atomic<Bool>(false)

        var isSet: Bool {
            flag.load(ordering: .relaxed)
        }

        func set() {
            flag.store(true, ordering: .relaxed)
        }
    }

    private struct Distribution {
        let label: String
        let samples: [UInt64]

        var formatted: String {
            let sorted = samples.sorted()
            func percentile(_ fraction: Double) -> UInt64 {
                sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
            }
            let mean = Double(sorted.reduce(0, +)) / Double(max(sorted.count, 1))
            return String(
                format: "%@: n=%d mean=%.1fns p50=%lluns p90=%lluns p99=%lluns max=%lluns",
                label,
                sorted.count,
                mean,
                percentile(0.5),
                percentile(0.9),
                percentile(0.99),
                sorted.last ?? 0
            )
        }
    }

    func testRecordLatencyDistributions() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OMNIWM_RUN_AX_WRITE_METRICS_BENCHMARK"] == "1",
            "Set OMNIWM_RUN_AX_WRITE_METRICS_BENCHMARK=1 to print AXWriteMetrics.record latency distributions"
        )
        let iterations = 200_000
        let writers = 8
        var report: [String] = []

        report.append(timed("clock-only baseline", iterations: iterations) { _ in }.formatted)

        let uncontended = AXWriteMetrics()
        let token = AXWriteMetrics.ContextToken(pid: 4_242, callbackGeneration: 1)
        uncontended.register(token, app: "Uncontended", bundleId: nil)
        report.append(
            timed("uncontended record", iterations: iterations) { index in
                uncontended.record(token, lane: .ordinary, nanoseconds: UInt64(index), succeeded: true)
            }.formatted
        )

        report.append(
            concurrent("\(writers) concurrent writers", writers: writers, iterations: iterations / writers) { _, _ in }
                .formatted
        )
        report.append(
            concurrent(
                "\(writers) writers vs snapshot loop",
                writers: writers,
                iterations: iterations / writers
            ) { metrics, stop in
                while !stop.isSet {
                    _ = metrics.snapshot()
                }
            }.formatted
        )
        report.append(
            concurrent(
                "\(writers) writers vs retire/register loop",
                writers: writers,
                iterations: iterations / writers
            ) { metrics, stop in
                var generation: UInt64 = 1_000
                while !stop.isSet {
                    let churn = AXWriteMetrics.ContextToken(pid: 77, callbackGeneration: generation)
                    metrics.register(churn, app: "Churn", bundleId: nil)
                    metrics.record(churn, lane: .closing, nanoseconds: 1, succeeded: true)
                    metrics.retire(churn)
                    generation &+= 1
                }
            }.formatted
        )

        print("AXWriteMetrics.record latency\n" + report.joined(separator: "\n"))
    }

    private func timed(_ label: String, iterations: Int, _ body: (Int) -> Void) -> Distribution {
        var samples: [UInt64] = []
        samples.reserveCapacity(iterations)
        for index in 0 ..< iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            body(index)
            samples.append(DispatchTime.now().uptimeNanoseconds &- start)
        }
        return Distribution(label: label, samples: samples)
    }

    private func concurrent(
        _ label: String,
        writers: Int,
        iterations: Int,
        contender: @escaping @Sendable (AXWriteMetrics, StopSignal) -> Void
    ) -> Distribution {
        let metrics = AXWriteMetrics()
        let tokens = (0 ..< writers).map {
            AXWriteMetrics.ContextToken(pid: pid_t(2_000 + $0), callbackGeneration: UInt64($0 + 1))
        }
        for token in tokens {
            metrics.register(token, app: "Writer \(token.pid)", bundleId: nil)
        }
        let stop = StopSignal()
        let merged = Mutex<[UInt64]>([])
        DispatchQueue.concurrentPerform(iterations: writers + 1) { index in
            guard index < writers else {
                contender(metrics, stop)
                return
            }
            let token = tokens[index]
            let samples = timed(label, iterations: iterations) { write in
                metrics.record(token, lane: .ordinary, nanoseconds: UInt64(write), succeeded: true)
            }.samples
            merged.withLock { $0.append(contentsOf: samples) }
            if index == 0 {
                stop.set()
            }
        }
        return Distribution(label: label, samples: merged.withLock { $0 })
    }
}
