// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation

enum WorkspaceBarAssetCatalogProcessRunner {
    private final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private var isComplete = false
        private var process: Process?
        private var outputHandle: FileHandle?
        private var outputURL: URL?
        private var continuation: CheckedContinuation<Data?, Never>?

        func start(
            process: Process,
            outputHandle: FileHandle,
            outputURL: URL,
            continuation: CheckedContinuation<Data?, Never>
        ) {
            lock.lock()
            guard !isComplete else {
                lock.unlock()
                closeAndRemove(outputHandle: outputHandle, outputURL: outputURL)
                continuation.resume(returning: nil)
                return
            }

            self.process = process
            self.outputHandle = outputHandle
            self.outputURL = outputURL
            self.continuation = continuation

            do {
                try process.run()
                lock.unlock()
            } catch {
                isComplete = true
                self.process = nil
                self.outputHandle = nil
                self.outputURL = nil
                self.continuation = nil
                lock.unlock()
                closeAndRemove(outputHandle: outputHandle, outputURL: outputURL)
                continuation.resume(returning: nil)
            }
        }

        func finish(process: Process) {
            lock.lock()
            guard !isComplete else {
                lock.unlock()
                return
            }

            isComplete = true
            let outputHandle = self.outputHandle
            let outputURL = self.outputURL
            let continuation = self.continuation
            self.process = nil
            self.outputHandle = nil
            self.outputURL = nil
            self.continuation = nil
            lock.unlock()

            if let outputHandle {
                try? outputHandle.close()
            }
            let data: Data?
            if process.terminationReason == .exit,
               process.terminationStatus == 0,
               let outputURL
            {
                data = try? Data(contentsOf: outputURL)
            } else {
                data = nil
            }
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation?.resume(returning: data)
        }

        func stop() {
            lock.lock()
            guard !isComplete else {
                lock.unlock()
                return
            }

            isComplete = true
            let process = self.process
            let outputHandle = self.outputHandle
            let outputURL = self.outputURL
            let continuation = self.continuation
            self.process = nil
            self.outputHandle = nil
            self.outputURL = nil
            self.continuation = nil
            lock.unlock()

            if let process, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            if let outputHandle, let outputURL {
                closeAndRemove(outputHandle: outputHandle, outputURL: outputURL)
            }
            continuation?.resume(returning: nil)
        }

        private func closeAndRemove(
            outputHandle: FileHandle,
            outputURL: URL
        ) {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async -> Data? {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "omniwm-assetutil-\(UUID().uuidString).json"
        )
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil
        ) else {
            return nil
        }

        let outputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice

        let invocation = Invocation()
        process.terminationHandler = { process in
            invocation.finish(process: process)
        }

        return await withTaskCancellationHandler {
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                invocation.stop()
            }
            let data = await withCheckedContinuation { continuation in
                invocation.start(
                    process: process,
                    outputHandle: outputHandle,
                    outputURL: outputURL,
                    continuation: continuation
                )
            }
            timeoutTask.cancel()
            return data
        } onCancel: {
            invocation.stop()
        }
    }
}
