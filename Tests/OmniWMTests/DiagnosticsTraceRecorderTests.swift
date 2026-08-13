// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
private final class DiagnosticsEvidenceGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class DiagnosticsTraceRecorderTests: XCTestCase {
    func testDiagnosticStringBudgetPreservesValidUTF8() {
        let bounded = RuntimeTraceLimits.boundedString(String(repeating: "🪟", count: 2_000))

        XCTAssertLessThanOrEqual(bounded.utf8.count, RuntimeTraceLimits.diagnosticStringBytes)
        XCTAssertEqual(String(data: Data(bounded.utf8), encoding: .utf8), bounded)
    }

    func testSessionTraceRecorderGatingEvictionAndReset() {
        let recorder = SessionTraceRecorder<Int>(sectionTitle: "Nums", capacity: 3) { "\($0)" }

        recorder.record(1)
        XCTAssertEqual(recorder.dump(), "none", "records dropped while capture inactive")

        recorder.beginCapture()
        recorder.record(1)
        recorder.record(2)
        recorder.record(3)
        recorder.record(4)
        XCTAssertEqual(recorder.dump(), "2\n3\n4", "ring evicts oldest beyond capacity")

        recorder.endCapture()
        recorder.record(5)
        XCTAssertEqual(recorder.dump(), "2\n3\n4", "records dropped after capture ends")

        recorder.beginCapture()
        XCTAssertEqual(recorder.dump(), "none", "beginCapture resets the ring")
    }

    func testSessionTraceRecorderDoesNotEvaluateWhenInactive() {
        let recorder = SessionTraceRecorder<Int>(sectionTitle: "Nums", capacity: 4) { "\($0)" }
        var evaluations = 0
        let make: () -> Int = {
            evaluations += 1
            return 7
        }

        recorder.record(make())
        XCTAssertEqual(evaluations, 0, "autoclosure must not run while inactive")

        recorder.beginCapture()
        recorder.record(make())
        XCTAssertEqual(evaluations, 1)
    }

    func testLogErrorTapCapturesOnlyErrorAndFault() {
        LogErrorTap.shared.reset()

        Log.config.error("boom-error")
        Log.terminal.fault("boom-fault")
        Log.layout.debug("boom-debug")
        Log.ax.info("boom-info")
        Log.ipc.notice("boom-notice")

        let dump = LogErrorTap.shared.dump()
        XCTAssertTrue(dump.contains("boom-error"))
        XCTAssertTrue(dump.contains("boom-fault"))
        XCTAssertFalse(dump.contains("boom-debug"))
        XCTAssertFalse(dump.contains("boom-info"))
        XCTAssertFalse(dump.contains("boom-notice"))
        XCTAssertTrue(dump.contains("[error] config"))
        XCTAssertTrue(dump.contains("[fault] terminal"))

        LogErrorTap.shared.reset()
        XCTAssertEqual(LogErrorTap.shared.dump(), "none")
    }

    func testLogErrorTapBoundsIndividualStrings() {
        LogErrorTap.shared.reset()
        let oversized = String(repeating: "🪟", count: 2_000)

        LogErrorTap.shared.record(category: oversized, level: oversized, message: oversized)

        let dump = LogErrorTap.shared.dump()
        XCTAssertFalse(dump.contains(oversized))
        XCTAssertLessThanOrEqual(
            dump.utf8.count,
            RuntimeTraceLimits.diagnosticStringBytes * 3 + 128
        )
        LogErrorTap.shared.reset()
    }

