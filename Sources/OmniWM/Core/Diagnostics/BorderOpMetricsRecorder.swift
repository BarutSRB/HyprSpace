// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import os
import Synchronization

final class BorderOpMetricsRecorder: RuntimeTraceRecording, @unchecked Sendable {
    static let shared = BorderOpMetricsRecorder()

    let sectionTitle = "Border Op Metrics"

    private struct Counters {
        var applyCalls = 0
        var shortCircuited = 0
        var updateCalls = 0
        var cornerRadiusHits = 0
        var cornerRadiusQueries = 0
        var redraws = 0
        var flushes = 0
        var rasterizedPointArea: UInt64 = 0
        var reshapes = 0
        var moveOnly = 0
        var moveAndOrder = 0
        var hides = 0
        var boundsQueryFallbacks = 0
    }

    private let active = Atomic<Bool>(false)
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    var isActive: Bool {
        active.load(ordering: .relaxed)
    }

    private func bump(_ body: @Sendable (inout Counters) -> Void) {
        guard active.load(ordering: .relaxed) else { return }
        counters.withLock { counters in
            guard active.load(ordering: .relaxed) else { return }
            body(&counters)
        }
    }

    func noteApply() {
        bump { $0.applyCalls += 1 }
    }

    func noteShortCircuit() {
        bump { $0.shortCircuited += 1 }
    }

    func noteUpdate() {
        bump { $0.updateCalls += 1 }
    }

    func noteCornerRadiusHit() {
        bump { $0.cornerRadiusHits += 1 }
    }

    func noteCornerRadiusQuery() {
        bump { $0.cornerRadiusQueries += 1 }
    }

    func noteRedraw(rasterizedArea: CGFloat = 0) {
        let boundedArea = rasterizedArea.isFinite ? max(0, rasterizedArea) : 0
        bump {
            $0.redraws += 1
            $0.rasterizedPointArea += UInt64(boundedArea.rounded(.up))
        }
    }

    func noteFlush() {
        bump { $0.flushes += 1 }
    }

    func noteReshape(count: Int = 1) {
        guard count > 0 else { return }
        bump { $0.reshapes += count }
    }

    func noteMoveOnly(count: Int = 1) {
        guard count > 0 else { return }
        bump { $0.moveOnly += count }
    }

    func noteMoveAndOrder(count: Int = 1) {
        guard count > 0 else { return }
        bump { $0.moveAndOrder += count }
    }

    func noteHide(count: Int = 1) {
        guard count > 0 else { return }
        bump { $0.hides += count }
    }

    func noteBoundsQueryFallback() {
        bump { $0.boundsQueryFallbacks += 1 }
    }

    func beginCapture() {
        counters.withLock { $0 = Counters() }
        active.store(true, ordering: .relaxed)
    }

    func endCapture() {
        active.store(false, ordering: .relaxed)
        counters.withLock { _ in }
    }

    func dump() -> String {
        let snapshot = counters.withLock { $0 }
        guard snapshot.applyCalls > 0 || snapshot.updateCalls > 0 else { return "none" }
        return [
            "applyCalls=\(snapshot.applyCalls) shortCircuited=\(snapshot.shortCircuited)"
                + " updateCalls=\(snapshot.updateCalls)",
            "cornerRadius hits=\(snapshot.cornerRadiusHits) queries=\(snapshot.cornerRadiusQueries)",
            "redraws=\(snapshot.redraws) flushes=\(snapshot.flushes)"
                + " rasterizedPointArea=\(snapshot.rasterizedPointArea) reshapes=\(snapshot.reshapes)"
                + " moveOnly=\(snapshot.moveOnly) moveAndOrder=\(snapshot.moveAndOrder)",
            "hides=\(snapshot.hides) boundsQueryFallbacks=\(snapshot.boundsQueryFallbacks)"
        ].joined(separator: "\n")
    }
}
