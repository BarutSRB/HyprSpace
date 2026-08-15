// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
import OmniWMIPC

struct OwnedFileDescriptor: ~Copyable {
    let rawValue: Int32

    deinit {
        Darwin.close(rawValue)
    }

    consuming func relinquish() -> Int32 {
        let descriptor = rawValue
        discard self
        return descriptor
    }
}

protocol IPCServerLifecycle: AnyObject {
    @MainActor func start() throws
    @MainActor func stop()
}

actor IPCConnectionRegistry {
    private var connections: [UUID: IPCConnection] = [:]

    func insert(_ connection: IPCConnection) {
        connections[connection.id] = connection
    }

    func remove(id: UUID) {
        connections.removeValue(forKey: id)
    }

    func stopAll() async {
        let currentConnections = Array(connections.values)
        connections.removeAll()
        for connection in currentConnections {
            await connection.stop()
        }
    }
}

final class IPCServer: IPCServerLifecycle {
    let socketPath: String

    private let controller: WMController
    private let bridge: IPCApplicationBridge
    private let authorizationToken: String
    private let connectionRegistry = IPCConnectionRegistry()
    private let queue = DispatchQueue(label: "com.barut.OmniWM.ipc.server")
    private let fileManager: FileManager
    private var listenSocket: OwnedFileDescriptor?
    private var acceptSource: DispatchSourceRead?

