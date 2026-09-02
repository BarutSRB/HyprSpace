// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

enum CLIExitCode: Int32 {
    case success = 0
    case rejected = 1
    case transportFailure = 2
    case invalidArguments = 3
    case internalError = 4
}

enum CLIParseError: Error, Equatable {
    case usage(String)
}

struct CLIWatchConfiguration: Equatable {
    let childArguments: [String]
}

struct ParsedCLICommand: Equatable {
    let invocation: CLIInvocation
    let outputFormat: CLIOutputFormat
    let expectsEventStream: Bool
    let watchConfiguration: CLIWatchConfiguration?

    var request: IPCRequest {
        guard case let .remote(request) = invocation else {
            preconditionFailure("Local CLI invocations do not have an IPC request")
        }
        return request
    }
}

enum CLIParser {
    private static var ruleDefinitionOptionFlags: Set<String> {
        Set(IPCAutomationManifest.ruleDefinitionOptionDescriptors.map(\.flag))
    }

    static func parse(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ParsedCLICommand {
        let normalized = normalize(arguments: arguments)
        let filteredArguments = normalized.arguments

        guard let command = filteredArguments.first else {
            throw CLIParseError.usage(usageText)
        }

        _ = environment
        let requestId = UUID().uuidString
        let outputFormat = normalized.outputFormat ?? CLIOutputFormat.defaultFormat(for: command)

        switch command {
        case "ping":
            guard filteredArguments.count == 1 else {
                throw CLIParseError.usage(usageText)
            }
            return ParsedCLICommand(
                invocation: .remote(.init(id: requestId, kind: .ping)),
                outputFormat: outputFormat,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "version":
            guard filteredArguments.count == 1 else {
                throw CLIParseError.usage(usageText)
            }
            return ParsedCLICommand(
                invocation: .remote(.init(id: requestId, kind: .version)),
                outputFormat: outputFormat,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "command":
            return ParsedCLICommand(
                invocation: .remote(try parseCommandRequest(
                    id: requestId,
                    arguments: Array(filteredArguments.dropFirst())
                )),
                outputFormat: outputFormat,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "query":
            return ParsedCLICommand(
                invocation: .remote(try parseQueryRequest(
                    id: requestId,
                    arguments: Array(filteredArguments.dropFirst())
                )),
                outputFormat: normalized.outputFormat ?? .json,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "rule":
            return ParsedCLICommand(
                invocation: .remote(try parseRuleRequest(
                    id: requestId,
                    arguments: Array(filteredArguments.dropFirst())
                )),
                outputFormat: outputFormat,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "capture":
            return ParsedCLICommand(
                invocation: .remote(try parseCaptureRequest(
                    id: requestId,
                    arguments: Array(filteredArguments.dropFirst())
                )),
                outputFormat: outputFormat,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "workspace":
            return ParsedCLICommand(
                invocation: .remote(try parseWorkspaceRequest(
                    id: requestId,
                    arguments: Array(filteredArguments.dropFirst())
                )),
                outputFormat: outputFormat,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "window":
            return ParsedCLICommand(
                invocation: .remote(try parseWindowRequest(
                    id: requestId,
                    arguments: Array(filteredArguments.dropFirst())
                )),
                outputFormat: outputFormat,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "subscribe":
            return ParsedCLICommand(
                invocation: .remote(try parseSubscribeRequest(
                    id: requestId,
                    arguments: Array(filteredArguments.dropFirst())
                )),
                outputFormat: .json,
                expectsEventStream: true,
                watchConfiguration: nil
            )
        case "watch":
            return try parseWatchCommand(
                id: requestId,
                arguments: Array(filteredArguments.dropFirst()),
                outputFormat: outputFormat
            )
        case "completion":
            return ParsedCLICommand(
                invocation: .local(try parseCompletionCommand(arguments: Array(filteredArguments.dropFirst()))),
                outputFormat: .text,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        case "help",
             "--help",
             "-h":
            return ParsedCLICommand(
                invocation: .local(.help),
                outputFormat: .text,
                expectsEventStream: false,
                watchConfiguration: nil
            )
        default:
            throw CLIParseError.usage(usageText)
        }
    }

    static func outputFormat(arguments: [String]) -> CLIOutputFormat {
        let normalized = normalize(arguments: arguments)
        return normalized.outputFormat ?? CLIOutputFormat.defaultFormat(for: normalized.arguments.first)
    }

    private struct NormalizedArguments {
        let arguments: [String]
        let outputFormat: CLIOutputFormat?
    }

    private struct ParsedSubscriptionArguments {
        let request: IPCSubscribeRequest
        let execArguments: [String]?
    }

    private static func normalize(arguments: [String]) -> NormalizedArguments {
        let rawArguments = Array(arguments.dropFirst())
        let execIndex = rawArguments.firstIndex(of: "--exec") ?? rawArguments.endIndex

        var filteredArguments: [String] = []
        var outputFormat: CLIOutputFormat?
        var index = 0

        while index < rawArguments.count {
            let argument = rawArguments[index]
            if index < execIndex, argument == "--format", index + 1 < rawArguments.count,
               let format = CLIOutputFormat(rawValue: rawArguments[index + 1])
            {
                outputFormat = format
                index += 2
                continue
            }
            if index < execIndex, argument == "--json" {
                outputFormat = .json
                index += 1
                continue
            }

            filteredArguments.append(argument)
            index += 1
        }

        return NormalizedArguments(arguments: filteredArguments, outputFormat: outputFormat)
    }

    private static func parseCommandRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard !arguments.isEmpty else {
            throw CLIParseError.usage(usageText)
        }

        for descriptor in IPCAutomationManifest.commandDescriptors(matching: arguments) {
            let commandWordCount = descriptor.commandWords.count
            let remainingCount = arguments.count - commandWordCount
            guard remainingCount == descriptor.arguments.count else {
                continue
            }

            let argumentTokens = Array(arguments.dropFirst(commandWordCount))
            do {
                let argumentValues = try zip(descriptor.arguments, argumentTokens).map(parseCommandArgumentValue)
                let request = try IPCCommandRequest(name: descriptor.name, argumentValues: argumentValues)
                return IPCRequest(id: id, command: request)
            } catch {
                continue
            }
        }

        throw CLIParseError.usage(usageText)
    }

    private static func parseQueryRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let rawName = arguments.first else {
            throw CLIParseError.usage(usageText)
        }

        guard let queryName = IPCQueryName(rawValue: rawName),
              let descriptor = IPCAutomationManifest.queryDescriptor(for: queryName)
        else {
            throw CLIParseError.usage(usageText)
        }

        var selectors = IPCQuerySelectors()
        var fields: [String] = []
        var index = 1
        var seenSelectors: Set<IPCQuerySelectorName> = []
        var sawFields = false

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--fields" {
                guard !sawFields, index + 1 < arguments.count else {
                    throw CLIParseError.usage(usageText)
                }
                let parsedFields = arguments[index + 1]
                    .split(separator: ",")
                    .map(String.init)
                guard !parsedFields.isEmpty,
                      !descriptor.fields.isEmpty,
                      parsedFields.allSatisfy({ descriptor.fields.contains($0) })
                else {
                    throw CLIParseError.usage(usageText)
                }
                fields = parsedFields
                sawFields = true
                index += 2
                continue
            }

            guard argument.hasPrefix("--") else {
                throw CLIParseError.usage(usageText)
            }

            let selectorName = String(argument.dropFirst(2))
            guard let selector = IPCQuerySelectorName(rawValue: selectorName),
                  descriptor.selectors.contains(where: { $0.name == selector }),
                  seenSelectors.insert(selector).inserted
            else {
                throw CLIParseError.usage(usageText)
            }

            if selector.expectsValue {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw CLIParseError.usage(usageText)
                }
                selectors = selectors.setting(selector, value: arguments[index + 1])
                index += 2
            } else {
                selectors = selectors.setting(selector)
                index += 1
            }
        }

        return IPCRequest(id: id, query: IPCQueryRequest(name: queryName, selectors: selectors, fields: fields))
    }

    private static func parseRuleRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let actionToken = arguments.first,
              let action = IPCRuleActionName(rawValue: actionToken)
        else {
            throw CLIParseError.usage(usageText)
        }

        switch action {
        case .add:
            let rule = try parseRuleDefinition(arguments: Array(arguments.dropFirst()))
            return IPCRequest(id: id, rule: .add(rule: rule))
        case .replace:
            guard arguments.count >= 2, UUID(uuidString: arguments[1]) != nil else {
                throw CLIParseError.usage(usageText)
            }
            let rule = try parseRuleDefinition(arguments: Array(arguments.dropFirst(2)))
            return IPCRequest(id: id, rule: .replace(id: arguments[1], rule: rule))
        case .remove:
            guard arguments.count == 2, UUID(uuidString: arguments[1]) != nil else {
                throw CLIParseError.usage(usageText)
            }
            return IPCRequest(id: id, rule: .remove(id: arguments[1]))
        case .move:
            guard arguments.count == 3,
                  UUID(uuidString: arguments[1]) != nil
            else {
                throw CLIParseError.usage(usageText)
            }
            return IPCRequest(
                id: id,
                rule: .move(id: arguments[1], position: try parsePositiveInteger(arguments[2]))
            )
        case .apply:
            let target = try parseRuleApplyTarget(arguments: Array(arguments.dropFirst()))
            return IPCRequest(id: id, rule: .apply(target: target))
        }
    }

    private static func parseRuleDefinition(arguments: [String]) throws -> IPCRuleDefinition {
        var bundleId: String?
        var appNameSubstring: String?
        var titleSubstring: String?
        var titleRegex: String?
        var axRole: String?
        var axSubrole: String?
        var layout: IPCRuleLayout = .auto
        var assignToWorkspace: String?
        var initialContainerPrimarySpan: Double?
        var minWidth: Double?
        var minHeight: Double?
        var seenFlags: Set<String> = []
        var index = 0

        while index < arguments.count {
            let flag = arguments[index]
            guard ruleDefinitionOptionFlags.contains(flag),
                  seenFlags.insert(flag).inserted,
                  index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--")
            else {
                throw CLIParseError.usage(usageText)
            }

            let value = arguments[index + 1]
            switch flag {
            case "--bundle-id":
                bundleId = value
            case "--app-name-substring":
                appNameSubstring = value
            case "--title-substring":
                titleSubstring = value
            case "--title-regex":
                titleRegex = value
            case "--ax-role":
                axRole = value
            case "--ax-subrole":
                axSubrole = value
            case "--layout":
                guard let parsedLayout = IPCRuleLayout(rawValue: value) else {
                    throw CLIParseError.usage(usageText)
                }
                layout = parsedLayout
            case "--assign-to-workspace":
                assignToWorkspace = value
            case "--initial-container-primary-span":
                initialContainerPrimarySpan = try parseInitialContainerPrimarySpan(value)
            case "--min-width":
                minWidth = try parsePositiveDouble(value)
            case "--min-height":
                minHeight = try parsePositiveDouble(value)
            default:
                throw CLIParseError.usage(usageText)
            }

            index += 2
        }

        let definition = IPCRuleDefinition(
            bundleId: bundleId ?? "",
            appNameSubstring: appNameSubstring,
            titleSubstring: titleSubstring,
            titleRegex: titleRegex,
            axRole: axRole,
            axSubrole: axSubrole,
            layout: layout,
            assignToWorkspace: assignToWorkspace,
            initialContainerPrimarySpan: initialContainerPrimarySpan,
            minWidth: minWidth,
            minHeight: minHeight
        )

        guard IPCRuleValidator.validate(definition).isValid else {
            throw CLIParseError.usage(usageText)
        }

        return definition
    }

    private static func parseRuleApplyTarget(arguments: [String]) throws -> IPCRuleApplyTarget {
        guard !arguments.isEmpty else {
            return .focused
        }

        var target: IPCRuleApplyTarget?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard target == nil else {
                throw CLIParseError.usage(usageText)
            }

            switch argument {
            case "--focused":
                target = .focused
                index += 1
            case "--window":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw CLIParseError.usage(usageText)
                }
                target = .window(windowId: arguments[index + 1])
                index += 2
            case "--pid":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw CLIParseError.usage(usageText)
                }
                target = .pid(try parsePID(arguments[index + 1]))
                index += 2
            default:
                throw CLIParseError.usage(usageText)
            }
        }

        guard let target else {
            throw CLIParseError.usage(usageText)
        }

        return target
    }

    private static func parseWorkspaceRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard !arguments.isEmpty else {
            throw CLIParseError.usage(usageText)
        }

        for descriptor in IPCAutomationManifest.workspaceActionDescriptors(matching: arguments) {
            let actionWords = descriptor.actionWords
            let remaining = Array(arguments.dropFirst(actionWords.count))

            switch descriptor.name {
            case .focusName:
                guard remaining.count == descriptor.arguments.count,
                      let targetValue = remaining.first
                else {
                    continue
                }
                return IPCRequest(
                    id: id,
                    workspace: .focusName(
                        target: WorkspaceTarget(resolvingInput: targetValue)
                    )
                )
            case .moveToMonitor:
                let flags = remaining.filter { $0.hasPrefix("--") }
                guard flags.allSatisfy(descriptor.optionalFlags.contains),
                      flags.count == Set(flags).count
                else {
                    continue
                }

                let positionals = remaining.filter { !$0.hasPrefix("--") }
                guard positionals.count == descriptor.arguments.count else {
                    continue
                }

                return IPCRequest(
                    id: id,
                    workspace: .moveToMonitor(
                        target: WorkspaceTarget(resolvingInput: positionals[0]),
                        direction: try parseDirection(positionals[1]),
                        force: flags.contains("--force")
                    )
                )
            }
        }

        throw CLIParseError.usage(usageText)
    }

