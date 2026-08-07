// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowInteractionPolicyTests: XCTestCase {
    private func decision(
        disposition: WindowDecisionDisposition = .floating,
        source: WindowDecisionSource = .heuristic,
        layoutDecisionKind: WindowDecisionLayoutKind = .fallbackLayout,
        heuristicReasons: [AXWindowHeuristicReason] = []
    ) -> WindowDecision {
        WindowDecision(
            disposition: disposition,
            source: source,
            layoutDecisionKind: layoutDecisionKind,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: heuristicReasons,
            deferredReason: nil
        )
    }

    func testAccessoryOverlayIsHandsOff() {
        let policy = WindowInteractionPolicy.resolve(
            decision: decision(heuristicReasons: [.accessoryWithoutClose]),
            windowServerLevel: -1
        )

        XCTAssertEqual(policy, .handsOffSurface)
        XCTAssertTrue(policy.tracksInModel)
        XCTAssertFalse(policy.mayFocus)
        XCTAssertFalse(policy.mayActivateApp)
        XCTAssertFalse(policy.mayWriteFrame)
        XCTAssertFalse(policy.mayBorder)
    }

    func testDockHelperMenuSurfaceIsHandsOff() {
        let policy = WindowInteractionPolicy.resolve(
            decision: decision(heuristicReasons: [.accessoryWithoutClose]),
            windowServerLevel: 3
        )

        XCTAssertEqual(policy, .handsOffSurface)
    }

    func testNonZeroWindowServerLevelIsHandsOffWithoutHeuristicReason() {
        let policy = WindowInteractionPolicy.resolve(
            decision: decision(),
            windowServerLevel: 2_147_483_629
        )

        XCTAssertEqual(policy, .handsOffSurface)
    }

    func testChromeTransientPopupReasonIsHandsOff() {
        let policy = WindowInteractionPolicy.resolve(
            decision: decision(heuristicReasons: [.noButtonsOnNonStandardSubrole]),
            windowServerLevel: 0
        )

        XCTAssertEqual(policy, .handsOffSurface)
    }

    func testTransientWidgetSurfacesAreUntrackedRatherThanHandsOff() {
        for ruleName in [
            WindowRuleEngine.transientWidgetSurfaceRuleName,
            WindowRuleEngine.helpTagSurfaceRuleName
        ] {
            XCTAssertEqual(
                WindowInteractionPolicy.resolve(
                    decision: decision(disposition: .unmanaged, source: .builtInRule(ruleName)),
                    windowServerLevel: 0
                ),
                .untracked,
                "\(ruleName) resolves to untracked because every producer of it is unmanaged"
            )
        }
    }

    func testExplicitUserRuleRestoresFullManagement() {
        let policy = WindowInteractionPolicy.resolve(
            decision: decision(
                source: .userRule(UUID()),
                layoutDecisionKind: .explicitLayout,
                heuristicReasons: [.accessoryWithoutClose]
            ),
            windowServerLevel: 3
        )

        XCTAssertEqual(policy, .full)
    }

    func testOnlyUserIntentOutranksTheOverlayLevelCheck() {
        let overlayLevel = CGWindowLevelForKey(.popUpMenuWindow)
        let intents: [(WindowDecisionSource, WindowInteractionPolicy)] = [
            (.manualOverride, .full),
            (.userRule(UUID()), .full),
            (.builtInRule("cleanShotRecordingOverlay"), .handsOffSurface)
        ]

        for (source, expected) in intents {
            XCTAssertEqual(
                WindowInteractionPolicy.resolve(
                    decision: decision(source: source, layoutDecisionKind: .explicitLayout),
                    windowServerLevel: overlayLevel
                ),
                expected,
                "\(source) at overlay level"
            )
        }
    }

    func testOrdinaryTiledWindowKeepsFullManagement() {
        let policy = WindowInteractionPolicy.resolve(
            decision: decision(disposition: .managed),
            windowServerLevel: 0
        )

        XCTAssertEqual(policy, .full)
    }

    func testUntrackedDispositionsCarryNoCapabilities() {
        for disposition in [WindowDecisionDisposition.unmanaged, .undecided] {
            XCTAssertEqual(
                WindowInteractionPolicy.resolve(
                    decision: decision(disposition: disposition),
                    windowServerLevel: 0
                ),
                .untracked
            )
        }
    }

    func testNarrowingIsMonotonic() {
        let narrowed = WindowInteractionPolicy.full.narrowed(by: .handsOffSurface)
        XCTAssertEqual(narrowed, .handsOffSurface)
        XCTAssertEqual(narrowed.narrowed(by: .full), .handsOffSurface)
    }
}