    @MainActor
    init(
        controller: WMController,
        socketPath: String = IPCSocketPath.resolvedPath(),
        fileManager: FileManager = .default,
        versionProvider: @escaping () -> String? = { Bundle.main.appVersion },
        sessionToken: String = UUID().uuidString,
        authorizationToken: String = UUID().uuidString
    ) {
        self.controller = controller
        self.socketPath = socketPath
        self.fileManager = fileManager
        self.authorizationToken = authorizationToken
        bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: versionProvider(),
            sessionToken: sessionToken,
            authorizationToken: authorizationToken
        )
    }

    @MainActor
    func start() throws {
        try ensureSocketDirectoryExists()
        try Self.removeExistingSocketIfNeeded(at: socketPath)
        try removeExistingSecretIfNeeded()

        var bindError: Error?
        queue.sync {
            do {
                let listeningSocket = try Self.makeListeningSocket(at: socketPath)
                let fd = listeningSocket.rawValue
                listenSocket = consume listeningSocket

                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler(handler: makeAcceptSourceHandler())
                acceptSource = source
                source.resume()
            } catch {
                bindError = error
            }
        }

        if let bindError {
            stop()
            throw bindError
        }

        do {
            try writeAuthorizationToken()
        } catch {
            stop()
            throw error
        }
        controller.ipcApplicationBridge = bridge
    }

    @MainActor
    func stop() {
        if controller.ipcApplicationBridge === bridge {
            controller.ipcApplicationBridge = nil
        }
        let bridge = self.bridge
        let connectionRegistry = self.connectionRegistry
        Task {
            await bridge.shutdown()
            await connectionRegistry.stopAll()
        }

        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            listenSocket = nil

            _ = unlink(socketPath)
            _ = unlink(secretPath)
        }
    }

    private func makeAcceptSourceHandler() -> () -> Void {
        { [weak self] in
            self?.acceptConnections()
        }
    }

    private func acceptConnections() {
        guard let listenFD = listenSocket?.rawValue else { return }

        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                return
            }

            let clientSocket = OwnedFileDescriptor(rawValue: clientFD)
            let authorized = Self.isCurrentUser(clientSocket.rawValue)
            guard let handle = Self.makeConnectionHandle(
                from: clientSocket,
                authorized: authorized
            ) else { continue }
            let connectionRegistry = self.connectionRegistry
            let bridge = self.bridge
            Task {
                let connection = IPCConnection(
                    handle: handle,
                    bridge: bridge,
                    onClose: { id in
                        Task {
                            await connectionRegistry.remove(id: id)
                        }
                    }
                )

                await connectionRegistry.insert(connection)
                await connection.start()
            }
        }
    }

    @MainActor
    private func ensureSocketDirectoryExists() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    @MainActor
    private func removeExistingSecretIfNeeded() throws {
        guard fileManager.fileExists(atPath: secretPath) else { return }
        try fileManager.removeItem(atPath: secretPath)
    }

    @MainActor
    private func writeAuthorizationToken() throws {
        let data = Data((authorizationToken + "\n").utf8)
        guard fileManager.createFile(atPath: secretPath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw POSIXError(.EIO)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretPath)
    }

    private static func removeExistingSocketIfNeeded(at path: String) throws {
        var fileStatus = stat()
        if lstat(path, &fileStatus) != 0 {
            if errno == ENOENT {
                return
            }
            let error = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(error)
        }

        let fileType = fileStatus.st_mode & S_IFMT
        guard fileType == S_IFSOCK else {
            throw POSIXError(.EEXIST)
        }

        if try isActiveSocket(at: path) {
            throw POSIXError(.EADDRINUSE)
        }

        guard unlink(path) == 0 else {
            let error = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(error)
        }
    }

    static func isActiveSocket(at path: String) throws -> Bool {
        let rawDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard rawDescriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        let socket = OwnedFileDescriptor(rawValue: rawDescriptor)

        var address = try socketAddress(for: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(socket.rawValue, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result == 0 {
            return true
        }

        let error = POSIXErrorCode(rawValue: errno) ?? .EIO
        switch error {
        case .ECONNREFUSED,
             .ENOENT:
            return false
        default:
            throw POSIXError(error)
        }
    }

    static func makeListeningSocket(at path: String) throws -> OwnedFileDescriptor {
        let rawDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard rawDescriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        let socket = OwnedFileDescriptor(rawValue: rawDescriptor)

        configureSocket(socket.rawValue, nonBlocking: true)

        var address = try socketAddress(for: path)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(socket.rawValue, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
            throw POSIXError(error)
        }

        if chmod(path, 0o600) != 0 {
            let error = POSIXErrorCode(rawValue: errno) ?? .EPERM
            throw POSIXError(error)
        }

        guard listen(socket.rawValue, SOMAXCONN) == 0 else {
            let error = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
            throw POSIXError(error)
        }

        return socket
    }

    static func makeConnectionHandle(
        from socket: consuming OwnedFileDescriptor,
        authorized: Bool
    ) -> FileHandle? {
        guard authorized else { return nil }
        configureSocket(socket.rawValue, nonBlocking: false)
        return FileHandle(
            fileDescriptor: socket.relinquish(),
            closeOnDealloc: true
        )
    }

    private static func socketAddress(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let utf8Path = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard utf8Path.count < pathCapacity else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8Path.enumerated() {
                buffer[index] = byte
            }
        }

        return address
    }

    private static func configureSocket(_ fd: Int32, nonBlocking: Bool) {
        let existingFlags = fcntl(fd, F_GETFL, 0)
        if existingFlags >= 0 {
            let updatedFlags = nonBlocking ? (existingFlags | O_NONBLOCK) : (existingFlags & ~O_NONBLOCK)
            _ = fcntl(fd, F_SETFL, updatedFlags)
        }

        let descriptorFlags = fcntl(fd, F_GETFD, 0)
        if descriptorFlags >= 0 {
            _ = fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC)
        }

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

    private static func isCurrentUser(_ fd: Int32) -> Bool {
        var effectiveUserID: uid_t = 0
        var groupID: gid_t = 0
        guard getpeereid(fd, &effectiveUserID, &groupID) == 0 else {
            return false
        }
        return effectiveUserID == geteuid()
    }

    private var secretPath: String {
        IPCSocketPath.secretPath(forSocketPath: socketPath)
    }
}
