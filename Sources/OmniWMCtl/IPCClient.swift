// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
import OmniWMIPC

struct IPCClient {
    let socketPath: String
    let authorizationToken: String?
    let fileManager: FileManager

    init(
        socketPath: String = IPCSocketPath.resolvedPath(),
        authorizationToken: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.socketPath = socketPath
        self.authorizationToken = authorizationToken
        self.fileManager = fileManager
    }

    func openConnection() throws -> IPCClientConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        configureSocket(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let utf8Path = Array(socketPath.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard utf8Path.count < pathCapacity else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8Path.enumerated() {
                buffer[index] = byte
            }
        }

        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(fd, pointer, addressLength)
            }
        }

        guard result == 0 else {
            let error = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
            close(fd)
            throw POSIXError(error)
        }

        return IPCClientConnection(
            handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true),
            authorizationToken: resolvedAuthorizationToken()
        )
    }

    private func configureSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
    }

    private func resolvedAuthorizationToken() -> String? {
        if let authorizationToken {
            return authorizationToken
        }

        let secretPath = IPCSocketPath.secretPath(forSocketPath: socketPath)
        guard let data = fileManager.contents(atPath: secretPath),
              let token = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }
}

actor IPCClientConnection {
    private let handle: FileHandle
    private let fileDescriptor: Int32
    private let authorizationToken: String?
    private var readBuffer = Data()

    init(handle: FileHandle, authorizationToken: String?) {
        self.handle = handle
        self.fileDescriptor = handle.fileDescriptor
        self.authorizationToken = authorizationToken
    }

    func send(_ request: IPCRequest) throws {
        try handle.write(contentsOf: IPCWire.encodeRequestLine(request.authorizing(with: authorizationToken)))
    }

    func readResponse() throws -> IPCResponse {
        guard let line = try readNextLine() else {
            throw POSIXError(.ECONNRESET)
        }
        return try IPCWire.decodeResponse(from: Data(line.utf8))
    }

    func readEvent() throws -> IPCEventEnvelope? {
        guard let line = try readNextLine() else {
            return nil
        }
        return try IPCWire.decodeEvent(from: Data(line.utf8))
    }

    func close() {
        interrupt()
        try? handle.close()
    }

    nonisolated func interrupt() {
        _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }

    private func readNextLine() throws -> String? {
        while true {
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let lineData = readBuffer.prefix(upTo: newlineIndex)
                readBuffer.removeSubrange(...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw POSIXError(.EINVAL)
                }
                return line
            }

            guard let chunk = try readChunk(), !chunk.isEmpty else {
                guard !readBuffer.isEmpty else { return nil }
                let remaining = readBuffer
                readBuffer.removeAll()
                guard let line = String(data: remaining, encoding: .utf8) else {
                    throw POSIXError(.EINVAL)
                }
                return line
            }

            readBuffer.append(chunk)
        }
    }

    private func readChunk() throws -> Data? {
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
}
