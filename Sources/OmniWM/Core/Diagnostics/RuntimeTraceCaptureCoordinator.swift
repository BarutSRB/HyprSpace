// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Observation

enum TraceCaptureDesiredState {
    case active
    case inactive
    case toggle
}

enum TraceCapturePhase: Equatable {
    case idle
    case recording
    case finalizing
}

struct TraceCaptureSession: Sendable {
    let startedAt: Date
    let startReport: String
}

struct TraceCaptureArtifact: Equatable, Sendable {
    let url: URL
    let startedAt: Date
    let endedAt: Date
}

struct TraceCaptureStatus: Equatable {
    let phase: TraceCapturePhase
    let startedAt: Date?
    let lastArtifact: TraceCaptureArtifact?

    var isActive: Bool {
        phase != .idle
    }
}

enum TraceCaptureOutcome {
    case started
    case stopped(TraceCaptureArtifact)
    case noChange
    case writeFailed(String)
}

private final class TraceByteSink {
    private let handle: FileHandle
    private(set) var byteCount = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        byteCount += data.count
    }
}

private final class BoundedTraceWriter {
    private static let truncationData = Data("\n== Trace Data Truncated ==\nreason=byte_budget\n".utf8)

    private let sink: TraceByteSink
    private let contentLimit: Int
    private(set) var truncated = false
    private var failure: Error?

    init(sink: TraceByteSink, reservedTailBytes: Int) {
        self.sink = sink
        contentLimit = RuntimeTraceLimits.captureBytes - reservedTailBytes - Self.truncationData.count
    }

    func appendLine(_ line: String) -> Bool {
        guard failure == nil, !truncated else { return false }
        var data = Data(line.utf8)
        data.append(0x0A)
        guard sink.byteCount + data.count <= contentLimit else {
            truncated = true
            return false
        }
        do {
            try sink.write(data)
            return true
        } catch {
            failure = error
            return false
        }
    }

    func finish(tail: Data) throws {
        if let failure {
            throw failure
        }
        if truncated {
            try sink.write(Self.truncationData)
        }
        try sink.write(tail)
    }
}

