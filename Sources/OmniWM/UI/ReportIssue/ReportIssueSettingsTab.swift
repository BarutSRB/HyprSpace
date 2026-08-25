// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct ReportIssueSettingsTab: View {
    @State private var model: ReportIssueViewModel
    @State private var showWalkthrough = false
    @State private var showDiscardConfirm = false
    @State private var traceStatus: DiagnosticsActionStatus = .idle
    @State private var didApplyCrashPrefill = false
    @State private var evidenceRefreshGeneration = 0
    @FocusState private var titleFocused: Bool

    let controller: WMController
    private let crashPrefill: FatalCapture.PendingCrashReport?

    init(controller: WMController) {
        self.controller = controller
        let pendingCrashReport = controller.pendingCrashReport
        crashPrefill = pendingCrashReport
        let settings = controller.settings
        _model = State(initialValue: ReportIssueViewModel(
            defaultLayout: controller.activeWorkspace().map { settings.layoutType(for: $0.name) }
                ?? settings.defaultLayoutType,
            prepareDiagnosticAttachment: {
                try await controller.prepareDiagnosticAttachment(evidence: $0)
            },
            hotkeyContextProvider: { text in
                IssueHotkeyContext.resolve(text: text, bindings: settings.hotkeyBindings)
            },
            loadDraft: { settings.issueDraft },
            saveDraft: { settings.issueDraft = $0 }
        ))
    }

    var body: some View {
        Form {
            switch model.phase {
            case let .submitted(outcome):
                submittedSection(outcome)
            default:
                contentSections
                    .disabled(model.phase == .submitting)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: handleAppear)
        .task(id: controller.traceCaptureStatus.lastArtifact) { await refreshAvailableEvidence() }
    }

    @ViewBuilder
    private var contentSections: some View {
        if showWalkthrough {
            IssueWalkthroughCard(onDismiss: dismissWalkthrough)
        }
        traceSection
        issueSection
        contextSection
        rewriteSection
        submitSection
    }

    @ViewBuilder
    private var issueSection: some View {
        Section("Issue") {
            TextField("Title", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
            Picker("Category", selection: $model.category) {
                ForEach(IssueCategory.allCases) { category in
                    Text(category.displayName).tag(category)
                }
            }
            labeledEditor("What happened", text: $model.actual)
            labeledEditor("What did you expect? (optional)", text: $model.expected, minHeight: 70)
            labeledEditor("Steps to reproduce (optional)", text: $model.repro, minHeight: 70)
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var contextSection: some View {
        Section("Context (optional)") {
            TextField("Affected app(s)", text: $model.affectedApps)
                .textFieldStyle(.roundedBorder)
            Picker("Active layout", selection: $model.layout) {
                ForEach(LayoutType.reportChoices) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            Picker("Worked in an earlier version?", selection: $model.regression) {
                ForEach(IssueRegression.allCases) { regression in
                    Text(regression.displayName).tag(regression)
                }
            }
            if model.regression == .yes {
                TextField("Last working version/build", text: $model.regressionVersion)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsCaption(
                "OmniWM version, macOS, your settings, and explicitly selected evidence are included "
                    + "in the diagnostic log — no need to type them."
            )
        }
    }

    @ViewBuilder
    private var rewriteSection: some View {
        if model.availability == .available {
            Section {
                HStack {
                    Button("Rewrite & Format with AI") {
                        Task { await model.requestRewrite() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canRequestRewrite)
                    if model.phase == .rewriting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let suggestion = model.suggestion {
                    suggestionPreview(suggestion)
                }
                SettingsCaption(
                    "On-device AI polishes your report into a clear, well-structured issue. "
                        + "Review it, then apply. Nothing leaves your Mac."
                )
            }
        }
    }

    @ViewBuilder
    private func suggestionPreview(_ suggestion: RewrittenIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested rewrite")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(suggestion.title)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
            Text(suggestion.body)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Apply") { model.applyRewrite() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { model.dismissSuggestion() }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var submitSection: some View {
        Section {
            SettingsCaption(
                "A fresh diagnostic snapshot is always prepared. Explicitly selected crash or trace evidence "
                    + "is appended to that same .log."
            )
            SettingsCaption(
                "Diagnostic logs may include OmniWM settings, app and window titles, and title-based rule "
                    + "matchers. Review the .log in Finder before attaching it to a public GitHub issue."
            )
            HStack {
                Button("Submit to GitHub") { Task { await model.submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSubmit || controller.traceCaptureStatus.phase != .idle)
                if model.phase == .submitting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing diagnostics…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if controller.traceCaptureStatus.phase != .idle {
                SettingsCaption(
                    controller.traceCaptureStatus.profile == .problem
                        ? "Stop, Save & Include the recording before submitting so this trace is attached."
                        : "Finish the performance capture before submitting. Performance artifacts are not attached "
                        + "as problem traces."
                )
            }
            if let hint = model.submitRequirementHint {
                SettingsCaption(hint)
            }
            SettingsCaption(
                "Opens a pre-filled new-issue page in your browser; you review and post it with your own "
                    + "GitHub account. OmniWM never sees your GitHub login."
            )
            draftFooter
        }
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) { model.startOver() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var draftFooter: some View {
        HStack {
            if model.hasDraftContent {
                Label("Draft saved", systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !showWalkthrough {
                Button("Show guide") { showWalkthrough = true }
                    .controlSize(.small)
            }
            if model.hasDraftContent {
                Button("Discard Draft", role: .destructive) { showDiscardConfirm = true }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func submittedSection(_ outcome: ReportIssueViewModel.SubmissionOutcome) -> some View {
        Section {
            switch outcome {
            case .openedBrowser:
                Label(
                    "Opened GitHub in your browser. Review it, then click \"Submit new issue\".",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case .copiedToClipboard:
                Label(
                    "The issue was too long for a link, so it was copied to your clipboard. "
                        + "Paste it into the GitHub page that just opened.",
                    systemImage: "doc.on.clipboard"
                )
                .foregroundStyle(.secondary)
            }
            attachmentStatus
            Button("Report another issue") { model.startOver() }
        }
    }

    @ViewBuilder
    private var attachmentStatus: some View {
        if let url = model.lastAttachment {
            Label(
                "Diagnostic log revealed in Finder — drag \(url.lastPathComponent) into the issue to attach it.",
                systemImage: "paperclip"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Reveal Log Again") { model.revealLastAttachment() }
                .controlSize(.small)
        }
        if let attachmentError = model.lastAttachmentError {
            Label(
                "Couldn't prepare the diagnostic log: \(attachmentError). Your issue still opened.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if let attachmentWarning = model.lastAttachmentWarning {
            Label(attachmentWarning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func labeledEditor(_ label: String, text: Binding<String>, minHeight: CGFloat = 90) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
            TextEditor(text: text)
                .frame(minHeight: minHeight)
                .font(.body)
                .accessibilityLabel(label)
        }
    }
}

extension ReportIssueSettingsTab {
    @ViewBuilder
    private var traceSection: some View {
        Section("Diagnostics recording") {
            switch controller.traceCaptureStatus.phase {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        controller.traceCaptureStatus.profile == .problem
                            ? "Starting diagnostics…"
                            : "A performance capture is starting."
                    )
                }
            case .recording:
                if controller.traceCaptureStatus.profile == .problem {
                    recordingLabel
                    Button("Stop, Save & Include Recording") { stopRecording() }
                    SettingsCaption(
                        "Stop, save, and include before submitting — an in-progress recording isn't ready to attach."
                    )
                } else {
                    Label("Performance capture in progress", systemImage: "gauge.with.dots.needle.67percent")
                    SettingsCaption("Performance captures are not diagnostic trace attachments.")
                }
            case .finalizing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        controller.traceCaptureStatus.profile == .problem
                            ? "Finalizing diagnostics…"
                            : "Finalizing performance capture…"
                    )
                }
            case .idle:
                Label("Fresh diagnostic snapshot (always included)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                evidencePicker
                if let selected = model.selectedEvidence,
                   !model.availableEvidence.contains(selected)
                {
                    SettingsCaption(
                        "The selected file is no longer available. Submission will continue with the fresh "
                            + "snapshot unless you select different evidence."
                    )
                }
                Button(recordButtonTitle) { startRecording() }
                    .buttonStyle(.borderedProminent)
                SettingsCaption(
                    "Reproduce the bug while recording, then come back — your draft is saved. "
                        + "Crash and trace evidence is included only when you explicitly select it."
                )
            }
            statusLabel(traceStatus)
        }
    }

    @ViewBuilder
    private var evidencePicker: some View {
        Picker("Additional evidence", selection: evidenceSelection) {
            Text("No additional evidence")
                .tag(IssueDiagnosticEvidence?.none)
            ForEach(model.availableEvidence, id: \.self) { evidence in
                Text(evidenceLabel(evidence))
                    .tag(Optional(evidence))
            }
            if let selected = model.selectedEvidence,
               !model.availableEvidence.contains(selected)
            {
                Text("Unavailable: \(selected.url.lastPathComponent)")
                    .tag(Optional(selected))
            }
        }
        .pickerStyle(.radioGroup)
    }

    private var evidenceSelection: Binding<IssueDiagnosticEvidence?> {
        Binding {
            model.selectedEvidence
        } set: { evidence in
            if let evidence {
                model.selectEvidence(evidence)
            } else {
                model.useFreshSnapshot()
            }
        }
    }

    private func evidenceLabel(_ evidence: IssueDiagnosticEvidence) -> String {
        switch evidence {
        case let .crash(url):
            "Crash: \(url.lastPathComponent)"
        case let .trace(url):
            "Saved trace: \(url.lastPathComponent)"
        }
    }

    private var recordButtonTitle: String {
        switch model.selectedEvidence {
        case .some(.crash):
            "Record a Trace"
        case .some(.trace):
            "Record Again"
        case nil:
            model.availableEvidence.contains { evidence in
                if case .trace = evidence { return true }
                return false
            } ? "Record Again" : "Record a Trace"
        }
    }

    @ViewBuilder
    private var recordingLabel: some View {
        if let startedAt = controller.traceCaptureStatus.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = elapsed(since: startedAt, now: context.date)
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    Text("Recording \(text)")
                        .font(.callout.monospacedDigit())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording in progress")
                .accessibilityValue(text)
            }
        }
    }

    private func handleAppear() {
        showWalkthrough = showWalkthrough || !controller.settings.hasSeenIssueWalkthrough
        titleFocused = model.title.isEmpty
    }

    private func applyCrashPrefillIfNeeded() {
        guard !didApplyCrashPrefill else { return }
        didApplyCrashPrefill = true
        guard let crashPrefill else { return }
        model.applyFreshCrashPrefill(crashPrefill)
    }

    private func refreshAvailableEvidence() async {
        evidenceRefreshGeneration &+= 1
        let generation = evidenceRefreshGeneration
        let directory = controller.diagnosticsDirectory
        let pendingCrashURL = controller.pendingCrashReport?.url
        let evidence = await Task.detached(priority: .utility) {
            DiagnosticsFileScanner.issueEvidence(
                in: directory,
                pendingCrashURL: pendingCrashURL
            )
        }.value
        guard !Task.isCancelled, generation == evidenceRefreshGeneration else { return }
        model.updateAvailableEvidence(evidence)
        applyCrashPrefillIfNeeded()
    }

    private func dismissWalkthrough() {
        controller.settings.hasSeenIssueWalkthrough = true
        showWalkthrough = false
    }

    private func startRecording() {
        Task {
            let outcome = await controller.toggleTraceCaptureForUI(desiredState: .active)
            switch outcome {
            case .started:
                model.recordingStarted()
                await refreshAvailableEvidence()
            case .noChange,
                 .stopped,
                 .writeFailed:
                break
            }
            traceStatus = diagnosticsRecordingStartStatus(for: outcome)
        }
    }

    private func stopRecording() {
        guard controller.traceCaptureStatus.phase == .recording,
              controller.traceCaptureStatus.profile == .problem
        else {
            traceStatus = .failure("No diagnostic recording is running")
            return
        }
        Task {
            switch await controller.toggleTraceCaptureForUI(desiredState: .inactive) {
            case let .stopped(artifact):
                guard artifact.profile == .problem else {
                    traceStatus = .failure("The active capture was not a diagnostic recording")
                    return
                }
                traceStatus = .idle
                model.recordingFinished(artifact: artifact)
                await refreshAvailableEvidence()
                NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
            case let .writeFailed(reason):
                traceStatus = .failure("Failed to write the recording: \(reason)")
            case .noChange:
                traceStatus = .failure("No recording is running")
            case .started:
                traceStatus = .failure("Unexpected recording state")
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: DiagnosticsActionStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
