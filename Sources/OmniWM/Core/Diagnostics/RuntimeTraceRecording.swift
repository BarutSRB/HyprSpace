// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import os
import Synchronization

enum RuntimeTraceLimits {
    static let captureBytes = 32 * 1024 * 1024
    static let stateReportBytes = 1024 * 1024
    static let automaticEvidenceBytes = 512 * 1024
    static let diagnosticStringBytes = 4 * 1024
    static let rulesSnapshotBytes = 512 * 1024
    static let cumulativeRulesSnapshotBytes = 1024 * 1024

    static func boundedString(_ string: String) -> String {
        boundedString(string, maxBytes: diagnosticStringBytes)
    }

    static func boundedString(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        let utf8 = string.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while end < utf8.endIndex, utf8[end] & 0xC0 == 0x80 {
            end = utf8.index(before: end)
        }
        return String(bytes: utf8[..<end], encoding: .utf8) ?? ""
    }
}

enum TraceFormat {
    static func rect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    static func point(_ point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "(%.0f,%.0f)", point.x, point.y)
    }
}

protocol RuntimeTraceRecording: Sendable {
    var sectionTitle: String { get }
    func beginCapture()
    func endCapture()
    func dump() -> String
    func forEachLine(_ body: (String) -> Bool)
    func releaseStorage()
}

extension RuntimeTraceRecording {
    func releaseStorage() {}

    func forEachLine(_ body: (String) -> Bool) {
        let output = dump()
        guard output != "none" else {
            _ = body("none")
            return
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard body(String(line)) else { return }
        }
    }
}

final class SessionTraceRecorder<Record: Sendable>: RuntimeTraceRecording, @unchecked Sendable {
    private struct SnapshotState {
        var retained: RingBuffer<Record>
        var sourceEvictionCount: UInt64 = 0
    }

    let sectionTitle: String

    private let buffer: LockedRingBuffer<Record>
    private let snapshotState: OSAllocatedUnfairLock<SnapshotState>
    private let active = Atomic<Bool>(false)
    private let formatter: @Sendable (Record) -> String

    init(sectionTitle: String, capacity: Int, formatter: @escaping @Sendable (Record) -> String) {
        self.sectionTitle = sectionTitle
        buffer = LockedRingBuffer(capacity: capacity)
        snapshotState = OSAllocatedUnfairLock(
            initialState: SnapshotState(retained: RingBuffer(capacity: capacity))
        )
        self.formatter = formatter
    }

    var isActive: Bool {
        active.load(ordering: .relaxed)
    }

    var isStoragePrepared: Bool {
        buffer.isStoragePrepared
    }

    var isSpareStoragePrepared: Bool {
        buffer.isSpareStoragePrepared
    }

    var isRetainedStoragePrepared: Bool {
        snapshotState.withLock { $0.retained.isStoragePrepared }
    }

    func releaseStorage() {
        buffer.releaseStorage()
        snapshotState.withLock { state in
            state.retained.releaseStorage()
            state.sourceEvictionCount = 0
        }
    }

    func record(_ make: @autoclosure () -> Record) {
        guard active.load(ordering: .relaxed) else { return }
        buffer.append(make(), while: {
            active.load(ordering: .relaxed)
        })
    }

    func beginCapture() {
        active.store(false, ordering: .relaxed)
        buffer.removeAll()
        snapshotState.withLock { state in
            state.retained.removeAll()
            state.sourceEvictionCount = 0
        }
        buffer.prepareStorage()
        active.store(true, ordering: .relaxed)
    }

    func endCapture() {
        active.store(false, ordering: .relaxed)
        buffer.synchronize()
    }

    func dump() -> String {
        let snapshot = captureSnapshot()
        guard !snapshot.records.isEmpty else { return "none" }
        var lines: [String] = []
        lines.reserveCapacity(snapshot.records.count + 1)
        if snapshot.evictionCount > 0 {
            lines.append("incomplete=true evicted=\(snapshot.evictionCount)")
        }
        lines.append(contentsOf: snapshot.records.map { RuntimeTraceLimits.boundedString(formatter($0)) })
        return lines.joined(separator: "\n")
    }

    func forEachLine(_ body: (String) -> Bool) {
        let snapshot = captureSnapshot()
        guard !snapshot.records.isEmpty else {
            _ = body("none")
            return
        }
        if snapshot.evictionCount > 0,
           !body("incomplete=true evicted=\(snapshot.evictionCount)")
        {
            return
        }
        for record in snapshot.records {
            guard body(RuntimeTraceLimits.boundedString(formatter(record))) else { return }
        }
    }

    private func captureSnapshot() -> (records: [Record], evictionCount: UInt64) {
        let drained = buffer.takeSnapshotWithEvictionCount()
        return snapshotState.withLock { state in
            state.sourceEvictionCount &+= drained.evictionCount
            for record in drained.records {
                state.retained.append(record)
            }
            return (
                state.retained.snapshot(),
                state.sourceEvictionCount &+ state.retained.evictionCount
            )
        }
    }
}
