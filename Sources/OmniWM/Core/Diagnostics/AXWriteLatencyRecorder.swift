// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import Synchronization

enum FrameEffectTraceKind: UInt8, Sendable {
    case none
    case displayTick
    case discrete

    var traceDescription: String {
        switch self {
        case .none:
            "none"
        case .displayTick:
            "display-tick"
        case .discrete:
            "discrete"
        }
    }
}

struct FrameEffectTraceOrigin: Equatable, Sendable {
    let effectId: UInt64
    let displayId: CGDirectDisplayID
    let kind: FrameEffectTraceKind

    static let none = Self(effectId: 0, displayId: 0, kind: .none)
}

@MainActor
enum FrameEffectTraceContext {
    private nonisolated static let activeCaptureGeneration = Atomic<UInt64>(0)
    private static var nextIdentifier: UInt64 = 1
    private(set) static var currentOrigin = FrameEffectTraceOrigin.none

    static var isActive: Bool {
        activeCaptureGeneration.load(ordering: .acquiring) != 0
    }

    static func beginCapture(generation: UInt64) {
        nextIdentifier = 1
        currentOrigin = .none
        activeCaptureGeneration.store(generation & 0xFFFF_FFFF, ordering: .releasing)
    }

    static func endCapture() {
        activeCaptureGeneration.store(0, ordering: .releasing)
        currentOrigin = .none
        nextIdentifier = 1
    }

    static func makeDisplayTickOrigin(displayId: CGDirectDisplayID) -> FrameEffectTraceOrigin {
        guard isActive else { return .none }
        return FrameEffectTraceOrigin(
            effectId: makeIdentifier(),
            displayId: displayId,
            kind: .displayTick
        )
    }

    static func originForSubmission() -> FrameEffectTraceOrigin {
        guard isActive else { return .none }
        if currentOrigin.effectId != 0 {
            return currentOrigin
        }
        return FrameEffectTraceOrigin(
            effectId: makeIdentifier(),
            displayId: 0,
            kind: .discrete
        )
    }

    @discardableResult
    static func install(_ origin: FrameEffectTraceOrigin) -> FrameEffectTraceOrigin {
        let previous = currentOrigin
        currentOrigin = origin
        return previous
    }

    static func restore(_ origin: FrameEffectTraceOrigin) {
        currentOrigin = origin
    }

    static func makeRequestTraceId(parentTraceId: UInt64 = 0) -> UInt64 {
        guard isActive else { return 0 }
        if parentTraceId != 0,
           captureGeneration(of: parentTraceId) != normalizedCaptureGeneration
        {
            return 0
        }
        return makeIdentifier()
    }

    nonisolated static func captureGeneration(of identifier: UInt64) -> UInt64 {
        identifier >> 32
    }

    nonisolated static func isCurrentCapture(identifier: UInt64) -> Bool {
        identifier != 0
            && captureGeneration(of: identifier) == activeCaptureGeneration.load(ordering: .acquiring)
    }

    nonisolated static func currentCaptureIdentifier(_ identifier: UInt64) -> UInt64 {
        isCurrentCapture(identifier: identifier) ? identifier : 0
    }

    private static var normalizedCaptureGeneration: UInt64 {
        activeCaptureGeneration.load(ordering: .relaxed)
    }

    private static func makeIdentifier() -> UInt64 {
        var local = nextIdentifier & 0xFFFF_FFFF
        if local == 0 {
            nextIdentifier &+= 1
            local = nextIdentifier & 0xFFFF_FFFF
        }
        nextIdentifier &+= 1
        return normalizedCaptureGeneration << 32 | local
    }
}

struct AXFrameSetterTiming: Equatable, Sendable {
    var sizeNs: UInt64 = 0
    var positionNs: UInt64 = 0
    var verificationNs: UInt64 = 0
}

enum AXWriteLatencyTrace {
    enum RecordKind: UInt8, Sendable {
        case batch
        case attempt
    }

    struct Record: Sendable {
        let kind: RecordKind
        let uptimeNs: UInt64
        let requestTraceId: UInt64
        let requestId: AXFrameRequestId
        let pid: pid_t
        let bundleId: String?
        let callbackGeneration: UInt64
        let lane: AppAXFrameLane
        let submissionId: UInt64
        let drainId: UInt64
        let windowId: Int
        let attempt: UInt8
        let count: Int
        let queueNs: UInt64
        let sizeNs: UInt64
        let positionNs: UInt64
        let verificationNs: UInt64
        let enhancedUIProbeNs: UInt64
        let enhancedUIDisableNs: UInt64
        let enhancedUIRestoreNs: UInt64
        let totalNs: UInt64
        let enhancedUI: Bool
        let failureReason: AXFrameWriteFailureReason?
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "AX Write Latency",
        capacity: 32_768
    ) { record in
        let prefix = "scope=ax-ordinary+ax-park closing=excluded skylight-position=excluded"
            + " t_ns=\(record.uptimeNs) trace=\(record.requestTraceId)"
            + " request=\(record.requestId) pid=\(record.pid)"
            + " bundle=\(record.bundleId ?? "nil") context=\(record.callbackGeneration)"
            + " lane=\(record.lane.traceDescription) submission=\(record.submissionId)"
            + " drain=\(record.drainId)"
        switch record.kind {
        case .batch:
            return prefix
                + " event=batch count=\(record.count)"
                + " enhanced_ui_probe_us=\(microseconds(record.enhancedUIProbeNs))"
                + " enhanced_ui_disable_us=\(microseconds(record.enhancedUIDisableNs))"
                + " enhanced_ui_restore_us=\(microseconds(record.enhancedUIRestoreNs))"
                + " total_us=\(microseconds(record.totalNs)) enhancedUI=\(record.enhancedUI)"
        case .attempt:
            let outcome = record.failureReason.map { "failure/\($0.traceDescription)" } ?? "success"
            return prefix
                + " event=attempt win=\(record.windowId) attempt=\(record.attempt)"
                + " queue_us=\(microseconds(record.queueNs))"
                + " size_us=\(microseconds(record.sizeNs))"
                + " position_us=\(microseconds(record.positionNs))"
                + " verification_us=\(microseconds(record.verificationNs))"
                + " total_us=\(microseconds(record.totalNs)) outcome=\(outcome)"
        }
    }

    private static func microseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.1f", Double(nanoseconds) / 1_000)
    }
}

extension AppAXFrameLane {
    var traceDescription: String {
        switch self {
        case .ordinary:
            "ordinary"
        case .park:
            "park"
        case .closing:
            "closing"
        }
    }

    var supportsFrameEffectTracing: Bool {
        self != .closing
    }
}
