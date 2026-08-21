// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct ReconcileTraceRecord: Equatable {
    let sequence: UInt64
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let invariantViolations: [ReconcileInvariantViolation]
}

@MainActor
final class ReconcileTraceRecorder {
    private static let defaultLimit = 256

    private var nextSequence: UInt64 = 1
    private var records: RingBuffer<ReconcileTraceRecord>

    init(limit: Int = defaultLimit) {
        records = RingBuffer(capacity: limit)
    }

    func append(
        event: WMEvent,
        normalizedEvent: WMEvent? = nil,
        plan: ActionPlan,
        invariantViolations: [ReconcileInvariantViolation] = [],
        timestamp: Date = Date()
    ) {
        let strippedEvent = event.strippingAXReferences()
        let record = ReconcileTraceRecord(
            sequence: nextSequence,
            timestamp: timestamp,
            event: strippedEvent,
            normalizedEvent: normalizedEvent.map { $0.strippingAXReferences() } ?? strippedEvent,
            plan: plan,
            invariantViolations: invariantViolations
        )
        nextSequence += 1
        records.append(record)
    }

    func append(transaction: ReconcileTxn) {
        append(
            event: transaction.event,
            normalizedEvent: transaction.normalizedEvent,
            plan: transaction.plan,
            invariantViolations: transaction.invariantViolations,
            timestamp: transaction.timestamp
        )
    }

    func snapshot() -> [ReconcileTraceRecord] {
        records.snapshot()
    }

    func reset() {
        records.removeAll()
        nextSequence = 1
    }
}
