// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

enum CLIOutputDestination: Equatable {
    case standardOutput
    case standardError

    var handle: FileHandle {
        switch self {
        case .standardOutput:
            FileHandle.standardOutput
        case .standardError:
            FileHandle.standardError
        }
    }
}

struct CLIRenderedOutput: Equatable {
    let data: Data
    let destination: CLIOutputDestination
}

enum CLILocalErrorCode: String, Codable, Equatable, Sendable {
    case invalidArguments = "invalid_arguments"
    case transportFailure = "transport_failure"
    case internalError = "internal_error"
}

struct CLILocalFailureEnvelope: Codable, Equatable, Sendable {
    let ok: Bool
    let source: String
    let status: IPCResponseStatus
    let code: CLILocalErrorCode
    let message: String
    let exitCode: Int32

    init(code: CLILocalErrorCode, message: String, exitCode: CLIExitCode) {
        ok = false
        source = "cli"
        status = .error
        self.code = code
        self.message = message
        self.exitCode = exitCode.rawValue
    }
}

enum CLIRenderer {
    static func responseOutput(_ response: IPCResponse, prefersJSON: Bool) throws -> CLIRenderedOutput {
        try responseOutput(response, format: prefersJSON ? .json : .text)
    }

    static func eventOutput(_ event: IPCEventEnvelope, prefersJSON: Bool) throws -> CLIRenderedOutput {
        try eventOutput(event, format: prefersJSON ? .json : .text)
    }

    static func parseErrorOutput(_ error: CLIParseError, prefersJSON: Bool) throws -> CLIRenderedOutput {
        try parseErrorOutput(error, format: prefersJSON ? .json : .text)
    }

    static func transportErrorOutput(_ error: Error, prefersJSON: Bool) throws -> CLIRenderedOutput {
        try transportErrorOutput(error, format: prefersJSON ? .json : .text)
    }

    static func internalErrorOutput(_ error: Error, prefersJSON: Bool) throws -> CLIRenderedOutput {
        try internalErrorOutput(error, format: prefersJSON ? .json : .text)
    }

    static func exitCode(for response: IPCResponse) -> CLIExitCode {
        guard !response.ok else { return .success }

        switch response.code {
        case .internalError:
            return .internalError
        case .disabled,
             .overviewOpen,
             .layoutMismatch,
             .protocolMismatch,
             .unauthorized,
             .staleWindowId,
             .notFound,
             .workspaceAssignmentConflict,
             .workspaceStateConflict,
             .invalidArguments,
             .invalidRequest,
             .none:
            return .rejected
        }
    }

    static func responseOutput(_ response: IPCResponse, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        if format.prefersJSON {
            return CLIRenderedOutput(
                data: try IPCWire.encodeResponseLine(response, prettyPrinted: true),
                destination: .standardOutput
            )
        }

        return CLIRenderedOutput(
            data: Data((formattedResponseText(response, format: format) + "\n").utf8),
            destination: .standardOutput
        )
    }

    static func eventOutput(_ event: IPCEventEnvelope, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        CLIRenderedOutput(
            data: try IPCWire.encodeEventLine(event, prettyPrinted: format.prefersJSON),
            destination: .standardOutput
        )
    }

    static func parseErrorOutput(_ error: CLIParseError, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        switch error {
        case let .usage(text):
            return try localFailureOutput(
                code: .invalidArguments,
                message: text,
                exitCode: .invalidArguments,
                format: format
            )
        }
    }

    static func transportErrorOutput(_ error: Error, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        try localFailureOutput(
            code: .transportFailure,
            message: "omniwmctl: \(error)",
            exitCode: .transportFailure,
            format: format
        )
    }

    static func internalErrorOutput(_ error: Error, format: CLIOutputFormat) throws -> CLIRenderedOutput {
        try localFailureOutput(
            code: .internalError,
            message: "omniwmctl: \(error)",
            exitCode: .internalError,
            format: format
        )
    }

    static func write(_ output: CLIRenderedOutput) {
        output.destination.handle.write(output.data)
    }

    private static func localFailureOutput(
        code: CLILocalErrorCode,
        message: String,
        exitCode: CLIExitCode,
        format: CLIOutputFormat
    ) throws -> CLIRenderedOutput {
        if format.prefersJSON {
            let envelope = CLILocalFailureEnvelope(code: code, message: message, exitCode: exitCode)
            return CLIRenderedOutput(
                data: try encodeLocalEnvelope(envelope),
                destination: .standardOutput
            )
        }

        let text = message.hasSuffix("\n") ? message : message + "\n"
        return CLIRenderedOutput(data: Data(text.utf8), destination: .standardError)
    }

