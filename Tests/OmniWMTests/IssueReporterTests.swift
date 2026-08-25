// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class IssueReporterTests: XCTestCase {
    func testRewritePromptResourceLoadsWithRequiredAnchors() {
        let prompt = IssueTemplate.rewriteInstructions
        XCTAssertFalse(prompt.isEmpty)
        XCTAssertTrue(prompt.contains(IssueTemplate.notProvided))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("numbered"))
        for header in IssueTemplate.requiredHeaders {
            let section = header.replacingOccurrences(of: "## ", with: "")
            XCTAssertTrue(prompt.contains(section), "rewrite prompt missing section: \(section)")
        }
    }

    func testRewritePromptContainsNoCopyableShortcutArtifacts() {
        let prompt = IssueTemplate.rewriteInstructions
        for artifact in ["Alt+Enter", "Toggle Fullscreen", "Press Alt+Enter", "KNOWN SHORTCUTS"] {
            XCTAssertFalse(
                prompt.localizedCaseInsensitiveContains(artifact),
                "base rewrite prompt must not contain copyable artifact: \(artifact)"
            )
        }
    }

    func testHotkeyPreambleResourceLoadsWithKnownShortcutsAnchor() {
        let preamble = IssueTemplate.hotkeyContextPreamble
        XCTAssertFalse(preamble.isEmpty)
        XCTAssertTrue(preamble.contains("KNOWN SHORTCUTS"))
    }

    func testEnvironmentBlockContainsVersions() {
        let builder = GitHubIssueURLBuilder(appVersion: "9.9.9", osVersion: "Version 26.1 (Build X)")
        let block = builder.environmentBlock()
        XCTAssertTrue(block.contains("9.9.9"))
        XCTAssertTrue(block.contains("26.1"))
    }

    func testSubmissionEncodesSpacesAndPlus() {
        let builder = GitHubIssueURLBuilder(appVersion: "1.0", osVersion: "26.0")
        guard case let .url(url) = builder.submission(title: "Bug report", body: "Crash in C++ now") else {
            return XCTFail("expected a url submission")
        }
        let string = url.absoluteString
        XCTAssertTrue(string.contains("Bug%20report"))
        XCTAssertTrue(string.contains("C%2B%2B"))
        XCTAssertFalse(string.contains("+"))
    }

    func testLongBodyFallsBackToClipboard() {
        let builder = GitHubIssueURLBuilder(appVersion: "1.0", osVersion: "26.0", maxURLLength: 60)
        let long = String(repeating: "x", count: 500)
        guard case let .clipboard(markdown, fallbackURL) = builder.submission(title: "Bug", body: long) else {
            return XCTFail("expected a clipboard submission")
        }
        XCTAssertTrue(markdown.contains("## Environment"))
        XCTAssertTrue(markdown.contains(long))
        let fallback = fallbackURL.absoluteString
        XCTAssertTrue(fallback.contains("title=Bug"))
        XCTAssertFalse(fallback.contains("body="))
    }

    func testRequestRewriteSuggestsWithoutMutatingFields() async {
        let engine = FakeIssueEngine(rewriteResult: .success(RewrittenIssue(title: "Clean title", body: "Clean body")))
        let model = makeModel(engine: engine)
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        XCTAssertEqual(model.suggestion, RewrittenIssue(title: "Clean title", body: "Clean body"))
        XCTAssertEqual(model.title, "rough title")
        XCTAssertEqual(model.actual, "rough body")
        XCTAssertNil(model.polishedBody)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertNil(model.errorMessage)
    }

    func testApplyRewriteSetsTitleAndPolishedBody() async {
        let engine = FakeIssueEngine(rewriteResult: .success(RewrittenIssue(title: "Clean title", body: "Clean body")))
        let model = makeModel(engine: engine)
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        model.applyRewrite()
        XCTAssertEqual(model.title, "Clean title")
        XCTAssertEqual(model.polishedBody, "Clean body")
        XCTAssertEqual(model.submissionBody, "Clean body")
        XCTAssertNil(model.suggestion)
    }

    func testRequestRewriteForwardsHotkeyContextToEngine() async {
        let engine = FakeIssueEngine()
        let context = "KNOWN SHORTCUTS:\n- \"shift+o\" is bound to: Toggle Overview"
        let model = makeModel(engine: engine, hotkeyContextProvider: { _ in context })
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        XCTAssertEqual(engine.lastHotkeyContext, context)
    }

    func testResolveBindsMentionedShortcutToCommand() {
        let resolved = IssueHotkeyContext.resolve(
            text: "When I press alt+shift+right nothing happens",
            bindings: HotkeyBindingRegistry.defaults()
        )
        XCTAssertTrue(
            resolved.contains("\"alt+shift+right\" is bound to: Move Right"),
            "expected Move Right, got: \(resolved)"
        )
    }

    func testResolveReportsUnboundShortcut() {
        let resolved = IssueHotkeyContext.resolve(text: "alt+shift+right does nothing", bindings: [])
        XCTAssertTrue(resolved.contains("\"alt+shift+right\" is not bound to any command"))
    }

    func testResolveIgnoresNonChordText() {
        let resolved = IssueHotkeyContext.resolve(
            text: "windows flicker sometimes",
            bindings: HotkeyBindingRegistry.defaults()
        )
        XCTAssertTrue(resolved.isEmpty)
    }

    func testRequestRewriteErrorSetsMessage() async {
        let engine = FakeIssueEngine(rewriteResult: .failure(IssueReportError.generationFailed("nope")))
        let model = makeModel(engine: engine)
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        XCTAssertEqual(model.errorMessage, "nope")
        XCTAssertNil(model.suggestion)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertTrue(model.canSubmit)
    }

    func testRequestRewriteIsNoOpWhenAIUnavailable() async {
        let model = makeModel(engine: FakeIssueEngine(availability: .appleIntelligenceNotEnabled))
        model.title = "Crash on launch"
        model.actual = "It crashes every time I open it."
        XCTAssertFalse(model.canRequestRewrite)
        await model.requestRewrite()
        XCTAssertNil(model.suggestion)
        XCTAssertNil(model.polishedBody)
    }

    func testCanRequestRewriteRequiresTitleAndActual() {
        let model = makeModel(engine: FakeIssueEngine())
        XCTAssertFalse(model.canRequestRewrite)
        model.title = "Title"
        XCTAssertFalse(model.canRequestRewrite)
        model.actual = "Message"
        XCTAssertTrue(model.canRequestRewrite)
    }

    func testEditingFieldsClearsSuggestion() async {
        let engine = FakeIssueEngine(rewriteResult: .success(RewrittenIssue(title: "Clean title", body: "Clean body")))
        let model = makeModel(engine: engine)
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        XCTAssertNotNil(model.suggestion)
        model.actual += " more detail"
        XCTAssertNil(model.suggestion)
    }

    func testComposeIncludesFilledFieldsAndOmitsEmptyOptional() {
        let model = makeModel(engine: FakeIssueEngine())
        model.title = "Bug"
        model.actual = "It crashed"
        model.category = .crash
        model.layout = .dwindle
        model.regression = .yes
        model.regressionVersion = "0.4.6"
        let composed = model.submissionBody
        XCTAssertTrue(composed.contains("## What happened\nIt crashed"))
        XCTAssertTrue(composed.contains("Crash"))
        XCTAssertTrue(composed.contains("Dwindle"))
        XCTAssertTrue(composed.contains("0.4.6"))
        XCTAssertFalse(composed.contains("## Expected behavior"))
    }

    func testStartOverClearsFields() {
        let model = makeModel(engine: FakeIssueEngine())
        model.title = "Bug"
        model.actual = "It crashed"
        model.category = .crash
        XCTAssertTrue(model.hasDraftContent)
        model.startOver()
        XCTAssertTrue(model.title.isEmpty)
        XCTAssertTrue(model.actual.isEmpty)
        XCTAssertEqual(model.category, .unspecified)
        XCTAssertFalse(model.hasDraftContent)
    }

    func testIssueDraftRoundTripsThroughRuntimeStateStore() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-issue-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = IssueDraft(
            title: "Bug",
            actual: "It crashed",
            expected: "No crash",
            repro: "Open app",
            affectedApps: "Safari",
            category: IssueCategory.crash.rawValue,
            layout: LayoutType.dwindle.rawValue,
            regression: IssueRegression.yes.rawValue,
            regressionVersion: "0.4.6",
            polishedBody: "## What happened\nIt crashed"
        )
        let writer = RuntimeStateStore(directory: directory, deferSaves: false)
        writer.issueDraft = draft
        let reader = RuntimeStateStore(directory: directory, deferSaves: false)
        XCTAssertEqual(reader.issueDraft, draft)
    }

    func testAppliedRewriteSurvivesDraftReload() async {
        var saved: IssueDraft?
        let engine = FakeIssueEngine(rewriteResult: .success(RewrittenIssue(title: "Clean title", body: "Clean body")))
        let model = ReportIssueViewModel(engine: engine, saveDraft: { saved = $0 })
        model.title = "rough title"
        model.actual = "rough body"
        await model.requestRewrite()
        model.applyRewrite()
        let reloaded = ReportIssueViewModel(engine: FakeIssueEngine(), loadDraft: { saved })
        XCTAssertEqual(reloaded.polishedBody, "Clean body")
        XCTAssertEqual(reloaded.submissionBody, "Clean body")
        XCTAssertEqual(reloaded.title, "Clean title")
    }

    func testAssembleSubstitutesNotProvidedForEmptyFields() {
        let body = IssueTemplate.assemble(
            summary: "It crashed on launch",
            stepsToReproduce: "",
            expectedBehavior: "   ",
            actualBehavior: "Crash",
            additionalContext: ""
        )
        XCTAssertTrue(body.contains("## Summary\nIt crashed on launch"))
        XCTAssertTrue(body.contains("## Steps to Reproduce\nNot provided"))
        XCTAssertTrue(body.contains("## Expected Behavior\nNot provided"))
        XCTAssertTrue(body.contains("## Actual Behavior\nCrash"))
        XCTAssertTrue(body.contains("## Additional Context\nNot provided"))
    }

    func testSubmitOpensBrowser() async {
        var opened: [URL] = []
        let model = makeModel(engine: FakeIssueEngine(), openURL: { opened.append($0) })
        model.title = "Bug"
        model.actual = "Body"
        await model.submit()
        XCTAssertEqual(model.phase, .submitted(.openedBrowser))
        XCTAssertEqual(opened.count, 1)
    }

    func testSubmitLongBodyCopiesToClipboard() async {
        var opened: [URL] = []
        var copied: [String] = []
        let builder = GitHubIssueURLBuilder(appVersion: "1.0", osVersion: "26.0", maxURLLength: 60)
        let model = makeModel(
            engine: FakeIssueEngine(),
            urlBuilder: builder,
            openURL: { opened.append($0) },
            copyToClipboard: { copied.append($0) }
        )
        model.title = "Bug"
        model.actual = String(repeating: "x", count: 500)
        await model.submit()
        XCTAssertEqual(model.phase, .submitted(.copiedToClipboard))
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue(copied.first?.contains("## Environment") ?? false)
    }

    func testSubmitRevealsAndRecordsSingleDiagnosticAttachment() async {
        var revealed: [URL] = []
        var resolvedEvidence: [IssueDiagnosticEvidence?] = []
        let attachment = URL(fileURLWithPath: "/tmp/omniwm-diagnostics.log")
        let crash = URL(fileURLWithPath: "/tmp/omniwm-crash.log")
        let model = makeModel(
            engine: FakeIssueEngine(),
            prepareDiagnosticAttachment: {
                resolvedEvidence.append($0)
                return DiagnosticAttachmentResult(url: attachment, includedEvidence: true)
            },
            revealInFinder: { revealed.append($0) }
        )
        model.title = "Bug"
        model.actual = "Body"
        model.category = .placement
        model.selectEvidence(.crash(crash))
        await model.submit()
        XCTAssertEqual(model.phase, .submitted(.openedBrowser))
        XCTAssertEqual(model.lastAttachment, attachment)
        XCTAssertNil(model.lastAttachmentError)
        XCTAssertEqual(resolvedEvidence, [.crash(crash)])
        XCTAssertEqual(revealed, [attachment])
    }

    func testSubmitDiagnosticAttachmentFailureStillSubmits() async {
        var opened: [URL] = []
        let model = makeModel(
            engine: FakeIssueEngine(),
            prepareDiagnosticAttachment: { _ in throw IssueReportError.generationFailed("disk full") },
            openURL: { opened.append($0) }
        )
        model.title = "Bug"
        model.actual = "Body"
        await model.submit()
        XCTAssertEqual(model.phase, .submitted(.openedBrowser))
        XCTAssertNil(model.lastAttachment)
        XCTAssertEqual(model.lastAttachmentError, "disk full")
        XCTAssertEqual(opened.count, 1)
    }

    func testUnavailableSelectedEvidenceProducesNonfatalWarning() async {
        let attachment = URL(fileURLWithPath: "/tmp/omniwm-diagnostics.log")
        let model = makeModel(
            engine: FakeIssueEngine(),
            prepareDiagnosticAttachment: { _ in
                DiagnosticAttachmentResult(url: attachment, includedEvidence: false)
            }
        )
        model.title = "Bug"
        model.actual = "Body"
        model.selectEvidence(.crash(URL(fileURLWithPath: "/tmp/missing-crash.log")))

        await model.submit()

        XCTAssertEqual(model.phase, .submitted(.openedBrowser))
        XCTAssertNotNil(model.lastAttachmentWarning)
        XCTAssertNil(model.lastAttachmentError)
    }

    func testSubmittingPhasePreventsDuplicateSubmission() async {
        let gate = IssueAttachmentGate()
        defer { gate.release() }
        let started = expectation(description: "attachment preparation started")
        let attachment = URL(fileURLWithPath: "/tmp/omniwm-diagnostics.log")
        var opened: [URL] = []
        let model = makeModel(
            engine: FakeIssueEngine(),
            prepareDiagnosticAttachment: { _ in
                started.fulfill()
                await gate.wait()
                return DiagnosticAttachmentResult(url: attachment, includedEvidence: false)
            },
            openURL: { opened.append($0) }
        )
        model.title = "Bug"
        model.actual = "Body"

        let firstSubmission = Task { @MainActor in await model.submit() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.phase, .submitting)

        let duplicateSubmission = Task { @MainActor in await model.submit() }
        await duplicateSubmission.value
        let preparationCount = gate.waitCount()
        XCTAssertEqual(preparationCount, 1)

        gate.release()
        await firstSubmission.value
        XCTAssertEqual(opened.count, 1)
    }

    func testSubmitUsesContentValidatedBeforeAttachmentPreparation() async throws {
        let gate = IssueAttachmentGate()
        defer { gate.release() }
        let started = expectation(description: "attachment preparation started")
        let attachment = URL(fileURLWithPath: "/tmp/omniwm-diagnostics.log")
        var opened: [URL] = []
        let model = makeModel(
            engine: FakeIssueEngine(),
            prepareDiagnosticAttachment: { _ in
                started.fulfill()
                await gate.wait()
                return DiagnosticAttachmentResult(url: attachment, includedEvidence: false)
            },
            openURL: { opened.append($0) }
        )
        model.title = "Original title"
        model.actual = "Original behavior"

        let submission = Task { @MainActor in await model.submit() }
        await fulfillment(of: [started], timeout: 2)
        model.title = ""
        model.actual = "Edited during submission"
        gate.release()
        await submission.value

        let openedURL = try XCTUnwrap(opened.first)
        let queryItems = try XCTUnwrap(URLComponents(url: openedURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(queryItems.first { $0.name == "title" }?.value, "Original title")
        let body = try XCTUnwrap(queryItems.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("Original behavior"))
        XCTAssertFalse(body.contains("Edited during submission"))
    }

    func testEvidenceSelectionIsSessionOnly() {
        var saved: IssueDraft?
        let crash = URL(fileURLWithPath: "/tmp/omniwm-crash.log")
        let model = ReportIssueViewModel(engine: FakeIssueEngine(), saveDraft: { saved = $0 })
        model.title = "Bug"
        model.actual = "Body"
        model.selectEvidence(.crash(crash))

        let restored = ReportIssueViewModel(engine: FakeIssueEngine(), loadDraft: { saved })

        XCTAssertEqual(model.selectedEvidence, .crash(crash))
        XCTAssertNil(restored.selectedEvidence)
    }

    func testRestoredDraftRequiresExplicitEvidenceReselection() {
        let crash = URL(fileURLWithPath: "/tmp/omniwm-crash.log")
        let draft = IssueDraft(
            title: "Bug",
            actual: "Body",
            expected: "",
            repro: "",
            affectedApps: "",
            category: IssueCategory.unspecified.rawValue,
            layout: LayoutType.niri.rawValue,
            regression: IssueRegression.unknown.rawValue,
            regressionVersion: "",
            polishedBody: ""
        )
        let model = ReportIssueViewModel(engine: FakeIssueEngine(), loadDraft: { draft })

        model.updateAvailableEvidence([.crash(crash)])

        XCTAssertTrue(model.restoredDraft)
        XCTAssertEqual(model.availableEvidence, [.crash(crash)])
        XCTAssertNil(model.selectedEvidence)
    }

    func testFreshCrashPrefillsAndSelectsOnlyWithoutDraftContent() {
        let crash = URL(fileURLWithPath: "/tmp/omniwm-crash-fresh.log")
        let report = FatalCapture.PendingCrashReport(
            url: crash,
            reason: "unexpected signal",
            detectedAt: Date(timeIntervalSince1970: 1)
        )
        let fresh = makeModel(engine: FakeIssueEngine())
        fresh.updateAvailableEvidence([.crash(crash)])

        fresh.applyFreshCrashPrefill(report)

        XCTAssertEqual(fresh.title, "Crash: unexpected signal")
        XCTAssertEqual(fresh.category, .crash)
        XCTAssertTrue(fresh.actual.contains("omniwm-crash-fresh.log"))
        XCTAssertTrue(fresh.actual.contains("unexpected signal"))
        XCTAssertEqual(fresh.selectedEvidence, .crash(crash))

        let draft = IssueDraft(
            title: "Existing report",
            actual: "Existing details",
            expected: "",
            repro: "",
            affectedApps: "",
            category: IssueCategory.placement.rawValue,
            layout: LayoutType.niri.rawValue,
            regression: IssueRegression.unknown.rawValue,
            regressionVersion: "",
            polishedBody: ""
        )
        let restored = ReportIssueViewModel(engine: FakeIssueEngine(), loadDraft: { draft })
        restored.updateAvailableEvidence([.crash(crash)])

        restored.applyFreshCrashPrefill(report)

        XCTAssertEqual(restored.title, "Existing report")
        XCTAssertEqual(restored.actual, "Existing details")
        XCTAssertEqual(restored.category, .placement)
        XCTAssertNil(restored.selectedEvidence)
    }

    func testRecordingStartClearsOnlySelectedTrace() {
        let crash = IssueDiagnosticEvidence.crash(URL(fileURLWithPath: "/tmp/omniwm-crash.log"))
        let trace = IssueDiagnosticEvidence.trace(URL(fileURLWithPath: "/tmp/omniwm-trace.log"))
        let model = makeModel(engine: FakeIssueEngine())
        model.updateAvailableEvidence([crash, trace])
        model.selectEvidence(crash)

        model.recordingStarted()

        XCTAssertEqual(model.selectedEvidence, crash)
        XCTAssertEqual(model.availableEvidence, [crash])

        model.updateAvailableEvidence([crash, trace])
        model.selectEvidence(trace)
        model.recordingStarted()

        XCTAssertNil(model.selectedEvidence)
        XCTAssertEqual(model.availableEvidence, [crash])
    }

    func testFinishedRecordingReplacesTraceChoiceAndSelectsIt() {
        let crash = IssueDiagnosticEvidence.crash(URL(fileURLWithPath: "/tmp/omniwm-crash.log"))
        let oldTrace = IssueDiagnosticEvidence.trace(URL(fileURLWithPath: "/tmp/omniwm-trace-old.log"))
        let newTraceURL = URL(fileURLWithPath: "/tmp/omniwm-trace-new.log")
        let model = makeModel(engine: FakeIssueEngine())
        model.updateAvailableEvidence([crash, oldTrace])

        model.recordingFinished(traceURL: newTraceURL)

        XCTAssertEqual(model.availableEvidence, [crash, .trace(newTraceURL)])
        XCTAssertEqual(model.selectedEvidence, .trace(newTraceURL))
    }

    func testPerformanceArtifactIsNotAcceptedAsTraceEvidence() {
        let oldTrace = IssueDiagnosticEvidence.trace(URL(fileURLWithPath: "/tmp/omniwm-trace-old.log"))
        let model = makeModel(engine: FakeIssueEngine())
        model.updateAvailableEvidence([oldTrace])
        model.selectEvidence(oldTrace)

        model.recordingFinished(artifact: TraceCaptureArtifact(
            profile: .performance,
            url: URL(fileURLWithPath: "/tmp/omniwm-performance.log"),
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        ))

        XCTAssertEqual(model.availableEvidence, [oldTrace])
        XCTAssertEqual(model.selectedEvidence, oldTrace)
    }

    func testEvidenceCatalogRefreshRetainsMissingSelectionForSubmissionWarning() async {
        let selectedTrace = IssueDiagnosticEvidence.trace(URL(fileURLWithPath: "/tmp/missing-trace.log"))
        let attachment = URL(fileURLWithPath: "/tmp/omniwm-diagnostics.log")
        let model = makeModel(
            engine: FakeIssueEngine(),
            prepareDiagnosticAttachment: { _ in
                DiagnosticAttachmentResult(url: attachment, includedEvidence: false)
            }
        )
        model.title = "Bug"
        model.actual = "Body"
        model.selectEvidence(selectedTrace)

        model.updateAvailableEvidence([])
        await model.submit()

        XCTAssertEqual(model.selectedEvidence, selectedTrace)
        XCTAssertNotNil(model.lastAttachmentWarning)
    }

    private func makeModel(
        engine: any IssueRewriting,
        urlBuilder: GitHubIssueURLBuilder = GitHubIssueURLBuilder(appVersion: "1.0", osVersion: "26.0"),
        prepareDiagnosticAttachment: @MainActor @escaping (IssueDiagnosticEvidence?) async throws
            -> DiagnosticAttachmentResult = { _ in
                throw IssueReportError.unavailable
            },
        hotkeyContextProvider: @MainActor @escaping (String) -> String = { _ in "" },
        revealInFinder: @MainActor @escaping (URL) -> Void = { _ in },
        openURL: @MainActor @escaping (URL) -> Void = { _ in },
        copyToClipboard: @MainActor @escaping (String) -> Void = { _ in }
    ) -> ReportIssueViewModel {
        ReportIssueViewModel(
            engine: engine,
            urlBuilder: urlBuilder,
            prepareDiagnosticAttachment: prepareDiagnosticAttachment,
            hotkeyContextProvider: hotkeyContextProvider,
            revealInFinder: revealInFinder,
            openURL: openURL,
            copyToClipboard: copyToClipboard
        )
    }
}

@MainActor
private final class FakeIssueEngine: IssueRewriting {
    let availability: IssueAIAvailability
    let rewriteResult: Result<RewrittenIssue, Error>
    private(set) var lastHotkeyContext: String?

    init(
        availability: IssueAIAvailability = .available,
        rewriteResult: Result<RewrittenIssue, Error> = .success(RewrittenIssue(title: "title", body: "body"))
    ) {
        self.availability = availability
        self.rewriteResult = rewriteResult
    }

    func rewrite(_ freeform: String, hotkeyContext: String) async throws -> RewrittenIssue {
        lastHotkeyContext = hotkeyContext
        return try rewriteResult.get()
    }
}

@MainActor
private final class IssueAttachmentGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var count = 0
    private var released = false

    func wait() async {
        count += 1
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitCount() -> Int {
        count
    }

    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll(keepingCapacity: true)
    }
}
