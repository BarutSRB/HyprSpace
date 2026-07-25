// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

enum TitleMatcherMode: String, CaseIterable, Identifiable {
    case none
    case substring
    case regex

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .none: "None"
        case .substring: "Contains"
        case .regex: "Regex"
        }
    }
}

enum AppRuleInitialContainerPrimarySpanPercent {
    static func percent(from proportion: Double) -> Double {
        proportion * 100
    }

    static func proportion(from percent: Double) -> Double {
        percent / 100
    }

    static func displayText(for proportion: Double) -> String {
        let percent = percent(from: proportion)
        if percent.isNaN { return "NaN" }
        if percent.isInfinite { return percent.sign == .minus ? "−∞" : "∞" }

        var text = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            percent
        )
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}

struct AppRuleDraft: Identifiable, Equatable {
    let id: UUID
    var bundleId: String
    var layoutAction: WindowRuleLayoutAction
    var assignToWorkspaceEnabled: Bool
    var assignToWorkspace: String
    var initialContainerPrimarySpanEnabled: Bool
    var initialContainerPrimarySpan: Double
    var minWidthEnabled: Bool
    var minWidth: Double
    var minHeightEnabled: Bool
    var minHeight: Double
    var appNameMatcherEnabled: Bool
    var appNameSubstring: String
    var titleMatcherMode: TitleMatcherMode
    var titleSubstring: String
    var titleRegex: String
    var axRoleEnabled: Bool
    var axRole: String
    var axSubroleEnabled: Bool
    var axSubrole: String

    init(id: UUID = UUID(), bundleId: String = "") {
        self.id = id
        self.bundleId = bundleId
        layoutAction = .auto
        assignToWorkspaceEnabled = false
        assignToWorkspace = ""
        initialContainerPrimarySpanEnabled = false
        initialContainerPrimarySpan = 0.5
        minWidthEnabled = false
        minWidth = 400
        minHeightEnabled = false
        minHeight = 300
        appNameMatcherEnabled = false
        appNameSubstring = ""
        titleMatcherMode = .none
        titleSubstring = ""
        titleRegex = ""
        axRoleEnabled = false
        axRole = ""
        axSubroleEnabled = false
        axSubrole = ""
    }

    init(rule: AppRule) {
        id = rule.id
        bundleId = rule.bundleId
        layoutAction = rule.effectiveLayoutAction
        assignToWorkspaceEnabled = rule.assignToWorkspace != nil
        assignToWorkspace = rule.assignToWorkspace ?? ""
        initialContainerPrimarySpanEnabled = rule.initialContainerPrimarySpan != nil
        initialContainerPrimarySpan = rule.initialContainerPrimarySpan ?? 0.5
        minWidthEnabled = rule.minWidth != nil
        minWidth = rule.minWidth ?? 400
        minHeightEnabled = rule.minHeight != nil
        minHeight = rule.minHeight ?? 300
        appNameMatcherEnabled = rule.appNameSubstring?.isEmpty == false
        appNameSubstring = rule.appNameSubstring ?? ""
        if rule.titleRegex?.isEmpty == false {
            titleMatcherMode = .regex
        } else if rule.titleSubstring?.isEmpty == false {
            titleMatcherMode = .substring
        } else {
            titleMatcherMode = .none
        }
        titleSubstring = rule.titleSubstring ?? ""
        titleRegex = rule.titleRegex ?? ""
        axRoleEnabled = rule.axRole?.isEmpty == false
        axRole = rule.axRole ?? ""
        axSubroleEnabled = rule.axSubrole?.isEmpty == false
        axSubrole = rule.axSubrole ?? ""
    }

    static func == (lhs: AppRuleDraft, rhs: AppRuleDraft) -> Bool {
        lhs.id == rhs.id &&
            lhs.bundleId == rhs.bundleId &&
            lhs.layoutAction == rhs.layoutAction &&
            lhs.assignToWorkspaceEnabled == rhs.assignToWorkspaceEnabled &&
            lhs.assignToWorkspace == rhs.assignToWorkspace &&
            lhs.initialContainerPrimarySpanEnabled == rhs.initialContainerPrimarySpanEnabled &&
            nanStableEqual(lhs.initialContainerPrimarySpan, rhs.initialContainerPrimarySpan) &&
            lhs.minWidthEnabled == rhs.minWidthEnabled &&
            nanStableEqual(lhs.minWidth, rhs.minWidth) &&
            lhs.minHeightEnabled == rhs.minHeightEnabled &&
            nanStableEqual(lhs.minHeight, rhs.minHeight) &&
            lhs.appNameMatcherEnabled == rhs.appNameMatcherEnabled &&
            lhs.appNameSubstring == rhs.appNameSubstring &&
            lhs.titleMatcherMode == rhs.titleMatcherMode &&
            lhs.titleSubstring == rhs.titleSubstring &&
            lhs.titleRegex == rhs.titleRegex &&
            lhs.axRoleEnabled == rhs.axRoleEnabled &&
            lhs.axRole == rhs.axRole &&
            lhs.axSubroleEnabled == rhs.axSubroleEnabled &&
            lhs.axSubrole == rhs.axSubrole
    }

