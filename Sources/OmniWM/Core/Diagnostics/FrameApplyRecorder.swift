// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum FrameApplyTrace {
    struct Record: Sendable {
        let timestamp: Date
        let pid: pid_t
        let windowId: Int
        let outcome: String
        let target: CGRect?
        let hint: CGRect?
        let observed: CGRect?
        let confirmed: CGRect?
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Frame Apply Trace",
        capacity: 1024
    ) { record in
        "\(record.timestamp.ISO8601Format()) win=\(record.windowId) pid=\(record.pid)"
            + " \(record.outcome)"
            + " target=\(TraceFormat.rect(record.target))"
            + " hint=\(TraceFormat.rect(record.hint))"
            + " observed=\(TraceFormat.rect(record.observed))"
            + " confirmed=\(TraceFormat.rect(record.confirmed))"
    }

    static func recordResult(_ result: AXFrameApplyResult) {
        guard shared.isActive else { return }
        let outcome: String = if let reason = result.writeResult.failureReason {
            "outcome=skip/\(reason.traceDescription)"
        } else {
            result.confirmedFrame != nil ? "outcome=confirmed" : "outcome=applied"
        }
        shared.record(
            Record(
                timestamp: Date(),
                pid: result.pid,
                windowId: result.windowId,
                outcome: outcome,
                target: result.targetFrame,
                hint: result.currentFrameHint,
                observed: result.writeResult.observedFrame,
                confirmed: result.confirmedFrame
            )
        )
    }

    static func recordAcceptedSizeConvergence(_ result: AXFrameApplyResult) {
        guard shared.isActive else { return }
        shared.record(
            Record(
                timestamp: Date(),
                pid: result.pid,
                windowId: result.windowId,
                outcome: "outcome=accepted-size-convergence",
                target: result.targetFrame,
                hint: result.currentFrameHint,
                observed: result.writeResult.observedFrame,
                confirmed: result.confirmedFrame
            )
        )
    }

    static func recordEvent(pid: pid_t, windowId: Int, outcome: String, target: CGRect? = nil) {
        shared.record(
            Record(
                timestamp: Date(),
                pid: pid,
                windowId: windowId,
                outcome: outcome,
                target: target,
                hint: nil,
                observed: nil,
                confirmed: nil
            )
        )
    }
}