    private static func formattedResponseText(_ response: IPCResponse, format: CLIOutputFormat) -> String {
        guard response.ok else { return humanReadableStatus(for: response) }
        guard let result = response.result else { return humanReadableStatus(for: response) }

        switch result.payload {
        case let .pong(pong):
            return pong.message
        case let .version(version):
            return humanReadableVersion(version)
        case let .workspaceBar(payload):
            return "workspace-bar monitors: \(payload.monitors.count)"
        case let .activeWorkspace(payload):
            return formattedActiveWorkspace(payload, format: format)
        case let .focusedMonitor(payload):
            return formattedFocusedMonitor(payload, format: format)
        case let .apps(payload):
            return formatAppSummary(payload.apps, format: format)
        case let .focusedWindow(payload):
            return formattedFocusedWindow(payload, format: format)
        case let .windows(payload):
            return formattedWindows(payload, format: format)
        case let .workspaces(payload):
            return formattedWorkspaces(payload, format: format)
        case let .displays(payload):
            return formattedDisplays(payload, format: format)
        case let .rules(payload):
            return formattedRules(payload, format: format)
        case let .ruleActions(payload):
            return formattedRuleActions(payload, format: format)
        case let .queries(payload):
            return formattedQueries(payload, format: format)
        case let .commands(payload):
            return formattedCommands(payload, format: format)
        case let .subscriptions(payload):
            return formattedSubscriptions(payload, format: format)
        case let .capabilities(payload):
            return formattedCapabilities(payload, format: format)
        case let .subscribed(payload):
            return "subscribed: \(payload.channels.map(\.rawValue).joined(separator: ", "))"
        }
    }

    private static func humanReadableStatus(for response: IPCResponse) -> String {
        if response.ok {
            return response.status.rawValue
        }

        if response.code == .protocolMismatch,
           let result = response.result,
           case let .version(version) = result.payload
        {
            return "error: protocol_mismatch (server protocol \(version.protocolVersion), app \(version.appVersion ?? "unknown"))"
        }

        if let code = response.code {
            return "\(response.status.rawValue): \(code.rawValue)"
        }

        return response.status.rawValue
    }

    private static func humanReadableVersion(_ version: IPCVersionResult) -> String {
        if let appVersion = version.appVersion {
            return "\(appVersion) (protocol \(version.protocolVersion))"
        }
        return "protocol \(version.protocolVersion)"
    }

    private static func formattedActiveWorkspace(
        _ payload: IPCActiveWorkspaceQueryResult,
        format: CLIOutputFormat
    ) -> String {
        formatRows(
            headers: ["DISPLAY", "WORKSPACE", "APP"],
            rows: [[
                payload.display?.name ?? "-",
                payload.workspace?.displayName ?? "-",
                payload.focusedApp?.name ?? "-"
            ]],
            format: format
        )
    }

    private static func formattedFocusedMonitor(
        _ payload: IPCFocusedMonitorQueryResult,
        format: CLIOutputFormat
    ) -> String {
        formatRows(
            headers: ["DISPLAY", "ACTIVE WORKSPACE"],
            rows: [[payload.display?.name ?? "-", payload.activeWorkspace?.displayName ?? "-"]],
            format: format
        )
    }

    private static func formattedFocusedWindow(
        _ payload: IPCFocusedWindowQueryResult,
        format: CLIOutputFormat
    ) -> String {
        guard let window = payload.window else {
            return "no focused window"
        }

        return formatRows(
            headers: ["ID", "PID", "APP", "TITLE", "WORKSPACE", "FRAME"],
            rows: [[
                window.id,
                pidDescription(window.pid),
                window.app?.name ?? "-",
                window.title ?? "-",
                window.workspace?.displayName ?? "-",
                frameDescription(window.frame)
            ]],
            format: format
        )
    }

    private static func formattedWindows(_ payload: IPCWindowsQueryResult, format: CLIOutputFormat) -> String {
        let rows = payload.windows.map { window in
            [
                window.id ?? "-",
                pidDescription(window.pid),
                window.app?.name ?? "-",
                window.title ?? "-",
                window.workspace?.displayName ?? "-",
                window.display?.name ?? "-",
                window.mode?.rawValue ?? "-",
                boolDescription(window.isFocused),
                boolDescription(window.isVisible),
                boolDescription(window.isScratchpad)
            ]
        }

        return formatRows(
            headers: ["ID", "PID", "APP", "TITLE", "WORKSPACE", "DISPLAY", "MODE", "FOCUSED", "VISIBLE", "SCRATCHPAD"],
            rows: rows,
            format: format
        )
    }

