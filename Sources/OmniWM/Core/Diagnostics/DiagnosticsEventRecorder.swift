// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Synchronization

final class DiagnosticsEventRecorder: @unchecked Sendable {
    static let shared = DiagnosticsEventRecorder()

    struct Record: Sendable {
        let timestamp: Date
        let name: String
        let pid: pid_t?
        let windowId: UInt32?
    }

    private static let lifecycleLimit = 512
    private static let verboseLimit = 4096

    private let lifecycle = LockedRingBuffer<Record>(capacity: DiagnosticsEventRecorder.lifecycleLimit)
    private let verbose = LockedRingBuffer<Record>(capacity: DiagnosticsEventRecorder.verboseLimit)
    private let verboseActive = Atomic<Bool>(false)

    var isVerboseStoragePrepared: Bool {
        verbose.isStoragePrepared
    }

    var isVerboseSpareStoragePrepared: Bool {
        verbose.isSpareStoragePrepared
    }

    func recordLifecycle(name: String, pid: pid_t? = nil, windowId: UInt32? = nil) {
        lifecycle.append(
            Record(
                timestamp: Date(),
                name: RuntimeTraceLimits.boundedString(name),
                pid: pid,
                windowId: windowId
            )
        )
    }

    func recordVerbose(name: String, pid: pid_t? = nil, windowId: UInt32? = nil) {
        guard verboseActive.load(ordering: .relaxed) else { return }
        let record = Record(
            timestamp: Date(),
            name: RuntimeTraceLimits.boundedString(name),
            pid: pid,
            windowId: windowId
        )
        verbose.append(
            record,
            while: {
                self.verboseActive.load(ordering: .relaxed)
            }
        )
    }

    func recordCGS(_ event: CGSWindowEvent) {
        switch event {
        case let .created(windowId, _):
            recordLifecycle(name: "cgs.created", windowId: windowId)
        case let .destroyed(windowId, _):
            recordLifecycle(name: "cgs.destroyed", windowId: windowId)
        case let .closed(windowId):
            recordLifecycle(name: "cgs.closed", windowId: windowId)
        case let .frameChanged(windowId):
            recordVerbose(name: "cgs.frameChanged", windowId: windowId)
        case let .orderChanged(windowId):
            recordVerbose(name: "cgs.orderChanged", windowId: windowId)
        case let .titleChanged(windowId):
            recordVerbose(name: "cgs.titleChanged", windowId: windowId)
        case let .frontAppChanged(pid):
            recordVerbose(name: "cgs.frontAppChanged", pid: pid)
        }
    }

    func beginVerboseCapture() {
        verboseActive.store(false, ordering: .relaxed)
        verbose.synchronize()
        verbose.removeAll()
        verbose.prepareActiveStorage()
        verboseActive.store(true, ordering: .relaxed)
    }

    func endVerboseCapture() {
        verboseActive.store(false, ordering: .relaxed)
        verbose.synchronize()
    }

    func releaseVerboseStorage() {
        verbose.releaseStorage()
    }

    func dumpLifecycle() -> String {
        format(lifecycle.snapshot())
    }

    func dumpVerbose() -> String {
        format(verbose.snapshot())
    }

    func forEachLifecycleLine(_ body: (String) -> Bool) {
        forEachLine(lifecycle.snapshot(), body)
    }

    func forEachVerboseLine(_ body: (String) -> Bool) {
        forEachLine(verbose.snapshot(), body)
    }

    private func format(_ records: [Record]) -> String {
        guard !records.isEmpty else { return "none" }
        return records.map(format).joined(separator: "\n")
    }

    private func forEachLine(_ records: [Record], _ body: (String) -> Bool) {
        guard !records.isEmpty else {
            _ = body("none")
            return
        }
        for record in records {
            guard body(format(record)) else { return }
        }
    }

    private func format(_ record: Record) -> String {
        var line = "\(record.timestamp.ISO8601Format()) ev=\(record.name)"
        if let pid = record.pid {
            line += " pid=\(pid)"
        }
        if let windowId = record.windowId {
            line += " win=\(windowId)"
        }
        return line
    }
}
