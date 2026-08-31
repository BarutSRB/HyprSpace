// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum ReconcileDebugDump {
    static func snapshot(_ snapshot: ReconcileSnapshot) -> String {
        var lines: [String] = [
            "topology displays=\(snapshot.topologyProfile.displays.count)",
            "selected-managed=\(snapshot.selectedManagedToken.map(String.init(describing:)) ?? "nil")",
            "native-focus=\(snapshot.focusSession.nativeFocusOwner)",
            "pending-focus=\(snapshot.focusSession.pendingManagedFocus.token.map(String.init(describing:)) ?? "nil")",
            "focus-lease=\(snapshot.focusSession.focusLease?.owner.rawValue ?? "nil")",
            "interaction-monitor=\(snapshot.interactionMonitorId.map(String.init(describing:)) ?? "nil")",
            "previous-interaction-monitor=\(snapshot.previousInteractionMonitorId.map(String.init(describing:)) ?? "nil")"
        ]

        for window in snapshot.windows {
            lines.append(
                "\(window.token) workspace=\(window.workspaceId.uuidString) mode=\(window.mode) phase=\(window.lifecyclePhase.rawValue) lifetime=\(window.lifetimeAuthority) observed=\(describe(window.observedState)) desired=\(window.desiredState.summary)"
            )
        }

        return lines.joined(separator: "\n")
    }

    static func trace(_ records: [ReconcileTraceRecord], limit: Int? = nil) -> String {
        let truncated = limit.map { Array(records.suffix(max(0, $0))) } ?? records
        if truncated.isEmpty {
            return "trace empty"
        }

        return truncated.map { record in
            var parts = [
                "#\(record.sequence)",
                record.timestamp.ISO8601Format(),
                "event=\(record.event.summary)"
            ]
            if record.normalizedEvent != record.event {
                parts.append("normalized=\(record.normalizedEvent.summary)")
            }
            if !record.plan.summary.isEmpty {
                parts.append("plan=\(record.plan.summary)")
            }
            if !record.invariantViolations.isEmpty {
                parts.append(
                    "violations=\(record.invariantViolations.map(\.code).joined(separator: ","))"
                )
            }
            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private static func describe(_ state: ObservedWindowState) -> String {
        [
            "workspace=\(state.workspaceId?.uuidString ?? "nil")",
            "monitor=\(state.monitorId.map(String.init(describing:)) ?? "nil")",
            "visible=\(state.isVisible)",
            "fullscreen=\(state.isNativeFullscreen)"
        ]
        .joined(separator: ",")
    }
}
