// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import XCTest

final class IPCResourceOwnershipTests: XCTestCase {
    func testOwnedFileDescriptorClosesAtEndOfScope() throws {
        let descriptor = try makeHighDescriptor()

        do {
            let owned = OwnedFileDescriptor(rawValue: descriptor)
            XCTAssertNotEqual(fcntl(owned.rawValue, F_GETFD), -1)
        }

        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testRelinquishedDescriptorStaysOpenUntilFileHandleCloses() throws {
        let descriptor = try makeHighDescriptor()
        let handle: FileHandle

        do {
            let owned = OwnedFileDescriptor(rawValue: descriptor)
            handle = FileHandle(
                fileDescriptor: owned.relinquish(),
                closeOnDealloc: true
            )
        }

        XCTAssertNotEqual(fcntl(descriptor, F_GETFD), -1)
        try handle.close()
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testOverlongListeningSocketPathDoesNotLeakDescriptors() throws {
        let baseline = try openDescriptorCount()
        let path = String(repeating: "x", count: MemoryLayout<sockaddr_un>.size)

        for _ in 0 ..< 32 {
            do {
                let socket = try IPCServer.makeListeningSocket(at: path)
                XCTFail("Expected overlong socket path to fail, opened \(socket.rawValue)")
            } catch {
                XCTAssertEqual(error as? POSIXError, POSIXError(.ENAMETOOLONG))
            }
        }

        XCTAssertEqual(try openDescriptorCount(), baseline)
    }

    func testOverlongActiveSocketProbeDoesNotLeakDescriptors() throws {
        let baseline = try openDescriptorCount()
        let path = String(repeating: "x", count: MemoryLayout<sockaddr_un>.size)

        for _ in 0 ..< 32 {
            XCTAssertThrowsError(try IPCServer.isActiveSocket(at: path)) { error in
                XCTAssertEqual(error as? POSIXError, POSIXError(.ENAMETOOLONG))
            }
        }

        XCTAssertEqual(try openDescriptorCount(), baseline)
    }

    func testBindFailureDoesNotLeakDescriptors() throws {
        let path = "/tmp/omniwm-ipc-\(UUID().uuidString.prefix(12))"
        let listener = try IPCServer.makeListeningSocket(at: path)
        defer { unlink(path) }
        XCTAssertNotEqual(fcntl(listener.rawValue, F_GETFD), -1)
        let baseline = try openDescriptorCount()

        for _ in 0 ..< 32 {
            do {
                let socket = try IPCServer.makeListeningSocket(at: path)
                XCTFail("Expected duplicate bind to fail, opened \(socket.rawValue)")
            } catch {
                XCTAssertEqual(error as? POSIXError, POSIXError(.EADDRINUSE))
            }
        }

        XCTAssertEqual(try openDescriptorCount(), baseline)
    }

    func testRejectedConnectionClosesDescriptorWithoutTransfer() throws {
        let descriptors = try makeSocketPair()
        defer { close(descriptors.peer) }
        let descriptor = descriptors.connection

        let handle = IPCServer.makeConnectionHandle(
            from: OwnedFileDescriptor(rawValue: descriptor),
            authorized: false
        )

        XCTAssertNil(handle)
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertNotEqual(fcntl(descriptors.peer, F_GETFD), -1)
    }

    func testAcceptedConnectionTransfersDescriptorToFileHandle() throws {
        let descriptors = try makeSocketPair()
        defer { close(descriptors.peer) }
        let descriptor = descriptors.connection

        let handle = try XCTUnwrap(
            IPCServer.makeConnectionHandle(
                from: OwnedFileDescriptor(rawValue: descriptor),
                authorized: true
            )
        )

        XCTAssertNotEqual(fcntl(descriptor, F_GETFD), -1)
        try handle.close()
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    private func makeHighDescriptor() throws -> Int32 {
        let source = socket(AF_UNIX, SOCK_STREAM, 0)
        guard source >= 0 else { throw POSIXError(.EIO) }
        defer { close(source) }
        let descriptor = fcntl(source, F_DUPFD_CLOEXEC, 1024)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        return descriptor
    }

    private func makeSocketPair() throws -> (connection: Int32, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        return (descriptors[0], descriptors[1])
    }

    private func openDescriptorCount() throws -> Int {
        let byteCount = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount >= 0 else { throw POSIXError(.EIO) }
        return Int(byteCount) / MemoryLayout<proc_fdinfo>.stride
    }
}
