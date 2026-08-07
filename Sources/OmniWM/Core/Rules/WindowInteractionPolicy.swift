// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct WindowInteractionPolicy: Equatable, Sendable {
    var tracksInModel: Bool
    var mayFocus: Bool
    var mayActivateApp: Bool
    var mayRaise: Bool
    var mayOrder: Bool
    var mayWriteFrame: Bool
    var mayBorder: Bool
    var mayPark: Bool

    static let full = WindowInteractionPolicy(
        tracksInModel: true,
        mayFocus: true,
        mayActivateApp: true,
        mayRaise: true,
        mayOrder: true,
        mayWriteFrame: true,
        mayBorder: true,
        mayPark: true
    )

    static let handsOffSurface = WindowInteractionPolicy(
        tracksInModel: true,
        mayFocus: false,
        mayActivateApp: false,
        mayRaise: false,
        mayOrder: false,
        mayWriteFrame: false,
        mayBorder: false,
        mayPark: false
    )

    static let untracked = WindowInteractionPolicy(
        tracksInModel: false,
        mayFocus: false,
        mayActivateApp: false,
        mayRaise: false,
        mayOrder: false,
        mayWriteFrame: false,
        mayBorder: false,
        mayPark: false
    )

    var isHandsOff: Bool {
        self == .handsOffSurface
    }

    var name: String {
        switch self {
        case .full: "full"
        case .handsOffSurface: "handsOffSurface"
        case .untracked: "untracked"
        default: grantedCapabilityName
        }
    }

    private var grantedCapabilityName: String {
        let granted = [
            ("tracksInModel", tracksInModel),
            ("mayFocus", mayFocus),
            ("mayActivateApp", mayActivateApp),
            ("mayRaise", mayRaise),
            ("mayOrder", mayOrder),
            ("mayWriteFrame", mayWriteFrame),
            ("mayBorder", mayBorder),
            ("mayPark", mayPark)
        ]
        .filter(\.1)
        .map(\.0)
        return "custom(\(granted.joined(separator: ",")))"
    }

    func narrowed(by other: WindowInteractionPolicy) -> WindowInteractionPolicy {
        WindowInteractionPolicy(
            tracksInModel: tracksInModel && other.tracksInModel,
            mayFocus: mayFocus && other.mayFocus,
            mayActivateApp: mayActivateApp && other.mayActivateApp,
            mayRaise: mayRaise && other.mayRaise,
            mayOrder: mayOrder && other.mayOrder,
            mayWriteFrame: mayWriteFrame && other.mayWriteFrame,
            mayBorder: mayBorder && other.mayBorder,
            mayPark: mayPark && other.mayPark
        )
    }
}

extension WindowInteractionPolicy {
    static let handsOffHeuristicReasons: Set<AXWindowHeuristicReason> = [
        .accessoryWithoutClose,
        .noButtonsOnNonStandardSubrole
    ]

    static let overlayWindowLevelFloor = CGWindowLevelForKey(.statusWindow)

    @MainActor
    static func resolve(for evaluation: WMController.WindowDecisionEvaluation) -> WindowInteractionPolicy {
        resolve(
            decision: evaluation.decision,
            windowServerLevel: evaluation.facts.windowServer?.level
        )
    }

    @MainActor
    static func resolve(
        decision: WindowDecision,
        windowServerLevel: Int32?
    ) -> WindowInteractionPolicy {
        guard decision.tracksWindow else { return .untracked }

        if decision.layoutDecisionKind == .explicitLayout, decision.reflectsExplicitUserIntent {
            return .full
        }

        if decision.disposition == .managed {
            return .full
        }

        if decision.heuristicReasons.contains(where: handsOffHeuristicReasons.contains) {
            return .handsOffSurface
        }

        if let windowServerLevel, windowServerLevel >= overlayWindowLevelFloor {
            return .handsOffSurface
        }

        return .full
    }
}
