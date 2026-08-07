// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import Foundation
@testable import OmniWM

extension AXWindowFactsDTO {
    func toModel() -> AXWindowFacts {
        AXWindowFacts(
            role: role,
            subrole: subrole,
            title: title,
            hasCloseButton: hasCloseButton,
            hasFullscreenButton: hasFullscreenButton,
            fullscreenButtonEnabled: fullscreenButtonEnabled,
            hasZoomButton: hasZoomButton,
            hasMinimizeButton: hasMinimizeButton,
            appPolicy: Self.policy(from: appPolicy),
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        )
    }

    private static func policy(from string: String?) -> NSApplication.ActivationPolicy? {
        switch string {
        case "accessory": .accessory
        case "prohibited": .prohibited
        case "regular": .regular
        default: nil
        }
    }
}

extension WindowSizeConstraintsDTO {
    func toModel() -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: CGSize(width: minWidth, height: minHeight),
            maxSize: CGSize(width: maxWidth, height: maxHeight),
            isFixed: isFixed
        )
    }
}

extension WindowServerInfoDTO {
    func toModel() -> WindowServerInfo {
        WindowServerInfo(
            id: id,
            pid: pid,
            level: level,
            frame: CGRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight),
            tags: tags,
            attributes: attributes,
            parentId: parentId,
            title: title
        )
    }
}

struct WindowClassificationOutcome: Equatable {
    var decision: WindowClassificationDecisionDTO
    var policy: String
}

@MainActor
enum WindowClassificationReproducer {
    static func recomputeOutcome(
        _ observation: WindowClassificationObservation,
        rules: [AppRule]
    ) -> WindowClassificationOutcome {
        let input = observation.input
        let engine = WindowRuleEngine()
        engine.rebuild(rules: rules)
        let facts = WindowRuleFacts(
            appName: input.appName,
            ax: input.ax.toModel(),
            sizeConstraints: input.sizeConstraints?.toModel(),
            windowServer: input.windowServer?.toModel()
        )
        let token = WindowToken(
            pid: observation.tokenPid,
            windowId: observation.tokenWindowId
        )
        let base = engine.decision(for: facts, token: token, appFullscreen: input.appFullscreen)
        let final = WindowRuleEngine.applyingManualOverride(base, manualOverride: input.manualOverride)
        let policy = WindowInteractionPolicy.resolve(
            decision: final,
            windowServerLevel: input.windowServer?.level
        )
        return WindowClassificationOutcome(
            decision: WindowClassificationDecisionDTO(from: final),
            policy: policy.name
        )
    }

    static func recompute(
        _ observation: WindowClassificationObservation,
        rules: [AppRule]
    ) -> WindowClassificationDecisionDTO {
        recomputeOutcome(observation, rules: rules).decision
    }
}
