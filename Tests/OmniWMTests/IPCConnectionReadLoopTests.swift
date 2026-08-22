// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IPCConnectionReadLoopTests: XCTestCase {
    private enum HarnessError: Error {
        case socketPairFailed(Int32)
        case timedOut
        case closed
        case ioFailed(Int32)
    }

    func testProcessesMultipleLinesFromOneWrite() async throws {
        let harness = try await makeHarness()

        var requests = try requestLine(id: "first")
        requests.append(try requestLine(id: "second"))
        try await harness.write(requests)

        let responses = try await harness.readResponseLines(count: 2)
            .map(IPCWire.decodeResponse(from:))
        XCTAssertEqual(responses.map(\.id), ["first", "second"])
        XCTAssertTrue(responses.allSatisfy(\.ok))
    }

    func testWaitsForFragmentedLineToComplete() async throws {
        let harness = try await makeHarness()

        let request = try requestLine(id: "fragmented")
        let splitIndex = request.index(request.startIndex, offsetBy: request.count / 2)
        try await harness.write(request[..<splitIndex])
        let receivedPrematureResponse = try await harness.hasReadableBytes(timeoutMilliseconds: 100)
        XCTAssertFalse(receivedPrematureResponse)

        try await harness.write(request[splitIndex...])
        let responseData = try await harness.readResponseLine()
        let response = try IPCWire.decodeResponse(from: responseData)
        XCTAssertEqual(response.id, "fragmented")
        XCTAssertTrue(response.ok)
    }

    func testInvalidUTF8ClosesWithoutResponding() async throws {
        let harness = try await makeHarness()

        try await harness.write(Data([0x66, 0xFF, 0xFE, 0x0A]))
        let observation = try await harness.readUntilEOF()

        XCTAssertTrue(observation.sawEOF)
        XCTAssertTrue(observation.lines.isEmpty)
    }

    func testAcceptsLineAtExactByteLimit() async throws {
        let harness = try await makeHarness()

        var exactLimit = Data(repeating: 0x61, count: IPCConnection.maxRequestLineBytes)
        exactLimit.append(0x0A)
        try await harness.write(exactLimit)

        let invalidResponseData = try await harness.readResponseLine()
        let invalidResponse = try IPCWire.decodeResponse(from: invalidResponseData)
        XCTAssertEqual(invalidResponse.code, .invalidRequest)

        try await harness.write(requestLine(id: "still-open"))
        let validResponseData = try await harness.readResponseLine()
        let validResponse = try IPCWire.decodeResponse(from: validResponseData)
        XCTAssertEqual(validResponse.id, "still-open")
        XCTAssertTrue(validResponse.ok)
    }

    func testRejectsLineOverByteLimitAndCloses() async throws {
        let harness = try await makeHarness()

        var overLimit = Data(repeating: 0x61, count: IPCConnection.maxRequestLineBytes + 1)
        overLimit.append(0x0A)
        try await harness.write(overLimit)
        let observation = try await harness.readUntilEOF()

        XCTAssertTrue(observation.sawEOF)
        XCTAssertEqual(observation.lines.count, 1)
        let response = try IPCWire.decodeResponse(from: XCTUnwrap(observation.lines.first))
        XCTAssertEqual(response.code, .invalidRequest)
    }

    func testProcessesUnterminatedRemainderAtEOF() async throws {
        let harness = try await makeHarness()

        var request = try requestLine(id: "eof-remainder")
        request.removeLast()
        try await harness.write(request)
        harness.closeWrites()
        let observation = try await harness.readUntilEOF()

        XCTAssertTrue(observation.sawEOF)
        XCTAssertEqual(observation.lines.count, 1)
        let response = try IPCWire.decodeResponse(from: XCTUnwrap(observation.lines.first))
        XCTAssertEqual(response.id, "eof-remainder")
        XCTAssertTrue(response.ok)
    }

    private func requestLine(id: String) throws -> Data {
        try IPCWire.encodeRequestLine(
            IPCRequest(
                id: id,
                kind: .ping,
                authorizationToken: "token"
            )
        )
    }

    private func makeHarness() async throws -> Harness {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw HarnessError.socketPairFailed(errno)
        }

        let serverHandle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peerHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let bridge = IPCApplicationBridge(
            controller: makeController(),
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
        let connection = IPCConnection(handle: serverHandle, bridge: bridge, onClose: { _ in })
        let harness = Harness(connection: connection, peerHandle: peerHandle)
        await connection.start()
        addTeardownBlock { @MainActor in
            await harness.stop()
        }
        return harness
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMIPCConnectionReadLoopTests-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    private final class Harness {
        struct ReadObservation: Sendable {
            let lines: [Data]
            let sawEOF: Bool
        }

        let connection: IPCConnection
        private let peerHandle: FileHandle

        init(connection: IPCConnection, peerHandle: FileHandle) {
            self.connection = connection
            self.peerHandle = peerHandle
        }

        func write(_ data: Data) async throws {
            let fileDescriptor = peerHandle.fileDescriptor
            try await Self.performBlocking {
                try Self.writeAll(data, to: fileDescriptor)
            }
        }

        func hasReadableBytes(timeoutMilliseconds: Int32) async throws -> Bool {
            let fileDescriptor = peerHandle.fileDescriptor
            return try await Self.performBlocking {
                try Self.pollReadable(fileDescriptor, timeoutMilliseconds: timeoutMilliseconds)
            }
        }

        func readResponseLine() async throws -> Data {
            try await readResponseLines(count: 1)[0]
        }

        func readResponseLines(count: Int) async throws -> [Data] {
            let fileDescriptor = peerHandle.fileDescriptor
            return try await Self.performBlocking {
                try Self.readLines(count: count, from: fileDescriptor)
            }
        }

        func readUntilEOF() async throws -> ReadObservation {
            let fileDescriptor = peerHandle.fileDescriptor
            return try await Self.performBlocking {
                try Self.readUntilEOF(from: fileDescriptor)
            }
        }

        func closeWrites() {
            shutdown(peerHandle.fileDescriptor, SHUT_WR)
        }

        func stop() async {
            await connection.stop()
            try? peerHandle.close()
        }

        private nonisolated static func performBlocking<T: Sendable>(
            _ operation: @escaping @Sendable () throws -> T
        ) async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try operation())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private nonisolated static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        fileDescriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw HarnessError.ioFailed(errno)
                    }
                }
            }
        }

        private nonisolated static func pollReadable(
            _ fileDescriptor: Int32,
            timeoutMilliseconds: Int32
        ) throws -> Bool {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            while true {
                let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
                if result > 0 {
                    return true
                }
                if result == 0 {
                    return false
                }
                if errno != EINTR {
                    throw HarnessError.ioFailed(errno)
                }
            }
        }

        private nonisolated static func readLines(count: Int, from fileDescriptor: Int32) throws -> [Data] {
            var lines: [Data] = []
            var currentLine = Data()
            while lines.count < count {
                let byte = try readByte(from: fileDescriptor)
                currentLine.append(byte)
                if byte == 0x0A {
                    lines.append(currentLine)
                    currentLine.removeAll(keepingCapacity: true)
                }
            }
            return lines
        }

        private nonisolated static func readUntilEOF(from fileDescriptor: Int32) throws -> ReadObservation {
            var lines: [Data] = []
            var currentLine = Data()
            while true {
                do {
                    let byte = try readByte(from: fileDescriptor)
                    currentLine.append(byte)
                    if byte == 0x0A {
                        lines.append(currentLine)
                        currentLine.removeAll(keepingCapacity: true)
                    }
                } catch HarnessError.closed {
                    return ReadObservation(lines: lines, sawEOF: true)
                }
            }
        }

        private nonisolated static func readByte(from fileDescriptor: Int32) throws -> UInt8 {
            while true {
                guard try pollReadable(fileDescriptor, timeoutMilliseconds: 30_000) else {
                    throw HarnessError.timedOut
                }
                var byte: UInt8 = 0
                let count = Darwin.read(fileDescriptor, &byte, 1)
                if count == 1 {
                    return byte
                }
                if count == 0 {
                    throw HarnessError.closed
                }
                if errno != EINTR {
                    throw HarnessError.ioFailed(errno)
                }
            }
        }
    }
}
