// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class PerformanceCaptureTests: XCTestCase {
    @MainActor
    func testResourceSnapshotsBracketReportFormatting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var operations: [String] = []
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [],
            processResourceProvider: {
                operations.append("resource")
                return nil
            }
        )

        _ = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: {
                operations.append("report")
                return "state"
            },
            performanceMetricsBegin: { operations.append("metricsBegin") },
            performanceMetricsEnd: { operations.append("metricsEnd") }
        )
        XCTAssertEqual(operations, ["metricsBegin", "resource", "report"])

        _ = await coordinator.toggle(
            desiredState: .inactive,
            profile: .performance,
            reportProvider: { "unused" }
        )
        XCTAssertEqual(
            operations,
            ["metricsBegin", "resource", "report", "metricsEnd", "resource", "report"]
        )
    }

    @MainActor
    func testPerformanceCaptureAvoidsDetailedRecordersAndWritesOneFinalArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousArtifact = directory.appendingPathComponent("omniwm-performance-previous.log")
        try Data("previous".utf8).write(to: previousArtifact)
        let recorder = CountingRuntimeTraceRecorder()
        let resources = PerformanceResourceProvider(
            snapshots: [
                makeSnapshot(capturedAt: 1, energy: 100, base: 10),
                makeSnapshot(capturedAt: 1_000_000_001, energy: 1_000_000_100, base: 20)
            ]
        )
        let reports = PerformanceReportProvider(reports: ["windows=2", "windows=3"])
        let evidenceEvaluations = Atomic<UInt64>(0)
        let metricBegins = Atomic<UInt64>(0)
        let metricEnds = Atomic<UInt64>(0)
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            processResourceProvider: { resources.next() }
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: { reports.next() },
            performanceMetricsBegin: {
                metricBegins.wrappingAdd(1, ordering: .relaxed)
            },
            performanceMetricsEnd: {
                metricEnds.wrappingAdd(1, ordering: .relaxed)
            },
            automaticEvidenceProvider: {
                evidenceEvaluations.wrappingAdd(1, ordering: .relaxed)
                return "must-not-run"
            }
        ) else {
            return XCTFail("expected performance capture to start")
        }

        XCTAssertEqual(coordinator.status.profile, .performance)
        XCTAssertEqual(recorder.beginCount.load(ordering: .relaxed), 0)
        XCTAssertEqual(recorder.endCount.load(ordering: .relaxed), 0)
        XCTAssertEqual(metricBegins.load(ordering: .relaxed), 1)
        XCTAssertEqual(metricEnds.load(ordering: .relaxed), 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [previousArtifact.lastPathComponent]
        )

        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            profile: .performance,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected performance capture to stop")
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(
            files,
            [artifact.url.lastPathComponent, previousArtifact.lastPathComponent].sorted(),
            "recent performance captures are retained so before/after comparison stays possible"
        )
        XCTAssertEqual(artifact.profile, .performance)
        XCTAssertTrue(artifact.url.lastPathComponent.hasPrefix("omniwm-performance-"))
        XCTAssertNil(coordinator.status.profile)
        XCTAssertEqual(recorder.beginCount.load(ordering: .relaxed), 0)
        XCTAssertEqual(recorder.endCount.load(ordering: .relaxed), 0)
        XCTAssertEqual(metricBegins.load(ordering: .relaxed), 1)
        XCTAssertEqual(metricEnds.load(ordering: .relaxed), 1)
        XCTAssertEqual(evidenceEvaluations.load(ordering: .relaxed), 0)
        XCTAssertEqual(resources.readCount, 2)

        let content = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(content.contains("== OmniWM Performance Capture =="))
        XCTAssertTrue(content.contains("energy=1.000000J"))
        XCTAssertTrue(content.contains("windows=2"))
        XCTAssertTrue(content.contains("windows=3"))
        XCTAssertFalse(content.contains("Verbose Window Events"))
        XCTAssertFalse(content.contains(recorder.sectionTitle))
        XCTAssertFalse(content.contains("must-not-run"))
    }

    @MainActor
    func testPerformanceCaptureReportsUnavailableKernelSamples() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [],
            processResourceProvider: { nil }
        )

        _ = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: { "ids-only" }
        )
        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            profile: .performance,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected performance capture to stop")
        }

        let content = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(content.contains("resourceSnapshot=unavailable"))
    }

    @MainActor
    func testFailedFinalWritePreservesPreviousPerformanceArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let previousArtifact = directory.appendingPathComponent("omniwm-performance-previous.log")
        try Data("previous".utf8).write(to: previousArtifact)
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [],
            processResourceProvider: { nil }
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: { "capture" }
        ) else {
            return XCTFail("expected performance capture to start")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        guard case .writeFailed = await coordinator.toggle(
            desiredState: .inactive,
            profile: .performance,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected final write to fail")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: previousArtifact.path))
        XCTAssertEqual(try String(contentsOf: previousArtifact, encoding: .utf8), "previous")
        XCTAssertEqual(coordinator.status.phase, .idle)
    }

    @MainActor
    func testConcurrentPerformanceStartsReserveExactlyOneSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [],
            processResourceProvider: { nil }
        )

        let first = Task { @MainActor in
            await coordinator.toggle(
                desiredState: .active,
                profile: .performance,
                reportProvider: { "first" }
            )
        }
        let second = Task { @MainActor in
            await coordinator.toggle(
                desiredState: .active,
                profile: .performance,
                reportProvider: { "second" }
            )
        }
        let outcomes = [await first.value, await second.value]

        XCTAssertEqual(startedCount(in: outcomes), 1)
        XCTAssertEqual(coordinator.status.phase, .recording)
        XCTAssertEqual(coordinator.status.profile, .performance)
        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            profile: .performance,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected reserved capture to stop")
        }
        XCTAssertEqual(artifact.profile, .performance)
    }

    @MainActor
    func testConcurrentCrossProfileStartsCannotOverlapRecorders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = CountingRuntimeTraceRecorder()
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            processResourceProvider: { nil }
        )

        let performance = Task { @MainActor in
            await coordinator.toggle(
                desiredState: .active,
                profile: .performance,
                reportProvider: { "performance" }
            )
        }
        let problem = Task { @MainActor in
            await coordinator.toggle(
                desiredState: .active,
                profile: .problem,
                reportProvider: { "problem" }
            )
        }
        let outcomes = [await performance.value, await problem.value]

        XCTAssertEqual(startedCount(in: outcomes), 1)
        let activeProfile = try XCTUnwrap(coordinator.status.profile)
        XCTAssertEqual(
            recorder.beginCount.load(ordering: .relaxed),
            activeProfile == .problem ? 1 : 0
        )
        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            profile: activeProfile,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected reserved capture to stop")
        }
        XCTAssertEqual(artifact.profile, activeProfile)
        XCTAssertEqual(
            recorder.endCount.load(ordering: .relaxed),
            activeProfile == .problem ? 1 : 0
        )
    }

    @MainActor
    func testCancelledAutoStopCannotFinalizeAReplacementCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleepGate = PerformanceCaptureSleepGate()
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [],
            processResourceProvider: { nil },
            captureSleeper: { duration in
                try await sleepGate.sleep(duration)
            }
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: { "first" }
        ) else {
            return XCTFail("expected first capture to start")
        }
        await sleepGate.waitUntilCount(1)
        _ = await coordinator.toggle(
            desiredState: .inactive,
            profile: .performance,
            reportProvider: { "unused" }
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: { "replacement" }
        ) else {
            return XCTFail("expected replacement capture to start")
        }
        let replacementStartedAt = try XCTUnwrap(coordinator.status.startedAt)
        await sleepGate.waitUntilCount(2)

        await sleepGate.resumeFirst()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.status.phase, .recording)
        XCTAssertEqual(coordinator.status.profile, .performance)
        XCTAssertEqual(coordinator.status.startedAt, replacementStartedAt)

        _ = await coordinator.toggle(
            desiredState: .inactive,
            profile: .performance,
            reportProvider: { "unused" }
        )
        await sleepGate.resumeFirst()
    }

    @MainActor
    func testPerformanceCaptureAutomaticallyFinalizesAfterMaximumDuration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleepGate = PerformanceCaptureSleepGate()
        let metricEnds = Atomic<UInt64>(0)
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [],
            processResourceProvider: { nil },
            captureSleeper: { duration in
                try await sleepGate.sleep(duration)
            }
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: { "automatic" },
            performanceMetricsEnd: {
                metricEnds.wrappingAdd(1, ordering: .relaxed)
            }
        ) else {
            return XCTFail("expected performance capture to start")
        }
        await sleepGate.waitUntilCount(1)

        await sleepGate.resumeFirst()
        for _ in 0 ..< 100 where coordinator.status.phase != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.status.phase, .idle)
        XCTAssertEqual(metricEnds.load(ordering: .relaxed), 1)
        let artifact = try XCTUnwrap(coordinator.status.lastArtifact)
        XCTAssertEqual(artifact.profile, .performance)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [artifact.url.lastPathComponent]
        )
        XCTAssertFalse(artifact.url.lastPathComponent.contains("partial"))
    }

    @MainActor
    func testControllerPerformanceArtifactOmitsConfiguredIdentifiersAndDetailedSections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        let privateIdentifier = "com.omniwm.private-performance-sentinel"
        settings.hiddenBarHiddenBundleIDs = [privateIdentifier]
        let controller = WMController(settings: settings, diagnosticsDirectory: directory)

        guard case .started = await controller.toggleTraceCapture(
            desiredState: .active,
            profile: .performance
        ) else {
            return XCTFail("expected controller performance capture to start")
        }
        guard case let .stopped(artifact) = await controller.toggleTraceCapture(
            desiredState: .inactive,
            profile: .performance
        ) else {
            return XCTFail("expected controller performance capture to stop")
        }

        let content = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertFalse(content.contains(privateIdentifier))
        XCTAssertFalse(content.contains("Settings (TOML)"))
        XCTAssertFalse(content.contains("Verbose Window Events"))
        XCTAssertTrue(content.contains("axPark submitted="))
        XCTAssertEqual(content.components(separatedBy: "== Owner Metrics Start ==").count - 1, 1)
        XCTAssertEqual(content.components(separatedBy: "== Owner Metrics End ==").count - 1, 1)
        XCTAssertLessThanOrEqual(try Data(contentsOf: artifact.url).count, RuntimeTraceLimits.captureBytes)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPerformanceCaptureTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
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
    }

    private func startedCount(in outcomes: [TraceCaptureOutcome]) -> Int {
        outcomes.reduce(into: 0) { count, outcome in
            if case .started = outcome {
                count += 1
            }
        }
    }

    @MainActor
    private func makeSnapshot(
        capturedAt: UInt64,
        energy: UInt64,
        base: UInt64
    ) -> ProcessResourceSnapshot {
        ProcessResourceSnapshot(
            capturedAt: capturedAt,
            energyNanojoules: energy,
            userTime: base,
            systemTime: base,
            runnableTime: base,
            packageIdleWakeups: base,
            interruptWakeups: base,
            qosTime: .init(
                background: base,
                maintenance: base,
                utility: base,
                default: base,
                userInitiated: base,
                userInteractive: base,
                legacy: base
            ),
            instructions: base,
            cycles: base,
            pageIns: base,
            diskBytesRead: base,
            diskBytesWritten: base,
            residentSize: base,
            physicalFootprint: base,
            intervalMaxPhysicalFootprint: base
        )
    }
}

private actor PerformanceCaptureSleepGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_: Duration) async throws {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilCount(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func resumeFirst() {
        continuations.removeFirst().resume()
    }
}

private final class CountingRuntimeTraceRecorder: RuntimeTraceRecording, @unchecked Sendable {
    let sectionTitle = "Detailed Recorder Must Stay Inactive"
    let beginCount = Atomic<UInt64>(0)
    let endCount = Atomic<UInt64>(0)

    func beginCapture() {
        beginCount.wrappingAdd(1, ordering: .relaxed)
    }

    func endCapture() {
        endCount.wrappingAdd(1, ordering: .relaxed)
    }

    func dump() -> String {
        "detailed-data"
    }
}

@MainActor
private final class PerformanceResourceProvider {
    private var snapshots: [ProcessResourceSnapshot]
    private(set) var readCount = 0

    init(snapshots: [ProcessResourceSnapshot]) {
        self.snapshots = snapshots
    }

    func next() -> ProcessResourceSnapshot? {
        defer { readCount += 1 }
        guard readCount < snapshots.count else { return nil }
        return snapshots[readCount]
    }
}

@MainActor
private final class PerformanceReportProvider {
    private var reports: [String]
    private var readCount = 0

    init(reports: [String]) {
        self.reports = reports
    }

    func next() -> String {
        defer { readCount += 1 }
        guard readCount < reports.count else { return "unavailable" }
        return reports[readCount]
    }
}