    private static func formattedWorkspaces(_ payload: IPCWorkspacesQueryResult, format: CLIOutputFormat) -> String {
        let rows = payload.workspaces.map { workspace in
            [
                workspace.id ?? "-",
                workspace.displayName ?? workspace.rawName ?? "-",
                workspace.display?.name ?? "-",
                workspace.layout?.rawValue ?? "-",
                boolDescription(workspace.isCurrent),
                boolDescription(workspace.isVisible),
                countsDescription(workspace.counts),
                workspace.focusedWindowId ?? "-"
            ]
        }

        return formatRows(
            headers: ["ID", "WORKSPACE", "DISPLAY", "LAYOUT", "CURRENT", "VISIBLE", "COUNTS", "FOCUSED WINDOW"],
            rows: rows,
            format: format
        )
    }

    private static func formattedDisplays(_ payload: IPCDisplaysQueryResult, format: CLIOutputFormat) -> String {
        var headers = ["ID", "NAME", "MAIN", "CURRENT", "ORIENTATION", "ACTIVE WORKSPACE", "FRAME"]
        var rows = payload.displays.map { display in
            [
                display.id ?? "-",
                display.name ?? "-",
                boolDescription(display.isMain),
                boolDescription(display.isCurrent),
                display.orientation?.rawValue ?? "-",
                display.activeWorkspace?.displayName ?? "-",
                frameDescription(display.frame)
            ]
        }

        appendDisplayColumn("INNER GAP", values: payload.displays.map(\.innerGap), headers: &headers, rows: &rows)
        appendDisplayColumn("OUTER LEFT", values: payload.displays.map(\.outerGapLeft), headers: &headers, rows: &rows)
        appendDisplayColumn(
            "OUTER RIGHT",
            values: payload.displays.map(\.outerGapRight),
            headers: &headers,
            rows: &rows
        )
        appendDisplayColumn("OUTER TOP", values: payload.displays.map(\.outerGapTop), headers: &headers, rows: &rows)
        appendDisplayColumn(
            "OUTER BOTTOM",
            values: payload.displays.map(\.outerGapBottom),
            headers: &headers,
            rows: &rows
        )

        return formatRows(headers: headers, rows: rows, format: format)
    }

    private static func appendDisplayColumn(
        _ header: String,
        values: [Double?],
        headers: inout [String],
        rows: inout [[String]]
    ) {
        guard values.contains(where: { $0 != nil }) else { return }
        headers.append(header)
        for index in rows.indices {
            rows[index].append(values[index].map { gapValueDescription($0) } ?? "-")
        }
    }

    private static func gapValueDescription(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        return value == value.rounded()
            ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
            : String(value)
    }

    private static func formattedRules(_ payload: IPCRulesQueryResult, format: CLIOutputFormat) -> String {
        let rows = payload.rules.map { rule in
            [
                String(rule.position),
                rule.id,
                rule.bundleId.isEmpty ? "—" : rule.bundleId,
                rule.layout.rawValue,
                rule.assignToWorkspace ?? "-",
                percentageDescription(rule.initialContainerPrimarySpan),
                rule.titleRegex ?? "-",
                String(rule.specificity),
                ruleValidityDescription(rule)
            ]
        }

        return formatRows(
            headers: [
                "POS",
                "ID",
                "BUNDLE ID",
                "LAYOUT",
                "WORKSPACE",
                "INITIAL PRIMARY SPAN",
                "TITLE REGEX",
                "SPECIFICITY",
                "VALID"
            ],
            rows: rows,
            format: format
        )
    }

