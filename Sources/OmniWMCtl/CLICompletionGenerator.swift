// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

enum CLICompletionGenerator {
    private static let subscribeFlags = ["--all", "--no-send-initial", "--reconnect"]
    private static let watchFlags = ["--all", "--no-send-initial", "--reconnect", "--exec"]

    static func script(for shell: CLIShell) -> String {
        switch shell {
        case .zsh:
            zshScript()
        case .bash:
            bashScript()
        case .fish:
            fishScript()
        }
    }

    private static func zshScript() -> String {
        """
        #compdef omniwmctl

        _omniwmctl() {
          local cur
          cur="${words[CURRENT]}"

          local suggestions=""
          if (( CURRENT == 2 )); then
            suggestions="\(shellWords(topLevelCommands))"
            compadd -- ${=suggestions}
            return
          fi

          case "${words[2]}" in
            query)
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(queryNames))"
              else
                local query_name="${words[3]}"
                local prev="${words[CURRENT-1]}"
                if [[ "$prev" == "--fields" ]]; then
                  case "$query_name" in
                    \(renderZshCase(map: queryFieldsByName))
                  esac
                else
                  case "$query_name" in
                    \(renderZshCase(map: queryFlagsByName))
                  esac
                fi
              fi
              ;;
            command)
              local first="${words[3]}"
              local second="${words[4]}"
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(commandFirstWords))"
              elif (( CURRENT == 4 )); then
                case "$first" in
                  \(renderZshCase(map: commandSlotThreeSuggestionsByFirst))
                esac
              elif (( CURRENT == 5 )); then
                case "$first $second" in
                  \(renderZshCase(map: commandSlotFourSuggestionsByPath))
                  *)
                    case "$first" in
                      \(renderZshCase(map: commandSlotFourFallbackByFirst))
                    esac
                    ;;
                esac
              elif (( CURRENT == 6 )); then
                case "$first $second" in
                  \(renderZshCase(map: commandSlotFiveSuggestionsByPath))
                esac
              fi
              ;;
            rule)
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(ruleActionNames))"
              elif [[ "${words[3]}" == "add" || "${words[3]}" == "replace" ]]; then
                local prev="${words[CURRENT-1]}"
                if [[ " \(shellWords(ruleDefinitionFlags)) " != *" $prev "* ]]; then
                  suggestions="\(shellWords(ruleDefinitionFlags))"
                fi
              elif [[ "${words[3]}" == "apply" ]]; then
                local prev="${words[CURRENT-1]}"
                if [[ "$prev" != "--window" && "$prev" != "--pid" ]]; then
                  suggestions="\(shellWords(ruleApplyFlags))"
                fi
              fi
              ;;
            capture)
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(captureActionNames))"
              elif (( CURRENT == 4 )) && [[ "${words[3]}" == "start" ]]; then
                suggestions="\(shellWords(captureProfiles))"
              fi
              ;;
            subscribe)
              if [[ " ${words[*]} " != *" --exec "* ]]; then
                suggestions="\(shellWords(sortedUnique(subscriptionNames + subscribeFlags)))"
              fi
              ;;
            watch)
              if [[ " ${words[*]} " != *" --exec "* ]]; then
                suggestions="\(shellWords(sortedUnique(subscriptionNames + watchFlags)))"
              fi
              ;;
            workspace)
              local action="${words[3]}"
              local workspace_positionals=0
              local index token skip_format_value=0
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(workspaceActionNames))"
              elif [[ "$action" == "\(workspaceMoveActionName)" ]]; then
                for (( index = 4; index < CURRENT; index++ )); do
                  token="${words[index]}"
                  if (( skip_format_value )); then
                    skip_format_value=0
                  elif [[ "$token" == "--format" ]]; then
                    skip_format_value=1
                  elif [[ "$token" != --* ]]; then
                    (( workspace_positionals += 1 ))
                  fi
                done
                if (( workspace_positionals == 1 )); then
                  suggestions="\(shellWords(workspaceMoveDirections))"
                fi
                if (( workspace_positionals <= 2 )) &&
                   [[ " ${words[*]} " != *" --force "* ]]; then
                  suggestions="$suggestions \(shellWords(workspaceMoveOptionalFlags))"
                fi
              fi
              ;;
            window)
              suggestions="\(shellWords(windowActionNames))"
              ;;
            completion)
              suggestions="zsh bash fish"
              ;;
          esac

          [[ -n "$suggestions" ]] && compadd -- ${=suggestions}
        }

        _omniwmctl "$@"
        """
    }

