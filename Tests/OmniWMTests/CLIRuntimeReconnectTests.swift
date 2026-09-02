// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CLIRuntimeReconnectTests: XCTestCase {
    func testSubscribeReconnectsAfterEOFWithBackoffAndResubscribesWithInitialSnapshots() async {
        let server = ScriptedIPCServer(steps: [
            .accept(events: 1),
            .refuse,
            .accept(events: 1),
            .reject(.unauthorized)
        ])

        let exitCode = await CLIRuntime.run(
            arguments: ["omniwmctl", "subscribe", "focus", "--no-send-initial", "--reconnect", "--format", "ndjson"],
            environment: server.environment
        )

        XCTAssertEqual(exitCode, CLIExitCode.rejected.rawValue)
        XCTAssertEqual(server.openAttempts, 4)
        XCTAssertEqual(server.sleeps, [.milliseconds(500), .seconds(1), .milliseconds(500)])
        XCTAssertEqual(server.receivedSubscriptions.map(\.sendInitial), [false, true, true])
        XCTAssertEqual(server.receivedSubscriptions.map(\.channels), [[.focus], [.focus], [.focus]])
    }

    func testSubscribeWithoutReconnectExitsTransportFailureAtEOF() async {
        let server = ScriptedIPCServer(steps: [.accept(events: 2)])

        let exitCode = await CLIRuntime.run(
            arguments: ["omniwmctl", "subscribe", "focus", "--format", "ndjson"],
            environment: server.environment
        )

        XCTAssertEqual(exitCode, CLIExitCode.transportFailure.rawValue)
        XCTAssertEqual(server.openAttempts, 1)
        XCTAssertTrue(server.sleeps.isEmpty)
    }

    func testReconnectNotAttemptedWhenInitialConnectFails() async {
        let server = ScriptedIPCServer(steps: [.refuse])

        let exitCode = await CLIRuntime.run(
            arguments: ["omniwmctl", "subscribe", "focus", "--reconnect", "--format", "ndjson"],
            environment: server.environment
        )

        XCTAssertEqual(exitCode, CLIExitCode.transportFailure.rawValue)
        XCTAssertEqual(server.openAttempts, 1)
        XCTAssertTrue(server.sleeps.isEmpty)
    }

    func testCancellationDuringReconnectBackoffExitsSuccessfully() async {
        let server = ScriptedIPCServer(steps: [.accept(events: 1), .refuse, .refuse, .refuse])
        let runtimeTask = LockedValue<Task<Int32, Never>?>(nil)
        server.onSleep = { count in
            if count == 2 {
                runtimeTask.value?.cancel()
            }
        }

        let task = Task {
            await CLIRuntime.run(
                arguments: ["omniwmctl", "subscribe", "focus", "--reconnect", "--format", "ndjson"],
                environment: server.environment
            )
        }
        runtimeTask.value = task
        let exitCode = await task.value

        XCTAssertEqual(exitCode, CLIExitCode.success.rawValue)
        XCTAssertEqual(server.openAttempts, 2)
        XCTAssertEqual(server.sleeps.count, 2)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class ScriptedIPCServer: @unchecked Sendable {
    enum Step: Sendable {
        case refuse
        case accept(events: Int)
        case reject(IPCErrorCode)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var attempts = 0
    private var subscriptions: [IPCSubscribeRequest] = []
    private var recordedSleeps: [Duration] = []
    var onSleep: (@Sendable (Int) -> Void)?

    init(steps: [Step]) {
        self.steps = steps
    }

    var openAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    var receivedSubscriptions: [IPCSubscribeRequest] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions
    }

    var sleeps: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps
    }

    var environment: CLIRuntimeEnvironment {
        CLIRuntimeEnvironment(
            openConnection: { try self.openConnection() },
            sleep: { duration in self.recordSleep(duration) }
        )
    }

    private func recordSleep(_ duration: Duration) {
        lock.lock()
        recordedSleeps.append(duration)
        let count = recordedSleeps.count
        lock.unlock()
        onSleep?(count)
    }

    private func openConnection() throws -> IPCClientConnection {
        lock.lock()
        attempts += 1
        let step = steps.isEmpty ? Step.refuse : steps.removeFirst()
        lock.unlock()

        switch step {
        case .refuse:
            throw POSIXError(.ECONNREFUSED)
        case let .accept(events):
            return try serve(failureCode: nil, events: events)
        case let .reject(code):
            return try serve(failureCode: code, events: 0)
        }
    }

    private func serve(failureCode: IPCErrorCode?, events: Int) throws -> IPCClientConnection {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw POSIXError(.EIO)
        }
        let serverDescriptor = sockets[1]
        DispatchQueue.global(qos: .userInitiated).async {
            self.handleSession(on: serverDescriptor, failureCode: failureCode, events: events)
        }
        return IPCClientConnection(
            handle: FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true),
            authorizationToken: nil
        )
    }

    private func handleSession(on descriptor: Int32, failureCode: IPCErrorCode?, events: Int) {
        defer { close(descriptor) }
        guard let line = Self.readLine(from: descriptor),
              let request = try? IPCWire.decodeRequest(from: line),
              case let .subscribe(subscription) = request.payload
        else { return }

        lock.lock()
        subscriptions.append(subscription)
        lock.unlock()

        let response = failureCode.map { IPCResponse.failure(id: request.id, kind: .subscribe, code: $0) }
            ?? IPCResponse.success(
                id: request.id,
                kind: .subscribe,
                status: .subscribed,
                result: IPCResult(subscribed: IPCSubscribeResult(channels: subscription.channels))
            )
        guard let responseLine = try? IPCWire.encodeResponseLine(response) else { return }
        Self.writeAll(responseLine, to: descriptor)

        for index in 0 ..< events {
            let event = IPCEventEnvelope.success(
                id: "event-\(index)",
                channel: .displayChanged,
                result: IPCResult(displays: IPCDisplaysQueryResult(displays: []))
            )
            guard let eventLine = try? IPCWire.encodeEventLine(event) else { return }
            Self.writeAll(eventLine, to: descriptor)
        }
    }

    private static func readLine(from descriptor: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptorState, 1, 10_000) > 0 else { return nil }
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else { return nil }
            if byte == 0x0A {
                return line
            }
            line.append(byte)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}
