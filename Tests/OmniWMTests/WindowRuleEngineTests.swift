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
        hasCloseButton: Bool = true,
        hasFullscreenButton: Bool = true,
        hasZoomButton: Bool = true,
        hasMinimizeButton: Bool = true,
        windowServer: WindowServerInfo? = nil,
        attributeFetchSucceeded: Bool = true
    ) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: appName,
            ax: AXWindowFacts(
                role: role,
                subrole: subrole,
                title: title,
                hasCloseButton: hasCloseButton,
                hasFullscreenButton: hasFullscreenButton,
                fullscreenButtonEnabled: hasFullscreenButton,
                hasZoomButton: hasZoomButton,
                hasMinimizeButton: hasMinimizeButton,
                appPolicy: .regular,
                bundleId: bundleId,
                attributeFetchSucceeded: attributeFetchSucceeded
            ),
            sizeConstraints: nil,
            windowServer: windowServer
        )
    }

    private func evaluate(
        _ engine: WindowRuleEngine,
        _ facts: WindowRuleFacts,
        token: WindowToken? = nil,
        appFullscreen: Bool = false
    ) -> WindowDecision {
        engine.decision(for: facts, token: token, appFullscreen: appFullscreen)
    }

    private func transientFacts(
        bundleId: String,
        windowServer: WindowServerInfo?,
        title: String? = nil,
        role: String? = kAXWindowRole as String,
        subrole: String? = kAXUnknownSubrole as String,
        hasCloseButton: Bool = false,
        hasFullscreenButton: Bool = false,
        hasZoomButton: Bool = false,
        hasMinimizeButton: Bool = false
    ) -> WindowRuleFacts {
        facts(
            appName: "Widget Host",
            bundleId: bundleId,
            title: title,
            role: role,
            subrole: subrole,
            hasCloseButton: hasCloseButton,
            hasFullscreenButton: hasFullscreenButton,
            hasZoomButton: hasZoomButton,
            hasMinimizeButton: hasMinimizeButton,
            windowServer: windowServer
        )
    }

    private func transientWindowServerInfo(
        token: WindowToken,
        frame: CGRect = .zero,
        level: Int32 = 0,
        tags: UInt64 = 0x1_400C_2482,
        attributes: UInt32 = 3,
        parentId: UInt32 = 7_905
    ) -> WindowServerInfo {
        WindowServerInfo(
            id: UInt32(token.windowId),
            pid: Int32(token.pid),
            level: level,
            frame: frame,
            tags: tags,
            attributes: attributes,
            parentId: parentId
        )
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
            facts(appName: "Steam", bundleId: "com.valvesoftware.steam.helper")
        )

        XCTAssertEqual(decision.disposition, .managed)
        XCTAssertEqual(decision.source, .builtInRule("steamClient"))
    }

    func testSteamBuiltInDoesNotTileTheNonHelperBundle() {
        let engine = WindowRuleEngine()
        let decision = evaluate(
            engine,
            facts(
                appName: "Steam",
                bundleId: "com.valvesoftware.steam",
                subrole: kAXUnknownSubrole as String
            )
        )

        XCTAssertNotEqual(decision.source, .builtInRule("steamClient"))
        XCTAssertEqual(decision.disposition, .floating)
    }

    func testCleanShotRecordingOverlayStillFloatsWithWindowServerEvidence() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_061, windowId: 84_062)
        let decision = evaluate(
            engine,
            facts(
                appName: "CleanShot X",
                bundleId: WindowRuleEngine.cleanShotBundleId,
                windowServer: WindowServerInfo(
                    id: 84_062,
                    pid: 84_061,
                    level: 103,
                    frame: .zero
                )
            ),
            token: token
        )

        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.source, .builtInRule("cleanShotRecordingOverlay"))
    }

    func testMoreSpecificRuleWithoutInitialWidthShadowsGenericWidthRule() {
        let engine = WindowRuleEngine()
        let generic = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.5)
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
        XCTAssertNil(decision.admissionHints.initialNiriContainerPrimarySpan)
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

    func testTraceProvenParentedTransientWidgetsAreUnmanagedAcrossBundles() {
        let engine = WindowRuleEngine()
        let popupToken = WindowToken(pid: 86_312, windowId: 7_916)
        let dropdownToken = WindowToken(pid: 86_312, windowId: 7_907)
        let traceSamples = [
            (
                popupToken,
                transientWindowServerInfo(
                    token: popupToken,
                    frame: CGRect(x: 2_128, y: 126, width: 320, height: 425)
                )
            ),
            (
                dropdownToken,
                transientWindowServerInfo(
                    token: dropdownToken,
                    frame: CGRect(x: 1_387, y: 71, width: 824, height: 89)
                )
            )
        ]

        for bundleId in ["com.google.Chrome", "org.example.widget-host"] {
            for (token, windowServer) in traceSamples {
                let decision = evaluate(
                    engine,
                    transientFacts(bundleId: bundleId, windowServer: windowServer),
                    token: token
                )
                XCTAssertEqual(decision.disposition, .unmanaged)
                XCTAssertEqual(
                    decision.source,
                    .builtInRule(WindowRuleEngine.transientWidgetSurfaceRuleName)
                )
                XCTAssertTrue(decision.isTransientWidgetSurfaceDecision)
                XCTAssertTrue(decision.isNonRenderableTransientSurfaceDecision)
                XCTAssertEqual(decision.admissionOutcome, .ignored)
                XCTAssertEqual(decision.admissionRejectionReason, .nonRenderableTransientSurface)
                XCTAssertNil(decision.deferredReason)
            }
        }
    }

    func testTransientWidgetMissingOrMismatchedWindowServerEvidenceDefers() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_011, windowId: 84_012)
        let mismatchedEvidence = [
            WindowServerInfo(id: 84_013, pid: 84_011, level: 0, frame: .zero, tags: 0x2, parentId: 9),
            WindowServerInfo(id: 84_012, pid: 84_014, level: 0, frame: .zero, tags: 0x2, parentId: 9)
        ]

        for evidence in [nil] + mismatchedEvidence.map(Optional.some) {
            let decision = evaluate(
                engine,
                transientFacts(bundleId: "org.example.widget-host", windowServer: evidence),
                token: token
            )
            XCTAssertEqual(decision.disposition, .undecided)
            XCTAssertEqual(decision.deferredReason, .windowServerEvidenceMissing)
            XCTAssertEqual(decision.admissionPendingReason, .windowServerEvidenceMissing)
            XCTAssertEqual(
                decision.source,
                .builtInRule(WindowRuleEngine.transientWidgetSurfaceRuleName)
            )
        }
    }

    func testTransientWidgetRequiresEveryWindowServerPredicate() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_021, windowId: 84_022)
        let nonmatchingEvidence = [
            transientWindowServerInfo(token: token, level: 1),
            transientWindowServerInfo(token: token, parentId: 0),
            transientWindowServerInfo(token: token, parentId: 84_022),
            transientWindowServerInfo(token: token, tags: 0),
            transientWindowServerInfo(token: token, tags: 0x1_400C_2483),
            transientWindowServerInfo(token: token, tags: 0x1_C00C_2482)
        ]

        for evidence in nonmatchingEvidence {
            let decision = evaluate(
                engine,
                transientFacts(bundleId: "org.example.widget-host", windowServer: evidence),
                token: token
            )
            XCTAssertEqual(decision.disposition, .floating)
            XCTAssertEqual(decision.source, .heuristic)
            XCTAssertFalse(decision.isTransientWidgetSurfaceDecision)
            XCTAssertFalse(decision.isNonRenderableTransientSurfaceDecision)
        }
    }

    func testTransientWidgetRequiresEveryAXPredicate() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_031, windowId: 84_032)
        let windowServer = transientWindowServerInfo(token: token)
        let candidates = [
            transientFacts(bundleId: "org.example", windowServer: windowServer, role: kAXButtonRole as String),
            transientFacts(
                bundleId: "org.example",
                windowServer: windowServer,
                subrole: kAXStandardWindowSubrole as String
            ),
            transientFacts(bundleId: "org.example", windowServer: windowServer, hasCloseButton: true),
            transientFacts(bundleId: "org.example", windowServer: windowServer, hasFullscreenButton: true),
            transientFacts(bundleId: "org.example", windowServer: windowServer, hasZoomButton: true),
            transientFacts(bundleId: "org.example", windowServer: windowServer, hasMinimizeButton: true)
        ]

        for facts in candidates {
            let decision = evaluate(engine, facts, token: token)
            XCTAssertEqual(decision.disposition, .floating)
            XCTAssertFalse(decision.isTransientWidgetSurfaceDecision)
            XCTAssertFalse(decision.isNonRenderableTransientSurfaceDecision)
        }
    }

    func testDialogsSheetsAndFailedAXFactsDoNotMatchTransientWidgetSignature() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_035, windowId: 84_036)
        let windowServer = transientWindowServerInfo(token: token)
        let semanticWindows = [
            transientFacts(
                bundleId: "org.example",
                windowServer: windowServer,
                subrole: kAXDialogSubrole as String
            ),
            transientFacts(
                bundleId: "org.example",
                windowServer: windowServer,
                subrole: kAXSystemDialogSubrole as String
            ),
            transientFacts(
                bundleId: "org.example",
                windowServer: windowServer,
                role: kAXSheetRole as String
            )
        ]

        for facts in semanticWindows {
            let decision = evaluate(engine, facts, token: token)
            XCTAssertEqual(decision.disposition, .floating)
            XCTAssertFalse(decision.isTransientWidgetSurfaceDecision)
            XCTAssertFalse(decision.isNonRenderableTransientSurfaceDecision)
        }

        let failedFacts = facts(
            appName: "Widget Host",
            bundleId: "org.example",
            role: kAXWindowRole as String,
            subrole: kAXUnknownSubrole as String,
            hasCloseButton: false,
            hasFullscreenButton: false,
            hasZoomButton: false,
            hasMinimizeButton: false,
            windowServer: windowServer,
            attributeFetchSucceeded: false
        )
        let failedDecision = evaluate(engine, failedFacts, token: token)
        XCTAssertEqual(failedDecision.disposition, .undecided)
        XCTAssertEqual(failedDecision.deferredReason, .attributeFetchFailed)
        XCTAssertFalse(failedDecision.isTransientWidgetSurfaceDecision)
        XCTAssertFalse(failedDecision.isNonRenderableTransientSurfaceDecision)
    }

    func testExplicitRulesPrecedeTransientWidgetClassification() {
        let token = WindowToken(pid: 84_041, windowId: 84_042)
        let windowServer = transientWindowServerInfo(token: token)

        let userEngine = WindowRuleEngine()
        let userRule = AppRule(bundleId: "org.example.widget-host", layout: .tile)
        userEngine.rebuild(rules: [userRule])
        let userDecision = evaluate(
            userEngine,
            transientFacts(bundleId: "org.example.widget-host", windowServer: windowServer),
            token: token
        )
        XCTAssertEqual(userDecision.disposition, .managed)
        XCTAssertEqual(userDecision.source, .userRule(userRule.id))

        let builtInDecision = evaluate(
            WindowRuleEngine(),
            transientFacts(bundleId: "com.valvesoftware.steam.helper", windowServer: windowServer),
            token: token
        )
        XCTAssertEqual(builtInDecision.disposition, .managed)
        XCTAssertEqual(builtInDecision.source, .builtInRule("steamClient"))
    }

    func testFullscreenAndBrowserPictureInPicturePrecedeTransientWidgetClassification() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_045, windowId: 84_046)
        let windowServer = transientWindowServerInfo(token: token)
        let fullscreenDecision = evaluate(
            engine,
            transientFacts(bundleId: "org.example.widget-host", windowServer: windowServer),
            token: token,
            appFullscreen: true
        )

        XCTAssertEqual(fullscreenDecision.disposition, .managed)
        XCTAssertEqual(fullscreenDecision.source, .heuristic)
        XCTAssertFalse(fullscreenDecision.isTransientWidgetSurfaceDecision)

        for bundleId in ["org.mozilla.firefox", "app.zen-browser.zen"] {
            let pictureInPictureDecision = evaluate(
                engine,
                transientFacts(
                    bundleId: bundleId,
                    windowServer: windowServer,
                    title: "Picture-in-Picture"
                ),
                token: token
            )
            XCTAssertEqual(pictureInPictureDecision.disposition, .floating)
            XCTAssertEqual(pictureInPictureDecision.source, .builtInRule("browserPictureInPicture"))
            XCTAssertFalse(pictureInPictureDecision.isTransientWidgetSurfaceDecision)
        }
    }

    func testAutomaticRuleEffectsDoNotOverrideTransientWidgetClassification() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "org.example.widget-host", minWidth: 420)
        engine.rebuild(rules: [rule])
        let token = WindowToken(pid: 84_051, windowId: 84_052)
        let windowServer = transientWindowServerInfo(token: token)

        let decision = evaluate(
            engine,
            transientFacts(bundleId: "org.example.widget-host", windowServer: windowServer),
            token: token
        )
        let overridden = WindowRuleEngine.applyingManualOverride(decision, manualOverride: .forceTile)

        XCTAssertEqual(decision.disposition, .unmanaged)
        XCTAssertEqual(decision.ruleEffects.minWidth, 420)
        XCTAssertEqual(overridden.disposition, .unmanaged)
    }

    func testHelpTagIsHardUnmanagedWithoutWindowServerOrCompleteAXFacts() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 86_312, windowId: 7_918)
        let arbitraryEvidence = [
            nil,
            WindowServerInfo(
                id: 99_999,
                pid: 77_777,
                level: 103,
                frame: CGRect(x: 1_287, y: 1_403, width: 118, height: 22),
                tags: 0x1,
                attributes: 7,
                parentId: 99_999
            )
        ]

        for windowServer in arbitraryEvidence {
            let decision = evaluate(
                engine,
                facts(
                    appName: "Google Chrome",
                    bundleId: "com.google.Chrome",
                    role: kAXHelpTagRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    windowServer: windowServer,
                    attributeFetchSucceeded: false
                ),
                token: token
            )
            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.helpTagSurfaceRuleName))
            XCTAssertTrue(decision.isHelpTagSurfaceDecision)
            XCTAssertTrue(decision.isNonRenderableTransientSurfaceDecision)
            XCTAssertEqual(decision.admissionRejectionReason, .nonRenderableTransientSurface)
            XCTAssertNil(decision.deferredReason)
        }
    }

    func testHelpTagPrecedesRulesFullscreenAndManualOverrides() {
        let userEngine = WindowRuleEngine()
        let explicitRule = AppRule(
            bundleId: "com.google.Chrome",
            layout: .tile,
            assignToWorkspace: "Web",
            minWidth: 500,
            minHeight: 375
        )
        userEngine.rebuild(rules: [explicitRule])
        let userDecision = evaluate(
            userEngine,
            facts(
                appName: "Google Chrome",
                bundleId: "com.google.Chrome",
                role: kAXHelpTagRole as String,
                subrole: kAXUnknownSubrole as String,
                hasCloseButton: false,
                hasFullscreenButton: false,
                hasZoomButton: false,
                hasMinimizeButton: false
            ),
            appFullscreen: true
        )

        XCTAssertEqual(userDecision.source, .builtInRule(WindowRuleEngine.helpTagSurfaceRuleName))
        XCTAssertEqual(userDecision.disposition, .unmanaged)
        XCTAssertNil(userDecision.workspaceName)
        XCTAssertEqual(userDecision.ruleEffects, .none)

        for override in [ManualWindowOverride.forceTile, .forceFloat] {
            let overridden = WindowRuleEngine.applyingManualOverride(userDecision, manualOverride: override)
            XCTAssertEqual(overridden, userDecision)
        }

        for bundleId in ["com.valvesoftware.steam", "com.apple.textinputmenuagent"] {
            let decision = evaluate(
                WindowRuleEngine(),
                facts(
                    appName: "Help Surface",
                    bundleId: bundleId,
                    role: kAXHelpTagRole as String,
                    subrole: kAXUnknownSubrole as String,
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    hasZoomButton: false,
                    hasMinimizeButton: false
                )
            )
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.helpTagSurfaceRuleName))
            XCTAssertEqual(decision.disposition, .unmanaged)
        }

        let titleEngine = WindowRuleEngine()
        titleEngine.rebuild(
            rules: [AppRule(bundleId: "com.google.Chrome", titleSubstring: "Tooltip", layout: .tile)]
        )
        let titleDecision = evaluate(
            titleEngine,
            facts(
                appName: "Google Chrome",
                bundleId: "com.google.Chrome",
                role: kAXHelpTagRole as String,
                subrole: kAXUnknownSubrole as String,
                hasCloseButton: false,
                hasFullscreenButton: false,
                hasZoomButton: false,
                hasMinimizeButton: false
            )
        )
        XCTAssertEqual(titleDecision.source, .builtInRule(WindowRuleEngine.helpTagSurfaceRuleName))
        XCTAssertNil(titleDecision.deferredReason)
    }

    func testNonRenderableDecisionSemanticsDistinguishTransientHelpTagAndPolicyIgnore() {
        let engine = WindowRuleEngine()
        let transientToken = WindowToken(pid: 84_071, windowId: 84_072)
        let transientDecision = evaluate(
            engine,
            transientFacts(
                bundleId: "org.example.widget-host",
                windowServer: transientWindowServerInfo(token: transientToken)
            ),
            token: transientToken
        )
        let helpTagDecision = evaluate(
            engine,
            facts(
                appName: "Widget Host",
                bundleId: "org.example.widget-host",
                role: kAXHelpTagRole as String,
                subrole: kAXUnknownSubrole as String,
                hasCloseButton: false,
                hasFullscreenButton: false,
                hasZoomButton: false,
                hasMinimizeButton: false
            )
        )
        let policyDecision = evaluate(
            engine,
            facts(appName: "Input Agent", bundleId: "com.apple.textinputmenuagent")
        )

        XCTAssertTrue(transientDecision.isTransientWidgetSurfaceDecision)
        XCTAssertFalse(transientDecision.isHelpTagSurfaceDecision)
        XCTAssertEqual(transientDecision.layoutDecisionKind, .fallbackLayout)
        XCTAssertEqual(transientDecision.admissionRejectionReason, .nonRenderableTransientSurface)

        XCTAssertFalse(helpTagDecision.isTransientWidgetSurfaceDecision)
        XCTAssertTrue(helpTagDecision.isHelpTagSurfaceDecision)
        XCTAssertEqual(helpTagDecision.layoutDecisionKind, .explicitLayout)
        XCTAssertEqual(helpTagDecision.admissionRejectionReason, .nonRenderableTransientSurface)

        XCTAssertEqual(policyDecision.disposition, .unmanaged)
        XCTAssertFalse(policyDecision.isNonRenderableTransientSurfaceDecision)
        XCTAssertEqual(policyDecision.admissionRejectionReason, .policyIgnored)
    }
}
