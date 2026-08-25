// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
import OmniWMIPC

final class CLIWatchProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?

    func set(_ process: Process) {
        lock.lock()
        currentProcess = process
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if currentProcess === process {
            currentProcess = nil
        }
        lock.unlock()
    }

    func terminateCurrent() {
        lock.lock()
        let process = currentProcess
        lock.unlock()

        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

enum CLIRuntime {
    private enum WatchRuntimeError: Error {
        case childLaunch(Error)
    }

    struct WatchChildResult: Sendable, Equatable {
        enum TerminationReason: Sendable, Equatable {
            case exit
            case uncaughtSignal
            case unknown
        }

        let terminationReason: TerminationReason
        let terminationStatus: Int32
    }

    static func run(arguments: [String], client: IPCClient = IPCClient()) async -> Int32 {
        let outputFormat = CLIParser.outputFormat(arguments: arguments)

        do {
            let parsed = try CLIParser.parse(arguments: arguments)

            switch parsed.invocation {
            case let .local(action):
                CLIRenderer.write(try localActionOutput(action))
                return CLIExitCode.success.rawValue
            case let .remote(request):
                let connection = try client.openConnection()
                defer {
                    Task {
                        await connection.close()
                    }
                }

                if let watchConfiguration = parsed.watchConfiguration {
                    return await runWatch(
                        request: request,
                        watchConfiguration: watchConfiguration,
                        connection: connection,
                        outputFormat: parsed.outputFormat
                    )
                }

                try await connection.send(request)
                let response = try await connection.readResponse()
                let responseExitCode = CLIRenderer.exitCode(for: response)
                CLIRenderer.write(try CLIRenderer.responseOutput(response, format: parsed.outputFormat))

                guard parsed.expectsEventStream else {
                    return responseExitCode.rawValue
                }

                let events = await connection.eventStream()
                for try await event in events {
                    CLIRenderer.write(try CLIRenderer.eventOutput(event, format: parsed.outputFormat))
                }
                return responseExitCode.rawValue
            }
        } catch let error as CLIParseError {
            writeLocalFailure(
                try? CLIRenderer.parseErrorOutput(error, format: outputFormat),
                outputFormat: outputFormat,
                code: .invalidArguments,
                exitCode: .invalidArguments,
                fallbackMessage: CLIParser.usageText
            )
            return CLIExitCode.invalidArguments.rawValue
        } catch {
            if isTransportError(error) {
                writeLocalFailure(
                    try? CLIRenderer.transportErrorOutput(error, format: outputFormat),
                    outputFormat: outputFormat,
                    code: .transportFailure,
                    exitCode: .transportFailure,
                    fallbackMessage: "omniwmctl: \(error)"
                )
                return CLIExitCode.transportFailure.rawValue
            }

            writeLocalFailure(
                try? CLIRenderer.internalErrorOutput(error, format: outputFormat),
                outputFormat: outputFormat,
                code: .internalError,
                exitCode: .internalError,
                fallbackMessage: "omniwmctl: \(error)"
            )
            return CLIExitCode.internalError.rawValue
        }
    }

    private static func runWatch(
        request: IPCRequest,
        watchConfiguration: CLIWatchConfiguration,
        connection: IPCClientConnection,
        outputFormat: CLIOutputFormat
    ) async -> Int32 {
        let processState = CLIWatchProcessState()

        return await withTaskCancellationHandler {
            do {
                try await connection.send(request)
                let response = try await connection.readResponse()
                guard response.ok else {
                    CLIRenderer.write(try CLIRenderer.responseOutput(response, format: outputFormat))
                    return CLIRenderer.exitCode(for: response).rawValue
                }

                while true {
                    if Task.isCancelled {
                        return CLIExitCode.success.rawValue
                    }

                    guard let event = try await connection.readEvent() else {
                        throw POSIXError(.ECONNRESET)
                    }

                    do {
                        let result = try await executeWatchChild(
                            event: event,
                            childArguments: watchConfiguration.childArguments,
                            processState: processState
                        )
                        if result.terminationReason != .exit || result.terminationStatus != 0 {
                            reportWatchChildFailure(result: result, command: watchConfiguration.childArguments)
                        }
                    } catch {
                        throw WatchRuntimeError.childLaunch(error)
                    }
                }
            } catch is CancellationError {
                return CLIExitCode.success.rawValue
            } catch let error as WatchRuntimeError {
                if Task.isCancelled {
                    return CLIExitCode.success.rawValue
                }

                switch error {
                case let .childLaunch(underlying):
                    writeLocalFailure(
                        try? CLIRenderer.internalErrorOutput(underlying, format: outputFormat),
                        outputFormat: outputFormat,
                        code: .internalError,
                        exitCode: .internalError,
                        fallbackMessage: "omniwmctl: \(underlying)"
                    )
                    return CLIExitCode.internalError.rawValue
                }
            } catch {
                if Task.isCancelled {
                    return CLIExitCode.success.rawValue
                }

                if isTransportError(error) {
                    writeLocalFailure(
                        try? CLIRenderer.transportErrorOutput(error, format: outputFormat),
                        outputFormat: outputFormat,
                        code: .transportFailure,
                        exitCode: .transportFailure,
                        fallbackMessage: "omniwmctl: \(error)"
                    )
                    return CLIExitCode.transportFailure.rawValue
                }

                writeLocalFailure(
                    try? CLIRenderer.internalErrorOutput(error, format: outputFormat),
                    outputFormat: outputFormat,
                    code: .internalError,
                    exitCode: .internalError,
                    fallbackMessage: "omniwmctl: \(error)"
                )
                return CLIExitCode.internalError.rawValue
            }
        } onCancel: {
            processState.terminateCurrent()
            connection.interrupt()
            Task {
                await connection.close()
            }
        }
    }

    private static func executeWatchChild(
        event: IPCEventEnvelope,
        childArguments: [String],
        processState: CLIWatchProcessState
    ) async throws -> WatchChildResult {
        return try await defaultWatchChildRunner(
            event: event,
            childArguments: childArguments,
            processState: processState
        )
    }

    private static func defaultWatchChildRunner(
        event: IPCEventEnvelope,
        childArguments: [String],
        processState: CLIWatchProcessState
    ) async throws -> WatchChildResult {
        guard let executableName = childArguments.first else {
            throw POSIXError(.EINVAL)
        }

        let process = Process()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.executableURL = URL(fileURLWithPath: try resolveExecutablePath(named: executableName))
        process.arguments = Array(childArguments.dropFirst())
        process.environment = childEnvironment(for: event)

        try process.run()
        processState.set(process)
        defer {
            processState.clear(process)
        }

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: IPCWire.encodeEventLine(event))
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            _ = await waitForTermination(of: process)
            process.terminationHandler = nil
            processState.clear(process)
            throw error
        }

        let result = await waitForTermination(of: process)
        process.terminationHandler = nil
        processState.clear(process)
        return result
    }

    private static func waitForTermination(of process: Process) async -> WatchChildResult {
        await withCheckedContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                private let lock = NSLock()
                private var didResume = false
                private let continuation: CheckedContinuation<WatchChildResult, Never>

                init(continuation: CheckedContinuation<WatchChildResult, Never>) {
                    self.continuation = continuation
                }

                func resumeIfNeeded(with result: WatchChildResult) {
                    lock.lock()
                    let shouldResume = !didResume
                    didResume = true
                    lock.unlock()

                    guard shouldResume else { return }
                    continuation.resume(returning: result)
                }
            }

            let state = ResumeState(continuation: continuation)

            process.terminationHandler = { terminatedProcess in
                state.resumeIfNeeded(
                    with: WatchChildResult(
                        terminationReason: terminationReason(for: terminatedProcess.terminationReason),
                        terminationStatus: terminatedProcess.terminationStatus
                    )
                )
            }

            if !process.isRunning {
                state.resumeIfNeeded(
                    with: WatchChildResult(
                        terminationReason: terminationReason(for: process.terminationReason),
                        terminationStatus: process.terminationStatus
                    )
                )
            }
        }
    }

    private static func terminationReason(for reason: Process.TerminationReason) -> WatchChildResult.TerminationReason {
        switch reason {
        case .exit:
            return .exit
        case .uncaughtSignal:
            return .uncaughtSignal
        @unknown default:
            return .unknown
        }
    }

    private static func childEnvironment(for event: IPCEventEnvelope) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIWM_EVENT_CHANNEL"] = event.channel.rawValue
        environment["OMNIWM_EVENT_KIND"] = event.result.kind.rawValue
        environment["OMNIWM_EVENT_ID"] = event.id
        return environment
    }

    private static func resolveExecutablePath(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if executableName.contains("/") {
            return executableName
        }

        let pathValue = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(executableName)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw POSIXError(.ENOENT)
    }

    private static func reportWatchChildFailure(result: WatchChildResult, command: [String]) {
        let commandText = command.joined(separator: " ")
        let message: String

        switch result.terminationReason {
        case .exit:
            message = "omniwmctl watch: child exited with status \(result.terminationStatus): \(commandText)\n"
        case .uncaughtSignal:
            message = "omniwmctl watch: child terminated by signal \(result.terminationStatus): \(commandText)\n"
        case .unknown:
            message = "omniwmctl watch: child terminated unexpectedly: \(commandText)\n"
        }

        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func localActionOutput(_ action: CLILocalAction) throws -> CLIRenderedOutput {
        let text: String

        switch action {
        case .help:
            text = CLIParser.usageText
        case let .completion(shell):
            text = CLICompletionGenerator.script(for: shell)
        }

        let terminated = text.hasSuffix("\n") ? text : text + "\n"
        return CLIRenderedOutput(data: Data(terminated.utf8), destination: .standardOutput)
    }

    private static func writeLocalFailure(
        _ rendered: CLIRenderedOutput?,
        outputFormat: CLIOutputFormat,
        code: CLILocalErrorCode,
        exitCode: CLIExitCode,
        fallbackMessage: String
    ) {
        if let rendered {
            CLIRenderer.write(rendered)
            return
        }

        if outputFormat.prefersJSON {
            FileHandle.standardOutput.write(
                minimalJSONFailure(code: code, exitCode: exitCode, message: fallbackMessage)
            )
            return
        }

        let text = fallbackMessage.hasSuffix("\n") ? fallbackMessage : fallbackMessage + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func isTransportError(_ error: Error) -> Bool {
        if error is POSIXError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
    }

    private static func minimalJSONFailure(
        code: CLILocalErrorCode,
        exitCode: CLIExitCode,
        message: String
    ) -> Data {
        let escapedMessage = jsonEscaped(message)
        let json = """
        {
          "code" : "\(code.rawValue)",
          "exitCode" : \(exitCode.rawValue),
          "message" : "\(escapedMessage)",
          "ok" : false,
          "source" : "cli",
          "status" : "error"
        }
        """
        return Data((json + "\n").utf8)
    }

    private static func jsonEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