    static func guided(from snapshot: WindowDecisionDebugSnapshot) -> AppRuleDraft? {
        let bundleId = snapshot.bundleId?.trimmedNonEmpty
        let appName = snapshot.appName?.trimmedNonEmpty
        guard bundleId != nil || appName != nil else { return nil }

        var draft = AppRuleDraft(bundleId: bundleId ?? "")
        if bundleId == nil, let appName {
            draft.appNameMatcherEnabled = true
            draft.appNameSubstring = appName
        }
        if let title = snapshot.title?.trimmedNonEmpty {
            draft.titleMatcherMode = .substring
            draft.titleSubstring = title
        }
        if let axRole = snapshot.axRole?.trimmedNonEmpty {
            draft.axRoleEnabled = true
            draft.axRole = axRole
        }
        if let axSubrole = snapshot.axSubrole?.trimmedNonEmpty {
            draft.axSubroleEnabled = true
            draft.axSubrole = axSubrole
        }
        return draft
    }

    var hasNarrowingMatchers: Bool {
        titleMatcherMode != .none || axRoleEnabled || axSubroleEnabled
    }

    var hasAnyRule: Bool {
        makeRule().hasAnyRule
    }

    var bundleIdError: String? {
        AppRuleDraftValidation.bundleIdError(for: bundleId)
    }

    var titleRegexError: String? {
        guard titleMatcherMode == .regex else { return nil }
        return AppRuleDraftValidation.titleRegexError(for: titleRegex)
    }

    var identifierHint: String? {
        guard hasAnyRule, !makeRule().hasIdentifyingMatcher else { return nil }
        return "Add a bundle ID, app name, or title — AX role/subrole alone match too broadly."
    }

    var minSizeError: String? {
        if minWidthEnabled, !(minWidth.isFinite && minWidth > 0) {
            return "Minimum width must be a positive number."
        }
        if minHeightEnabled, !(minHeight.isFinite && minHeight > 0) {
            return "Minimum height must be a positive number."
        }
        return nil
    }

    var initialContainerPrimarySpanError: String? {
        IPCRuleValidator.initialContainerPrimarySpanError(
            for: initialContainerPrimarySpanEnabled ? initialContainerPrimarySpan : nil
        )
    }

    var effectHint: String? {
        let rule = makeRule()
        guard rule.hasIdentifyingMatcher, !rule.hasEffect else { return nil }
        return "This rule matches windows but has no effect — set a layout, workspace, initial container primary span, "
            + "or minimum size."
    }

    var isValid: Bool {
        let rule = makeRule()
        return bundleIdError == nil && titleRegexError == nil && initialContainerPrimarySpanError == nil &&
            minSizeError == nil
            && rule.hasIdentifyingMatcher && rule.hasEffect
    }

    func represents(_ rule: AppRule) -> Bool {
        AppRuleDraft(rule: makeRule(id: rule.id)) == AppRuleDraft(rule: rule)
    }

    mutating func selectApplication(bundleId: String?, appName: String) {
        if let bundleId {
            self.bundleId = bundleId
            appNameMatcherEnabled = false
            appNameSubstring = ""
        } else {
            self.bundleId = ""
            appNameMatcherEnabled = true
            appNameSubstring = appName
        }
    }

    func makeRule(id: UUID? = nil) -> AppRule {
        AppRule(
            id: id ?? self.id,
            bundleId: bundleId.trimmingCharacters(in: .whitespacesAndNewlines),
            appNameSubstring: appNameMatcherEnabled ? appNameSubstring.trimmedNonEmpty : nil,
            titleSubstring: titleMatcherMode == .substring ? titleSubstring.trimmedNonEmpty : nil,
            titleRegex: titleMatcherMode == .regex ? titleRegex.trimmedNonEmpty : nil,
            axRole: axRoleEnabled ? axRole.trimmedNonEmpty : nil,
            axSubrole: axSubroleEnabled ? axSubrole.trimmedNonEmpty : nil,
            layout: layoutAction == .auto ? nil : layoutAction,
            assignToWorkspace: assignToWorkspaceEnabled ? assignToWorkspace.trimmedNonEmpty : nil,
            initialContainerPrimarySpan: initialContainerPrimarySpanEnabled ? initialContainerPrimarySpan : nil,
            minWidth: minWidthEnabled ? minWidth : nil,
            minHeight: minHeightEnabled ? minHeight : nil
        )
    }

    private static func nanStableEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs == rhs || (lhs.isNaN && rhs.isNaN)
    }
}

enum AppRuleDraftValidation {
    static func bundleIdError(for bundleId: String) -> String? {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return IPCRuleValidator.bundleIdError(for: trimmed)
    }

    static func titleRegexError(for pattern: String?) -> String? {
        IPCRuleValidator.invalidRegexMessage(for: pattern?.trimmedNonEmpty)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
