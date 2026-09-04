// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IPCConnectionConcurrencyTests: XCTestCase {
    private enum HarnessError: Error {
        case socketPairFailed(Int32)
        case ioFailed(Int32)
    }

    final class CloseSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var closedCount = 0

        func markClosed() {
            lock.lock()
            closedCount += 1
            lock.unlock()
        }

        var didClose: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closedCount > 0
        }
    }

    private struct Peer {
        let connection: IPCConnection
        let peerDescriptor: Int32
        let signal: CloseSignal
    }

    func testConnectionsBeyondCoreCountStayResponsive() async throws {
        let connectionCount = ProcessInfo.processInfo.activeProcessorCount * 2 + 4
        var peers: [Peer] = []
        for _ in 0 ..< connectionCount {
            peers.append(try await makePeer())
        }

        XCTAssertEqual(peers.count, connectionCount)

        for index in [0, connectionCount / 2, connectionCount - 1] {
            let peer = peers[index]
            try await writeRequest(id: "probe-\(index)", to: peer.peerDescriptor)
            let readable = try await pollReadable(peer.peerDescriptor, timeoutMilliseconds: 2_000)
            XCTAssertTrue(
                readable,
                "connection \(index) of \(connectionCount) did not answer within 2s"
            )
        }
    }

    func testDisconnectedSubscriberDoesNotRetainStreams() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw HarnessError.socketPairFailed(errno)
        }

        let peerHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        defer { try? peerHandle.close() }
        let controller = makeController()
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
        let connection = IPCConnection(
            handle: FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
            bridge: bridge,
            onClose: { _ in }
        )
        let line = try IPCWire.encodeRequestLine(
            IPCRequest(
                id: "subscribe-then-close",
                subscribe: IPCSubscribeRequest(channels: [.displayChanged], sendInitial: false),
                authorizationToken: "token"
            )
        )
        try peerHandle.close()

        await connection.process(String(decoding: line, as: UTF8.self))

        let isClosed = await connection.isClosed
        let hasEventTasks = await !connection.eventTasks.isEmpty
        XCTAssertTrue(isClosed)
        XCTAssertFalse(hasEventTasks)
        XCTAssertFalse(bridge.hasSubscribers(for: .displayChanged))

        await connection.stop()
        await bridge.shutdown()
        withExtendedLifetime(controller) {}
    }

    func testStalledClientIsEvictedOnOutboxBound() async throws {
        let peer = try await makePeer(
            limits: IPCConnection.Limits(
                maxPendingWriteBytes: 16 * 1024,
                writeStallTimeout: .seconds(30)
            ),
            socketBufferBytes: 4096
        )
        let healthy = try await makePeer()

        try await floodRequests(count: 600, to: peer.peerDescriptor)

        let evicted = await waitForClose(peer.signal, timeout: 5.0)
        XCTAssertTrue(evicted, "a client that never reads should be evicted once its outbox passes the bound")

        try await writeRequest(id: "healthy", to: healthy.peerDescriptor)
        let readable = try await pollReadable(healthy.peerDescriptor, timeoutMilliseconds: 2_000)
        XCTAssertTrue(readable, "a stalled client must not block an unrelated connection")
        XCTAssertFalse(healthy.signal.didClose)
    }

    func testStalledClientIsEvictedOnWriteTimeout() async throws {
        let peer = try await makePeer(
            limits: IPCConnection.Limits(
                maxPendingWriteBytes: 8 * 1024 * 1024,
                writeStallTimeout: .milliseconds(200)
            ),
            socketBufferBytes: 4096
        )

        try await floodRequests(count: 600, to: peer.peerDescriptor)

        let evicted = await waitForClose(peer.signal, timeout: 5.0)
        XCTAssertTrue(evicted, "a backlogged outbox should be evicted once the stall timeout elapses")
    }

    private func waitForClose(_ signal: CloseSignal, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if signal.didClose { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return signal.didClose
    }

    private func makePeer(
        limits: IPCConnection.Limits = .default,
        socketBufferBytes: Int32? = nil
    ) async throws -> Peer {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw HarnessError.socketPairFailed(errno)
        }

        if let socketBufferBytes {
            for descriptor in descriptors {
                var value = socketBufferBytes
                _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &value, socklen_t(MemoryLayout<Int32>.size))
                _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &value, socklen_t(MemoryLayout<Int32>.size))
            }
        }

        var noSigPipe: Int32 = 1
        _ = setsockopt(
            descriptors[1],
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let serverHandle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let signal = CloseSignal()
        let bridge = IPCApplicationBridge(
            controller: makeController(),
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
        let connection = IPCConnection(
            handle: serverHandle,
            bridge: bridge,
            limits: limits,
            onClose: { _ in signal.markClosed() }
        )
        await connection.start()

        let peerDescriptor = descriptors[1]
        addTeardownBlock { @MainActor in
            await connection.stop()
            close(peerDescriptor)
        }
        return Peer(connection: connection, peerDescriptor: peerDescriptor, signal: signal)
    }

    private func writeRequest(id: String, to descriptor: Int32) async throws {
        let line = try IPCWire.encodeRequestLine(
            IPCRequest(id: id, kind: .ping, authorizationToken: "token")
        )
        try await Self.performBlocking { try Self.writeAll(line, to: descriptor) }
    }

    private func floodRequests(count: Int, to descriptor: Int32) async throws {
        let payload = try Self.makeFloodPayload(count: count)
        try? await Self.performBlocking { try Self.writeAll(payload, to: descriptor) }
    }

    private nonisolated static func makeFloodPayload(count: Int) throws -> Data {
        var payload = Data()
        for index in 0 ..< count {
            payload.append(
                try IPCWire.encodeRequestLine(
                    IPCRequest(id: "flood-\(index)", kind: .ping, authorizationToken: "token")
                )
            )
        }
        return payload
    }

    private func pollReadable(_ descriptor: Int32, timeoutMilliseconds: Int32) async throws -> Bool {
        try await Self.performBlocking { try Self.pollReadableBlocking(
            descriptor,
            timeoutMilliseconds: timeoutMilliseconds
        ) }
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

    private nonisolated static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
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

    private nonisolated static func pollReadableBlocking(
        _ descriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws -> Bool {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let result = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
            if result > 0 { return true }
            if result == 0 { return false }
            if errno != EINTR { throw HarnessError.ioFailed(errno) }
        }
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMIPCConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
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
