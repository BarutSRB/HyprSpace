// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IPCCaptureBridgeTests: XCTestCase {
    private enum TestError: Error {
        case unexpectedResult
    }

    func testTraceStartStatusAndStopProjectSharedCaptureState() async throws {
        let harness = try makeHarness()

        let start = await harness.bridge.response(
            for: request(id: "start", capture: .start(.trace))
        )
        XCTAssertTrue(start.ok)
        XCTAssertEqual(start.kind, .capture)
        XCTAssertEqual(start.status, .executed)
        let started = try captureResult(from: start)
        XCTAssertEqual(started.phase, .recording)
        XCTAssertEqual(started.profile, .trace)
        XCTAssertNotNil(started.startedAt.flatMap(ISO8601DateFormatter().date(from:)))
        XCTAssertNil(started.lastArtifact)
        XCTAssertNil(started.failureReason)

        let status = await harness.bridge.response(
            for: request(id: "status", capture: .status)
        )
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.kind, .capture)
        XCTAssertEqual(status.status, .success)
        XCTAssertEqual(try captureResult(from: status), started)

        let stop = await harness.bridge.response(
            for: request(id: "stop", capture: .stop)
        )
        XCTAssertTrue(stop.ok)
        XCTAssertEqual(stop.kind, .capture)
        XCTAssertEqual(stop.status, .executed)
        let stopped = try captureResult(from: stop)
        XCTAssertEqual(stopped.phase, .idle)
        XCTAssertNil(stopped.profile)
        XCTAssertNil(stopped.startedAt)
        XCTAssertNil(stopped.failureReason)
        let artifact = try XCTUnwrap(stopped.lastArtifact)
        XCTAssertEqual(artifact.profile, .trace)
        XCTAssertTrue(artifact.path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: artifact.startedAt))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: artifact.endedAt))
    }

    func testCaptureBypassesRuntimeCommandGatesAndConflictIncludesCurrentSnapshot() async throws {
        let harness = try makeHarness()
        harness.controller.isEnabled = false
        harness.controller.settings.animationsEnabled = false
        harness.controller.settings.defaultLayoutType = .dwindle
        harness.controller.toggleOverview()
        defer {
            if harness.controller.isOverviewOpen() {
                harness.controller.toggleOverview()
            }
        }
        XCTAssertTrue(harness.controller.isOverviewOpen())
        XCTAssertEqual(harness.controller.settings.defaultLayoutType, .dwindle)

        let start = await harness.bridge.response(
            for: request(id: "performance", capture: .start(.performance))
        )
        XCTAssertTrue(start.ok)
        let started = try captureResult(from: start)
        XCTAssertEqual(started.phase, .recording)
        XCTAssertEqual(started.profile, .performance)

        let conflict = await harness.bridge.response(
            for: request(id: "conflict", capture: .start(.trace))
        )
        XCTAssertFalse(conflict.ok)
        XCTAssertEqual(conflict.kind, .capture)
        XCTAssertEqual(conflict.code, .captureStateConflict)
        let conflicted = try captureResult(from: conflict)
        XCTAssertEqual(conflicted.phase, .recording)
        XCTAssertEqual(conflicted.profile, .performance)
        XCTAssertEqual(conflicted.startedAt, started.startedAt)
        XCTAssertNil(conflicted.failureReason)

        let stop = await harness.bridge.response(
            for: request(id: "stop", capture: .stop)
        )
        XCTAssertTrue(stop.ok)
    }

    func testControllerAndIPCShareCaptureState() async throws {
        let harness = try makeHarness()

        guard case .started = await harness.controller.toggleTraceCapture(
            desiredState: .active,
            profile: .performance
        ) else {
            return XCTFail("expected controller capture to start")
        }

        let statusResponse = await harness.bridge.response(
            for: request(id: "status", capture: .status)
        )
        let status = try captureResult(from: statusResponse)
        XCTAssertEqual(status.phase, .recording)
        XCTAssertEqual(status.profile, .performance)

        let stop = await harness.bridge.response(
            for: request(id: "stop", capture: .stop)
        )
        XCTAssertTrue(stop.ok)
        XCTAssertEqual(harness.controller.traceCaptureStatus.phase, .idle)
    }

    func testPerformanceStatusCanExposePreviousTraceArtifact() async throws {
        let harness = try makeHarness()

        _ = await harness.bridge.response(
            for: request(id: "trace-start", capture: .start(.trace))
        )
        let traceStop = await harness.bridge.response(
            for: request(id: "trace-stop", capture: .stop)
        )
        let traceArtifact = try XCTUnwrap(try captureResult(from: traceStop).lastArtifact)

        let performanceStart = await harness.bridge.response(
            for: request(id: "performance-start", capture: .start(.performance))
        )
        XCTAssertTrue(performanceStart.ok)
        let statusResponse = await harness.bridge.response(
            for: request(id: "performance-status", capture: .status)
        )
        let status = try captureResult(from: statusResponse)
        XCTAssertEqual(status.phase, .recording)
        XCTAssertEqual(status.profile, .performance)
        XCTAssertEqual(status.lastArtifact, traceArtifact)
        XCTAssertEqual(status.lastArtifact?.profile, .trace)

        let stop = await harness.bridge.response(
            for: request(id: "performance-stop", capture: .stop)
        )
        XCTAssertTrue(stop.ok)
    }

    func testCaptureRequiresAuthorization() async throws {
        let harness = try makeHarness()

        let response = await harness.bridge.response(
            for: request(id: "unauthorized", capture: .status, token: "wrong")
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.kind, .capture)
        XCTAssertEqual(response.code, .unauthorized)
        XCTAssertNil(response.result)
        XCTAssertEqual(harness.controller.traceCaptureStatus.phase, .idle)
    }

    func testOlderProtocolCaptureRequestReturnsMismatchWithoutChangingState() async throws {
        let harness = try makeHarness()
        let request = IPCRequest(
            version: 11,
            id: "old-capture",
            kind: .capture,
            authorizationToken: "token",
            payload: .capture(.start(.trace))
        )

        let response = await harness.bridge.response(for: request)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.kind, .capture)
        XCTAssertEqual(response.code, .protocolMismatch)
        guard case let .version(version) = response.result?.payload else {
            return XCTFail("expected version result")
        }
        XCTAssertEqual(version.protocolVersion, OmniWMIPCProtocol.version)
        XCTAssertEqual(harness.controller.traceCaptureStatus.phase, .idle)
    }

    func testCapabilitiesProjectCaptureActionsThroughBridge() async throws {
        let harness = try makeHarness()
        let request = IPCRequest(
            id: "capabilities",
            query: IPCQueryRequest(name: .capabilities),
            authorizationToken: "token"
        )

        let response = await harness.bridge.response(for: request)

        XCTAssertTrue(response.ok)
        guard case let .capabilities(capabilities) = response.result?.payload else {
            return XCTFail("expected capabilities result")
        }
        XCTAssertEqual(capabilities.captureActions, IPCAutomationManifest.captureActionDescriptors)
    }

    func testCaptureWriteFailureReturnsBoundedReasonAndCurrentSnapshot() async throws {
        let harness = try makeHarness(blockDiagnosticsDirectory: true)

        let response = await harness.bridge.response(
            for: request(id: "write-failure", capture: .start(.trace))
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.kind, .capture)
        XCTAssertEqual(response.code, .internalError)
        let result = try captureResult(from: response)
        XCTAssertEqual(result.phase, .idle)
        XCTAssertNil(result.profile)
        XCTAssertNil(result.startedAt)
        XCTAssertNil(result.lastArtifact)
        let reason = try XCTUnwrap(result.failureReason)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertLessThanOrEqual(reason.utf8.count, RuntimeTraceLimits.diagnosticStringBytes)
    }

    private func request(
        id: String,
        capture: IPCCaptureRequest,
        token: String = "token"
    ) -> IPCRequest {
        IPCRequest(id: id, capture: capture, authorizationToken: token)
    }

    private func captureResult(from response: IPCResponse) throws -> IPCCaptureResult {
        guard case let .capture(result) = response.result?.payload else {
            XCTFail("expected capture result")
            throw TestError.unexpectedResult
        }
        return result
    }

    private func makeHarness(blockDiagnosticsDirectory: Bool = false) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMIPCCaptureBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let diagnosticsDirectory: URL
        if blockDiagnosticsDirectory {
            let blocker = root.appendingPathComponent("blocker", isDirectory: false)
            try Data("blocked".utf8).write(to: blocker)
            diagnosticsDirectory = blocker.appendingPathComponent("diagnostics", isDirectory: true)
        } else {
            diagnosticsDirectory = root.appendingPathComponent("diagnostics", isDirectory: true)
        }
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
        let controller = WMController(
            settings: settings,
            diagnosticsDirectory: diagnosticsDirectory,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
        addTeardownBlock { @MainActor in
            if controller.isTraceCaptureActive {
                _ = await controller.toggleTraceCapture(desiredState: .inactive)
            }
            try? FileManager.default.removeItem(at: root)
        }
        return Harness(controller: controller, bridge: bridge)
    }

    private struct Harness {
        let controller: WMController
        let bridge: IPCApplicationBridge
    }
}
