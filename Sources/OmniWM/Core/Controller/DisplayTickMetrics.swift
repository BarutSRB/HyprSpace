// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct DisplayTickClassification: Equatable, Sendable {
    let longTimestampGap: Bool
    let workExceededNominalPeriod: Bool
    let completionPastTarget: Bool

    var timingAnomaly: Bool {
        longTimestampGap || workExceededNominalPeriod
    }
}

struct DisplayTickMetrics {
    private(set) var tickCount = 0
    private(set) var timingAnomalyCount = 0
    private(set) var longTimestampGapCount = 0
    private(set) var workExceededNominalPeriodCount = 0
    private(set) var completionPastTargetCount = 0
    private(set) var maxIntervalMicros = 0
    private(set) var maxWorkMicros = 0
    private(set) var minEntrySlackMicros = 0
    private(set) var minCompletionSlackMicros = 0
    private var totalWorkMicros = 0

    var meanWorkMicros: Int {
        tickCount == 0 ? 0 : totalWorkMicros / tickCount
    }

    var timingAnomalyFraction: Double {
        tickCount == 0 ? 0 : Double(timingAnomalyCount) / Double(tickCount)
    }

    @discardableResult
    mutating func record(
        intervalMs: Double,
        expectedMs: Double,
        workMs: Double,
        hasPreviousTick: Bool,
        entrySlackMs: Double,
        completionSlackMs: Double
    ) -> DisplayTickClassification {
        let classification = DisplayTickClassification(
            longTimestampGap: hasPreviousTick && intervalMs > 1.5 * expectedMs,
            workExceededNominalPeriod: expectedMs > 0 && workMs > expectedMs,
            completionPastTarget: completionSlackMs < 0
        )
        let entrySlackMicros = Self.micros(entrySlackMs)
        let completionSlackMicros = Self.micros(completionSlackMs)
        if tickCount == 0 {
            minEntrySlackMicros = entrySlackMicros
            minCompletionSlackMicros = completionSlackMicros
        } else {
            minEntrySlackMicros = min(minEntrySlackMicros, entrySlackMicros)
            minCompletionSlackMicros = min(minCompletionSlackMicros, completionSlackMicros)
        }
        tickCount += 1
        if classification.longTimestampGap { longTimestampGapCount += 1 }
        if classification.workExceededNominalPeriod { workExceededNominalPeriodCount += 1 }
        if classification.completionPastTarget { completionPastTargetCount += 1 }
        if classification.timingAnomaly { timingAnomalyCount += 1 }

        let workMicros = Self.micros(workMs)
        totalWorkMicros += workMicros
        maxWorkMicros = max(maxWorkMicros, workMicros)
        maxIntervalMicros = max(maxIntervalMicros, Self.micros(intervalMs))
        return classification
    }

    private static func micros(_ milliseconds: Double) -> Int {
        Int((milliseconds * 1_000).rounded())
    }
}
