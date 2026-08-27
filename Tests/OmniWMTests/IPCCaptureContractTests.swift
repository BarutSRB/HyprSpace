// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC
import XCTest

final class IPCCaptureContractTests: XCTestCase {
    func testCaptureRequestsUseFlatActionPayloads() throws {
        let cases: [(IPCCaptureRequest, [String: String])] = [
            (.start(.trace), ["name": "start", "profile": "trace"]),
            (.start(.performance), ["name": "start", "profile": "performance"]),
            (.stop, ["name": "stop"]),
            (.status, ["name": "status"])
        ]

        for (capture, expectedPayload) in cases {
            let request = IPCRequest(id: "capture", capture: capture, authorizationToken: "token")
            let data = try IPCWire.makeEncoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertEqual(object["version"] as? Int, 13)
            XCTAssertEqual(object["kind"] as? String, "capture")
            XCTAssertEqual(object["payload"] as? [String: String], expectedPayload)
            XCTAssertEqual(try IPCWire.makeDecoder().decode(IPCRequest.self, from: data), request)
        }
    }

    func testCaptureStartRequiresProfile() {
        XCTAssertThrowsError(
            try IPCWire.makeDecoder().decode(
                IPCCaptureRequest.self,
                from: Data(#"{"name":"start"}"#.utf8)
            )
        )
    }

    func testCaptureResultRoundTripsRFC3339TimestampsAsStrings() throws {
        let result = IPCCaptureResult(
            phase: .recording,
            profile: .performance,
            startedAt: "2026-08-25T15:04:05Z",
            lastArtifact: IPCCaptureArtifact(
                profile: .trace,
                path: "/tmp/omniwm-trace.json",
                startedAt: "2026-08-25T14:00:00Z",
                endedAt: "2026-08-25T14:01:00Z"
            ),
            failureReason: "write failed"
        )
        let response = IPCResponse.success(
            id: "capture",
            kind: .capture,
            status: .executed,
            result: IPCResult(capture: result)
        )

        let data = try IPCWire.encodeResponseLine(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resultObject = try XCTUnwrap(object["result"] as? [String: Any])
        let payload = try XCTUnwrap(resultObject["payload"] as? [String: Any])
        let artifact = try XCTUnwrap(payload["lastArtifact"] as? [String: Any])

        XCTAssertEqual(resultObject["kind"] as? String, "capture")
        XCTAssertEqual(payload["startedAt"] as? String, "2026-08-25T15:04:05Z")
        XCTAssertEqual(artifact["startedAt"] as? String, "2026-08-25T14:00:00Z")
        XCTAssertEqual(artifact["endedAt"] as? String, "2026-08-25T14:01:00Z")
        XCTAssertFalse(payload["startedAt"] is NSNumber)
        XCTAssertEqual(try IPCWire.decodeResponse(from: data), response)
    }

    func testCaptureManifestDescribesOnlyCapturePaths() {
        let descriptors = IPCAutomationManifest.captureActionDescriptors

        XCTAssertEqual(descriptors.map(\.name), [.start, .stop, .status])
        XCTAssertEqual(
            descriptors.map(\.path),
            ["capture start <trace|performance>", "capture stop", "capture status"]
        )
        XCTAssertEqual(descriptors.first?.arguments, ["trace|performance"])
        XCTAssertTrue(descriptors.dropFirst().allSatisfy(\.arguments.isEmpty))
    }

    func testCapabilitiesIncludeCaptureActionsButCommandsDoNot() throws {
        let capabilities = IPCCapabilitiesQueryResult(
            appVersion: "test",
            authorizationRequired: true,
            windowIdScope: "session",
            queries: [],
            commands: [],
            captureActions: IPCAutomationManifest.captureActionDescriptors,
            ruleActions: [],
            workspaceActions: [],
            windowActions: [],
            subscriptions: []
        )
        let commands = IPCCommandsQueryResult(commands: [], workspaceActions: [], windowActions: [])
        let encoder = IPCWire.makeEncoder()
        let capabilitiesObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(capabilities)) as? [String: Any]
        )
        let commandsObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(commands)) as? [String: Any]
        )

        XCTAssertEqual(capabilities.captureActions, IPCAutomationManifest.captureActionDescriptors)
        XCTAssertNotNil(capabilitiesObject["captureActions"])
        XCTAssertNil(commandsObject["captureActions"])
    }

    func testCaptureKindsAndConflictCodeUsePublicWireNames() {
        XCTAssertEqual(IPCRequestKind.capture.rawValue, "capture")
        XCTAssertEqual(IPCResponseKind.capture.rawValue, "capture")
        XCTAssertEqual(IPCResponseKind(requestKind: .capture), .capture)
        XCTAssertEqual(IPCResultKind.capture.rawValue, "capture")
        XCTAssertEqual(IPCErrorCode.captureStateConflict.rawValue, "capture_state_conflict")
    }
}
