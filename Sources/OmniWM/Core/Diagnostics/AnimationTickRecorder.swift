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
        let scrollMs: Double
        let dwindleMs: Double
        let closingMs: Double
        let reconcileMs: Double
        let totalMs: Double
        let dropped: Bool

        init(
            mediaTime: CFTimeInterval,
            effectId: UInt64 = 0,
            displayId: CGDirectDisplayID,
            intervalMs: Double,
            expectedMs: Double,
            scrollMs: Double,
            dwindleMs: Double,
            closingMs: Double,
            reconcileMs: Double,
            totalMs: Double,
            dropped: Bool
        ) {
            self.mediaTime = mediaTime
            self.effectId = effectId
            self.displayId = displayId
            self.intervalMs = intervalMs
            self.expectedMs = expectedMs
            self.scrollMs = scrollMs
            self.dwindleMs = dwindleMs
            self.closingMs = closingMs
            self.reconcileMs = reconcileMs
            self.totalMs = totalMs
            self.dropped = dropped
        }
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Animation Tick Timing",
        capacity: 4096
    ) { record in
        let timing = String(
            format: "interval=%.2fms expected=%.2fms scroll=%.2fms dwindle=%.2fms"
                + " closing=%.2fms reconcile=%.2fms total=%.2fms",
            record.intervalMs,
            record.expectedMs,
            record.scrollMs,
            record.dwindleMs,
            record.closingMs,
            record.reconcileMs,
            record.totalMs
        )
        let mediaTime = String(format: "%.3f", record.mediaTime)
        return "t=\(mediaTime) effect=\(record.effectId) disp=\(record.displayId)"
            + " \(timing)\(record.dropped ? " DROPPED" : "")"
    }
}