    @MainActor
    func testCaptureCoordinatorTogglesDomainRecorders() async {
        AppVisibilityTrace.record(
            .notification,
            pid: 1,
            visibility: .hidden,
            outcome: .observed
        )
        XCTAssertFalse(AppVisibilityTrace.shared.dump().contains("event=notification"))
        RawAXNotificationTrace.record(name: "ax.before", pid: 1, windowId: nil)
        XCTAssertFalse(RawAXNotificationTrace.shared.dump().contains("ax.before"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTraceRecorder-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory)
        let startOutcome = await coordinator.toggle(desiredState: .active) { "report" }
        guard case .started = startOutcome else {
            return XCTFail("expected capture to start")
        }

        RawAXNotificationTrace.record(name: "ax.during", pid: 7, windowId: 42)
        AppVisibilityTrace.record(
            .stateTransition,
            pid: 7,
            visibility: .hidden,
            outcome: .applied,
            intakeSequence: 12,
            worldSequence: 34,
            intentId: 56,
            windowId: 42,
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000042"),
            generation: 3,
            intentGeneration: 2,
            managedWindowCount: 2,
            affectedWorkspaceCount: 2,
            activeWorkspaceCount: 1,
            destination: .window,
            source: .service
        )
        NiriLayoutTrace.record(.viewport, workspaceId: nil, "jump 0→10 col=0")
        AnimationTickTrace.shared.record(
            AnimationTickTrace.Record(
                mediaTime: 1,
                displayId: 1,
                intervalMs: 99,
                expectedMs: 6,
                scrollMs: 5,
                dwindleMs: 0,
                closingMs: 0,
                reconcileMs: 1,
                totalMs: 6,
                dropped: true
            )
        )
        BorderOpMetricsRecorder.shared.noteApply()
        ScrollTickTrace.shared.record(
            ScrollTickTrace.Record(
                mediaTime: 2,
                displayId: 1,
                animsMs: 0.1,
                snapshotMs: 0.2,
                buildMs: 0.1,
                commitMs: 290.0,
                totalMs: 290.4,
                show: 1,
                hide: 1,
                frames: 9,
                windowCount: 12,
                isAnimationTick: true
            )
        )
        AXWriteLatencyTrace.shared.record(
            AXWriteLatencyTrace.Record(
                mediaTime: 2,
                pid: 4242,
                count: 9,
                totalMs: 288.0,
                slowestMs: 250.0,
                enhancedUI: true
            )
        )
        let appVisibilityDump = AppVisibilityTrace.shared.dump()
        XCTAssertTrue(appVisibilityDump.contains("event=state_transition"))
        XCTAssertTrue(appVisibilityDump.contains("pid=7"))
        XCTAssertTrue(appVisibilityDump.contains("visibility=hidden"))
        XCTAssertTrue(appVisibilityDump.contains("outcome=applied"))
        XCTAssertTrue(appVisibilityDump.contains("intake_seq=12"))
        XCTAssertTrue(appVisibilityDump.contains("world_seq=34"))
        XCTAssertTrue(appVisibilityDump.contains("intent=56"))
        XCTAssertTrue(appVisibilityDump.contains("win=42"))
        XCTAssertTrue(appVisibilityDump.contains("workspace=00000000-0000-0000-0000-000000000042"))
        XCTAssertTrue(appVisibilityDump.contains("generation=3"))
        XCTAssertTrue(appVisibilityDump.contains("intent_generation=2"))
        XCTAssertTrue(appVisibilityDump.contains("managed_windows=2"))
        XCTAssertTrue(appVisibilityDump.contains("affected_workspaces=2"))
        XCTAssertTrue(appVisibilityDump.contains("active_workspaces=1"))
        XCTAssertTrue(appVisibilityDump.contains("destination=window"))
        XCTAssertTrue(appVisibilityDump.contains("source=service"))
        XCTAssertTrue(RawAXNotificationTrace.shared.dump().contains("ax.during"))
        XCTAssertTrue(NiriLayoutTrace.shared.dump().contains("jump 0→10"))
        XCTAssertTrue(AnimationTickTrace.shared.dump().contains("DROPPED"))
        XCTAssertTrue(BorderOpMetricsRecorder.shared.dump().contains("applyCalls=1"))
        XCTAssertTrue(ScrollTickTrace.shared.dump().contains("commit=290.00ms"))
        XCTAssertTrue(AXWriteLatencyTrace.shared.dump().contains("pid=4242"))

        let outcome = await coordinator.toggle(desiredState: .inactive) { "report" }
        guard case let .stopped(artifact) = outcome else {
            return XCTFail("expected capture to stop with an artifact")
        }
        let body = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
        XCTAssertTrue(body.contains("== macOS App Visibility Trace =="))
        XCTAssertTrue(body.contains("event=state_transition"))
        XCTAssertTrue(body.contains("== Raw AX Notifications =="))
        XCTAssertTrue(body.contains("== Niri Layout Trace =="))
        XCTAssertTrue(body.contains("== Frame Apply Trace =="))
        XCTAssertTrue(body.contains("== Animation Tick Timing =="))
        XCTAssertTrue(body.contains("== Scroll Tick Breakdown =="))
        XCTAssertTrue(body.contains("== AX Write Latency =="))
        XCTAssertTrue(body.contains("== Border Op Metrics =="))
        XCTAssertTrue(body.contains("== Mouse Trace =="))
        try? FileManager.default.removeItem(at: artifact.url)

        AppVisibilityTrace.record(
            .notification,
            pid: 1,
            visibility: .visible,
            outcome: .observed
        )
        XCTAssertFalse(AppVisibilityTrace.shared.dump().contains("event=notification"))
        RawAXNotificationTrace.record(name: "ax.after", pid: 1, windowId: nil)
        XCTAssertFalse(RawAXNotificationTrace.shared.dump().contains("ax.after"))
    }

    @MainActor
    func testFinalizationFreezesRecorderBeforeAwaitingEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTraceFinalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Test Records", capacity: 4) { $0 }
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder]
        )
        let gate = DiagnosticsEvidenceGate()
        defer { gate.release() }
        let evidenceStarted = expectation(description: "automatic evidence started")

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { "start report" },
            automaticEvidenceProvider: {
                evidenceStarted.fulfill()
                await gate.wait()
                return "status=timed_out"
            }
        ) else {
            return XCTFail("expected capture to start")
        }
        recorder.record("before stop")

        let stopTask = Task { @MainActor in
            await coordinator.toggle(desiredState: .inactive, reportProvider: { "end report" })
        }
        await fulfillment(of: [evidenceStarted], timeout: 2)

        XCTAssertEqual(coordinator.status.phase, .finalizing)
        XCTAssertFalse(recorder.isActive)
        recorder.record("after stop")
        gate.release()

        guard case let .stopped(artifact) = await stopTask.value else {
            return XCTFail("expected final artifact")
        }
        let body = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(body.contains("before stop"))
        XCTAssertFalse(body.contains("after stop"))
        XCTAssertTrue(body.contains("== Automatic AX Evidence ==\nstatus=timed_out"))
        XCTAssertEqual(coordinator.status.phase, .idle)
    }

    @MainActor
    func testFinalTraceIsByteBoundedAndPreservesReservedTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTraceBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Large Records", capacity: 3_000) { $0 }
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder]
        )
        var reportCount = 0

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: {
                reportCount += 1
                return reportCount == 1
                    ? "start-sentinel\n" + String(repeating: "s", count: 2 * 1024 * 1024)
                    : "end-sentinel\n" + String(repeating: "e", count: 2 * 1024 * 1024)
            },
            automaticEvidenceProvider: {
                "automatic-sentinel\n" + String(repeating: "a", count: 1024 * 1024)
            }
        ) else {
            return XCTFail("expected capture to start")
        }
        for index in 0 ..< 3_000 {
            recorder.record("record-\(index)-" + String(repeating: "🪟", count: 1_500))
        }

        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected capture artifact")
        }
        let data = try Data(contentsOf: artifact.url)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertLessThanOrEqual(data.count, RuntimeTraceLimits.captureBytes)
        XCTAssertEqual(body.components(separatedBy: "== Trace Data Truncated ==").count - 1, 1)
        XCTAssertTrue(body.contains("start-sentinel"))
        XCTAssertTrue(body.contains("automatic-sentinel"))
        XCTAssertTrue(body.contains("end-sentinel"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".omniwm-trace-") && $0.hasSuffix(".tmp") }
        )
    }

    func testBorderOpMetricsRecorderGatingAndReset() {
        let recorder = BorderOpMetricsRecorder()

        recorder.noteApply()
        XCTAssertEqual(recorder.dump(), "none", "counters ignored while inactive")

        recorder.beginCapture()
        recorder.noteApply()
        recorder.noteUpdate()
        recorder.noteMoveOnly()
        recorder.noteMoveOnly()
        recorder.noteCornerRadiusQuery()
        let dump = recorder.dump()
        XCTAssertTrue(dump.contains("applyCalls=1"))
        XCTAssertTrue(dump.contains("updateCalls=1"))
        XCTAssertTrue(dump.contains("moveOnly=2"))
        XCTAssertTrue(dump.contains("queries=1"))

        recorder.endCapture()
        recorder.noteApply()
        XCTAssertTrue(recorder.dump().contains("applyCalls=1"), "counters frozen after capture ends")

        recorder.beginCapture()
        XCTAssertEqual(recorder.dump(), "none", "beginCapture resets counters")
    }

    func testLayoutBuildMetricsSeparatesRoutes() {
        var metrics = LayoutBuildMetrics()
        metrics.recordBuild(seconds: 0.001, route: .relayout, workspaceCount: 1, windowCount: 12)
        metrics.recordBuild(seconds: 0.002, route: .scrollTick, workspaceCount: 1, windowCount: 12)

        let dump = metrics.dump()
        XCTAssertTrue(dump.contains("builds=2"))
        XCTAssertTrue(dump.contains("route=relayout ws=1 win=11-20"))
        XCTAssertTrue(dump.contains("route=scrollTick ws=1 win=11-20"))
    }
}