    private static func bashScript() -> String {
        """
        _omniwmctl()
        {
          local cur prev command first second query_name suggestions workspace_action
          local workspace_positionals index token skip_format_value
          COMPREPLY=()
          cur="${COMP_WORDS[COMP_CWORD]}"
          prev="${COMP_WORDS[COMP_CWORD-1]}"
          command="${COMP_WORDS[1]}"

          __omniwmctl_compgen() {
            COMPREPLY=( $(compgen -W "$1" -- "$cur") )
          }

          if [[ ${COMP_CWORD} -eq 1 ]]; then
            __omniwmctl_compgen "\(shellWords(topLevelCommands))"
            return 0
          fi

          case "$command" in
            query)
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __omniwmctl_compgen "\(shellWords(queryNames))"
                return 0
              fi

              query_name="${COMP_WORDS[2]}"
              suggestions=""
              if [[ "$prev" == "--fields" ]]; then
                case "$query_name" in
                  \(renderBashCase(map: queryFieldsByName))
                esac
              else
                case "$query_name" in
                  \(renderBashCase(map: queryFlagsByName))
                esac
              fi
              __omniwmctl_compgen "$suggestions"
              return 0
              ;;
            command)
              first="${COMP_WORDS[2]}"
              second="${COMP_WORDS[3]}"
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __omniwmctl_compgen "\(shellWords(commandFirstWords))"
                return 0
              elif [[ ${COMP_CWORD} -eq 3 ]]; then
                suggestions=""
                case "$first" in
                  \(renderBashCase(map: commandSlotThreeSuggestionsByFirst))
                esac
                __omniwmctl_compgen "$suggestions"
                return 0
              elif [[ ${COMP_CWORD} -eq 4 ]]; then
                suggestions=""
                case "$first $second" in
                  \(renderBashCase(map: commandSlotFourSuggestionsByPath))
                  *)
                    case "$first" in
                      \(renderBashCase(map: commandSlotFourFallbackByFirst))
                    esac
                    ;;
                esac
                __omniwmctl_compgen "$suggestions"
                return 0
              elif [[ ${COMP_CWORD} -eq 5 ]]; then
                suggestions=""
                case "$first $second" in
                  \(renderBashCase(map: commandSlotFiveSuggestionsByPath))
                esac
                __omniwmctl_compgen "$suggestions"
                return 0
              fi
              ;;
            rule)
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __omniwmctl_compgen "\(shellWords(ruleActionNames))"
                return 0
              fi
              if [[ "${COMP_WORDS[2]}" == "add" || "${COMP_WORDS[2]}" == "replace" ]]; then
                if [[ " \(shellWords(ruleDefinitionFlags)) " != *" $prev "* ]]; then
                  __omniwmctl_compgen "\(shellWords(ruleDefinitionFlags))"
                  return 0
                fi
              fi
              if [[ "${COMP_WORDS[2]}" == "apply" && "$prev" != "--window" && "$prev" != "--pid" ]]; then
                __omniwmctl_compgen "\(shellWords(ruleApplyFlags))"
                return 0
              fi
              ;;
            capture)
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __omniwmctl_compgen "\(shellWords(captureActionNames))"
                return 0
              elif [[ ${COMP_CWORD} -eq 3 && "${COMP_WORDS[2]}" == "start" ]]; then
                __omniwmctl_compgen "\(shellWords(captureProfiles))"
                return 0
              fi
              ;;
            subscribe)
              if [[ " ${COMP_WORDS[*]} " != *" --exec "* ]]; then
                __omniwmctl_compgen "\(shellWords(sortedUnique(subscriptionNames + subscribeFlags)))"
                return 0
              fi
              ;;
            watch)
              if [[ " ${COMP_WORDS[*]} " != *" --exec "* ]]; then
                __omniwmctl_compgen "\(shellWords(sortedUnique(subscriptionNames + watchFlags)))"
                return 0
              fi
              ;;
            workspace)
              workspace_action="${COMP_WORDS[2]}"
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __omniwmctl_compgen "\(shellWords(workspaceActionNames))"
              elif [[ "$workspace_action" == "\(workspaceMoveActionName)" ]]; then
                workspace_positionals=0
                skip_format_value=0
                for (( index = 3; index < COMP_CWORD; index++ )); do
                  token="${COMP_WORDS[index]}"
                  if [[ ${skip_format_value} -eq 1 ]]; then
                    skip_format_value=0
                  elif [[ "$token" == "--format" ]]; then
                    skip_format_value=1
                  elif [[ "$token" != --* ]]; then
                    (( workspace_positionals += 1 ))
                  fi
                done
                if [[ ${workspace_positionals} -eq 1 ]]; then
                  suggestions="\(shellWords(workspaceMoveDirections))"
                fi
                if [[ ${workspace_positionals} -le 2 ]] &&
                   [[ " ${COMP_WORDS[*]} " != *" --force "* ]]; then
                  suggestions="$suggestions \(shellWords(workspaceMoveOptionalFlags))"
                fi
                __omniwmctl_compgen "$suggestions"
              fi
              return 0
              ;;
            window)
              __omniwmctl_compgen "\(shellWords(windowActionNames))"
              return 0
              ;;
            completion)
              __omniwmctl_compgen "zsh bash fish"
              return 0
              ;;
          esac
        }

        complete -F _omniwmctl omniwmctl
        """
    }

