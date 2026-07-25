// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowRuleEngineTests: XCTestCase {
    private func facts(
        appName: String?,
        bundleId: String?,
        title: String? = nil,
        role: String? = kAXWindowRole as String,
        subrole: String? = kAXStandardWindowSubrole as String,
        attributeFetchSucceeded: Bool = true
    ) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: appName,
            ax: AXWindowFacts(
                role: role,
                subrole: subrole,
                title: title,
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: bundleId,
                attributeFetchSucceeded: attributeFetchSucceeded
            ),
            sizeConstraints: nil,
            windowServer: nil
        )
    }

    private func evaluate(_ engine: WindowRuleEngine, _ facts: WindowRuleFacts) -> WindowDecision {
        engine.decision(for: facts, token: nil, appFullscreen: false)
    }

    private func facts(
        appName: String?,
        bundleId: String?,
        windowLevel: Int32
    ) -> WindowRuleFacts {
        let base = facts(appName: appName, bundleId: bundleId, subrole: "AXUnknown")
        return WindowRuleFacts(
            appName: base.appName,
            ax: base.ax,
            sizeConstraints: base.sizeConstraints,
            windowServer: WindowServerInfo(
                id: 1,
                pid: 4321,
                level: windowLevel,
                frame: CGRect(x: 1420, y: 27, width: 310, height: 824)
            )
        )
    }

    func testMenuBarPopoverAboveNormalLevelsIsUnmanaged() {
        // A menu-bar app's popover (BetterDisplay's opens at the screensaver level) must never be
        // tracked: fronting or moving it makes the app dismiss it, and it strands a workspace-bar
        // entry. Only the window level distinguishes it from a floatable panel.
        let engine = WindowRuleEngine()
        let popover = evaluate(
            engine,
            facts(appName: "BetterDisplay", bundleId: "pro.betterdisplay.BetterDisplay", windowLevel: 1000)
        )

        XCTAssertEqual(popover.disposition, .unmanaged)
        XCTAssertEqual(popover.source, .builtInRule(WindowRuleEngine.elevatedWindowLevelRuleName))
    }

    func testUserRuleCannotForceAnElevatedSurfaceToBeManaged() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "pro.betterdisplay.BetterDisplay", layout: .tile)
        engine.rebuild(rules: [rule])

        let popover = evaluate(
            engine,
            facts(appName: "BetterDisplay", bundleId: "pro.betterdisplay.BetterDisplay", windowLevel: 1000)
        )

        XCTAssertEqual(popover.disposition, .unmanaged)
        XCTAssertNotEqual(popover.source, .userRule(rule.id))
    }

    func testOrdinaryAndFloatingLevelWindowsStayManageable() {
        // The gate must sit above the levels apps use for panels and dialogs, so those keep being
        // classified normally rather than being dropped wholesale.
        let engine = WindowRuleEngine()
        for level: Int32 in [0, 3, 8, 19] {
            let decision = evaluate(
                engine,
                facts(appName: "Preview", bundleId: "com.apple.Preview", windowLevel: level)
            )
            XCTAssertNotEqual(
                decision.disposition,
                .unmanaged,
                "level \(level) is an ordinary app window level and must still be classified"
            )
        }
    }

    func testAppNameWildcardMatchesNoBundleWindows() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "", appNameSubstring: "VMD", layout: .float)
        engine.rebuild(rules: [rule])

        for title in ["VMD Main", "VMD TkConsole"] {
            let decision = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: title))
            XCTAssertEqual(decision.disposition, .floating)
            XCTAssertEqual(decision.source, .userRule(rule.id))
        }

        let other = evaluate(engine, facts(appName: "Finder", bundleId: nil))
        XCTAssertNotEqual(other.source, .userRule(rule.id))
    }

    func testAppNamePlusTitleTargetsSingleWindow() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            bundleId: "",
            appNameSubstring: "VMD",
            titleSubstring: "TkConsole",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        let tkConsole = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: "VMD TkConsole"))
        XCTAssertEqual(tkConsole.source, .userRule(rule.id))

        let main = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: "VMD Main"))
        XCTAssertNotEqual(main.source, .userRule(rule.id))
    }

    func testEmptyBundleAxOnlyRuleIsDropped() {
        let engine = WindowRuleEngine()
        let axOnly = AppRule(bundleId: "", axSubrole: kAXStandardWindowSubrole as String, layout: .float)
        engine.rebuild(rules: [axOnly])

        let decision = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: "VMD Main"))
        XCTAssertNotEqual(decision.source, .userRule(axOnly.id))
    }

    func testBundledAxSubroleRefinesMatch() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            bundleId: "com.test.app",
            axSubrole: kAXStandardWindowSubrole as String,
            layout: .float
        )
        engine.rebuild(rules: [rule])

        let matched = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))
        XCTAssertEqual(matched.disposition, .floating)
        XCTAssertEqual(matched.source, .userRule(rule.id))

        let wrongSubrole = evaluate(
            engine,
            facts(appName: "Test", bundleId: "com.test.app", subrole: "AXDialog")
        )
        XCTAssertNotEqual(wrongSubrole.source, .userRule(rule.id))
    }

    func testEmptyBundleActionOnlyRuleIsDropped() {
        let engine = WindowRuleEngine()
        let actionOnly = AppRule(bundleId: "", layout: .float)
        engine.rebuild(rules: [actionOnly])

        let decision = evaluate(engine, facts(appName: "Anything", bundleId: nil))
        XCTAssertNotEqual(decision.source, .userRule(actionOnly.id))
    }

    func testBundledRuleDoesNotMatchNoBundleWindow() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "com.test.app", layout: .float)
        engine.rebuild(rules: [rule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: nil))
        XCTAssertNotEqual(decision.source, .userRule(rule.id))
    }

    func testBundleRuleOutranksSingleMatcherWildcard() {
        let engine = WindowRuleEngine()
        let wildcard = AppRule(bundleId: "", appNameSubstring: "Test", layout: .float)
        let bundled = AppRule(bundleId: "com.test.app", layout: .tile)
        engine.rebuild(rules: [wildcard, bundled])

        let decision = evaluate(engine, facts(appName: "Test App", bundleId: "com.test.app"))
        XCTAssertEqual(decision.disposition, .managed)
        XCTAssertEqual(decision.source, .userRule(bundled.id))
    }

    func testSteamBuiltInDefersWhenAXFactsFailed() {
        let engine = WindowRuleEngine()
        let decision = evaluate(
            engine,
            facts(
                appName: "Steam",
                bundleId: "com.valvesoftware.steam",
                role: nil,
                subrole: nil,
                attributeFetchSucceeded: false
            )
        )

        XCTAssertEqual(decision.disposition, .undecided)
        XCTAssertEqual(decision.deferredReason, .attributeFetchFailed)
        XCTAssertEqual(decision.admissionOutcome, .deferred)
    }

    func testSteamBuiltInTilesWhenAXFactsAreValid() {
        let engine = WindowRuleEngine()
        let decision = evaluate(
            engine,
            facts(appName: "Steam", bundleId: "com.valvesoftware.steam")
        )

        XCTAssertEqual(decision.disposition, .managed)
        XCTAssertEqual(decision.source, .builtInRule("steamClient"))
    }

    func testMoreSpecificRuleWithoutInitialWidthShadowsGenericWidthRule() {
        let engine = WindowRuleEngine()
        let generic = AppRule(bundleId: "com.test.app", initialColumnWidth: 0.5)
        let specific = AppRule(
            bundleId: "com.test.app",
            titleSubstring: "Inspector",
            layout: .tile
        )
        engine.rebuild(rules: [generic, specific])

        let decision = evaluate(
            engine,
            facts(appName: "Test", bundleId: "com.test.app", title: "Inspector")
        )
        XCTAssertEqual(decision.source, .userRule(specific.id))
        XCTAssertNil(decision.admissionHints.initialNiriColumnWidth)
    }

    func testSystemTextInputPanelStaysUnmanagedWithWildcard() {
        let engine = WindowRuleEngine()
        let wildcard = AppRule(bundleId: "", appNameSubstring: "Input", layout: .float)
        engine.rebuild(rules: [wildcard])

        let decision = evaluate(
            engine,
            facts(appName: "Input Agent", bundleId: "com.apple.textinputmenuagent")
        )
        XCTAssertEqual(decision.disposition, .unmanaged)
    }

    func testScopedTitleFetchEnabledForNoBundleTitleRule() {
        let engine = WindowRuleEngine()
        XCTAssertFalse(engine.requiresTitle(for: nil))

        let rule = AppRule(bundleId: "", titleSubstring: "Main", layout: .float)
        engine.rebuild(rules: [rule])

        XCTAssertTrue(engine.requiresTitle(for: nil))

        let decision = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: "VMD Main"))
        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.source, .userRule(rule.id))
    }

    func testUnscopedTitleRuleFetchesTitleForBundledApp() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "", titleSubstring: "Main", layout: .float)
        engine.rebuild(rules: [rule])

        XCTAssertTrue(engine.requiresTitle(for: "example.app"))
    }

    func testAppNameScopedTitleRuleFetchesOnlyForMatchingApp() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            bundleId: "",
            appNameSubstring: "VMD",
            titleSubstring: "Main",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        XCTAssertTrue(engine.requiresTitle(for: "example.app", appName: "VMD Viewer"))
        XCTAssertFalse(engine.requiresTitle(for: "example.app", appName: "Other App"))
        XCTAssertNotEqual(
            evaluate(engine, facts(appName: "Other App", bundleId: "example.app")).disposition,
            .undecided
        )
    }

    func testProjectionSnapshotValidWhenAnchoredOnAppName() {
        let rule = AppRule(bundleId: "", appNameSubstring: "VMD", layout: .float)
        let snapshot = IPCRuleProjection.snapshot(from: rule, position: 1, invalidRegexMessagesByRuleId: [:])
        XCTAssertTrue(snapshot.isValid)
    }

    func testProjectionSnapshotInvalidWhenNoAnchor() {
        let rule = AppRule(bundleId: "", layout: .float)
        let snapshot = IPCRuleProjection.snapshot(from: rule, position: 1, invalidRegexMessagesByRuleId: [:])
        XCTAssertFalse(snapshot.isValid)
    }

    func testEffectlessRuleDoesNotShadowEffectiveRule() {
        let engine = WindowRuleEngine()
        // More specific (bundle + app name) but effect-less: must be dropped, not shadow.
        let effectless = AppRule(bundleId: "com.test.app", appNameSubstring: "Test")
        // Less specific (bundle only) but floats.
        let effective = AppRule(bundleId: "com.test.app", layout: .float)
        engine.rebuild(rules: [effectless, effective])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))
        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.source, .userRule(effective.id))
    }

    func testEffectlessRuleSnapshotIsInvalidWithMessage() {
        let rule = AppRule(bundleId: "com.test.app", appNameSubstring: "Test")
        let snapshot = IPCRuleProjection.snapshot(from: rule, position: 1, invalidRegexMessagesByRuleId: [:])
        XCTAssertFalse(snapshot.isValid)
        XCTAssertFalse(snapshot.validationMessages.isEmpty)
    }
}
