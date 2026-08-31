// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct WindowClassificationObservation: Codable, Equatable, Sendable {
    var tokenPid: Int32
    var tokenWindowId: Int
    var appName: String?
    var bundleId: String?
    var workspaceName: String?
    var rulesRevision: UInt64
    var input: WindowClassificationInput
    var observedDecision: WindowClassificationDecisionDTO

    func boundedForDiagnostics() -> WindowClassificationObservation {
        var copy = self
        copy.appName = copy.appName.map(RuntimeTraceLimits.boundedString)
        copy.bundleId = copy.bundleId.map(RuntimeTraceLimits.boundedString)
        copy.workspaceName = copy.workspaceName.map(RuntimeTraceLimits.boundedString)
        copy.input.appName = copy.input.appName.map(RuntimeTraceLimits.boundedString)
        copy.input.ax.role = copy.input.ax.role.map(RuntimeTraceLimits.boundedString)
        copy.input.ax.subrole = copy.input.ax.subrole.map(RuntimeTraceLimits.boundedString)
        copy.input.ax.title = copy.input.ax.title.map(RuntimeTraceLimits.boundedString)
        copy.input.ax.appPolicy = copy.input.ax.appPolicy.map(RuntimeTraceLimits.boundedString)
        copy.input.ax.bundleId = copy.input.ax.bundleId.map(RuntimeTraceLimits.boundedString)
        if var windowServer = copy.input.windowServer {
            windowServer.title = windowServer.title.map(RuntimeTraceLimits.boundedString)
            copy.input.windowServer = windowServer
        }
        copy.observedDecision.disposition = RuntimeTraceLimits.boundedString(copy.observedDecision.disposition)
        copy.observedDecision.source = RuntimeTraceLimits.boundedString(copy.observedDecision.source)
        copy.observedDecision.heuristicReasons = copy.observedDecision.heuristicReasons.map(
            RuntimeTraceLimits.boundedString
        )
        copy.observedDecision.deferredReason = copy.observedDecision.deferredReason.map(
            RuntimeTraceLimits.boundedString
        )
        copy.observedDecision.layoutDecisionKind = RuntimeTraceLimits.boundedString(
            copy.observedDecision.layoutDecisionKind
        )
        copy.observedDecision.workspaceName = copy.observedDecision.workspaceName.map(
            RuntimeTraceLimits.boundedString
        )
        return copy
    }
}

extension WindowClassificationObservation {
    @MainActor
    init(
        token: WindowToken,
        bundleId: String?,
        rulesRevision: UInt64,
        evaluation: WMController.WindowDecisionEvaluation
    ) {
        self.init(
            tokenPid: token.pid,
            tokenWindowId: token.windowId,
            appName: evaluation.facts.appName,
            bundleId: bundleId ?? evaluation.facts.ax.bundleId,
            workspaceName: evaluation.decision.workspaceName,
            rulesRevision: rulesRevision,
            input: WindowClassificationInput(
                appName: evaluation.facts.appName,
                ax: AXWindowFactsDTO(from: evaluation.facts.ax),
                sizeConstraints: evaluation.facts.sizeConstraints.map(WindowSizeConstraintsDTO.init(from:)),
                windowServer: evaluation.facts.windowServer.map(WindowServerInfoDTO.init(from:)),
                appFullscreen: evaluation.appFullscreen,
                manualOverride: evaluation.manualOverride
            ),
            observedDecision: WindowClassificationDecisionDTO(from: evaluation.decision)
        )
    }
}

struct WindowClassificationRulesSnapshot: Codable, Equatable, Sendable {
    let kind: String
    let revision: UInt64
    let rules: [AppRule]
    let originalRuleCount: Int
    let truncated: Bool

    init(revision: UInt64, rules: [AppRule], originalRuleCount: Int? = nil, truncated: Bool = false) {
        let originalCount = originalRuleCount ?? rules.count
        var boundedRules: [AppRule] = []
        boundedRules.reserveCapacity(min(rules.count, 64))
        var estimatedBytes = 128
        for rule in rules {
            let boundedRule = Self.boundedRule(rule)
            let ruleBytes = Self.estimatedDiagnosticBytes(boundedRule)
            guard estimatedBytes + ruleBytes <= RuntimeTraceLimits.rulesSnapshotBytes else {
                break
            }
            boundedRules.append(boundedRule)
            estimatedBytes += ruleBytes
        }
        self.init(
            revision: revision,
            boundedRules: boundedRules,
            originalRuleCount: originalCount,
            truncated: truncated || boundedRules.count < originalCount
        )
    }