    private static func fishScript() -> String {
        let helperFunctions = """
        function __omniwmctl_prev_arg_is
            set -l tokens (commandline -opc)
            test (count $tokens) -gt 0; or return 1
            set -l prev $tokens[-1]
            contains -- $prev $argv
        end

        function __omniwmctl_has_arg
            set -l tokens (commandline -opc)
            contains -- $argv[1] $tokens
        end

        function __omniwmctl_workspace_positionals
            set -l count 0
            set -l action_seen false
            set -l skip_format_value false
            for token in (commandline -opc)
                if test "$action_seen" = false
                    if test "$token" = "\(workspaceMoveActionName)"
                        set action_seen true
                    end
                else if test "$skip_format_value" = true
                    set skip_format_value false
                else if test "$token" = "--format"
                    set skip_format_value true
                else if not string match -q -- '--*' "$token"
                    set count (math $count + 1)
                end
            end
            echo $count
        end

        function __omniwmctl_workspace_positionals_are
            test (__omniwmctl_workspace_positionals) -eq "$argv[1]"
        end

        function __omniwmctl_workspace_positionals_at_most
            test (__omniwmctl_workspace_positionals) -le "$argv[1]"
        end
        """

        let baseLines = topLevelCommands.map { command in
            "complete -c omniwmctl -f -n '__fish_use_subcommand' -a '\(command)'"
        }
        let queryLines = queryNames.map { query in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from query' -a '\(query)'"
        }
        let queryFlagLines = queryFlagsByName.flatMap { queryName, flags in
            flags.map { flag in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from query; and __fish_seen_subcommand_from \(queryName)' -a '\(flag)'"
            }
        }
        let queryFieldLines = queryFieldsByName.flatMap { queryName, fields in
            fields.map { field in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from query; and __fish_seen_subcommand_from \(queryName); and __omniwmctl_prev_arg_is --fields' -a '\(field)'"
            }
        }
        let commandRootLines = commandFirstWords.map { word in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command' -a '\(word)'"
        }
        let commandNestedLines = commandSlotThreeSuggestionsByFirst.flatMap { first, suggestions in
            suggestions.map { suggestion in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(first)' -a '\(suggestion)'"
            }
        }
        let commandPathArgumentLines = commandSlotFourSuggestionsByPath.flatMap { path, suggestions in
            let pathWords = path.split(separator: " ").map(String.init)
            guard pathWords.count == 2 else { return [String]() }
            return suggestions.map { suggestion in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(pathWords[0]); and __fish_seen_subcommand_from \(pathWords[1])' -a '\(suggestion)'"
            }
        }
        let commandFallbackLines = commandSlotFourFallbackByFirst.flatMap { first, suggestions in
            suggestions.map { suggestion in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(first)' -a '\(suggestion)'"
            }
        }
        let commandSecondArgumentLines = commandSlotFiveSuggestionsByPath.flatMap { path, suggestions in
            let pathWords = path.split(separator: " ").map(String.init)
            guard pathWords.count == 2 else { return [String]() }
            return suggestions.map { suggestion in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(pathWords[0]); and __fish_seen_subcommand_from \(pathWords[1])' -a '\(suggestion)'"
            }
        }
        let ruleLines = ruleActionNames.map { action in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from rule' -a '\(action)'"
        }
        let ruleDefinitionLines = ruleDefinitionFlags.flatMap { flag in
            [
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from rule; and __fish_seen_subcommand_from add' -a '\(flag)'",
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from rule; and __fish_seen_subcommand_from replace' -a '\(flag)'"
            ]
        }
        let ruleApplyLines = ruleApplyFlags.map { flag in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from rule; and __fish_seen_subcommand_from apply' -a '\(flag)'"
        }
        let captureActionLines = captureActionNames.map { action in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from capture; and not __fish_seen_subcommand_from \(shellWords(captureActionNames))' -a '\(action)'"
        }
        let captureProfileLines = captureProfiles.map { profile in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from capture; and __fish_seen_subcommand_from start; and not __fish_seen_subcommand_from \(shellWords(captureProfiles))' -a '\(profile)'"
        }
        let subscribeLines = sortedUnique(subscriptionNames + subscribeFlags).map { token in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from subscribe' -a '\(token)'"
        }
        let watchLines = sortedUnique(subscriptionNames + watchFlags).map { token in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from watch' -a '\(token)'"
        }
        let workspaceLines = workspaceActionNames.map { action in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from workspace; and not __fish_seen_subcommand_from \(shellWords(workspaceActionNames))' -a '\(action)'"
        }
        let workspaceMoveDirectionLines = workspaceMoveDirections.map { direction in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from workspace; and __fish_seen_subcommand_from \(workspaceMoveActionName); and __omniwmctl_workspace_positionals_are 1' -a '\(direction)'"
        }
        let workspaceMoveFlagLines = workspaceMoveOptionalFlags.map { flag in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from workspace; and __fish_seen_subcommand_from \(workspaceMoveActionName); and __omniwmctl_workspace_positionals_at_most 2; and not __omniwmctl_has_arg \(flag)' -a '\(flag)'"
        }
        let windowLines = windowActionNames.map { action in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from window' -a '\(action)'"
        }
        let shellLines = CLIShell.allCases.map { shell in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from completion' -a '\(shell.rawValue)'"
        }

        return (
            [helperFunctions]
                + baseLines
                + queryLines
                + queryFlagLines.sorted()
                + queryFieldLines.sorted()
                + commandRootLines
                + commandNestedLines.sorted()
                + commandPathArgumentLines.sorted()
                + commandFallbackLines.sorted()
                + commandSecondArgumentLines.sorted()
                + ruleLines
                + ruleDefinitionLines
                + ruleApplyLines
                + captureActionLines
                + captureProfileLines
                + subscribeLines
                + watchLines
                + workspaceLines
                + workspaceMoveDirectionLines
                + workspaceMoveFlagLines
                + windowLines
                + shellLines
        )
        .joined(separator: "\n")
    }

