// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
import OmniWMIPC

actor IPCConnection {
    enum ReadLoopError: Error {
        case requestTooLarge
    }

    struct Limits: Sendable {
        var maxPendingWriteBytes: Int
        var writeStallTimeout: DispatchTimeInterval

        init(maxPendingWriteBytes: Int = 1 << 20, writeStallTimeout: DispatchTimeInterval = .seconds(5)) {
            self.maxPendingWriteBytes = maxPendingWriteBytes
            self.writeStallTimeout = writeStallTimeout
        }

        static let `default` = Limits()
    }

    enum FlushOutcome {
        case drained
        case wouldBlock
        case failed
    }

    static let maxRequestLineBytes = 64 * 1024
    static let readBudgetPerFiring = 64 * 1024

    nonisolated let id = UUID()

    let ioQueue = DispatchSerialQueue(
        label: "com.barut.OmniWM.ipc.connection",
        qos: .userInitiated
    )

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioQueue.asUnownedSerialExecutor()
    }

    let handle: FileHandle
    let fileDescriptor: Int32
    let limits: Limits
    private let bridge: IPCApplicationBridge
    private let onClose: @Sendable (UUID) -> Void

    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var readsSuspended = false
    var writesSuspended = true
    var pendingSourceCancellations = 0

    var readBuffer = Data()
    var pendingWrites: [Data] = []
    var pendingWriteOffset = 0
    var pendingWriteBytes = 0
    var backlogStartedAt: DispatchTime?
    var stallWatchdogScheduled = false

    var eventTasks: [IPCSubscriptionChannel: Task<Void, Never>] = [:]
    var isProcessing = false
    var inputFinished = false
    var isClosing = false
    var isClosed = false

    init(
        handle: FileHandle,
        bridge: IPCApplicationBridge,
        limits: Limits = .default,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.handle = handle
        fileDescriptor = handle.fileDescriptor
        self.bridge = bridge
        self.limits = limits
        self.onClose = onClose
        IPCServer.configureSocket(fileDescriptor, nonBlocking: true)
    }

    func start() {
        guard readSource == nil, !isClosed else { return }

        let read = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: ioQueue)
        read.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.handleReadable() }
        }
        read.setCancelHandler { [self] in
            assumeIsolated { $0.sourceDidCancel() }
        }

        let write = DispatchSource.makeWriteSource(fileDescriptor: fileDescriptor, queue: ioQueue)
        write.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.handleWritable() }
        }
        write.setCancelHandler { [self] in
            assumeIsolated { $0.sourceDidCancel() }
        }

        readSource = read
        writeSource = write
        pendingSourceCancellations = 2
        readsSuspended = false
        writesSuspended = true
        read.resume()

        drainRequests()
    }

    func stop() {
        closeImmediately()
    }

    func notifyClosed() {
        onClose(id)
    }

    func process(_ line: String) async {
        let data = Data(line.utf8)

        if let envelope = IPCWire.decodeRequestEnvelope(from: data),
           envelope.version != OmniWMIPCProtocol.version
        {
            let response = await bridge.mismatchResponse(for: envelope)
            do {
                try send(response)
            } catch {
                closeImmediately()
            }
            return
        }

        var pendingRegistrations: [IPCEventStreamRegistration] = []
        do {
            let request = try IPCWire.decodeRequest(from: data)
            let response = await bridge.response(for: request)

            guard response.ok,
                  case let .subscribe(subscribeRequest) = request.payload
            else {
                try send(response)
                return
            }

            let channels = IPCAutomationManifest.expandedChannels(for: subscribeRequest)
            let newChannels = channels.filter { eventTasks[$0] == nil }

            pendingRegistrations.reserveCapacity(newChannels.count)
            for channel in newChannels {
                let registration = await bridge.registerStream(for: channel)
                pendingRegistrations.append(registration)
            }

            let initialEvents = subscribeRequest.sendInitial
                ? await bridge.initialEvents(for: newChannels)
                : []

            try send(response)

            for event in initialEvents {
                try send(event)
            }

            for registration in pendingRegistrations {
                let task = Task(priority: .utility) {
                    for await event in registration.stream {
                        do {
                            try self.send(event)
                        } catch {
                            self.stop()
                            return
                        }
                    }
                }
                eventTasks[registration.channel] = task
            }
        } catch {
            for registration in pendingRegistrations {
                await bridge.unregisterStream(registration)
            }
            do {
                try send(IPCResponse.failure(id: "", kind: .error, code: .invalidRequest))
            } catch {
                closeImmediately()
            }
        }
    }

    func send(_ response: IPCResponse) throws {
        guard !isClosed else { throw POSIXError(.ECANCELED) }
        enqueue(try IPCWire.encodeResponseLine(response))
        guard !isClosed else { throw POSIXError(.ECANCELED) }
    }

    func send(_ event: IPCEventEnvelope) throws {
        guard !isClosed else { throw POSIXError(.ECANCELED) }
        enqueue(try IPCWire.encodeEventLine(event))
        guard !isClosed else { throw POSIXError(.ECANCELED) }
    }

    nonisolated static func decodeUTF8(_ bytes: Span<UInt8>) throws -> String {
        do {
            return String(copying: try UTF8Span(validating: bytes))
        } catch {
            throw POSIXError(.EINVAL)
        }
    }
}
