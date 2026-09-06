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

    func testStatusPanelSuppressesAutomaticFocusWithoutBlockingActivationObservations() {
        let engine = FocusPolicyEngine()
        engine.beginLease(owner: .statusPanel, reason: "status_panel", duration: nil)

        XCTAssertFalse(engine.evaluate(.focusFollowsMouse).allowsFocusChange)
        XCTAssertFalse(engine.evaluate(.managedFocusRecovery).allowsFocusChange)
        XCTAssertEqual(engine.evaluate(.managedFocusRecovery).reason, "status_panel")
        XCTAssertTrue(engine.evaluate(.windowFronting).allowsFocusChange)
        for source: ActivationEventSource in [
            .workspaceDidActivateApplication,
            .cgsFrontAppChanged,
            .focusedWindowChanged
        ] {
            XCTAssertTrue(engine.evaluate(.managedAppActivation(source: source)).allowsFocusChange)
        }

        engine.endLease(owner: .statusPanel)

        XCTAssertTrue(engine.evaluate(.focusFollowsMouse).allowsFocusChange)
        XCTAssertTrue(engine.evaluate(.managedFocusRecovery).allowsFocusChange)
    }

    func testStatusPanelAndNativeMenuLeasesEndIndependently() {
        let engine = FocusPolicyEngine()
        engine.beginLease(owner: .nativeMenu, reason: "menu_anywhere", duration: nil)
        engine.beginLease(owner: .statusPanel, reason: "status_panel", duration: nil)

        engine.endLease(owner: .statusPanel)

        XCTAssertEqual(engine.activeLease?.owner, .nativeMenu)
        XCTAssertFalse(engine.evaluate(.focusFollowsMouse).allowsFocusChange)
        XCTAssertFalse(engine.evaluate(.managedAppActivation(source: .cgsFrontAppChanged)).allowsFocusChange)
        XCTAssertTrue(engine.evaluate(.managedFocusRecovery).allowsFocusChange)

        engine.beginLease(owner: .statusPanel, reason: "status_panel", duration: nil)
        engine.endLease(owner: .nativeMenu)

        XCTAssertEqual(engine.activeLease?.owner, .statusPanel)
        XCTAssertFalse(engine.evaluate(.focusFollowsMouse).allowsFocusChange)
        XCTAssertFalse(engine.evaluate(.managedFocusRecovery).allowsFocusChange)
        XCTAssertTrue(engine.evaluate(.managedAppActivation(source: .cgsFrontAppChanged)).allowsFocusChange)

        engine.endLease(owner: .statusPanel)

        XCTAssertNil(engine.activeLease)
        XCTAssertTrue(engine.evaluate(.focusFollowsMouse).allowsFocusChange)
        XCTAssertTrue(engine.evaluate(.managedFocusRecovery).allowsFocusChange)
    }

    func testStatusPanelAllowsActivationFactResolution() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMStatusPanelActivationTests")
        let pid: pid_t = 646_001
        var resolvedPids: [pid_t] = []
        controller.factResolver.factProvider = {
            resolvedPids.append($0)
            return nil
        }
        controller.hasStartedServices = true
        controller.focusPolicyEngine.beginLease(owner: .statusPanel, reason: "status_panel", duration: nil)

        controller.axEventHandler.handleAppActivation(pid: pid, source: .workspaceDidActivateApplication)
        controller.axEventHandler.handleAppActivation(pid: pid, source: .cgsFrontAppChanged)

        XCTAssertEqual(resolvedPids, [pid, pid])
        XCTAssertTrue(controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertTrue(controller.shouldSuppressManagedFocusRecovery)
    }
}
