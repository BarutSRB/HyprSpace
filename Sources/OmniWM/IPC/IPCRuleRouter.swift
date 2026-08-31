// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

@MainActor
final class IPCRuleRouter {
    let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func handle(_ request: IPCRuleRequest) async -> Result<IPCRulesQueryResult, IPCErrorCode> {
        switch request {
        case let .add(rule):
            return add(rule)
        case let .replace(id, rule):
            return replace(id: id, with: rule)
        case let .remove(id):
            return remove(id: id)
        case let .move(id, position):
            return move(id: id, to: position)
        case let .apply(target):
            return await apply(target)
        }
    }

    private func add(_ definition: IPCRuleDefinition) -> Result<IPCRulesQueryResult, IPCErrorCode> {
        guard IPCRuleValidator.validate(definition).isValid else {
            return .failure(.invalidArguments)
        }

        var rules = controller.settings.appRules
        rules.append(IPCRuleProjection.appRule(from: definition))
        controller.settings.appRules = rules
        controller.updateAppRules()
        return .success(currentRulesResult())
    }

    private func replace(id: String, with definition: IPCRuleDefinition) -> Result<IPCRulesQueryResult, IPCErrorCode> {
        guard IPCRuleValidator.validate(definition).isValid else {
            return .failure(.invalidArguments)
        }
        guard let ruleId = UUID(uuidString: id) else {
            return .failure(.invalidArguments)
        }

        var rules = controller.settings.appRules
        guard let index = rules.firstIndex(where: { $0.id == ruleId }) else {
            return .failure(.notFound)
        }

        rules[index] = IPCRuleProjection.appRule(from: definition, id: ruleId)
        controller.settings.appRules = rules
        controller.updateAppRules()
        return .success(currentRulesResult())
    }

    private func remove(id: String) -> Result<IPCRulesQueryResult, IPCErrorCode> {
        guard let ruleId = UUID(uuidString: id) else {
            return .failure(.invalidArguments)
        }

        var rules = controller.settings.appRules
        guard let index = rules.firstIndex(where: { $0.id == ruleId }) else {
            return .failure(.notFound)
        }

        rules.remove(at: index)
        controller.settings.appRules = rules
        controller.updateAppRules()
        return .success(currentRulesResult())
    }

    private func move(id: String, to position: Int) -> Result<IPCRulesQueryResult, IPCErrorCode> {
        guard let ruleId = UUID(uuidString: id) else {
            return .failure(.invalidArguments)
        }

        var rules = controller.settings.appRules
        guard let currentIndex = rules.firstIndex(where: { $0.id == ruleId }) else {
            return .failure(.notFound)
        }
        guard position > 0, position <= rules.count else {
            return .failure(.invalidArguments)
        }

        let destinationIndex = position - 1
        let rule = rules.remove(at: currentIndex)
        rules.insert(rule, at: destinationIndex)
        controller.settings.appRules = rules
        controller.updateAppRules()
        return .success(currentRulesResult())
    }

    private func apply(_ target: IPCRuleApplyTarget) async -> Result<IPCRulesQueryResult, IPCErrorCode> {
        let reevaluationTargets: Set<WindowRuleReevaluationTarget>

        switch target {
        case .focused:
            guard let token = controller.focusedOrFrontmostWindowTokenForAutomation(
                preferFrontmostWhenExternalOrOwnedFocusActive: true
            ) else {
                return .failure(.notFound)
            }
            reevaluationTargets = [.window(token)]
        case let .window(windowId):
            switch IPCWindowOpaqueID.validate(windowId, expectingSessionToken: sessionToken) {
            case .invalid:
                return .failure(.invalidArguments)
            case .stale:
                return .failure(.staleWindowId)
            case let .valid(pid, windowId):
                reevaluationTargets = [.window(WindowToken(pid: pid, windowId: windowId))]
            }
        case let .pid(pid):
            guard pid > 0 else {
                return .failure(.invalidArguments)
            }
            guard !controller.workspaceManager.entries(forPid: pid_t(pid)).isEmpty else {
                return .failure(.notFound)
            }
            reevaluationTargets = [.pid(pid_t(pid))]
        }

        let outcome = await controller.reevaluateWindowRules(
            for: reevaluationTargets,
            context: .explicitRuleApply
        )
        guard outcome.resolvedAnyTarget, outcome.evaluatedAnyWindow else {
            return .failure(.notFound)
        }

        return .success(currentRulesResult())
    }

    private func currentRulesResult() -> IPCRulesQueryResult {
        IPCRuleProjection.result(
            settings: controller.settings,
            windowRuleEngine: controller.windowRuleEngine
        )
    }
}
