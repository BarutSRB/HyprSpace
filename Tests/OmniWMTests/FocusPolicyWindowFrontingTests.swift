// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FocusPolicyWindowFrontingTests: XCTestCase {
    func testWindowFrontingIsAllowedWithoutLeases() {
        let engine = FocusPolicyEngine()
        XCTAssertTrue(engine.evaluate(.windowFronting).allowsFocusChange)
    }

    func testForeignTransientUILeaseDeniesWindowFronting() {
        let engine = FocusPolicyEngine()
        engine.beginLease(
            owner: .foreignTransientUI,
            reason: "foreign_menu",
            suppressesFocusFollowsMouse: true,
            duration: nil
        )

        let decision = engine.evaluate(.windowFronting)
        XCTAssertFalse(decision.allowsFocusChange)
        XCTAssertEqual(decision.reason, "foreign_menu")

        engine.endLease(owner: .foreignTransientUI)
        XCTAssertTrue(engine.evaluate(.windowFronting).allowsFocusChange)
    }

    func testUnrelatedLeasesDoNotBlockWindowFronting() {
        let engine = FocusPolicyEngine()
        engine.beginLease(
            owner: .windowCloseFocusRecovery,
            reason: "close_recovery",
            suppressesFocusFollowsMouse: true,
            duration: nil
        )

        XCTAssertTrue(engine.evaluate(.windowFronting).allowsFocusChange)
    }

    func testForeignTransientUIOutranksOtherLeases() {
        let engine = FocusPolicyEngine()
        engine.beginLease(
            owner: .nativeAppSwitch,
            reason: "app_switch",
            suppressesFocusFollowsMouse: true,
            duration: nil
        )
        engine.beginLease(
            owner: .foreignTransientUI,
            reason: "foreign_menu",
            suppressesFocusFollowsMouse: true,
            duration: nil
        )

        XCTAssertEqual(engine.activeLease?.owner, .foreignTransientUI)
    }
}
