// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import SwiftUI

enum DiagnosticsActionStatus: Equatable {
    case idle
    case success(String)
    case failure(String)
}

func diagnosticsRecordingStartStatus(for outcome: TraceCaptureOutcome) -> DiagnosticsActionStatus {
    switch outcome {
    case .started:
        .success("Recording started")
    case .noChange:
        .failure("A recording is already running")
    case .stopped:
        .failure("Unexpected recording state")
    case let .writeFailed(reason):
        .failure(reason)
    }
}

func privateAPIProbePresentationStatus(for report: PrivateAPIProbeReport) -> DiagnosticsActionStatus {
    let failures = report.selfTests.filter { $0.outcome == .failed }.count
    let checks = "\(report.selfTests.count) checks, \(failures) failures"
    guard let foreign = report.foreign else {
        let prefix = failures == 0 ? "Inconclusive: " : ""
        return .failure("\(prefix)\(checks) · no unmanaged foreign window probed")
    }
    let foreignResult = "foreign transaction move=\(foreign.skylightMoved ? "yes" : "no")"
        + ", restored=\(foreign.restored ? "yes" : "no")"
    guard failures == 0 else {
        return .failure("\(checks) · \(foreignResult)")
    }
    switch foreign.outcome {
    case .works where foreign.skylightMoved && foreign.restored:
        return .success("\(checks) · \(foreignResult)")
    case .inconclusive:
        return .failure("Inconclusive: \(checks) · \(foreignResult)")
    case .works,
         .failed:
        return .failure("\(checks) · \(foreignResult)")
    }
}

struct DiagnosticsSettingsTab: View {
    @Bindable var controller: WMController
    let navigation: SettingsNavigationModel

    @State private var traceStatus: DiagnosticsActionStatus = .idle
    @State private var probeStatus: DiagnosticsActionStatus = .idle
    @State private var isPrivateAPIProbeRunning = false
    @State private var recentFiles: [DiagnosticsFile] = []
    @State private var reloadToken = 0

    private var directory: URL {
        OmniWMStoragePaths.live.diagnosticsDirectory
    }

    var body: some View {
        Form {
            crashBannerSection
            healthSection
            privateAPICapabilitySection
            recordingSection
            performanceRecordingSection
            savedDiagnosticsSection
        }
        .formStyle(.grouped)
        .task(id: reloadToken) {
            let directory = directory
            recentFiles = await Task.detached { DiagnosticsFileScanner.scan(directory) }.value
            controller.refreshDiagnosticsIssues()
        }
        .onChange(of: controller.traceCaptureStatus.lastArtifact) { _, artifact in
            guard let artifact else { return }
            NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
            traceStatus = .success(
                artifact.profile == .performance
                    ? "Performance capture saved \(artifact.url.lastPathComponent)"
                    : "Recording saved \(artifact.url.lastPathComponent)"
            )
            reloadToken += 1
        }
    }

