// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum WindowDecisionDisposition: Equatable, Sendable {
    case managed
    case floating
    case unmanaged
    case undecided
}

enum WindowDecisionSource: Equatable, Sendable {
    case manualOverride
    case userRule(UUID)
    case builtInRule(String)
    case heuristic
}

enum WindowDecisionLayoutKind: String, Equatable, Sendable {
    case explicitLayout
    case fallbackLayout
}

enum WindowDecisionDeferredReason: String, Equatable, Sendable {
    case attributeFetchFailed
    case independentRootEvidenceMissing
    case requiredTitleMissing
    case windowServerEvidenceMissing
}

enum WindowDecisionAdmissionOutcome: String, Equatable, Sendable {
    case trackedTiling
    case trackedFloating
    case ignored
    case deferred
}

enum ManualWindowOverride: String, Codable, Equatable {
    case forceTile
    case forceFloat
}

struct ManagedWindowRuleEffects: Equatable, Sendable {
    var minWidth: Double?
    var minHeight: Double?
    var matchedRuleId: UUID?

    static let none = ManagedWindowRuleEffects()
}

struct ManagedWindowAdmissionHints: Equatable, Sendable {
    var initialNiriContainerPrimarySpan: Double?

    static let none = ManagedWindowAdmissionHints()
}

struct WindowDecision: Equatable, Sendable {
    let disposition: WindowDecisionDisposition
    let source: WindowDecisionSource
    let layoutDecisionKind: WindowDecisionLayoutKind
    let workspaceName: String?
    let ruleEffects: ManagedWindowRuleEffects
    let admissionHints: ManagedWindowAdmissionHints
    let heuristicReasons: [AXWindowHeuristicReason]
    let deferredReason: WindowDecisionDeferredReason?

    var managesWindow: Bool {
        disposition == .managed
    }

    var trackedMode: TrackedWindowMode? {
        switch disposition {
        case .managed:
            .tiling
        case .floating:
            .floating
        case .unmanaged,
             .undecided:
            nil
        }
    }

    var admissionOutcome: WindowDecisionAdmissionOutcome {
        switch disposition {
        case .managed:
            .trackedTiling
        case .floating:
            .trackedFloating
        case .unmanaged:
            .ignored
        case .undecided:
            .deferred
        }
    }

    var tracksWindow: Bool {
        trackedMode != nil
    }

    var reflectsExplicitUserIntent: Bool {
        switch source {
        case .manualOverride,
             .userRule:
            true
        case .builtInRule,
             .heuristic:
            false
        }
    }

    var isResolved: Bool {
        disposition != .undecided
    }

    @MainActor
    var isUnprovenIndependentRootDecision: Bool {
        source == .builtInRule(WindowRuleEngine.unprovenIndependentRootRuleName)
    }
}

struct WindowRuleFacts: Equatable, Sendable {
    let appName: String?
    let ax: AXWindowFacts
    let sizeConstraints: WindowSizeConstraints?
    let windowServer: WindowServerInfo?

    var degradedWindowServerChildEvidence: Bool {
        guard !ax.attributeFetchSucceeded,
              let windowServer
        else {
            return false
        }
        return windowServer.hasModalTag || (windowServer.hasFloatingTag && !windowServer.hasDocumentTag)
    }
}

enum WindowRuleReevaluationTarget: Hashable, Sendable {
    case window(WindowToken)
    case pid(pid_t)
}

enum WindowRuleReevaluationContext: Equatable, Sendable {
    case automatic
    case explicitRuleApply
}

struct WindowRuleReevaluationOutcome: Equatable, Sendable {
    let resolvedAnyTarget: Bool
    let evaluatedAnyWindow: Bool
    let relayoutNeeded: Bool
    let stale: Bool

    init(
        resolvedAnyTarget: Bool,
        evaluatedAnyWindow: Bool,
        relayoutNeeded: Bool,
        stale: Bool = false
    ) {
        self.resolvedAnyTarget = resolvedAnyTarget
        self.evaluatedAnyWindow = evaluatedAnyWindow
        self.relayoutNeeded = relayoutNeeded
        self.stale = stale
    }

    static let none = WindowRuleReevaluationOutcome(
        resolvedAnyTarget: false,
        evaluatedAnyWindow: false,
        relayoutNeeded: false
    )
}