    private static func percentageDescription(_ proportion: Double?) -> String {
        guard let proportion else { return "-" }
        var percentage = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            proportion * 100
        )
        while percentage.last == "0" {
            percentage.removeLast()
        }
        if percentage.last == "." {
            percentage.removeLast()
        }
        return percentage + "%"
    }

    private static func ruleValidityDescription(_ rule: IPCRuleSnapshot) -> String {
        if rule.isValid { return boolDescription(true) }
        return rule.validationMessages.isEmpty
            ? boolDescription(false)
            : "no: " + rule.validationMessages.joined(separator: "; ")
    }

    private static func formattedQueries(_ payload: IPCQueriesQueryResult, format: CLIOutputFormat) -> String {
        let rows = payload.queries.map { query in
            [
                query.name.rawValue,
                query.summary,
                dashIfEmpty(query.selectors.map(\.name.flag).joined(separator: ", ")),
                dashIfEmpty(query.fields.joined(separator: ", "))
            ]
        }

        return formatRows(
            headers: ["NAME", "SUMMARY", "SELECTORS", "FIELDS"],
            rows: rows,
            format: format
        )
    }

    private static func formattedRuleActions(
        _ payload: IPCRuleActionsQueryResult,
        format: CLIOutputFormat
    ) -> String {
        let rows = payload.ruleActions.map { descriptor in
            [
                descriptor.path,
                descriptor.summary,
                dashIfEmpty(descriptor.arguments.joined(separator: ", ")),
                dashIfEmpty(
                    descriptor.options.map { option in
                        if let valuePlaceholder = option.valuePlaceholder {
                            return "\(option.flag) \(valuePlaceholder)"
                        }
                        return option.flag
                    }
                    .joined(separator: ", ")
                )
            ]
        }

        return formatRows(
            headers: ["PATH", "SUMMARY", "ARGUMENTS", "OPTIONS"],
            rows: rows,
            format: format
        )
    }

    private static func formattedCommands(_ payload: IPCCommandsQueryResult, format: CLIOutputFormat) -> String {
        let commandRows = payload.commands.map {
            [$0.path, $0.summary, $0.layoutCompatibility.rawValue]
        }
        let workspaceRows = payload.workspaceActions.map { [$0.path, $0.summary, "workspace"] }
        let windowRows = payload.windowActions.map { [$0.path, $0.summary, "window"] }

        return formatRows(
            headers: ["PATH", "SUMMARY", "SURFACE"],
            rows: commandRows + workspaceRows + windowRows,
            format: format
        )
    }

    private static func formattedSubscriptions(
        _ payload: IPCSubscriptionsQueryResult,
        format: CLIOutputFormat
    ) -> String {
        let rows = payload.subscriptions.map { subscription in
            [subscription.channel.rawValue, subscription.resultKind.rawValue, subscription.summary]
        }
        return formatRows(headers: ["CHANNEL", "RESULT", "SUMMARY"], rows: rows, format: format)
    }

    private static func formattedCapabilities(
        _ payload: IPCCapabilitiesQueryResult,
        format: CLIOutputFormat
    ) -> String {
        let rows = [
            ["protocol-version", String(payload.protocolVersion)],
            ["app-version", payload.appVersion ?? "-"],
            ["authorization-required", payload.authorizationRequired ? "true" : "false"],
            ["window-id-scope", payload.windowIdScope],
            ["queries", String(payload.queries.count)],
            ["commands", String(payload.commands.count)],
            ["rule-actions", String(payload.ruleActions.count)],
            ["workspace-actions", String(payload.workspaceActions.count)],
            ["window-actions", String(payload.windowActions.count)],
            ["subscriptions", String(payload.subscriptions.count)]
        ]

        return formatRows(headers: ["CAPABILITY", "VALUE"], rows: rows, format: format)
    }

    private static func formatAppSummary(_ apps: [IPCManagedAppSummary], format: CLIOutputFormat) -> String {
        let rows = apps.map { app in
            [app.appName, app.bundleId.isEmpty ? "—" : app.bundleId, sizeDescription(app.windowSize)]
        }
        return formatRows(headers: ["APP", "BUNDLE ID", "WINDOW SIZE"], rows: rows, format: format)
    }

    private static func formatRows(headers: [String], rows: [[String]], format: CLIOutputFormat) -> String {
        switch format {
        case .json:
            return ""
        case .tsv:
            let sanitizedRows = ([headers] + rows).map { $0.map(sanitizedCell) }
            return sanitizedRows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .text,
             .table:
            return renderTable(headers: headers, rows: rows)
        }
    }

    private static func renderTable(headers: [String], rows: [[String]]) -> String {
        let cleanHeaders = headers.map(sanitizedCell)
        let cleanRows = rows.map { $0.map(sanitizedCell) }
        let widths = cleanHeaders.indices.map { column in
            ([cleanHeaders[column]] + cleanRows.map { row in row.indices.contains(column) ? row[column] : "" })
                .map(\.count)
                .max() ?? 0
        }

        func renderRow(_ row: [String]) -> String {
            cleanHeaders.indices.map { column in
                let value = row.indices.contains(column) ? row[column] : ""
                return value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
        }

        var lines = [renderRow(cleanHeaders)]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        if cleanRows.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: cleanRows.map(renderRow))
        }
        return lines.joined(separator: "\n")
    }

    private static func sanitizedCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func boolDescription(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "yes" : "no"
    }

    private static func countsDescription(_ counts: IPCWorkspaceWindowCounts?) -> String {
        guard let counts else { return "-" }
        return "total=\(counts.total), tiled=\(counts.tiled), floating=\(counts.floating), scratchpad=\(counts.scratchpad)"
    }

    private static func frameDescription(_ rect: IPCRect?) -> String {
        guard let rect else { return "-" }
        return "\(Int(rect.x)),\(Int(rect.y)) \(Int(rect.width))x\(Int(rect.height))"
    }

    private static func pidDescription(_ pid: Int32?) -> String {
        guard let pid else { return "-" }
        return String(pid)
    }

    private static func dashIfEmpty(_ value: String) -> String {
        value.isEmpty ? "-" : value
    }

    private static func sizeDescription(_ size: IPCSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    private static func encodeLocalEnvelope(_ envelope: CLILocalFailureEnvelope) throws -> Data {
        var data = try IPCWire.makeEncoder(prettyPrinted: true).encode(envelope)
        data.append(0x0A)
        return data
    }
}
