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

final class CLIConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: IPCClientConnection?

    func open(with environment: CLIRuntimeEnvironment) throws -> IPCClientConnection {
        let connection = try environment.openConnection()
        lock.lock()
        current = connection
        lock.unlock()
        return connection
    }

    func interruptCurrent() {
        lock.lock()
        let connection = current
        lock.unlock()
        connection?.interrupt()
    }

    func closeCurrent() {
        lock.lock()
        let connection = current
        current = nil
        lock.unlock()
        guard let connection else { return }
        connection.interrupt()
        Task {
            await connection.close()
        }
    }
}

struct CLIRuntimeEnvironment: Sendable {
    let openConnection: @Sendable () throws -> IPCClientConnection
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = CLIRuntimeEnvironment(
        openConnection: { try IPCClient().openConnection() },
        sleep: { try await Task.sleep(for: $0) }
    )
}

enum CLIRuntime {
    private enum WatchRuntimeError: Error {
        case childLaunch(Error)
    }

    private struct SubscriptionSession {
        let connection: IPCClientConnection
        let response: IPCResponse
    }

    private static let reconnectInitialDelay: Duration = .milliseconds(500)
    private static let reconnectMaximumDelay: Duration = .seconds(5)

    struct WatchChildResult: Sendable, Equatable {
        enum TerminationReason: Sendable, Equatable {
            case exit
            case uncaughtSignal
            case unknown
        }

        let terminationReason: TerminationReason
        let terminationStatus: Int32
    }

    static func run(arguments: [String], environment: CLIRuntimeEnvironment = .live) async -> Int32 {
        let outputFormat = CLIParser.outputFormat(arguments: arguments)

        do {
            let parsed = try CLIParser.parse(arguments: arguments)

            switch parsed.invocation {
            case let .local(action):
                CLIRenderer.write(try localActionOutput(action))
                return CLIExitCode.success.rawValue
            case let .remote(request):
                if case let .subscribe(subscription) = request.payload {
                    return await runSubscription(
                        request: request,
                        subscription: subscription,
                        parsed: parsed,
                        environment: environment
                    )
                }

                let connection = try environment.openConnection()
                defer {
                    Task {
                        await connection.close()
                    }
                }

                try await connection.send(request)
                let response = try await connection.readResponse()
                CLIRenderer.write(try CLIRenderer.responseOutput(response, format: parsed.outputFormat))
                return CLIRenderer.exitCode(for: response).rawValue
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

    private static func runSubscription(
        request: IPCRequest,
        subscription: IPCSubscribeRequest,
        parsed: ParsedCLICommand,
        environment: CLIRuntimeEnvironment
    ) async -> Int32 {
        let processState = CLIWatchProcessState()
        let connections = CLIConnectionBox()
        let outputFormat = parsed.outputFormat

        func openSession(sendInitial: Bool) async throws -> SubscriptionSession {
            let connection = try connections.open(with: environment)
            try await connection.send(IPCRequest(
                id: request.id,
                subscribe: IPCSubscribeRequest(
                    channels: subscription.channels,
                    allChannels: subscription.allChannels,
                    sendInitial: sendInitial
                )
            ))
            return SubscriptionSession(connection: connection, response: try await connection.readResponse())
        }

        func reconnectSession() async throws -> SubscriptionSession {
            var delay = reconnectInitialDelay
            while true {
                try await environment.sleep(delay)
                try Task.checkCancellation()
                delay = min(delay * 2, reconnectMaximumDelay)
                do {
                    return try await openSession(sendInitial: true)
                } catch let error where isTransportError(error) {
                    connections.closeCurrent()
                    writeNotice("omniwmctl: reconnect failed: \(error)")
                }
            }
        }

        func deliver(_ event: IPCEventEnvelope) async throws {
            guard let watchConfiguration = parsed.watchConfiguration else {
                CLIRenderer.write(try CLIRenderer.eventOutput(event, format: outputFormat))
                return
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

        return await withTaskCancellationHandler {
            defer {
                connections.closeCurrent()
            }
            do {
                var session = try await openSession(sendInitial: subscription.sendInitial)
                if !session.response.ok || parsed.watchConfiguration == nil {
                    CLIRenderer.write(try CLIRenderer.responseOutput(session.response, format: outputFormat))
                }
                guard session.response.ok else {
                    return CLIRenderer.exitCode(for: session.response).rawValue
                }

                while true {
                    do {
                        try await forwardEvents(from: session.connection, deliver: deliver)
                    } catch let error where parsed.reconnect && isTransportError(error) && !Task.isCancelled {
                        connections.closeCurrent()
                        writeNotice("omniwmctl: connection lost: \(error); reconnecting")
                        session = try await reconnectSession()
                        guard session.response.ok else {
                            CLIRenderer.write(try CLIRenderer.responseOutput(session.response, format: outputFormat))
                            return CLIRenderer.exitCode(for: session.response).rawValue
                        }
                        writeNotice("omniwmctl: reconnected")
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
            connections.interruptCurrent()
        }
    }

    private static func forwardEvents(
        from connection: IPCClientConnection,
        deliver: (IPCEventEnvelope) async throws -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard let event = try await connection.readEvent() else {
                throw POSIXError(.ECONNRESET)
            }
            try await deliver(event)
        }
    }

    private static func writeNotice(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
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
