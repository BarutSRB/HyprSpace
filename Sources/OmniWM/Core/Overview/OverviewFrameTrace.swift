// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore
import Synchronization

enum OverviewFrameTrace {
    enum Event: String, Sendable {
        case callback
        case draw
        case invalidation
    }

    struct Record: Sendable {
        let event: Event
        let mediaTime: CFTimeInterval
        let displayId: CGDirectDisplayID
        let generation: UInt64
        let sequence: UInt64
        let progress: Double
        let durationMs: Double
        let waitMs: Double
        let targetLeadMs: Double
        let pendingInvalidations: Int
        let endpointScheduled: Bool
        let sessionCompleted: Bool
    }

    final class Recorder: RuntimeTraceRecording, @unchecked Sendable {
        let sectionTitle = "Overview Frame Timing"

        private let recorder: SessionTraceRecorder<Record>
        private let nextCaptureGeneration = Atomic<UInt64>(0)
        private let activeCaptureGeneration = Atomic<UInt64>(0)

        init() {
            recorder = SessionTraceRecorder(
                sectionTitle: sectionTitle,
                capacity: 8192
            ) { record in
                let mediaTime = String(format: "%.6f", record.mediaTime)
                let timing = String(
                    format: "duration=%.3fms wait=%.3fms lead=%.3fms",
                    record.durationMs,
                    record.waitMs,
                    record.targetLeadMs
                )
                let progress = String(format: "%.5f", record.progress)
                return "event=\(record.event.rawValue) t=\(mediaTime) disp=\(record.displayId)"
                    + " gen=\(record.generation) seq=\(record.sequence) progress=\(progress) \(timing)"
                    + " pending=\(record.pendingInvalidations) endpoint=\(record.endpointScheduled)"
                    + " complete=\(record.sessionCompleted)"
            }
        }

        var isActive: Bool {
            captureGeneration != 0
        }

        var captureGeneration: UInt64 {
            activeCaptureGeneration.load(ordering: .acquiring)
        }

        func record(_ make: @autoclosure () -> Record) {
            guard isActive else { return }
            recorder.record(make())
        }

        func beginCapture() {
            recorder.beginCapture()
            var generation = nextCaptureGeneration.wrappingAdd(1, ordering: .relaxed).newValue
            if generation == 0 {
                generation = nextCaptureGeneration.wrappingAdd(1, ordering: .relaxed).newValue
            }
            activeCaptureGeneration.store(generation, ordering: .releasing)
        }

        func endCapture() {
            activeCaptureGeneration.store(0, ordering: .releasing)
            recorder.endCapture()
        }

        func dump() -> String {
            recorder.dump()
        }

        func forEachLine(_ body: (String) -> Bool) {
            recorder.forEachLine(body)
        }
    }

    static let shared = Recorder()
}
