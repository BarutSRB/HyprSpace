// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

actor IPCConnection {
    private enum ReadLoopError: Error {
        case requestTooLarge
    }

    static let maxRequestLineBytes = 64 * 1024

    nonisolated let id = UUID()

    private let handle: FileHandle
    private let bridge: IPCApplicationBridge
    private let onClose: @Sendable (UUID) -> Void
    private var readTask: Task<Void, Never>?
    private var eventTasks: [IPCSubscriptionChannel: Task<Void, Never>] = [:]
    private var isClosed = false

    init(
        handle: FileHandle,
        bridge: IPCApplicationBridge,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.handle = handle
        self.bridge = bridge
        self.onClose = onClose
    }

    func start() {
        guard readTask == nil else { return }
        let fileDescriptor = handle.fileDescriptor
        readTask = Task(priority: .userInitiated) {
            await Self.runReadLoop(fileDescriptor: fileDescriptor, owner: self)
        }
    }

    func stop() {
        closeIfNeeded()
    }

    private nonisolated static func runReadLoop(fileDescriptor: Int32, owner: IPCConnection) async {
        var readBuffer = Data()
        do {
            while let line = try readNextLine(from: fileDescriptor, buffer: &readBuffer) {
                if Task.isCancelled {
                    break
                }
                await owner.process(line)
            }
        } catch {
            await owner.handleReadLoopError(error)
        }

        await owner.finishReadLoop()
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
                closeIfNeeded()
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
                closeIfNeeded()
            }
        }
    }

    private func handleReadLoopError(_ error: Error) {
        guard let readLoopError = error as? ReadLoopError else {
            return
        }

        switch readLoopError {
        case .requestTooLarge:
            try? send(IPCResponse.failure(id: "", kind: .error, code: .invalidRequest))
        }
    }

    private func send(_ response: IPCResponse) throws {
        guard !isClosed else { throw POSIXError(.ECANCELED) }
        try handle.write(contentsOf: IPCWire.encodeResponseLine(response))
    }

    private func send(_ event: IPCEventEnvelope) throws {
        guard !isClosed else { throw POSIXError(.ECANCELED) }
        try handle.write(contentsOf: IPCWire.encodeEventLine(event))
    }

    private func finishReadLoop() {
        closeIfNeeded()
    }

    private nonisolated static func readNextLine(from fileDescriptor: Int32, buffer: inout Data) throws -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineByteCount = buffer.distance(from: buffer.startIndex, to: newlineIndex)
                guard lineByteCount <= maxRequestLineBytes else {
                    throw ReadLoopError.requestTooLarge
                }
                let line = try decodeUTF8(buffer.span.extracting(first: lineByteCount))
                buffer.removeSubrange(...newlineIndex)
                return line
            }

            guard let chunk = try readChunk(from: fileDescriptor), !chunk.isEmpty else {
                guard !buffer.isEmpty else { return nil }
                let line = try decodeUTF8(buffer.span)
                buffer.removeAll(keepingCapacity: true)
                return line
            }

            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                guard newlineIndex <= maxRequestLineBytes else {
                    throw ReadLoopError.requestTooLarge
                }
                continue
            }

            if buffer.count > maxRequestLineBytes {
                throw ReadLoopError.requestTooLarge
            }
        }
    }

    private nonisolated static func decodeUTF8(_ bytes: Span<UInt8>) throws -> String {
        do {
            return String(copying: try UTF8Span(validating: bytes))
        } catch {
            throw POSIXError(.EINVAL)
        }
    }

    private nonisolated static func readChunk(from fileDescriptor: Int32) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                return Data(buffer[0 ..< count])
            }
            if count == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            let error = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(error)
        }
    }

    private func closeIfNeeded() {
        guard !isClosed else { return }
        isClosed = true

        let tasks = Array(eventTasks.values)
        eventTasks.removeAll()

        let currentReadTask = readTask
        readTask = nil
        currentReadTask?.cancel()

        for task in tasks {
            task.cancel()
        }

        try? handle.close()
        onClose(id)
    }
}
