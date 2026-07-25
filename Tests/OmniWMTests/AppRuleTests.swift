// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppRuleTests: XCTestCase {
    func testNormalizeSingleTitleDropsSubstringWhenBothSet() {
        let rule = AppRule(
            bundleId: "com.test.app",
            titleSubstring: "Main",
            titleRegex: "^Main$",
            layout: .float
        )
        XCTAssertNil(rule.titleSubstring)
        XCTAssertEqual(rule.titleRegex, "^Main$")
    }

    func testNormalizeKeepsLoneTitleMatchers() {
        let substring = AppRule(bundleId: "a", titleSubstring: "Main", layout: .float)
        XCTAssertEqual(substring.titleSubstring, "Main")
        XCTAssertNil(substring.titleRegex)

        let regex = AppRule(bundleId: "a", titleRegex: "^Main$", layout: .float)
        XCTAssertNil(regex.titleSubstring)
        XCTAssertEqual(regex.titleRegex, "^Main$")
    }

    func testNormalizeSingleTitleAppliesOnDecode() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","bundleId":"com.test.app",\
        "titleSubstring":"Main","titleRegex":"^Main$","layout":"float"}
        """
        let rule = try JSONDecoder().decode(AppRule.self, from: Data(json.utf8))
        XCTAssertNil(rule.titleSubstring)
        XCTAssertEqual(rule.titleRegex, "^Main$")
    }

    func testHasEffect() {
        XCTAssertFalse(AppRule(bundleId: "com.test.app").hasEffect)
        XCTAssertFalse(AppRule(bundleId: "com.test.app", appNameSubstring: "Test").hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", layout: .float).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", assignToWorkspace: "2").hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.05).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 1.0).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", minWidth: 400).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", minHeight: 300).hasEffect)
    }

    func testInvalidInitialContainerPrimarySpanDoesNotCountAsEffect() {
        for value in [0.049, 1.001, .nan, .infinity, -.infinity] {
            let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: value)
            XCTAssertNil(rule.validInitialContainerPrimarySpan)
            XCTAssertFalse(rule.hasEffect)
        }
    }

    func testInitialContainerPrimarySpanRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.appRules = [AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.5)]

        let data = try SettingsTOMLCodec.encode(export)
        let toml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(toml.contains("initialContainerPrimarySpan = 0.5"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).appRules.first?.initialContainerPrimarySpan, 0.5)
    }

    func testNilInitialContainerPrimarySpanIsOmittedFromJSONAndTOML() throws {
        let rule = AppRule(bundleId: "com.test.app", layout: .float)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any]
        )
        XCTAssertNil(json["initialContainerPrimarySpan"])

        var export = SettingsExport.defaults()
        export.appRules = [rule]
        let tomlData = try SettingsTOMLCodec.encode(export)
        let toml = try XCTUnwrap(String(data: tomlData, encoding: .utf8))
        XCTAssertFalse(toml.contains("initialContainerPrimarySpan"))
        XCTAssertNil(try SettingsTOMLCodec.decode(tomlData).appRules.first?.initialContainerPrimarySpan)
    }

    func testLegacyInitialColumnWidthTOMLKeyIsIgnoredAndDiagnosed() throws {
        var export = SettingsExport.defaults()
        export.appRules = [
            AppRule(
                bundleId: "com.test.app",
                layout: .float,
                initialContainerPrimarySpan: 0.5
            )
        ]
        let canonical = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        let legacy = Data(
            canonical.replacingOccurrences(
                of: "initialContainerPrimarySpan",
                with: "initialColumnWidth"
            ).utf8
        )

        let decoded = try SettingsTOMLCodec.decode(legacy)

        XCTAssertNil(decoded.appRules.first?.initialContainerPrimarySpan)
        XCTAssertEqual(
            SettingsTOMLCodec.unknownKeyPaths(in: legacy),
            ["appRules[0].initialColumnWidth"]
        )
    }

    @MainActor
    func testAppRulesRevisionChangesOnlyForDistinctRules() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMRuleRevision-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let baseline = settings.appRulesRevision
        let rules = [AppRule(bundleId: "com.test.app", layout: .float)]

        settings.appRules = rules
        XCTAssertEqual(settings.appRulesRevision, baseline + 1)

        settings.appRules = rules
        XCTAssertEqual(settings.appRulesRevision, baseline + 1)
    }

    @MainActor
    func testIPCProjectionRoundTripsInitialContainerPrimarySpan() {
        let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.5)
        let definition = IPCRuleProjection.definition(from: rule)
        let projectedRule = IPCRuleProjection.appRule(from: definition, id: rule.id)
        let snapshot = IPCRuleProjection.snapshot(
            from: projectedRule,
            position: 1,
            invalidRegexMessagesByRuleId: [:]
        )

        XCTAssertEqual(definition.initialContainerPrimarySpan, 0.5)
        XCTAssertEqual(projectedRule, rule)
        XCTAssertEqual(snapshot.initialContainerPrimarySpan, 0.5)
        XCTAssertTrue(snapshot.isValid)
    }

    @MainActor
    func testIPCProjectionReportsInvalidInitialContainerPrimarySpan() {
        let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 1.001)
        let snapshot = IPCRuleProjection.snapshot(
            from: rule,
            position: 1,
            invalidRegexMessagesByRuleId: [:]
        )

        XCTAssertFalse(snapshot.isValid)
        XCTAssertTrue(snapshot.validationMessages.contains { $0.hasPrefix("Initial container primary span") })
    }

    func testDraftDefaultsAndRoundTripsInitialContainerPrimarySpan() {
        let emptyDraft = AppRuleDraft()
        XCTAssertFalse(emptyDraft.initialContainerPrimarySpanEnabled)
        XCTAssertEqual(emptyDraft.initialContainerPrimarySpan, 0.5)

        let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.75)
        let draft = AppRuleDraft(rule: rule)
        XCTAssertTrue(draft.initialContainerPrimarySpanEnabled)
        XCTAssertEqual(draft.initialContainerPrimarySpan, 0.75)
        XCTAssertNil(draft.initialContainerPrimarySpanError)
        XCTAssertEqual(draft.makeRule(), rule)
    }

    func testSelectingBundledApplicationReplacesOnlyApplicationIdentityMatchers() {
        var draft = populatedDraft()
        let expectedId = draft.id

        draft.selectApplication(bundleId: "com.example.Bundled", appName: "Bundled")

        XCTAssertEqual(draft.id, expectedId)
        XCTAssertEqual(draft.bundleId, "com.example.Bundled")
        XCTAssertFalse(draft.appNameMatcherEnabled)
        XCTAssertEqual(draft.appNameSubstring, "")
        assertUnrelatedSelectionState(draft)
    }

    func testSelectingBundlelessApplicationReplacesOnlyApplicationIdentityMatchers() {
        var draft = populatedDraft()
        let expectedId = draft.id

        draft.selectApplication(bundleId: nil, appName: "Bundleless")

        XCTAssertEqual(draft.id, expectedId)
        XCTAssertEqual(draft.bundleId, "")
        XCTAssertTrue(draft.appNameMatcherEnabled)
        XCTAssertEqual(draft.appNameSubstring, "Bundleless")
        assertUnrelatedSelectionState(draft)
    }

    func testInitialContainerPrimarySpanPercentConversionHandlesFractionsAndExtremeValues() {
        let proportion = 0.5555
        let percent = AppRuleInitialContainerPrimarySpanPercent.percent(from: proportion)
        XCTAssertEqual(percent, 55.55, accuracy: 0.000_000_1)
        XCTAssertEqual(
            AppRuleInitialContainerPrimarySpanPercent.proportion(from: percent),
            proportion,
            accuracy: 0.000_000_1
        )
        XCTAssertTrue(AppRuleInitialContainerPrimarySpanPercent.percent(from: .greatestFiniteMagnitude).isInfinite)
        XCTAssertTrue(AppRuleInitialContainerPrimarySpanPercent.percent(from: .nan).isNaN)
        XCTAssertEqual(AppRuleInitialContainerPrimarySpanPercent.percent(from: .infinity), .infinity)
        XCTAssertEqual(AppRuleInitialContainerPrimarySpanPercent.percent(from: -.infinity), -.infinity)
        XCTAssertEqual(AppRuleInitialContainerPrimarySpanPercent.displayText(for: proportion), "55.55")

        var invalidDraft = AppRuleDraft(bundleId: "com.test.app")
        invalidDraft.initialContainerPrimarySpanEnabled = true
        invalidDraft.initialContainerPrimarySpan = AppRuleInitialContainerPrimarySpanPercent.proportion(from: 4.9)
        XCTAssertEqual(invalidDraft.initialContainerPrimarySpan, 0.049, accuracy: 0.000_000_1)
        XCTAssertNotNil(invalidDraft.initialContainerPrimarySpanError)
    }

    func testDraftEqualityAndRuleRepresentationAreNaNStable() {
        let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: .nan)
        let lhs = AppRuleDraft(rule: rule)
        let rhs = AppRuleDraft(rule: rule)

        XCTAssertEqual(lhs, rhs)
        XCTAssertTrue(lhs.represents(rule))

        var changed = lhs
        changed.initialContainerPrimarySpan = .infinity
        XCTAssertNotEqual(changed, rhs)
        XCTAssertFalse(changed.represents(rule))
    }

    private func populatedDraft() -> AppRuleDraft {
        var draft = AppRuleDraft(bundleId: "com.example.Previous")
        draft.layoutAction = .float
        draft.assignToWorkspaceEnabled = true
        draft.assignToWorkspace = "work"
        draft.initialContainerPrimarySpanEnabled = true
        draft.initialContainerPrimarySpan = 0.7
        draft.minWidthEnabled = true
        draft.minWidth = 640
        draft.minHeightEnabled = true
        draft.minHeight = 480
        draft.appNameMatcherEnabled = true
        draft.appNameSubstring = "Previous"
        draft.titleMatcherMode = .regex
        draft.titleSubstring = "unchanged substring"
        draft.titleRegex = "^Document"
        draft.axRoleEnabled = true
        draft.axRole = "AXWindow"
        draft.axSubroleEnabled = true
        draft.axSubrole = "AXStandardWindow"
        return draft
    }

    private func assertUnrelatedSelectionState(_ draft: AppRuleDraft) {
        XCTAssertEqual(draft.layoutAction, .float)
        XCTAssertTrue(draft.assignToWorkspaceEnabled)
        XCTAssertEqual(draft.assignToWorkspace, "work")
        XCTAssertTrue(draft.initialContainerPrimarySpanEnabled)
        XCTAssertEqual(draft.initialContainerPrimarySpan, 0.7)
        XCTAssertTrue(draft.minWidthEnabled)
        XCTAssertEqual(draft.minWidth, 640)
        XCTAssertTrue(draft.minHeightEnabled)
        XCTAssertEqual(draft.minHeight, 480)
        XCTAssertEqual(draft.titleMatcherMode, .regex)
        XCTAssertEqual(draft.titleSubstring, "unchanged substring")
        XCTAssertEqual(draft.titleRegex, "^Document")
        XCTAssertTrue(draft.axRoleEnabled)
        XCTAssertEqual(draft.axRole, "AXWindow")
        XCTAssertTrue(draft.axSubroleEnabled)
        XCTAssertEqual(draft.axSubrole, "AXStandardWindow")
    }
}