    var estimatedDiagnosticBytes: Int {
        128 + rules.reduce(0) { $0 + Self.estimatedDiagnosticBytes($1) }
    }

    static func estimatedDiagnosticBytes(for rules: [AppRule]) -> Int {
        var total = 128
        for rule in rules {
            total += estimatedDiagnosticBytes(rule)
            if total >= RuntimeTraceLimits.rulesSnapshotBytes {
                return RuntimeTraceLimits.rulesSnapshotBytes
            }
        }
        return total
    }

    init(revision: UInt64, boundedRules: [AppRule], originalRuleCount: Int, truncated: Bool) {
        kind = "rules_snapshot"
        self.revision = revision
        self.rules = boundedRules
        self.originalRuleCount = originalRuleCount
        self.truncated = truncated
    }

    func encodedLine(using encoder: JSONEncoder) -> String {
        func encode(_ value: WindowClassificationRulesSnapshot) -> String? {
            guard let data = try? encoder.encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        if let full = encode(self), full.utf8.count <= RuntimeTraceLimits.rulesSnapshotBytes {
            return full
        }

        var lower = 0
        var upper = rules.count
        var result = WindowClassificationRulesSnapshot(
            revision: revision,
            boundedRules: [],
            originalRuleCount: originalRuleCount,
            truncated: true
        )
        while lower <= upper {
            let midpoint = lower + (upper - lower) / 2
            let candidate = WindowClassificationRulesSnapshot(
                revision: revision,
                boundedRules: Array(rules.prefix(midpoint)),
                originalRuleCount: originalRuleCount,
                truncated: true
            )
            guard let line = encode(candidate) else {
                upper = midpoint - 1
                continue
            }
            if line.utf8.count <= RuntimeTraceLimits.rulesSnapshotBytes {
                result = candidate
                lower = midpoint + 1
            } else {
                upper = midpoint - 1
            }
        }
        return encode(result)
            ?? "{\"kind\":\"rules_snapshot\",\"revision\":\(revision),\"rules\":[],\"originalRuleCount\":\(originalRuleCount),\"truncated\":true}"
    }

    private static func boundedRule(_ rule: AppRule) -> AppRule {
        AppRule(
            id: rule.id,
            bundleId: RuntimeTraceLimits.boundedString(rule.bundleId),
            appNameSubstring: rule.appNameSubstring.map(RuntimeTraceLimits.boundedString),
            titleSubstring: rule.titleSubstring.map(RuntimeTraceLimits.boundedString),
            titleRegex: rule.titleRegex.map(RuntimeTraceLimits.boundedString),
            axRole: rule.axRole.map(RuntimeTraceLimits.boundedString),
            axSubrole: rule.axSubrole.map(RuntimeTraceLimits.boundedString),
            layout: rule.layout,
            assignToWorkspace: rule.assignToWorkspace.map(RuntimeTraceLimits.boundedString),
            initialContainerPrimarySpan: rule.initialContainerPrimarySpan,
            minWidth: rule.minWidth,
            minHeight: rule.minHeight
        )
    }

    private static func estimatedDiagnosticBytes(_ rule: AppRule) -> Int {
        256
            + min(rule.bundleId.utf8.count, RuntimeTraceLimits.diagnosticStringBytes)
            + min(rule.appNameSubstring?.utf8.count ?? 0, RuntimeTraceLimits.diagnosticStringBytes)
            + min(rule.titleSubstring?.utf8.count ?? 0, RuntimeTraceLimits.diagnosticStringBytes)
            + min(rule.titleRegex?.utf8.count ?? 0, RuntimeTraceLimits.diagnosticStringBytes)
            + min(rule.axRole?.utf8.count ?? 0, RuntimeTraceLimits.diagnosticStringBytes)
            + min(rule.axSubrole?.utf8.count ?? 0, RuntimeTraceLimits.diagnosticStringBytes)
            + min(rule.assignToWorkspace?.utf8.count ?? 0, RuntimeTraceLimits.diagnosticStringBytes)
    }
}