private actor TraceCaptureFileWriter {
    private let diagnosticsDirectory: URL

    init(diagnosticsDirectory: URL) {
        self.diagnosticsDirectory = diagnosticsDirectory
    }

    func writeInitialPartial(
        session: TraceCaptureSession,
        recorders: [any RuntimeTraceRecording]
    ) throws -> URL {
        let url = try writePartial(session: session, recorders: recorders)
        DiagnosticsRetention.wipe(
            directory: diagnosticsDirectory,
            prefixes: ["omniwm-trace-"],
            except: [url]
        )
        return url
    }

    func writePartial(
        session: TraceCaptureSession,
        recorders: [any RuntimeTraceRecording]
    ) throws -> URL {
        let url = diagnosticsDirectory.appendingPathComponent(
            partialFilename(startedAt: session.startedAt),
            isDirectory: false
        )
        try writeAtomically(to: url) { sink in
            try writeCapture(
                to: sink,
                session: session,
                endedAt: nil,
                recorders: recorders,
                automaticEvidence: nil,
                endReport: nil
            )
        }
        return url
    }

    func writeFinal(
        session: TraceCaptureSession,
        endedAt: Date,
        recorders: [any RuntimeTraceRecording],
        automaticEvidence: String,
        endReport: String
    ) throws -> URL {
        let filename = "omniwm-trace-\(milliseconds(session.startedAt))-\(milliseconds(endedAt)).log"
        let url = diagnosticsDirectory.appendingPathComponent(filename, isDirectory: false)
        try writeAtomically(to: url) { sink in
            try writeCapture(
                to: sink,
                session: session,
                endedAt: endedAt,
                recorders: recorders,
                automaticEvidence: automaticEvidence,
                endReport: endReport
            )
        }
        try? FileManager.default.removeItem(
            at: diagnosticsDirectory.appendingPathComponent(
                partialFilename(startedAt: session.startedAt),
                isDirectory: false
            )
        )
        return url
    }

    private func writeCapture(
        to sink: TraceByteSink,
        session: TraceCaptureSession,
        endedAt: Date?,
        recorders: [any RuntimeTraceRecording],
        automaticEvidence: String?,
        endReport: String?
    ) throws {
        let tail = tailData(automaticEvidence: automaticEvidence, endReport: endReport)
        let writer = BoundedTraceWriter(sink: sink, reservedTailBytes: tail.count)
        let append: (String) -> Bool = { writer.appendLine($0) }

        _ = append("== OmniWM Trace Capture ==")
        _ = append("startedAt=\(session.startedAt.ISO8601Format())")
        _ = append(endedAt.map { "endedAt=\($0.ISO8601Format())" } ?? "status=in-progress (partial)")
        _ = append("")
        _ = append("== State At Start ==")
        _ = append(RuntimeTraceLimits.boundedString(session.startReport, maxBytes: RuntimeTraceLimits.stateReportBytes))
        _ = append("")
        _ = append("== Lifecycle Events (recent, always-on) ==")
        DiagnosticsEventRecorder.shared.forEachLifecycleLine(append)
        _ = append("")
        _ = append("== Verbose Window Events (capture window) ==")
        DiagnosticsEventRecorder.shared.forEachVerboseLine(append)
        for recorder in recorders {
            guard append(""), append("== \(recorder.sectionTitle) ==") else { break }
            recorder.forEachLine(append)
            if writer.truncated { break }
        }
        try writer.finish(tail: tail)
    }

    private func tailData(automaticEvidence: String?, endReport: String?) -> Data {
        var data = Data()
        func append(_ string: String) {
            data.append(contentsOf: string.utf8)
        }
        if let automaticEvidence {
            append("\n== Automatic AX Evidence ==\n")
            append(
                RuntimeTraceLimits.boundedString(
                    automaticEvidence,
                    maxBytes: RuntimeTraceLimits.automaticEvidenceBytes
                )
            )
            append("\n")
        }
        if let endReport {
            append("\n== State At End ==\n")
            append(RuntimeTraceLimits.boundedString(endReport, maxBytes: RuntimeTraceLimits.stateReportBytes))
            append("\n")
        }
        return data
    }

    private func writeAtomically(to destination: URL, body: (TraceByteSink) throws -> Void) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let temporary = diagnosticsDirectory.appendingPathComponent(
            ".omniwm-trace-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var handle: FileHandle?
        do {
            guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let openedHandle = try FileHandle(forWritingTo: temporary)
            handle = openedHandle
            try body(TraceByteSink(handle: openedHandle))
            try openedHandle.synchronize()
            try openedHandle.close()
            handle = nil
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? handle?.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func partialFilename(startedAt: Date) -> String {
        "omniwm-trace-\(milliseconds(startedAt)).partial.log"
    }

    private func milliseconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }
}

@MainActor @Observable
final class RuntimeTraceCaptureCoordinator {
    private static let flushIntervalSeconds = 15
    private static let maxCaptureSeconds = 600

    private var phase: TraceCapturePhase = .idle
    private var session: TraceCaptureSession?
    private var reportProvider: (() -> String)?
    private var automaticEvidenceProvider: (() async -> String)?
    private var captureTask: Task<Void, Never>?
    private(set) var lastArtifact: TraceCaptureArtifact?
    var onStateChange: (() -> Void)?
    private let recorders: [any RuntimeTraceRecording]
    private let writer: TraceCaptureFileWriter

    init(
        diagnosticsDirectory: URL = OmniWMStoragePaths.live.diagnosticsDirectory,
        recorders: [any RuntimeTraceRecording] = [
            AppVisibilityTrace.shared,
            NativeFullscreenPlaceholderTrace.shared,
            NativeFullscreenPlaceholderTrace.motion,
            WindowAdmissionTrace.shared,
            RawAXNotificationTrace.shared,
            FrameApplyTrace.shared,
            NiriLayoutTrace.shared,
            AnimationTickTrace.shared,
            ParkVisibilityAudit.shared,
            ScrollTickTrace.shared,
            AXWriteLatencyTrace.shared,
            BorderOpMetricsRecorder.shared,
            MouseTrace.shared,
            InputTrace.shared
        ]
    ) {
        writer = TraceCaptureFileWriter(diagnosticsDirectory: diagnosticsDirectory)
        self.recorders = recorders
    }

    var isActive: Bool {
        phase != .idle
    }

    var status: TraceCaptureStatus {
        TraceCaptureStatus(phase: phase, startedAt: session?.startedAt, lastArtifact: lastArtifact)
    }

    func toggle(
        desiredState: TraceCaptureDesiredState,
        reportProvider: @escaping () -> String,
        automaticEvidenceProvider: @escaping () async -> String = { "none" }
    ) async -> TraceCaptureOutcome {
        switch desiredState {
        case .active:
            return phase == .idle
                ? await start(
                    reportProvider: reportProvider,
                    automaticEvidenceProvider: automaticEvidenceProvider
                )
                : .noChange
        case .inactive:
            return phase == .recording ? await stop() : .noChange
        case .toggle:
            return phase == .idle
                ? await start(
                    reportProvider: reportProvider,
                    automaticEvidenceProvider: automaticEvidenceProvider
                )
                : phase == .recording ? await stop() : .noChange
        }
    }

    private func start(
        reportProvider: @escaping () -> String,
        automaticEvidenceProvider: @escaping () async -> String
    ) async -> TraceCaptureOutcome {
        DiagnosticsEventRecorder.shared.beginVerboseCapture()
        recorders.forEach { $0.beginCapture() }
        self.reportProvider = reportProvider
        self.automaticEvidenceProvider = automaticEvidenceProvider
        let session = TraceCaptureSession(
            startedAt: Date(),
            startReport: RuntimeTraceLimits.boundedString(
                reportProvider(),
                maxBytes: RuntimeTraceLimits.stateReportBytes
            )
        )
        self.session = session
        phase = .recording
        onStateChange?()

        do {
            _ = try await writer.writeInitialPartial(session: session, recorders: recorders)
            guard phase == .recording,
                  self.session?.startedAt == session.startedAt
            else { return .noChange }
            if lastArtifact != nil {
                lastArtifact = nil
                onStateChange?()
            }
        } catch {
            guard phase == .recording,
                  self.session?.startedAt == session.startedAt
            else { return .noChange }
            DiagnosticsEventRecorder.shared.endVerboseCapture()
            recorders.forEach { $0.endCapture() }
            self.session = nil
            self.reportProvider = nil
            self.automaticEvidenceProvider = nil
            phase = .idle
            onStateChange?()
            return .writeFailed(error.localizedDescription)
        }

        startCaptureTask()
        return .started
    }

    private func startCaptureTask() {
        captureTask = Task { [weak self] in
            let maxFlushes = Self.maxCaptureSeconds / Self.flushIntervalSeconds
            for _ in 0 ..< maxFlushes {
                do {
                    try await Task.sleep(for: .seconds(Self.flushIntervalSeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.writePartial()
            }
            guard !Task.isCancelled, let self else { return }
            self.captureTask = nil
            _ = await self.finalize()
        }
    }

    private func stop() async -> TraceCaptureOutcome {
        let activeTask = captureTask
        captureTask = nil
        activeTask?.cancel()
        return await finalize()
    }

    private func finalize() async -> TraceCaptureOutcome {
        guard phase == .recording, let session else { return .noChange }
        phase = .finalizing
        onStateChange?()

        let endedAt = Date()
        DiagnosticsEventRecorder.shared.endVerboseCapture()
        recorders.forEach { $0.endCapture() }
        let endReport = RuntimeTraceLimits.boundedString(
            reportProvider?() ?? "report unavailable",
            maxBytes: RuntimeTraceLimits.stateReportBytes
        )
        let evidenceProvider = automaticEvidenceProvider
        reportProvider = nil
        automaticEvidenceProvider = nil
        let automaticEvidence = RuntimeTraceLimits.boundedString(
            await evidenceProvider?() ?? "none",
            maxBytes: RuntimeTraceLimits.automaticEvidenceBytes
        )

        do {
            let url = try await writer.writeFinal(
                session: session,
                endedAt: endedAt,
                recorders: recorders,
                automaticEvidence: automaticEvidence,
                endReport: endReport
            )
            let artifact = TraceCaptureArtifact(url: url, startedAt: session.startedAt, endedAt: endedAt)
            lastArtifact = artifact
            self.session = nil
            phase = .idle
            onStateChange?()
            return .stopped(artifact)
        } catch {
            self.session = nil
            phase = .idle
            onStateChange?()
            return .writeFailed(error.localizedDescription)
        }
    }

    private func writePartial() async {
        guard phase == .recording, let session else { return }
        _ = try? await writer.writePartial(session: session, recorders: recorders)
    }
}
