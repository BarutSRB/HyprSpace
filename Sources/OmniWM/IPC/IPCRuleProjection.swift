// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

@MainActor
enum IPCRuleProjection {
    static func result(
        settings: SettingsStore,
        windowRuleEngine: WindowRuleEngine
    ) -> IPCRulesQueryResult {
        let rules = settings.appRules.enumerated().map { index, rule in
            snapshot(
                from: rule,
                position: index + 1,
                invalidRegexMessagesByRuleId: windowRuleEngine.invalidRegexMessagesByRuleId
            )
        }
        return IPCRulesQueryResult(rules: rules)
    }

    static func snapshot(
        from rule: AppRule,
        position: Int,
        invalidRegexMessagesByRuleId: [UUID: String]
    ) -> IPCRuleSnapshot {
        let definition = definition(from: rule)
        let validation = IPCRuleValidator.validate(definition)
        let invalidRegexMessage = invalidRegexMessagesByRuleId[rule.id] ?? validation.invalidRegexMessage
        let validationMessages = [
            validation.bundleIdError,
            invalidRegexMessage,
            validation.identifierError,
            validation.titleMatcherError,
            validation.initialContainerPrimarySpanError,
            validation.effectError,
            validation.minSizeError
        ].compactMap { $0 }
        let isValid = validationMessages.isEmpty

        return IPCRuleSnapshot(
            id: rule.id.uuidString,
            position: position,
            bundleId: definition.bundleId,
            appNameSubstring: definition.appNameSubstring,
            titleSubstring: definition.titleSubstring,
            titleRegex: definition.titleRegex,
            axRole: definition.axRole,
            axSubrole: definition.axSubrole,
            layout: definition.layout,
            assignToWorkspace: definition.assignToWorkspace,
            initialContainerPrimarySpan: definition.initialContainerPrimarySpan,
            minWidth: definition.minWidth,
            minHeight: definition.minHeight,
            specificity: rule.specificity,
            isValid: isValid,
            invalidRegexMessage: invalidRegexMessage,
            validationMessages: validationMessages
        )
    }

    static func definition(from rule: AppRule) -> IPCRuleDefinition {
        normalized(
            IPCRuleDefinition(
                bundleId: rule.bundleId,
                appNameSubstring: rule.appNameSubstring,
                titleSubstring: rule.titleSubstring,
                titleRegex: rule.titleRegex,
                axRole: rule.axRole,
                axSubrole: rule.axSubrole,
                layout: ipcRuleLayout(from: rule.effectiveLayoutAction),
                assignToWorkspace: rule.assignToWorkspace,
                initialContainerPrimarySpan: rule.initialContainerPrimarySpan,
                minWidth: rule.minWidth,
                minHeight: rule.minHeight
            )
        )
    }

    static func appRule(from definition: IPCRuleDefinition, id: UUID = UUID()) -> AppRule {
        let normalized = normalized(definition)
        return AppRule(
            id: id,
            bundleId: normalized.bundleId,
            appNameSubstring: normalized.appNameSubstring,
            titleSubstring: normalized.titleSubstring,
            titleRegex: normalized.titleRegex,
            axRole: normalized.axRole,
            axSubrole: normalized.axSubrole,
            layout: windowRuleLayout(from: normalized.layout),
            assignToWorkspace: normalized.assignToWorkspace,
            initialContainerPrimarySpan: normalized.initialContainerPrimarySpan,
            minWidth: normalized.minWidth,
            minHeight: normalized.minHeight
        )
    }

    private static func normalized(_ definition: IPCRuleDefinition) -> IPCRuleDefinition {
        IPCRuleDefinition(
            bundleId: definition.bundleId.trimmingCharacters(in: .whitespacesAndNewlines),
            appNameSubstring: definition.appNameSubstring?.trimmedNonEmpty,
            titleSubstring: definition.titleSubstring?.trimmedNonEmpty,
            titleRegex: definition.titleRegex?.trimmedNonEmpty,
            axRole: definition.axRole?.trimmedNonEmpty,
            axSubrole: definition.axSubrole?.trimmedNonEmpty,
            layout: definition.layout,
            assignToWorkspace: definition.assignToWorkspace?.trimmedNonEmpty,
            initialContainerPrimarySpan: definition.initialContainerPrimarySpan,
            minWidth: definition.minWidth,
            minHeight: definition.minHeight
        )
    }

    private static func ipcRuleLayout(from action: WindowRuleLayoutAction) -> IPCRuleLayout {
        switch action {
        case .auto:
            .auto
        case .tile:
            .tile
        case .float:
            .float
        }
    }

    private static func windowRuleLayout(from layout: IPCRuleLayout) -> WindowRuleLayoutAction? {
        switch layout {
        case .auto:
            nil
        case .tile:
            .tile
        case .float:
            .float
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