    private static var topLevelCommands: [String] {
        [
            "ping",
            "version",
            "help",
            "completion",
            "command",
            "query",
            "rule",
            "capture",
            "workspace",
            "window",
            "subscribe",
            "watch"
        ]
    }

    private static var queryNames: [String] {
        sortedUnique(IPCAutomationManifest.queryDescriptors.map(\.name.rawValue))
    }

    private static var subscriptionNames: [String] {
        IPCSubscriptionChannel.allCases.map(\.rawValue)
    }

    private static var ruleActionNames: [String] {
        IPCAutomationManifest.ruleActionDescriptors.map(\.name.rawValue)
    }

    private static var ruleApplyFlags: [String] {
        IPCAutomationManifest.ruleActionDescriptor(for: .apply)?.options.map(\.flag) ?? []
    }

    private static var ruleDefinitionFlags: [String] {
        IPCAutomationManifest.ruleDefinitionOptionDescriptors.map(\.flag)
    }

    private static var captureActionNames: [String] {
        IPCAutomationManifest.captureActionDescriptors.map(\.name.rawValue)
    }

    private static var captureProfiles: [String] {
        [IPCCaptureProfile.trace.rawValue, IPCCaptureProfile.performance.rawValue]
    }

    private static var workspaceActionNames: [String] {
        IPCAutomationManifest.workspaceActionDescriptors.map(\.name.rawValue)
    }

    private static var workspaceMoveActionName: String {
        IPCWorkspaceActionName.moveToMonitor.rawValue
    }

    private static var workspaceMoveDirections: [String] {
        literalValues(for: .direction) ?? []
    }

    private static var workspaceMoveOptionalFlags: [String] {
        IPCAutomationManifest.workspaceActionDescriptors
            .first { $0.name == .moveToMonitor }?
            .optionalFlags ?? []
    }