struct WindowDecisionDebugSnapshot: Equatable, Sendable {
    let token: WindowToken?
    let appName: String?
    let bundleId: String?
    let title: String?
    let axRole: String?
    let axSubrole: String?
    let appFullscreen: Bool
    let manualOverride: ManualWindowOverride?
    let disposition: WindowDecisionDisposition
    let source: WindowDecisionSource
    let layoutDecisionKind: WindowDecisionLayoutKind
    let deferredReason: WindowDecisionDeferredReason?
    let admissionOutcome: WindowDecisionAdmissionOutcome
    let workspaceName: String?
    let minWidth: Double?
    let minHeight: Double?
    let initialNiriContainerPrimarySpan: Double?
    let matchedRuleId: UUID?
    let heuristicReasons: [AXWindowHeuristicReason]
    let attributeFetchSucceeded: Bool

    var sourceDescription: String {
        switch source {
        case .manualOverride:
            "manualOverride"
        case let .userRule(ruleId):
            "userRule(\(ruleId.uuidString))"
        case let .builtInRule(name):
            "builtInRule(\(name))"
        case .heuristic:
            "heuristic"
        }
    }

    private func stringValue<T>(_ value: T?) -> String {
        value.map { String(describing: $0) } ?? "nil"
    }

    func formattedDump() -> String {
        let lines: [String] = [
            "token=\(token.map { "\($0.pid):\($0.windowId)" } ?? "nil")",
            "appName=\(appName ?? "nil")",
            "bundleId=\(bundleId ?? "nil")",
            "title=\(title ?? "nil")",
            "axRole=\(axRole ?? "nil")",
            "axSubrole=\(axSubrole ?? "nil")",
            "appFullscreen=\(appFullscreen)",
            "manualOverride=\(manualOverride?.rawValue ?? "nil")",
            "disposition=\(String(describing: disposition))",
            "source=\(sourceDescription)",
            "layoutDecisionKind=\(layoutDecisionKind.rawValue)",
            "deferredReason=\(deferredReason?.rawValue ?? "nil")",
            "admissionOutcome=\(admissionOutcome.rawValue)",
            "workspaceName=\(workspaceName ?? "nil")",
            "minWidth=\(stringValue(minWidth))",
            "minHeight=\(stringValue(minHeight))",
            "initialNiriContainerPrimarySpan=\(stringValue(initialNiriContainerPrimarySpan))",
            "matchedRuleId=\(matchedRuleId?.uuidString ?? "nil")",
            "heuristicReasons=\(heuristicReasons.map(\.rawValue).joined(separator: ","))",
            "attributeFetchSucceeded=\(attributeFetchSucceeded)"
        ]
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class WindowRuleEngine {
    static let ownedWindowRuleName = "ownedWindow"
    nonisolated static let externalSurfaceRuleName = "externalSurface"
    nonisolated static let unprovenIndependentRootRuleName = "unprovenIndependentRoot"
    nonisolated static let hiddenTitleBarWindowRuleName = "hiddenTitleBarWindow"
    private static let finderQuickLookSubrole = "Quick Look"
    private static let nativeFullscreenSubrole = "AXFullScreenWindow"
    private static let systemSurfaceLevelFloor = CGWindowLevelForKey(.statusWindow)

    private enum StructuralEligibility {
        case eligible
        case requiresExplicitInclusion
        case requiresExplicitUserInclusion
        case requiresIndependentRootInclusion
        case external
        case deferred(WindowDecisionDeferredReason)
    }

    private enum RuleSource {
        case user
        case builtIn(String)
    }

    private struct CompiledRule {
        let rule: AppRule
        let source: RuleSource
        let titleRegex: NSRegularExpression?
        let order: Int

        var requiresTitle: Bool {
            rule.titleSubstring?.isEmpty == false || titleRegex != nil
        }

        var requiresDynamicReevaluation: Bool {
            rule.hasAdvancedMatchers
        }

        func matchesApp(bundleId: String?, appName: String?) -> Bool {
            if let requiredBundleId = nonEmpty(rule.bundleId),
               requiredBundleId.caseInsensitiveCompare(bundleId ?? "") != .orderedSame
            {
                return false
            }
            if let appNameSubstring = nonEmpty(rule.appNameSubstring) {
                guard let appName,
                      appName.localizedCaseInsensitiveContains(appNameSubstring)
                else {
                    return false
                }
            }
            return true
        }

        func canApplyExplicitly(to facts: WindowRuleFacts) -> Bool {
            switch source {
            case .builtIn("steamClient"):
                facts.ax.attributeFetchSucceeded
            case .user,
                 .builtIn:
                true
            }
        }

        var explicitlyIncludesNonstandardSurface: Bool {
            rule.effectiveLayoutAction != .auto
                && nonEmpty(rule.axRole) != nil
                && nonEmpty(rule.axSubrole) != nil
        }

        func matches(_ facts: WindowRuleFacts) -> Bool {
            if let bundleId = nonEmpty(rule.bundleId),
               bundleId.caseInsensitiveCompare(facts.ax.bundleId ?? "") != .orderedSame
            {
                return false
            }

            if let appNameSubstring = nonEmpty(rule.appNameSubstring) {
                guard let appName = facts.appName,
                      appName.localizedCaseInsensitiveContains(appNameSubstring)
                else {
                    return false
                }
            }

            if let titleSubstring = nonEmpty(rule.titleSubstring) {
                guard let title = facts.ax.title,
                      title.localizedCaseInsensitiveContains(titleSubstring)
                else {
                    return false
                }
            }

            if let titleRegex {
                guard let title = facts.ax.title else { return false }
                let range = NSRange(title.startIndex..., in: title)
                guard titleRegex.firstMatch(in: title, range: range) != nil else {
                    return false
                }
            }

            if let axRole = nonEmpty(rule.axRole), facts.ax.role != axRole {
                return false
            }

            if let axSubrole = nonEmpty(rule.axSubrole), facts.ax.subrole != axSubrole {
                return false
            }

            return true
        }

        private func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    private var compiledUserRules: [CompiledRule] = []
    private let builtInRules: [CompiledRule]
    private var titleRules: [CompiledRule] = []
    private(set) var invalidRegexMessagesByRuleId: [UUID: String] = [:]

    private(set) var hasDynamicReevaluationRules = false
    private let inputMethodBundleIds: Set<String>
    private let hiddenTitleBarFullscreenButtonOptionalBundleIds: Set<String>
    private let hiddenTitleBarNonStandardSubroleBundleIds: Set<String>

    init(
        inputMethodBundleIds: Set<String>? = nil,
        hiddenTitleBarFullscreenButtonOptionalBundleIds: Set<String>? = nil,
        hiddenTitleBarNonStandardSubroleBundleIds: Set<String>? = nil
    ) {
        self.hiddenTitleBarFullscreenButtonOptionalBundleIds = hiddenTitleBarFullscreenButtonOptionalBundleIds
            ?? HiddenTitleBarRegistry.fullscreenButtonOptionalBundleIds
        self.hiddenTitleBarNonStandardSubroleBundleIds = hiddenTitleBarNonStandardSubroleBundleIds
            ?? HiddenTitleBarRegistry.nonStandardSubroleBundleIds
        self.inputMethodBundleIds = inputMethodBundleIds ?? InputMethodBundleRegistry.discover()
        builtInRules = Self.makeBuiltInRules()
        titleRules = builtInRules.filter(\.requiresTitle)
        hasDynamicReevaluationRules = builtInRules.contains { $0.requiresDynamicReevaluation }
    }

    var needsWindowReevaluation: Bool {
        hasDynamicReevaluationRules
    }

    func requiresTitle(for bundleId: String?, appName: String? = nil) -> Bool {
        titleRules.contains { $0.matchesApp(bundleId: bundleId, appName: appName) }
    }

    func rebuild(rules: [AppRule]) {
        var invalidRegexMessagesByRuleId: [UUID: String] = [:]
        compiledUserRules = rules.enumerated().compactMap { index, rule in
            guard rule.hasIdentifyingMatcher, rule.hasEffect else { return nil }
            return compile(
                rule: rule,
                source: .user,
                order: index,
                invalidRegexMessagesByRuleId: &invalidRegexMessagesByRuleId
            )
        }
        self.invalidRegexMessagesByRuleId = invalidRegexMessagesByRuleId

        titleRules = (builtInRules + compiledUserRules).filter(\.requiresTitle)
        hasDynamicReevaluationRules = compiledUserRules.contains { $0.requiresDynamicReevaluation }
            || builtInRules.contains { $0.requiresDynamicReevaluation }
    }

    static func applyingManualOverride(
        _ decision: WindowDecision,
        manualOverride: ManualWindowOverride?
    ) -> WindowDecision {
        guard let manualOverride, decision.tracksWindow else {
            return decision
        }
        return WindowDecision(
            disposition: manualOverride == .forceTile ? .managed : .floating,
            source: .manualOverride,
            layoutDecisionKind: .explicitLayout,
            workspaceName: decision.workspaceName,
            ruleEffects: decision.ruleEffects,
            admissionHints: decision.admissionHints,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    func decision(
        for facts: WindowRuleFacts,
        token: WindowToken?,
        appFullscreen: Bool
    ) -> WindowDecision {
        if facts.ax.role == (kAXHelpTagRole as String) {
            return externalSurfaceDecision()
        }

        if let bundleId = facts.ax.bundleId?.lowercased(),
           inputMethodBundleIds.contains(bundleId)
        {
            return externalSurfaceDecision()
        }

        let structuralEligibility = structuralEligibility(
            for: facts,
            token: token,
            appFullscreen: appFullscreen
        )

        let userRule: CompiledRule?
        let builtInRule: CompiledRule?
        switch structuralEligibility {
        case .eligible:
            userRule = bestMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestMatch(in: builtInRules, facts: facts)
        case .requiresExplicitInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestExplicitInclusionMatch(in: builtInRules, facts: facts)
            if userRule == nil, builtInRule == nil {
                return externalSurfaceDecision()
            }
        case .requiresExplicitUserInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = nil
            if userRule == nil {
                return externalSurfaceDecision()
            }
        case .requiresIndependentRootInclusion:
            userRule = bestExplicitInclusionMatch(in: compiledUserRules, facts: facts)
            builtInRule = bestExplicitInclusionMatch(in: builtInRules, facts: facts)
            if userRule == nil, builtInRule == nil {
                return unprovenIndependentRootDecision()
            }
        case .external:
            return externalSurfaceDecision()
        case let .deferred(reason):
            return deferredStructuralDecision(reason: reason)
        }

        let workspaceName = userRule?.rule.assignToWorkspace
        let effects = ManagedWindowRuleEffects(
            minWidth: userRule?.rule.minWidth,
            minHeight: userRule?.rule.minHeight,
            matchedRuleId: userRule?.rule.id
        )
        let admissionHints = ManagedWindowAdmissionHints(
            initialNiriContainerPrimarySpan: userRule?.rule.validInitialContainerPrimarySpan
        )

        if let userRule,
           let userDecision = explicitDecision(
               userRule,
               workspaceName: workspaceName,
               effects: effects,
               admissionHints: admissionHints
           )
        {
            return userDecision
        }

        // Built-in layout can still inherit workspace assignment and sizing effects
        // from a matching user auto rule.
        if let builtInRule,
           builtInRule.canApplyExplicitly(to: facts),
           let builtInDecision = explicitDecision(
               builtInRule,
               workspaceName: workspaceName,
               effects: effects,
               admissionHints: admissionHints
           )
        {
            return builtInDecision
        }

        if facts.ax.title == nil,
           requiresTitle(for: facts.ax.bundleId, appName: facts.appName)
        {
            return WindowDecision(
                disposition: .undecided,
                source: userRule.map { .userRule($0.rule.id) }
                    ?? builtInRule.map { builtInRuleSource(for: $0) }
                    ?? .heuristic,
                layoutDecisionKind: .fallbackLayout,
                workspaceName: workspaceName,
                ruleEffects: effects,
                admissionHints: admissionHints,
                heuristicReasons: [],
                deferredReason: .requiredTitleMissing
            )
        }

        if appFullscreen {
            return WindowDecision(
                disposition: .managed,
                source: userRule.map { .userRule($0.rule.id) }
                    ?? builtInRule.map { builtInRuleSource(for: $0) }
                    ?? .heuristic,
                layoutDecisionKind: .fallbackLayout,
                workspaceName: workspaceName,
                ruleEffects: effects,
                admissionHints: admissionHints,
                heuristicReasons: [],
                deferredReason: nil
            )
        }

        if HiddenTitleBarRegistry.decision(
            for: facts.ax,
            windowServer: facts.windowServer,
            fullscreenButtonOptionalBundleIds: hiddenTitleBarFullscreenButtonOptionalBundleIds,
            nonStandardSubroleBundleIds: hiddenTitleBarNonStandardSubroleBundleIds
        ) {
            return WindowDecision(
                disposition: .managed,
                source: .builtInRule(Self.hiddenTitleBarWindowRuleName),
                layoutDecisionKind: .fallbackLayout,
                workspaceName: workspaceName,
                ruleEffects: effects,
                admissionHints: admissionHints,
                heuristicReasons: [],
                deferredReason: nil
            )
        }

        let heuristic = AXWindowService.heuristicDisposition(for: facts.ax)

        return WindowDecision(
            disposition: heuristic.disposition,
            source: userRule.map { .userRule($0.rule.id) } ?? .heuristic,
            layoutDecisionKind: .fallbackLayout,
            workspaceName: workspaceName,
            ruleEffects: effects,
            admissionHints: admissionHints,
            heuristicReasons: heuristic.reasons,
            deferredReason: heuristic.disposition == .undecided ? .attributeFetchFailed : nil
        )
    }

    private func structuralEligibility(
        for facts: WindowRuleFacts,
        token: WindowToken?,
        appFullscreen: Bool
    ) -> StructuralEligibility {
        guard facts.ax.attributeFetchSucceeded else {
            return .deferred(.attributeFetchFailed)
        }

        guard let role = facts.ax.role,
              let subrole = facts.ax.subrole
        else {
            return .deferred(.attributeFetchFailed)
        }

        let windowServerEvidence: WindowServerInfo?
        if let token {
            guard let windowServer = facts.windowServer,
                  let windowId = UInt32(exactly: token.windowId),
                  windowServer.id == windowId,
                  pid_t(windowServer.pid) == token.pid
            else {
                return .deferred(.windowServerEvidenceMissing)
            }
            windowServerEvidence = windowServer
        } else {
            windowServerEvidence = facts.windowServer
        }

        if let windowServer = windowServerEvidence,
           windowServer.parentId != 0,
           windowServer.parentId != windowServer.id
        {
            return .external
        }

        if let windowServer = windowServerEvidence,
           windowServer.level >= Self.systemSurfaceLevelFloor
        {
            return .requiresExplicitUserInclusion
        }

        if facts.ax.appPolicy == .prohibited
            || (facts.ax.appPolicy == .accessory && !facts.ax.hasCloseButton)
        {
            return .requiresExplicitInclusion
        }

        guard role == (kAXWindowRole as String) else {
            return .requiresExplicitInclusion
        }

        if appFullscreen || Self.automaticRootSubroles.contains(subrole) {
            return .eligible
        }

        if Self.independentRootSubroles.contains(subrole) {
            if HiddenTitleBarRegistry.decision(
                for: facts.ax,
                windowServer: facts.windowServer,
                fullscreenButtonOptionalBundleIds: hiddenTitleBarFullscreenButtonOptionalBundleIds,
                nonStandardSubroleBundleIds: hiddenTitleBarNonStandardSubroleBundleIds
            ) {
                return .eligible
            }

            let hasWindowChrome = facts.ax.hasCloseButton
                || facts.ax.hasFullscreenButton
                || facts.ax.hasZoomButton
                || facts.ax.hasMinimizeButton
            if hasWindowChrome || facts.ax.isMain == true || facts.ax.isModal == true {
                return .eligible
            }
            if facts.ax.isMain == nil || facts.ax.isModal == nil {
                return .deferred(.independentRootEvidenceMissing)
            }
            return .requiresIndependentRootInclusion
        }

        return .requiresExplicitInclusion
    }

    private static let automaticRootSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        nativeFullscreenSubrole
    ]

    private static let independentRootSubroles: Set<String> = [
        kAXDialogSubrole as String,
        kAXFloatingWindowSubrole as String
    ]

    private func externalSurfaceDecision() -> WindowDecision {
        WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(Self.externalSurfaceRuleName),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func unprovenIndependentRootDecision() -> WindowDecision {
        WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(Self.unprovenIndependentRootRuleName),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func deferredStructuralDecision(
        reason: WindowDecisionDeferredReason
    ) -> WindowDecision {
        WindowDecision(
            disposition: .undecided,
            source: .heuristic,
            layoutDecisionKind: .fallbackLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: reason == .attributeFetchFailed ? [.attributeFetchFailed] : [],
            deferredReason: reason
        )
    }

    private func explicitDecision(
        _ compiled: CompiledRule,
        workspaceName: String?,
        effects: ManagedWindowRuleEffects,
        admissionHints: ManagedWindowAdmissionHints
    ) -> WindowDecision? {
        let source: WindowDecisionSource = switch compiled.source {
        case .user:
            .userRule(compiled.rule.id)
        case let .builtIn(name):
            .builtInRule(name)
        }

        let disposition: WindowDecisionDisposition
        switch compiled.rule.effectiveLayoutAction {
        case .float:
            disposition = .floating
        case .tile:
            disposition = .managed
        case .auto:
            return nil
        }

        return WindowDecision(
            disposition: disposition,
            source: source,
            layoutDecisionKind: .explicitLayout,
            workspaceName: workspaceName,
            ruleEffects: effects,
            admissionHints: admissionHints,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func builtInRuleSource(for compiled: CompiledRule) -> WindowDecisionSource {
        switch compiled.source {
        case let .builtIn(name):
            .builtInRule(name)
        case .user:
            .heuristic
        }
    }

    private func bestMatch(
        in rules: [CompiledRule],
        facts: WindowRuleFacts,
        requireExplicitInclusion: Bool = false
    ) -> CompiledRule? {
        var best: CompiledRule?

        for candidate in rules {
            if requireExplicitInclusion,
               !candidate.explicitlyIncludesNonstandardSurface
            {
                continue
            }
            guard candidate.matches(facts) else { continue }
            guard let currentBest = best else {
                best = candidate
                continue
            }

            if candidate.rule.specificity > currentBest.rule.specificity
                || (candidate.rule.specificity == currentBest.rule.specificity && candidate.order < currentBest.order)
            {
                best = candidate
            }
        }

        return best
    }

    private func bestExplicitInclusionMatch(
        in rules: [CompiledRule],
        facts: WindowRuleFacts
    ) -> CompiledRule? {
        bestMatch(
            in: rules,
            facts: facts,
            requireExplicitInclusion: true
        )
    }

    private func compile(
        rule: AppRule,
        source: RuleSource,
        order: Int,
        invalidRegexMessagesByRuleId: inout [UUID: String]
    ) -> CompiledRule? {
        let titleRegex: NSRegularExpression?
        if let pattern = rule.titleRegex, !pattern.isEmpty {
            do {
                titleRegex = try NSRegularExpression(pattern: pattern)
            } catch {
                invalidRegexMessagesByRuleId[rule.id] = error.localizedDescription
                return nil
            }
        } else {
            titleRegex = nil
        }

        return CompiledRule(
            rule: rule,
            source: source,
            titleRegex: titleRegex,
            order: order
        )
    }

    private static func makeBuiltInRules() -> [CompiledRule] {
        var rules: [CompiledRule] = []

        for (index, bundleId) in DefaultFloatingApps.bundleIds.sorted().enumerated() {
            let rule = AppRule(
                bundleId: bundleId,
                layout: .float
            )
            rules.append(
                CompiledRule(
                    rule: rule,
                    source: .builtIn("defaultFloatingApp"),
                    titleRegex: nil,
                    order: index
                )
            )
        }

        let pipRules: [AppRule] = [
            AppRule(
                bundleId: "org.mozilla.firefox",
                titleRegex: "^Picture-in-Picture$",
                axRole: kAXWindowRole as String,
                axSubrole: kAXStandardWindowSubrole as String,
                layout: .float
            ),
            AppRule(
                bundleId: "app.zen-browser.zen",
                titleRegex: "^Picture-in-Picture$",
                axRole: kAXWindowRole as String,
                axSubrole: kAXStandardWindowSubrole as String,
                layout: .float
            )
        ]

        let pipOffset = rules.count
        for (index, rule) in pipRules.enumerated() {
            rules.append(
                CompiledRule(
                    rule: rule,
                    source: .builtIn("browserPictureInPicture"),
                    titleRegex: try! NSRegularExpression(pattern: rule.titleRegex ?? ""),
                    order: pipOffset + index
                )
            )
        }

        for subrole in [kAXStandardWindowSubrole as String, kAXUnknownSubrole as String] {
            rules.append(
                CompiledRule(
                    rule: AppRule(
                        bundleId: "com.valvesoftware.steam.helper",
                        axRole: kAXWindowRole as String,
                        axSubrole: subrole,
                        layout: .tile
                    ),
                    source: .builtIn("steamClient"),
                    titleRegex: nil,
                    order: rules.count
                )
            )
        }

        rules.append(
            CompiledRule(
                rule: AppRule(
                    bundleId: "com.apple.finder",
                    axRole: kAXWindowRole as String,
                    axSubrole: finderQuickLookSubrole,
                    layout: .float
                ),
                source: .builtIn("finderQuickLook"),
                titleRegex: nil,
                order: rules.count
            )
        )

        return rules
    }
}
