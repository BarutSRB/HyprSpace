// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Observation

enum TraceCaptureDesiredState {
    case active
    case inactive
    case toggle
}

enum TraceCaptureProfile: String, Equatable, Sendable {
    case problem
    case performance
}

enum TraceCapturePhase: Equatable {
    case idle
    case starting
    case recording
    case finalizing
}

struct TraceCaptureSession: Sendable {
    let profile: TraceCaptureProfile
    let startedAt: Date
    let startReport: String
    let processResourceStart: ProcessResourceSnapshot?
}

struct TraceCaptureArtifact: Equatable, Sendable {
    let profile: TraceCaptureProfile
    let url: URL
    let startedAt: Date
    let endedAt: Date
}

struct TraceCaptureStatus: Equatable {
    let phase: TraceCapturePhase
    let profile: TraceCaptureProfile?
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
    static let retainedPerformanceCaptures = 5

    private let diagnosticsDirectory: URL

    init(diagnosticsDirectory: URL) {
        self.diagnosticsDirectory = diagnosticsDirectory
    }

    func preparePerformanceCapture() throws {
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
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

    func writePerformanceFinal(
        session: TraceCaptureSession,
        endedAt: Date,
        processResourceDelta: ProcessResourceDelta?,
        endReport: String
    ) throws -> URL {
        let filename = "omniwm-performance-\(milliseconds(session.startedAt))-\(milliseconds(endedAt)).log"
        let url = diagnosticsDirectory.appendingPathComponent(filename, isDirectory: false)
        try writeAtomically(to: url, temporaryPrefix: ".omniwm-performance-") { sink in
            let writer = BoundedTraceWriter(sink: sink, reservedTailBytes: 0)
            _ = writer.appendLine("== OmniWM Performance Capture ==")
            _ = writer.appendLine("startedAt=\(session.startedAt.ISO8601Format())")
            _ = writer.appendLine("endedAt=\(endedAt.ISO8601Format())")
            _ = writer.appendLine("scope=OmniWM process CPU; WindowServer and GPU require external profiling")
            _ = writer.appendLine("detailedRecorders=disabled partialWrites=disabled automaticAXEvidence=disabled")
            _ = writer.appendLine("")
            _ = writer.appendLine("== Process Resource Delta ==")
            _ = writer.appendLine(processResourceDelta?.formatted() ?? "resourceSnapshot=unavailable")
            _ = writer.appendLine("")
            _ = writer.appendLine("== State At Start ==")
            _ = writer.appendLine(
                RuntimeTraceLimits.boundedString(
                    session.startReport,
                    maxBytes: RuntimeTraceLimits.stateReportBytes
                )
            )
            _ = writer.appendLine("")
            _ = writer.appendLine("== State At End ==")
            _ = writer.appendLine(
                RuntimeTraceLimits.boundedString(
                    endReport,
                    maxBytes: RuntimeTraceLimits.stateReportBytes
                )
            )
            try writer.finish(tail: Data())
        }
        DiagnosticsRetention.wipe(
            directory: diagnosticsDirectory,
            prefixes: ["omniwm-performance-"],
            except: [url],
            keepingNewest: Self.retainedPerformanceCaptures
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

    private func writeAtomically(
        to destination: URL,
        temporaryPrefix: String = ".omniwm-trace-",
        body: (TraceByteSink) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let temporary = diagnosticsDirectory.appendingPathComponent(
            "\(temporaryPrefix)\(UUID().uuidString).tmp",
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
    private var startingProfile: TraceCaptureProfile?
    private var session: TraceCaptureSession?
    private var reportProvider: (() -> String)?
    private var automaticEvidenceProvider: (() async -> String)?
    private var performanceMetricsEnd: (() -> Void)?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration: UInt64 = 0
    private(set) var lastArtifact: TraceCaptureArtifact?
    var onStateChange: (() -> Void)?
    private let recorders: [any RuntimeTraceRecording]
    private let writer: TraceCaptureFileWriter
    private let processResourceProvider: () -> ProcessResourceSnapshot?
    private let captureSleeper: @Sendable (Duration) async throws -> Void

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
        ],
        processResourceProvider: @escaping () -> ProcessResourceSnapshot? = ProcessResourceSnapshot.capture,
        captureSleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        writer = TraceCaptureFileWriter(diagnosticsDirectory: diagnosticsDirectory)
        self.recorders = recorders
        self.processResourceProvider = processResourceProvider
        self.captureSleeper = captureSleeper
    }

    var isActive: Bool {
        phase != .idle
    }

    var status: TraceCaptureStatus {
        TraceCaptureStatus(
            phase: phase,
            profile: session?.profile ?? startingProfile,
            startedAt: session?.startedAt,
            lastArtifact: lastArtifact
        )
    }

    func toggle(
        desiredState: TraceCaptureDesiredState,
        profile: TraceCaptureProfile = .problem,
        reportProvider: @escaping () -> String,
        performanceMetricsBegin: @escaping () -> Void = {},
        performanceMetricsEnd: @escaping () -> Void = {},
        automaticEvidenceProvider: @escaping () async -> String = { "none" }
    ) async -> TraceCaptureOutcome {
        switch desiredState {
        case .active:
            return phase == .idle
                ? await start(
                    profile: profile,
                    reportProvider: reportProvider,
                    performanceMetricsBegin: performanceMetricsBegin,
                    performanceMetricsEnd: performanceMetricsEnd,
                    automaticEvidenceProvider: automaticEvidenceProvider
                )
                : .noChange
        case .inactive:
            return phase == .recording ? await stop() : .noChange
        case .toggle:
            return phase == .idle
                ? await start(
                    profile: profile,
                    reportProvider: reportProvider,
                    performanceMetricsBegin: performanceMetricsBegin,
                    performanceMetricsEnd: performanceMetricsEnd,
                    automaticEvidenceProvider: automaticEvidenceProvider
                )
                : phase == .recording ? await stop() : .noChange
        }
    }

    private func start(
        profile: TraceCaptureProfile,
        reportProvider: @escaping () -> String,
        performanceMetricsBegin: @escaping () -> Void,
        performanceMetricsEnd: @escaping () -> Void,
        automaticEvidenceProvider: @escaping () async -> String
    ) async -> TraceCaptureOutcome {
        guard phase == .idle else { return .noChange }
        captureGeneration &+= 1
        let generation = captureGeneration
        startingProfile = profile
        phase = .starting
        onStateChange?()
        var startedAt = Date()
        var processResourceStart: ProcessResourceSnapshot?
        if profile == .problem {
            DiagnosticsEventRecorder.shared.beginVerboseCapture()
            recorders.forEach { $0.beginCapture() }
        }
        do {
            if profile == .performance {
                try await writer.preparePerformanceCapture()
            }
            guard captureGeneration == generation, phase == .starting, startingProfile == profile else {
                return .noChange
            }
            if profile == .performance {
                performanceMetricsBegin()
                self.performanceMetricsEnd = performanceMetricsEnd
                startedAt = Date()
                processResourceStart = processResourceProvider()
            }
            let startReport = RuntimeTraceLimits.boundedString(
                reportProvider(),
                maxBytes: RuntimeTraceLimits.stateReportBytes
            )
            let session = TraceCaptureSession(
                profile: profile,
                startedAt: startedAt,
                startReport: startReport,
                processResourceStart: processResourceStart
            )
            self.reportProvider = reportProvider
            self.automaticEvidenceProvider = profile == .problem ? automaticEvidenceProvider : nil
            self.session = session
            startingProfile = nil
            phase = .recording
            onStateChange?()
            if profile == .problem {
                _ = try await writer.writeInitialPartial(session: session, recorders: recorders)
            }
            guard captureGeneration == generation,
                  phase == .recording,
                  self.session?.startedAt == session.startedAt
            else { return .noChange }
            if profile == .problem, lastArtifact?.profile == .problem {
                lastArtifact = nil
                onStateChange?()
            }
        } catch {
            guard captureGeneration == generation else { return .noChange }
            if profile == .problem {
                DiagnosticsEventRecorder.shared.endVerboseCapture()
                recorders.forEach { $0.endCapture() }
            }
            startingProfile = nil
            self.session = nil
            self.reportProvider = nil
            self.automaticEvidenceProvider = nil
            self.performanceMetricsEnd = nil
            phase = .idle
            onStateChange?()
            return .writeFailed(error.localizedDescription)
        }

        startCaptureTask(profile: profile, generation: generation)
        return .started
    }

    private func startCaptureTask(profile: TraceCaptureProfile, generation: UInt64) {
        let sleeper = captureSleeper
        captureTask = Task { [weak self] in
            if profile == .problem {
                let maxFlushes = Self.maxCaptureSeconds / Self.flushIntervalSeconds
                for _ in 0 ..< maxFlushes {
                    do {
                        try await sleeper(.seconds(Self.flushIntervalSeconds))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, let self else { return }
                    await self.writePartial(generation: generation)
                }
            } else {
                do {
                    try await sleeper(.seconds(Self.maxCaptureSeconds))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            guard self.captureGeneration == generation else { return }
            self.captureTask = nil
            _ = await self.finalize(generation: generation)
        }
    }

    private func stop() async -> TraceCaptureOutcome {
        let activeTask = captureTask
        captureTask = nil
        activeTask?.cancel()
        return await finalize(generation: captureGeneration)
    }

    private func finalize(generation: UInt64) async -> TraceCaptureOutcome {
        guard captureGeneration == generation, phase == .recording, let session else { return .noChange }
        let endedAt: Date
        let processResourceEnd: ProcessResourceSnapshot?
        if session.profile == .performance {
            performanceMetricsEnd?()
            performanceMetricsEnd = nil
            processResourceEnd = processResourceProvider()
            endedAt = Date()
        } else {
            processResourceEnd = nil
            endedAt = Date()
        }
        phase = .finalizing
        onStateChange?()

        if session.profile == .problem {
            DiagnosticsEventRecorder.shared.endVerboseCapture()
            recorders.forEach { $0.endCapture() }
        }
        let endReport = RuntimeTraceLimits.boundedString(
            reportProvider?() ?? "report unavailable",
            maxBytes: RuntimeTraceLimits.stateReportBytes
        )
        let evidenceProvider = automaticEvidenceProvider
        reportProvider = nil
        automaticEvidenceProvider = nil

        do {
            let url: URL
            if session.profile == .performance {
                let processResourceDelta = session.processResourceStart.flatMap { start in
                    processResourceEnd.flatMap { start.delta(to: $0) }
                }
                url = try await writer.writePerformanceFinal(
                    session: session,
                    endedAt: endedAt,
                    processResourceDelta: processResourceDelta,
                    endReport: endReport
                )
            } else {
                let automaticEvidence = RuntimeTraceLimits.boundedString(
                    await evidenceProvider?() ?? "none",
                    maxBytes: RuntimeTraceLimits.automaticEvidenceBytes
                )
                url = try await writer.writeFinal(
                    session: session,
                    endedAt: endedAt,
                    recorders: recorders,
                    automaticEvidence: automaticEvidence,
                    endReport: endReport
                )
            }
            guard captureGeneration == generation, phase == .finalizing else { return .noChange }
            let artifact = TraceCaptureArtifact(
                profile: session.profile,
                url: url,
                startedAt: session.startedAt,
                endedAt: endedAt
            )
            lastArtifact = artifact
            self.session = nil
            phase = .idle
            onStateChange?()
            return .stopped(artifact)
        } catch {
            guard captureGeneration == generation else { return .noChange }
            self.session = nil
            phase = .idle
            onStateChange?()
            return .writeFailed(error.localizedDescription)
        }
    }

    private func writePartial(generation: UInt64) async {
        guard captureGeneration == generation,
              phase == .recording,
              let session,
              session.profile == .problem
        else { return }
        _ = try? await writer.writePartial(session: session, recorders: recorders)
    }
}