    private static var windowActionNames: [String] {
        IPCAutomationManifest.windowActionDescriptors.map(\.name.rawValue)
    }

    private static var commandFirstWords: [String] {
        sortedUnique(IPCAutomationManifest.commandDescriptors.compactMap { $0.commandWords.first })
    }

    private static var commandSlotThreeSuggestionsByFirst: [String: [String]] {
        var map: [String: Set<String>] = [:]

        for descriptor in IPCAutomationManifest.commandDescriptors {
            guard let first = descriptor.commandWords.first else { continue }
            if descriptor.commandWords.count > 1 {
                map[first, default: []].insert(descriptor.commandWords[1])
            }
            if let literals = literalValues(for: descriptor.arguments.first?.kind) {
                map[first, default: []].formUnion(literals)
            }
        }

        return map.mapValues { Array($0).sorted() }
    }

    private static var commandSlotFourSuggestionsByPath: [String: [String]] {
        commandArgumentSuggestionsByPath(argumentIndex: 0, commandWordCount: 2)
    }

    private static var commandSlotFourFallbackByFirst: [String: [String]] {
        var map: [String: Set<String>] = [:]
        for descriptor in IPCAutomationManifest.commandDescriptors where descriptor.commandWords.count == 1 {
            guard descriptor.arguments.count > 1,
                  let literals = literalValues(for: descriptor.arguments[1].kind),
                  let first = descriptor.commandWords.first
            else {
                continue
            }
            map[first, default: []].formUnion(literals)
        }
        return map.mapValues { Array($0).sorted() }
    }

    private static var commandSlotFiveSuggestionsByPath: [String: [String]] {
        commandArgumentSuggestionsByPath(argumentIndex: 1, commandWordCount: 2)
    }

    private static func commandArgumentSuggestionsByPath(
        argumentIndex: Int,
        commandWordCount: Int
    ) -> [String: [String]] {
        var map: [String: Set<String>] = [:]
        for descriptor in IPCAutomationManifest.commandDescriptors
            where descriptor.commandWords.count == commandWordCount
        {
            guard descriptor.arguments.count > argumentIndex,
                  let literals = literalValues(for: descriptor.arguments[argumentIndex].kind)
            else {
                continue
            }
            map[pathKey(descriptor.commandWords), default: []].formUnion(literals)
        }
        return map.mapValues { Array($0).sorted() }
    }

    private static var queryFlagsByName: [String: [String]] {
        var map: [String: [String]] = [:]
        for descriptor in IPCAutomationManifest.queryDescriptors {
            let flags = sortedUnique(selectorFlags(for: descriptor) + (descriptor.fields.isEmpty ? [] : ["--fields"]))
            map[descriptor.name.rawValue] = flags
        }
        return map
    }

    private static var queryFieldsByName: [String: [String]] {
        Dictionary(
            uniqueKeysWithValues: IPCAutomationManifest.queryDescriptors.map { descriptor in
                (descriptor.name.rawValue, descriptor.fields)
            }
        )
    }

    private static func selectorFlags(for descriptor: IPCQueryDescriptor) -> [String] {
        descriptor.selectors.map(\.name.flag)
    }

    private static func literalValues(for kind: IPCCommandArgumentKind?) -> [String]? {
        guard let kind else { return nil }
        switch kind {
        case .direction:
            return ["left", "right", "up", "down"]
        case .layout:
            return ["default", "niri", "dwindle"]
        case .resizeAxis:
            return ["horizontal", "vertical"]
        case .resizeOperation:
            return ["grow", "shrink"]
        case .scratchpadIndex:
            return IPCScratchpadSlots.range.map(String.init)
        case .workspaceNumber,
             .columnIndex,
             .windowIndex,
             .sizeChange:
            return nil
        }
    }

    private static func pathKey(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    private static func renderZshCase(map: [String: [String]]) -> String {
        map.keys.sorted().map { key in
            """
            \(quotedCasePattern(key)))
                            suggestions="\(shellWords(map[key] ?? []))"
                            ;;
            """
        }
        .joined(separator: "\n                  ")
    }

    private static func renderBashCase(map: [String: [String]]) -> String {
        map.keys.sorted().map { key in
            """
            \(quotedCasePattern(key)))
                  suggestions="\(shellWords(map[key] ?? []))"
                  ;;
            """
        }
        .joined(separator: "\n                ")
    }

    private static func quotedCasePattern(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func shellWords(_ words: [String]) -> String {
        sortedUnique(words).joined(separator: " ")
    }
}