    @ViewBuilder
    private var crashBannerSection: some View {
        if let crash = controller.pendingCrashReport {
            Section {
                LabeledContent {
                    Button("Report Crash…") {
                        navigation.section = .reportIssue
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } label: {
                    Label("OmniWM recovered from a crash", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(crash.reason)
                    .font(.callout)
                SettingsCaption("Report it to open a pre-filled issue with the crash details.")
                HStack(spacing: 8) {
                    Button("Copy File") {
                        copyFile(crash.url)
                    }
                    .accessibilityLabel("Copy crash log file")
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([crash.url])
                    }
                    .accessibilityLabel("Reveal crash log in Finder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        Section("Health") {
            if controller.diagnosticsIssues.isEmpty {
                Label("No issues detected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(controller.diagnosticsIssues) { issue in
                    issueRow(issue)
                }
            }
        }
    }

    @ViewBuilder
    private func issueRow(_ issue: DiagnosticsIssue) -> some View {
        let isCritical = issue.severity == .critical
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 8) {
                    if let urlString = issue.systemSettingsURLString {
                        Button("Open Settings") {
                            openSystemSettings(urlString)
                        }
                        .accessibilityLabel("Open System Settings for \(issue.title)")
                    }
                    if issue.revealsConfigFolder {
                        Button("Reveal Config Folder") {
                            revealConfigFolder()
                        }
                        .accessibilityLabel("Reveal config folder for \(issue.title)")
                    }
                }
                .controlSize(.small)
            } label: {
                Label(issue.title, systemImage: isCritical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isCritical ? .red : .orange)
            }
            Text(issue.message)
                .font(.callout)
            SettingsCaption(issue.remediation)
        }
    }

    @ViewBuilder
    private var privateAPICapabilitySection: some View {
        Section("Private-API Capability") {
            Button("Run Private-API Probe") {
                runPrivateAPIProbe()
            }
            .disabled(isPrivateAPIProbeRunning)
            statusLabel(probeStatus)
            SettingsCaption(
                "On-demand check of every private window-server API on this Mac, confirming each actually works. "
                    + "It briefly nudges one unmanaged open window a few pixels and restores its verified starting "
                    + "position, so you may see a window jump for an instant. The full result is written "
                    + "into the Private API Capability section of your next diagnostics report."
            )
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        Section("Record a Problem") {
            switch controller.traceCaptureStatus.phase {
            case .idle:
                Button("Start Recording") {
                    startRecording()
                }
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
                    recordingProgressLabel
                    Button("Stop & Save Recording") {
                        stopRecording()
                    }
                } else {
                    Text("A performance capture is running.")
                        .foregroundStyle(.secondary)
                }
            case .finalizing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finalizing diagnostics…")
                }
            }
            statusLabel(traceStatus)
            SettingsCaption(
                "Start recording, reproduce one problem, then stop and attach the saved trace log. "
                    + "The app and window evidence is captured automatically. This detailed recording changes runtime "
                    + "work and must not be used for energy comparisons."
            )
        }
    }

    @ViewBuilder
    private var performanceRecordingSection: some View {
        Section("Measure Performance") {
            switch controller.traceCaptureStatus.phase {
            case .idle:
                Button("Start Performance Capture") {
                    startPerformanceCapture()
                }
            case .starting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        controller.traceCaptureStatus.profile == .performance
                            ? "Starting performance capture…"
                            : "A detailed problem recording is starting."
                    )
                }
            case .recording:
                if controller.traceCaptureStatus.profile == .performance {
                    Label("Performance capture in progress", systemImage: "gauge.with.dots.needle.67percent")
                    Button("Stop & Save Performance Capture") {
                        stopPerformanceCapture()
                    }
                } else {
                    Text("A detailed problem recording is running.")
                        .foregroundStyle(.secondary)
                }
            case .finalizing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finalizing capture…")
                }
            }
            SettingsCaption(
                "Records aggregate operation counts, CPU energy, CPU time, wakeups and memory with one final write. "
                    + "It does not enable detailed event traces. Use Instruments or powermetrics separately to measure "
                    + "WindowServer and GPU energy."
            )
        }
    }

    @ViewBuilder
    private var recordingProgressLabel: some View {
        if let startedAt = controller.traceCaptureStatus.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = elapsed(since: startedAt, now: context.date)
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    Text("Recording \(elapsed)")
                        .font(.callout.monospacedDigit())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording in progress")
                .accessibilityValue(elapsed)
            }
        }
    }

    @ViewBuilder
    private var savedDiagnosticsSection: some View {
        Section("Saved Diagnostics") {
            if recentFiles.isEmpty {
                Text("No diagnostics files yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentFiles.prefix(10)) { file in
                    savedDiagnosticRow(file)
                }
            }
            HStack {
                Button("Refresh") {
                    reloadToken += 1
                }
                Button("Reveal Folder") {
                    revealFolder()
                }
            }
        }
    }

    @ViewBuilder
    private func savedDiagnosticRow(_ file: DiagnosticsFile) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Copy Path") {
                    copyToPasteboard(file.url.path)
                }
                .accessibilityLabel("Copy path for \(file.name)")
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
                .accessibilityLabel("Reveal \(file.name) in Finder")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        } label: {
            Text(artifactType(file))
                .font(.callout)
            Text(file.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(byteCount(file.sizeBytes))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Copy Path") {
                copyToPasteboard(file.url.path)
            }
            Button("Copy File") {
                copyFile(file.url)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
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

    private func runPrivateAPIProbe() {
        guard !isPrivateAPIProbeRunning else { return }
        isPrivateAPIProbeRunning = true
        Task {
            defer { isPrivateAPIProbeRunning = false }
            let report = await controller.runPrivateAPIProbe()
            probeStatus = privateAPIProbePresentationStatus(for: report)
        }
    }

    private func startRecording() {
        Task {
            let outcome = await controller.toggleTraceCaptureForUI(desiredState: .active)
            traceStatus = diagnosticsRecordingStartStatus(for: outcome)
        }
    }

    private func stopRecording() {
        Task {
            switch await controller.toggleTraceCaptureForUI(desiredState: .inactive) {
            case .stopped:
                break
            case let .writeFailed(reason):
                traceStatus = .failure("Failed to write the recording: \(reason)")
            case .noChange:
                traceStatus = .failure("No recording is running")
            case .started:
                traceStatus = .failure("Unexpected recording state")
            }
        }
    }

    private func startPerformanceCapture() {
        Task {
            let outcome = await controller.toggleTraceCaptureForUI(
                desiredState: .active,
                profile: .performance
            )
            traceStatus = diagnosticsRecordingStartStatus(for: outcome)
        }
    }

    private func stopPerformanceCapture() {
        Task {
            switch await controller.toggleTraceCaptureForUI(
                desiredState: .inactive,
                profile: .performance
            ) {
            case .stopped:
                break
            case let .writeFailed(reason):
                traceStatus = .failure("Failed to write the performance capture: \(reason)")
            case .noChange:
                traceStatus = .failure("No performance capture is running")
            case .started:
                traceStatus = .failure("Unexpected capture state")
            }
        }
    }

    private func revealFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealConfigFolder() {
        let directory = SettingsFilePersistence.defaultDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func copyFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    private func artifactType(_ file: DiagnosticsFile) -> String {
        let name = file.name
        if name.hasPrefix("omniwm-trace-") {
            return name.hasSuffix(".partial.log") ? "Trace (incomplete)" : "Trace"
        }
        if name.hasPrefix("omniwm-performance-") {
            return "Performance"
        }
        if name.hasPrefix("omniwm-crash-") {
            return "Crash"
        }
        if name.hasPrefix("omniwm-diagnostics-") {
            return "Diagnostics"
        }
        return name
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
