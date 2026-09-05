// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
import OmniWMIPC

extension IPCConnection {
    func handleReadable() {
        guard !isClosed else { return }

        var chunk = [UInt8](repeating: 0, count: 4096)
        var consumed = 0
        while consumed < Self.readBudgetPerFiring {
            let count = Darwin.read(fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                readBuffer.append(contentsOf: chunk[0 ..< count])
                consumed += count
                continue
            }
            if count == 0 {
                inputFinished = true
                cancelReadSource()
                break
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            closeImmediately()
            return
        }

        drainRequests()
    }

    func drainRequests() {
        guard !isProcessing, !isClosed else { return }

        let line: String?
        do {
            line = try takeNextLine()
        } catch {
            handleFramingError(error)
            return
        }

        guard let line else {
            if inputFinished { beginGracefulClose() }
            return
        }

        isProcessing = true
        suspendReads()
        Task { [weak self] in
            guard let self else { return }
            await process(line)
            await finishProcessing()
        }
    }

    func finishProcessing() {
        isProcessing = false
        resumeReads()
        drainRequests()
    }

    func takeNextLine() throws -> String? {
        if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineByteCount = readBuffer.distance(from: readBuffer.startIndex, to: newlineIndex)
            guard lineByteCount <= Self.maxRequestLineBytes else {
                throw ReadLoopError.requestTooLarge
            }
            let line = try Self.decodeUTF8(readBuffer.span.extracting(first: lineByteCount))
            readBuffer.removeSubrange(...newlineIndex)
            return line
        }

        if readBuffer.count > Self.maxRequestLineBytes {
            throw ReadLoopError.requestTooLarge
        }

        guard inputFinished, !readBuffer.isEmpty else { return nil }
        let line = try Self.decodeUTF8(readBuffer.span)
        readBuffer.removeAll(keepingCapacity: true)
        return line
    }

    func handleFramingError(_ error: Error) {
        guard let readLoopError = error as? ReadLoopError else {
            closeImmediately()
            return
        }

        switch readLoopError {
        case .requestTooLarge:
            try? send(IPCResponse.failure(id: "", kind: .error, code: .invalidRequest))
            beginGracefulClose()
        }
    }

    func enqueue(_ data: Data) {
        guard !isClosed, !data.isEmpty else { return }
        pendingWrites.append(data)
        pendingWriteBytes += data.count

        switch flushOutbox() {
        case .drained:
            backlogStartedAt = nil
        case .failed:
            closeImmediately()
        case .wouldBlock:
            guard pendingWriteBytes <= limits.maxPendingWriteBytes else {
                closeImmediately()
                return
            }
            resumeWrites()
            if backlogStartedAt == nil {
                backlogStartedAt = .now()
                scheduleStallWatchdog()
            }
        }
    }

    func handleWritable() {
        guard !isClosed else { return }

        switch flushOutbox() {
        case .drained:
            backlogStartedAt = nil
            suspendWrites()
            if isClosing { finalizeClose() }
        case .wouldBlock:
            break
        case .failed:
            closeImmediately()
        }
    }

    func flushOutbox() -> FlushOutcome {
        while let head = pendingWrites.first {
            let remaining = head.count - pendingWriteOffset
            let written = head.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fileDescriptor, base.advanced(by: pendingWriteOffset), remaining)
            }

            if written > 0 {
                pendingWriteOffset += written
                pendingWriteBytes -= written
                if pendingWriteOffset >= head.count {
                    pendingWrites.removeFirst()
                    pendingWriteOffset = 0
                }
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            return .failed
        }
        return .drained
    }

    func scheduleStallWatchdog() {
        guard !stallWatchdogScheduled else { return }
        stallWatchdogScheduled = true
        ioQueue.asyncAfter(deadline: .now() + limits.writeStallTimeout) { [weak self] in
            self?.assumeIsolated { $0.checkWriteStall() }
        }
    }

    func checkWriteStall() {
        stallWatchdogScheduled = false
        guard !isClosed, let backlogStartedAt else { return }

        if DispatchTime.now() >= backlogStartedAt + limits.writeStallTimeout {
            closeImmediately()
        } else {
            scheduleStallWatchdog()
        }
    }

    func beginGracefulClose() {
        guard !isClosed, !isClosing else { return }
        isClosing = true
        cancelReadSource()
        if pendingWrites.isEmpty {
            finalizeClose()
        } else {
            resumeWrites()
        }
    }

    func closeImmediately() {
        guard !isClosed else { return }
        isClosing = true
        pendingWrites.removeAll()
        pendingWriteOffset = 0
        pendingWriteBytes = 0
        backlogStartedAt = nil
        finalizeClose()
    }

    func finalizeClose() {
        guard !isClosed else { return }
        isClosed = true

        let tasks = Array(eventTasks.values)
        eventTasks.removeAll()
        for task in tasks { task.cancel() }

        cancelReadSource()
        cancelWriteSource()

        if pendingSourceCancellations == 0 {
            try? handle.close()
        }
        notifyClosed()
    }

    func sourceDidCancel() {
        pendingSourceCancellations -= 1
        guard pendingSourceCancellations == 0, isClosed else { return }
        try? handle.close()
    }

    func suspendReads() {
        guard let readSource, !readsSuspended else { return }
        readsSuspended = true
        readSource.suspend()
    }

    func resumeReads() {
        guard let readSource, readsSuspended, !isClosed, !isClosing else { return }
        readsSuspended = false
        readSource.resume()
    }

    func cancelReadSource() {
        guard let source = readSource else { return }
        readSource = nil
        if readsSuspended {
            readsSuspended = false
            source.resume()
        }
        source.cancel()
    }

    func resumeWrites() {
        guard let writeSource, writesSuspended, !isClosed else { return }
        writesSuspended = false
        writeSource.resume()
    }

    func suspendWrites() {
        guard let writeSource, !writesSuspended else { return }
        writesSuspended = true
        writeSource.suspend()
    }

    func cancelWriteSource() {
        guard let source = writeSource else { return }
        writeSource = nil
        if writesSuspended {
            writesSuspended = false
            source.resume()
        }
        source.cancel()
    }
}
