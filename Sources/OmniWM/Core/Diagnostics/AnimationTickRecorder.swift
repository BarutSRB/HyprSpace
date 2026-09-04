// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import QuartzCore

enum AnimationTickTrace {
    struct Record: Sendable {
        let mediaTime: CFTimeInterval
        let effectId: UInt64
        let displayId: CGDirectDisplayID
        let intervalMs: Double
        let expectedMs: Double
        let entrySlackMs: Double
        let completionSlackMs: Double
        let scrollMs: Double
        let dwindleMs: Double
        let closingMs: Double
        let reconcileMs: Double
        let totalMs: Double
        let classification: DisplayTickClassification

        init(
            mediaTime: CFTimeInterval,
            effectId: UInt64 = 0,
            displayId: CGDirectDisplayID,
            intervalMs: Double,
            expectedMs: Double,
            entrySlackMs: Double,
            completionSlackMs: Double,
            scrollMs: Double,
            dwindleMs: Double,
            closingMs: Double,
            reconcileMs: Double,
            totalMs: Double,
            classification: DisplayTickClassification
        ) {
            self.mediaTime = mediaTime
            self.effectId = effectId
            self.displayId = displayId
            self.intervalMs = intervalMs
            self.expectedMs = expectedMs
            self.entrySlackMs = entrySlackMs
            self.completionSlackMs = completionSlackMs
            self.scrollMs = scrollMs
            self.dwindleMs = dwindleMs
            self.closingMs = closingMs
            self.reconcileMs = reconcileMs
            self.totalMs = totalMs
            self.classification = classification
        }
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Animation Tick Timing",
        capacity: 4096
    ) { record in
        let timing = String(
            format: "interval=%.2fms expected=%.2fms entry_slack=%.2fms completion_slack=%.2fms"
                + " scroll=%.2fms dwindle=%.2fms closing=%.2fms reconcile=%.2fms total=%.2fms",
            record.intervalMs,
            record.expectedMs,
            record.entrySlackMs,
            record.completionSlackMs,
            record.scrollMs,
            record.dwindleMs,
            record.closingMs,
            record.reconcileMs,
            record.totalMs
        )
        let flags = [
            record.classification.longTimestampGap ? " LONG_GAP" : "",
            record.classification.workExceededNominalPeriod ? " WORK_OVER_PERIOD" : "",
            record.classification.completionPastTarget ? " COMPLETION_PAST_TARGET" : ""
        ].joined()
        let mediaTime = String(format: "%.3f", record.mediaTime)
        return "t=\(mediaTime) effect=\(record.effectId) disp=\(record.displayId) \(timing)\(flags)"
    }
}
