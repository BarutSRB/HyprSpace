// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import QuartzCore

enum ScrollTickTrace {
    struct Record: Sendable {
        let mediaTime: CFTimeInterval
        let effectId: UInt64
        let displayId: CGDirectDisplayID
        let animsMs: Double
        let snapshotMs: Double
        let buildMs: Double
        let commitMs: Double
        let totalMs: Double
        let show: Int
        let hide: Int
        let frames: Int
        let windowCount: Int
        let isAnimationTick: Bool

        init(
            mediaTime: CFTimeInterval,
            effectId: UInt64 = 0,
            displayId: CGDirectDisplayID,
            animsMs: Double,
            snapshotMs: Double,
            buildMs: Double,
            commitMs: Double,
            totalMs: Double,
            show: Int,
            hide: Int,
            frames: Int,
            windowCount: Int,
            isAnimationTick: Bool
        ) {
            self.mediaTime = mediaTime
            self.effectId = effectId
            self.displayId = displayId
            self.animsMs = animsMs
            self.snapshotMs = snapshotMs
            self.buildMs = buildMs
            self.commitMs = commitMs
            self.totalMs = totalMs
            self.show = show
            self.hide = hide
            self.frames = frames
            self.windowCount = windowCount
            self.isAnimationTick = isAnimationTick
        }
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Scroll Tick Breakdown",
        capacity: 4096
    ) { record in
        let spans = String(
            format: "anims=%.2fms snapshot=%.2fms build=%.2fms commit=%.2fms total=%.2fms",
            record.animsMs,
            record.snapshotMs,
            record.buildMs,
            record.commitMs,
            record.totalMs
        )
        let mediaTime = String(format: "%.3f", record.mediaTime)
        return "t=\(mediaTime) effect=\(record.effectId) disp=\(record.displayId) \(spans)"
            + " show=\(record.show) hide=\(record.hide) frames=\(record.frames)"
            + " win=\(record.windowCount) anim=\(record.isAnimationTick)"
    }
}
