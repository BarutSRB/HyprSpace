// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ReportIssueViewModel {
    enum Phase: Equatable {
        case editing
        case rewriting
        case submitting
        case submitted(SubmissionOutcome)
    }

    enum SubmissionOutcome: Equatable {
        case openedBrowser
        case copiedToClipboard
    }

    var title = "" {
        didSet { handleEdit(oldValue, title) }
    }

    var actual = "" {
        didSet { handleEdit(oldValue, actual) }
    }

    var expected = "" {
        didSet { handleEdit(oldValue, expected) }
    }

    var repro = "" {
        didSet { handleEdit(oldValue, repro) }
    }

    var affectedApps = "" {
        didSet { handleEdit(oldValue, affectedApps) }
    }

    var regressionVersion = "" {
        didSet { handleEdit(oldValue, regressionVersion) }
    }

    var category: IssueCategory = .unspecified {
        didSet { handleSelection(oldValue != category) }
    }

    var layout: LayoutType = .niri {
        didSet { handleSelection(oldValue != layout) }
    }

    var regression: IssueRegression = .unknown {
        didSet { handleSelection(oldValue != regression) }
    }

    private(set) var phase: Phase = .editing
    private(set) var suggestion: RewrittenIssue?
    private(set) var polishedBody: String?
    private(set) var errorMessage: String?
    private(set) var lastAttachment: URL?
    private(set) var lastAttachmentError: String?
    private(set) var lastAttachmentWarning: String?
    private(set) var selectedEvidence: IssueDiagnosticEvidence?
    private(set) var availableEvidence: [IssueDiagnosticEvidence] = []

    let availability: IssueAIAvailability
    let restoredDraft: Bool

    private let engine: (any IssueRewriting)?
    private let urlBuilder: GitHubIssueURLBuilder
    private let prepareDiagnosticAttachment: @MainActor (IssueDiagnosticEvidence?) async throws
        -> DiagnosticAttachmentResult
    private let hotkeyContextProvider: @MainActor (String) -> String
    private let revealInFinder: @MainActor (URL) -> Void
    private let openURL: @MainActor (URL) -> Void
    private let copyToClipboard: @MainActor (String) -> Void
    private let saveDraft: @MainActor (IssueDraft?) -> Void
    private var isRestoring = false

    init(
        engine: (any IssueRewriting)? = nil,
        defaultLayout: LayoutType = .niri,
        urlBuilder: GitHubIssueURLBuilder = GitHubIssueURLBuilder(),
        prepareDiagnosticAttachment: @MainActor @escaping (IssueDiagnosticEvidence?) async throws
            -> DiagnosticAttachmentResult = { _ in
                throw IssueReportError.unavailable
            },
        hotkeyContextProvider: @MainActor @escaping (String) -> String = { _ in "" },
        revealInFinder: @MainActor @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        openURL: @MainActor @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        copyToClipboard: @MainActor @escaping (String) -> Void = { string in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        },
        loadDraft: @MainActor () -> IssueDraft? = { nil },
        saveDraft: @MainActor @escaping (IssueDraft?) -> Void = { _ in }
    ) {
        let engine = engine ?? IssueRewritingFactory.make()
        let draft = loadDraft()
        self.engine = engine
        availability = engine?.availability ?? .unsupported
        restoredDraft = draft != nil
        self.urlBuilder = urlBuilder
        self.prepareDiagnosticAttachment = prepareDiagnosticAttachment
        self.hotkeyContextProvider = hotkeyContextProvider
        self.revealInFinder = revealInFinder
        self.openURL = openURL
        self.copyToClipboard = copyToClipboard
        self.saveDraft = saveDraft
        restore(draft: draft, defaultLayout: defaultLayout.normalizedForReport)
    }

    var canRequestRewrite: Bool {
        phase == .editing && availability == .available && !isTitleEmpty && !isActualEmpty
    }

    var canSubmit: Bool {
        phase == .editing && !isTitleEmpty && !isActualEmpty
    }

    var hasDraftContent: Bool {
        [title, actual, expected, repro, affectedApps, regressionVersion].contains { !$0.isEmpty }
            || category != .unspecified
            || regression != .unknown
            || polishedBody?.isEmpty == false
    }

    var submitRequirementHint: String? {
        guard phase == .editing, !canSubmit else { return nil }
        var missing: [String] = []
        if isTitleEmpty { missing.append("a title") }
        if isActualEmpty { missing.append("what happened") }
        return missing.isEmpty ? nil : "Add \(missing.joined(separator: " and ")) to submit."
    }

    var submissionBody: String {
        if let polishedBody { return polishedBody }
        return IssueTemplate.compose(
            IssueComposition(
                category: category,
                actual: actual,
                expected: expected,
                repro: repro,
                affectedApps: affectedApps,
                layout: layout,
                regression: regression,
                regressionVersion: regressionVersion
            )
        )
    }

    func requestRewrite() async {
        guard canRequestRewrite, let engine else { return }
        phase = .rewriting
        errorMessage = nil
        do {
            let prompt = "Title: \(title)\n\nMessage: \(submissionBody)"
            suggestion = try await engine.rewrite(prompt, hotkeyContext: hotkeyContextProvider(prompt))
        } catch {
            errorMessage = error.localizedDescription
        }
        phase = .editing
    }

    func applyRewrite() {
        guard let suggestion else { return }
        isRestoring = true
        title = suggestion.title
        isRestoring = false
        polishedBody = suggestion.body
        self.suggestion = nil
        persistDraft()
    }

    func dismissSuggestion() {
        suggestion = nil
    }

    func submit() async {
        guard canSubmit else { return }
        let evidence = selectedEvidence
        let submittedTitle = title
        let submittedBody = submissionBody
        phase = .submitting
        lastAttachment = nil
        lastAttachmentError = nil
        lastAttachmentWarning = nil
        do {
            let result = try await prepareDiagnosticAttachment(evidence)
            guard phase == .submitting else { return }
            lastAttachment = result.url
            if evidence != nil, !result.includedEvidence {
                lastAttachmentWarning = "The selected evidence was unavailable, so the log contains a fresh snapshot only."
            }
            revealInFinder(result.url)
        } catch {
            guard phase == .submitting else { return }
            lastAttachmentError = error.localizedDescription
        }
        switch urlBuilder.submission(title: submittedTitle, body: submittedBody) {
        case let .url(url):
            openURL(url)
            phase = .submitted(.openedBrowser)
        case let .clipboard(markdown, fallbackURL):
            copyToClipboard(markdown)
            openURL(fallbackURL)
            phase = .submitted(.copiedToClipboard)
        }
        saveDraft(nil)
    }

    func selectEvidence(_ evidence: IssueDiagnosticEvidence) {
        selectedEvidence = evidence
        lastAttachmentWarning = nil
    }

    func updateAvailableEvidence(_ evidence: [IssueDiagnosticEvidence]) {
        availableEvidence = evidence
    }

    func applyFreshCrashPrefill(_ report: FatalCapture.PendingCrashReport) {
        let evidence = IssueDiagnosticEvidence.crash(report.url)
        guard !restoredDraft,
              !hasDraftContent,
              availableEvidence.contains(evidence)
        else { return }
        title = "Crash: \(report.reason)"
        category = .crash
        actual = "OmniWM recovered from a crash (log: \(report.url.lastPathComponent)).\n\n"
            + "Reason: \(report.reason)"
        selectEvidence(evidence)
    }

    func recordingStarted() {
        availableEvidence.removeAll {
            if case .trace = $0 { return true }
            return false
        }
        if case .trace? = selectedEvidence {
            useFreshSnapshot()
        }
    }

    func recordingFinished(traceURL: URL) {
        let trace = IssueDiagnosticEvidence.trace(traceURL)
        availableEvidence.removeAll {
            if case .trace = $0 { return true }
            return false
        }
        availableEvidence.append(trace)
        selectEvidence(trace)
    }

    func recordingFinished(artifact: TraceCaptureArtifact) {
        guard artifact.profile == .problem else { return }
        recordingFinished(traceURL: artifact.url)
    }

    func useFreshSnapshot() {
        selectedEvidence = nil
        lastAttachmentWarning = nil
    }

    func revealLastAttachment() {
        guard let lastAttachment else { return }
        revealInFinder(lastAttachment)
    }

    func startOver() {
        isRestoring = true
        title = ""
        actual = ""
        expected = ""
        repro = ""
        affectedApps = ""
        regressionVersion = ""
        category = .unspecified
        regression = .unknown
        isRestoring = false
        suggestion = nil
        polishedBody = nil
        errorMessage = nil
        lastAttachment = nil
        lastAttachmentError = nil
        lastAttachmentWarning = nil
        selectedEvidence = nil
        phase = .editing
        saveDraft(nil)
    }

    private func restore(draft: IssueDraft?, defaultLayout: LayoutType) {
        isRestoring = true
        defer { isRestoring = false }
        guard let draft else {
            layout = defaultLayout
            return
        }
        title = draft.title
        actual = draft.actual
        expected = draft.expected
        repro = draft.repro
        affectedApps = draft.affectedApps
        regressionVersion = draft.regressionVersion
        category = IssueCategory(rawValue: draft.category) ?? .unspecified
        layout = LayoutType(rawValue: draft.layout)?.normalizedForReport ?? defaultLayout
        regression = IssueRegression(rawValue: draft.regression) ?? .unknown
        polishedBody = draft.polishedBody.isEmpty ? nil : draft.polishedBody
    }

    private func handleEdit(_ oldValue: String, _ newValue: String) {
        guard oldValue != newValue else { return }
        invalidateSuggestion()
        persistDraft()
    }

    private func handleSelection(_ changed: Bool) {
        guard changed else { return }
        invalidateSuggestion()
        persistDraft()
    }

    private func invalidateSuggestion() {
        guard !isRestoring else { return }
        suggestion = nil
        polishedBody = nil
    }

    private func persistDraft() {
        guard !isRestoring else { return }
        saveDraft(hasDraftContent ? currentDraft : nil)
    }

    private var currentDraft: IssueDraft {
        IssueDraft(
            title: title,
            actual: actual,
            expected: expected,
            repro: repro,
            affectedApps: affectedApps,
            category: category.rawValue,
            layout: layout.rawValue,
            regression: regression.rawValue,
            regressionVersion: regressionVersion,
            polishedBody: polishedBody ?? ""
        )
    }

    private var isTitleEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isActualEmpty: Bool {
        actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