    private static func parseCaptureRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let actionToken = arguments.first,
              let action = IPCCaptureActionName(rawValue: actionToken)
        else {
            throw CLIParseError.usage(usageText)
        }

        let capture: IPCCaptureRequest
        switch action {
        case .start:
            guard arguments.count == 2,
                  let profile = IPCCaptureProfile(rawValue: arguments[1])
            else {
                throw CLIParseError.usage(usageText)
            }
            capture = .start(profile)
        case .stop:
            guard arguments.count == 1 else {
                throw CLIParseError.usage(usageText)
            }
            capture = .stop
        case .status:
            guard arguments.count == 1 else {
                throw CLIParseError.usage(usageText)
            }
            capture = .status
        }

        return IPCRequest(id: id, capture: capture)
    }

    private static func parseWindowRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let action = arguments.first.flatMap(IPCWindowActionName.init(rawValue:)),
              let descriptor = IPCAutomationManifest.windowActionDescriptors.first(where: { $0.name == action }),
              arguments.count == 1 + descriptor.arguments.count
        else {
            throw CLIParseError.usage(usageText)
        }

        return IPCRequest(
            id: id,
            window: IPCWindowRequest(
                name: action,
                windowId: arguments[1],
                workspaceTarget: action == .moveToWorkspace ? WorkspaceTarget(resolvingInput: arguments[2]) : nil
            )
        )
    }

    private static func parseSubscribeRequest(id: String, arguments: [String]) throws -> IPCRequest {
        let parsed = try parseSubscriptionArguments(arguments: arguments, allowExec: false)
        return IPCRequest(id: id, subscribe: parsed.request)
    }

    private static func parseWatchCommand(
        id: String,
        arguments: [String],
        outputFormat: CLIOutputFormat
    ) throws -> ParsedCLICommand {
        let parsed = try parseSubscriptionArguments(arguments: arguments, allowExec: true)
        guard let execArguments = parsed.execArguments else {
            throw CLIParseError.usage(usageText)
        }

        return ParsedCLICommand(
            invocation: .remote(IPCRequest(id: id, subscribe: parsed.request)),
            outputFormat: outputFormat,
            expectsEventStream: false,
            watchConfiguration: CLIWatchConfiguration(childArguments: execArguments)
        )
    }

    private static func parseCompletionCommand(arguments: [String]) throws -> CLILocalAction {
        guard arguments.count == 1,
              let shell = CLIShell(rawValue: arguments[0])
        else {
            throw CLIParseError.usage(usageText)
        }
        return .completion(shell)
    }

    private static func parseSubscriptionArguments(
        arguments: [String],
        allowExec: Bool
    ) throws -> ParsedSubscriptionArguments {
        var channels: [IPCSubscriptionChannel] = []
        var allChannels = false
        var sendInitial = true
        var sawChannelList = false
        var index = 0
        var execArguments: [String]?

        while index < arguments.count {
            let argument = arguments[index]

            if allowExec, argument == "--exec" {
                let remaining = Array(arguments.dropFirst(index + 1))
                guard !remaining.isEmpty, execArguments == nil else {
                    throw CLIParseError.usage(usageText)
                }
                execArguments = remaining
                index = arguments.count
                break
            }

            switch argument {
            case "--all":
                guard !allChannels else { throw CLIParseError.usage(usageText) }
                allChannels = true
                index += 1
            case "--no-send-initial":
                guard sendInitial else { throw CLIParseError.usage(usageText) }
                sendInitial = false
                index += 1
            default:
                guard !argument.hasPrefix("--"), !sawChannelList else {
                    throw CLIParseError.usage(usageText)
                }
                let parsedChannels = argument
                    .split(separator: ",")
                    .map(String.init)
                guard !parsedChannels.isEmpty else {
                    throw CLIParseError.usage(usageText)
                }
                let resolvedChannels = parsedChannels.compactMap(IPCSubscriptionChannel.init(rawValue:))
                guard resolvedChannels.count == parsedChannels.count else {
                    throw CLIParseError.usage(usageText)
                }
                channels = resolvedChannels
                sawChannelList = true
                index += 1
            }
        }

        guard allChannels || !channels.isEmpty else {
            throw CLIParseError.usage(usageText)
        }

        if allowExec, execArguments == nil {
            throw CLIParseError.usage(usageText)
        }

        return ParsedSubscriptionArguments(
            request: IPCSubscribeRequest(
                channels: channels,
                allChannels: allChannels,
                sendInitial: sendInitial
            ),
            execArguments: execArguments
        )
    }

    private static func parseDirection(_ rawValue: String) throws -> IPCDirection {
        guard let direction = IPCDirection(rawValue: rawValue) else {
            throw CLIParseError.usage(usageText)
        }
        return direction
    }

    private static func parseResizeAxis(_ rawValue: String) throws -> IPCResizeAxis {
        guard let axis = IPCResizeAxis(rawValue: rawValue) else {
            throw CLIParseError.usage(usageText)
        }
        return axis
    }

    private static func parseWorkspaceNumber(_ rawValue: String) throws -> Int {
        guard let workspaceNumber = Int(rawValue), workspaceNumber > 0 else {
            throw CLIParseError.usage(usageText)
        }
        return workspaceNumber
    }

    private static func parseScratchpadIndex(_ rawValue: String) throws -> Int {
        guard let index = Int(rawValue), IPCScratchpadSlots.range.contains(index) else {
            throw CLIParseError.usage(usageText)
        }
        return index
    }

    private static func parsePositiveInteger(_ rawValue: String) throws -> Int {
        guard let value = Int(rawValue), value > 0 else {
            throw CLIParseError.usage(usageText)
        }
        return value
    }

    private static func parsePositiveDouble(_ rawValue: String) throws -> Double {
        guard let value = Double(rawValue), value > 0 else {
            throw CLIParseError.usage(usageText)
        }
        return value
    }

    private static func parseInitialContainerPrimarySpan(_ rawValue: String) throws -> Double {
        guard let value = Double(rawValue), value.isFinite, (0.05 ... 1.0).contains(value) else {
            throw CLIParseError.usage(usageText)
        }
        return value
    }

    private static func parsePID(_ rawValue: String) throws -> Int32 {
        guard let value = Int32(rawValue), value > 0 else {
            throw CLIParseError.usage(usageText)
        }
        return value
    }

    private static func parseColumnIndex(_ rawValue: String) throws -> Int {
        guard let columnIndex = Int(rawValue), columnIndex > 0 else {
            throw CLIParseError.usage(usageText)
        }
        return columnIndex
    }

    private static func parseWindowIndex(_ rawValue: String) throws -> Int {
        guard let windowIndex = Int(rawValue), windowIndex > 0 else {
            throw CLIParseError.usage(usageText)
        }
        return windowIndex
    }

    private static func parseResizeOperation(_ rawValue: String) throws -> IPCResizeOperation {
        guard let operation = IPCResizeOperation(rawValue: rawValue) else {
            throw CLIParseError.usage(usageText)
        }
        return operation
    }

    private static func parseWorkspaceLayout(_ rawValue: String) throws -> IPCWorkspaceLayout {
        guard let layout = IPCWorkspaceLayout(rawValue: rawValue) else {
            throw CLIParseError.usage(usageText)
        }
        return layout
    }

    private static func parseSizeChange(_ rawValue: String) throws -> IPCSizeChange {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIParseError.usage(usageText)
        }

        let isProportion = trimmed.hasSuffix("%")
        let numericText = isProportion ? String(trimmed.dropLast()) : trimmed
        guard let value = Double(numericText), value.isFinite else {
            throw CLIParseError.usage(usageText)
        }

        if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            return isProportion ? .adjustProportion(value) : .adjustFixed(value)
        }
        return isProportion ? .setProportion(value) : .setFixed(value)
    }

    private static func parseCommandArgumentValue(
        _ pair: (IPCCommandArgumentDescriptor, String)
    ) throws -> IPCCommandArgumentValue {
        let (descriptor, token) = pair

        switch descriptor.kind {
        case .direction:
            return .direction(try parseDirection(token))
        case .workspaceNumber:
            return .integer(try parseWorkspaceNumber(token))
        case .columnIndex:
            return .integer(try parseColumnIndex(token))
        case .windowIndex:
            return .integer(try parseWindowIndex(token))
        case .scratchpadIndex:
            return .integer(try parseScratchpadIndex(token))
        case .layout:
            return .layout(try parseWorkspaceLayout(token))
        case .resizeAxis:
            return .resizeAxis(try parseResizeAxis(token))
        case .resizeOperation:
            return .resizeOperation(try parseResizeOperation(token))
        case .sizeChange:
            return .sizeChange(try parseSizeChange(token))
        }
    }

    static let usageText: String = {
        let queryNames = IPCAutomationManifest.queryDescriptors.map(\.name.rawValue).joined(separator: ", ")
        let subscriptionNames = IPCSubscriptionChannel.allCases.map(\.rawValue).joined(separator: ",")
        let commandLines = IPCAutomationManifest.commandDescriptors.map(\.path)
        let ruleLines = IPCAutomationManifest.ruleActionDescriptors.map(\.path)
        let ruleOptionLines = IPCAutomationManifest.ruleDefinitionOptionDescriptors.map { descriptor in
            if let valuePlaceholder = descriptor.valuePlaceholder {
                return "  \(descriptor.flag) \(valuePlaceholder)"
            }
            return "  \(descriptor.flag)"
        }
        let workspaceLines = IPCAutomationManifest.workspaceActionDescriptors.map(\.path)
        let windowLines = IPCAutomationManifest.windowActionDescriptors.map(\.path)
        let captureLines = IPCAutomationManifest.captureActionDescriptors.map(\.path)

        var lines = [
            "Usage:",
            "  omniwmctl ping",
            "  omniwmctl version",
            "  omniwmctl help",
            "  omniwmctl completion <zsh|bash|fish>"
        ]
        lines += commandLines.map { "  omniwmctl \($0)" }
        lines += ruleLines.map { "  omniwmctl \($0)" }
        lines += captureLines.map { "  omniwmctl \($0)" }
        lines += [
            "  omniwmctl query <\(queryNames)> [selectors...] [--fields <csv>] [--format <json|table|tsv|text>]"
        ]
        lines += workspaceLines.map { "  omniwmctl \($0)" }
        lines += windowLines.map { "  omniwmctl \($0)" }
        lines += [
            "  omniwmctl subscribe <\(subscriptionNames)> [--no-send-initial]",
            "  omniwmctl subscribe --all [--no-send-initial]",
            "  omniwmctl watch <\(subscriptionNames)> [--no-send-initial] --exec <argv...>",
            "  omniwmctl watch --all [--no-send-initial] --exec <argv...>",
            "",
            "Formats:",
            "  --format json|table|tsv|text",
            "  --json (alias for --format json)",
            "",
            "Rule Options:"
        ]
        lines += ruleOptionLines
        lines += [
            "",
            "Query Selectors:"
        ]

        for descriptor in IPCAutomationManifest.queryDescriptors where !descriptor.selectors.isEmpty {
            let selectors = descriptor.selectors
                .map { selector in
                    selector.name.expectsValue ? "\(selector.name.flag) <value>" : selector.name.flag
                }
                .joined(separator: ", ")
            lines.append("  \(descriptor.name.rawValue): \(selectors)")
        }

        lines.append("")
        lines.append("Query Fields:")
        for descriptor in IPCAutomationManifest.queryDescriptors where !descriptor.fields.isEmpty {
            lines.append("  \(descriptor.name.rawValue): \(descriptor.fields.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }()
}
