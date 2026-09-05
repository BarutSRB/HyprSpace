// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Dispatch
import Foundation

enum MainThreadAXSpanTrace {
    enum Operation: String, Sendable {
        case fronting
        case activateApp = "activate-app"
        case privateFocus = "private-focus"
        case sameAppDeactivate = "same-app-deactivate"
        case sameAppHandoff = "same-app-handoff"
        case axRaise = "ax-raise"
        case orderWindow = "order-window"
        case closeButtonPress = "close-button-press"
        case setNativeFullscreen = "set-native-fullscreen"
        case readFrame = "read-frame"
        case readSubrole = "read-subrole"
        case readRoleAndSubrole = "read-role-subrole"
        case readFullscreen = "read-fullscreen"
        case readFullscreenAttribute = "read-fullscreen-attribute"
        case readWindowFacts = "read-window-facts"
        case readSizeConstraints = "read-size-constraints"
        case readSizeSettable = "read-size-settable"
        case readProcessIdentifier = "read-pid"
        case lookupWindowRef = "lookup-window-ref"
    }

    struct Record: Sendable {
        let uptimeNs: UInt64
        let operation: Operation
        let pid: pid_t
        let windowId: Int
        let nanoseconds: UInt64
        let succeeded: Bool
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Main Thread AX Spans",
        capacity: 16_384
    ) { record in
        "scope=main-thread-sync t_ns=\(record.uptimeNs) op=\(record.operation.rawValue)"
            + " pid=\(record.pid) win=\(record.windowId)"
            + " total_us=\(String(format: "%.1f", Double(record.nanoseconds) / 1_000))"
            + " outcome=\(record.succeeded ? "success" : "failure")"
    }

    static func measure<Value, Failure: Error>(
        _ operation: Operation,
        pid: pid_t = 0,
        windowId: Int = 0,
        _ body: () throws(Failure) -> Value,
        succeeded: (Value) -> Bool = { _ in true }
    ) throws(Failure) -> Value {
        guard shared.isActive, Thread.isMainThread else { return try body() }
        let startedNs = DispatchTime.now().uptimeNanoseconds
        do throws(Failure) {
            let value = try body()
            record(operation, pid: pid, windowId: windowId, startedNs: startedNs, succeeded: succeeded(value))
            return value
        } catch {
            record(operation, pid: pid, windowId: windowId, startedNs: startedNs, succeeded: false)
            throw error
        }
    }

    private static func record(
        _ operation: Operation,
        pid: pid_t,
        windowId: Int,
        startedNs: UInt64,
        succeeded: Bool
    ) {
        let endNs = DispatchTime.now().uptimeNanoseconds
        shared.record(
            Record(
                uptimeNs: endNs,
                operation: operation,
                pid: pid,
                windowId: windowId,
                nanoseconds: endNs &- startedNs,
                succeeded: succeeded
            )
        )
    }
}
