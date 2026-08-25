// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IPCProtocolEnvelopeTests: XCTestCase {
    private enum ConnectionTestError: Error {
        case socketPairFailed
        case responseTimedOut
        case responseClosed
        case responseIOFailed(Int32)
    }

    private func requestLine(version: Int, kind: String, payload: String, token: String = "token") -> Data {
        Data("""
        {"version":\(version),"id":"req-1","kind":"\(kind)","authorizationToken":"\(token)","payload":\(payload)}
        """.utf8)
    }

    func testCurrentProtocolVersionIsTwelve() {
        XCTAssertEqual(OmniWMIPCProtocol.version, 12)
    }

    func testV11FullscreenOuterGapDisplayFieldIsAdditiveOnWire() throws {
        let legacyShapedResponse = IPCResponse.success(
            id: "legacy",
            kind: .query,
            result: IPCResult(
                displays: IPCDisplaysQueryResult(
                    displays: [IPCDisplayQuerySnapshot(id: "display")]
                )
            )
        )
        let legacyData = try IPCWire.encodeResponseLine(legacyShapedResponse)
        XCTAssertFalse(String(decoding: legacyData, as: UTF8.self).contains("fullscreenUsesOuterGaps"))
        let decodedLegacy = try IPCWire.decodeResponse(from: legacyData)
        guard case let .displays(legacyDisplays) = decodedLegacy.result?.payload else {
            return XCTFail("expected displays result")
        }
        XCTAssertNil(try XCTUnwrap(legacyDisplays.displays.first).fullscreenUsesOuterGaps)

        let explicitFalseResponse = IPCResponse.success(
            id: "current",
            kind: .query,
            result: IPCResult(
                displays: IPCDisplaysQueryResult(
                    displays: [IPCDisplayQuerySnapshot(id: "display", fullscreenUsesOuterGaps: false)]
                )
            )
        )
        let explicitFalseData = try IPCWire.encodeResponseLine(explicitFalseResponse)
        let decodedExplicitFalse = try IPCWire.decodeResponse(from: explicitFalseData)
        guard case let .displays(currentDisplays) = decodedExplicitFalse.result?.payload else {
            return XCTFail("expected displays result")
        }
        XCTAssertEqual(try XCTUnwrap(currentDisplays.displays.first).fullscreenUsesOuterGaps, false)
    }

    func testEnvelopeDecodesVersionWhenCommandNameIsUnknown() throws {
        let data = requestLine(version: 6, kind: "command", payload: #"{"name":"toggle-hidden-bar"}"#)
        XCTAssertThrowsError(try IPCWire.decodeRequest(from: data))
        let envelope = try XCTUnwrap(IPCWire.decodeRequestEnvelope(from: data))
        XCTAssertEqual(envelope.version, 6)
        XCTAssertEqual(envelope.id, "req-1")
        XCTAssertEqual(envelope.kind, "command")
    }

    func testEnvelopeDecodeFailsWithoutVersion() {
        XCTAssertNil(IPCWire.decodeRequestEnvelope(from: Data(#"{"id":"x","kind":"ping"}"#.utf8)))
        XCTAssertNil(IPCWire.decodeRequestEnvelope(from: Data("not json".utf8)))
    }

    func testMismatchResponseReturnsProtocolMismatchWithVersionResult() async throws {
        let bridge = makeBridge()
        let data = requestLine(version: 6, kind: "command", payload: #"{"name":"toggle-hidden-bar"}"#)
        let envelope = try XCTUnwrap(IPCWire.decodeRequestEnvelope(from: data))

        let response = await bridge.mismatchResponse(for: envelope)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "req-1")
        XCTAssertEqual(response.kind, .command)
        XCTAssertEqual(response.code, .protocolMismatch)
        XCTAssertEqual(protocolVersion(in: response), OmniWMIPCProtocol.version)
    }

    func testMismatchResponseAnswersVersionRequestsWithSuccess() async throws {
        let bridge = makeBridge()
        let data = requestLine(version: 6, kind: "version", payload: "{}")
        let envelope = try XCTUnwrap(IPCWire.decodeRequestEnvelope(from: data))

        let response = await bridge.mismatchResponse(for: envelope)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.kind, .version)
        XCTAssertEqual(protocolVersion(in: response), OmniWMIPCProtocol.version)
    }

    func testMismatchResponseRequiresAuthorization() async throws {
        let bridge = makeBridge()
        let data = requestLine(version: 6, kind: "command", payload: #"{"name":"toggle-hidden-bar"}"#, token: "wrong")
        let envelope = try XCTUnwrap(IPCWire.decodeRequestEnvelope(from: data))

        let response = await bridge.mismatchResponse(for: envelope)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, .unauthorized)
        XCTAssertNil(response.result)
    }

    func testV11ConnectionReturnsProtocolMismatchBeforeV12PayloadDecode() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw ConnectionTestError.socketPairFailed
        }

        let serverHandle = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        let clientHandle = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        let controller = makeController()
        let bridge = makeBridge(controller: controller)
        let connection = IPCConnection(handle: serverHandle, bridge: bridge, onClose: { _ in })

        let request = requestLine(version: 11, kind: "workspace", payload: #"{"name":"move-to-monitor"}"#)
        XCTAssertThrowsError(try IPCWire.decodeRequest(from: request))
        await connection.process(String(decoding: request, as: UTF8.self))

        let clientDescriptor = clientHandle.fileDescriptor
        let responseData = try Self.readResponseLine(from: clientDescriptor)
        let response = try IPCWire.decodeResponse(from: responseData)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "req-1")
        XCTAssertEqual(response.kind, .workspace)
        XCTAssertEqual(response.code, .protocolMismatch)
        XCTAssertEqual(protocolVersion(in: response), OmniWMIPCProtocol.version)

        await connection.stop()
        try? clientHandle.close()
        withExtendedLifetime(controller) {}
    }

    private nonisolated static func readResponseLine(from fileDescriptor: Int32) throws -> Data {
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let result = Darwin.poll(&descriptor, 1, 2_000)
            if result > 0 {
                guard descriptor.revents & Int16(POLLIN) != 0 else {
                    throw ConnectionTestError.responseClosed
                }
                break
            }
            if result == 0 {
                throw ConnectionTestError.responseTimedOut
            }
            guard errno == EINTR else {
                throw ConnectionTestError.responseIOFailed(errno)
            }
        }

        var data = Data()
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(fileDescriptor, &byte, 1)
            if result == 1 {
                data.append(byte)
                if byte == 0x0A {
                    return data
                }
                continue
            }
            if result == -1, errno == EINTR { continue }
            if result == -1 { throw ConnectionTestError.responseIOFailed(errno) }
            throw ConnectionTestError.responseClosed
        }
    }

    private func protocolVersion(in response: IPCResponse) -> Int? {
        guard case let .version(result) = response.result?.payload else { return nil }
        return result.protocolVersion
    }

    private func makeBridge(controller: WMController? = nil) -> IPCApplicationBridge {
        IPCApplicationBridge(
            controller: controller ?? makeController(),
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMIPCProtocolEnvelopeTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
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
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }
}
