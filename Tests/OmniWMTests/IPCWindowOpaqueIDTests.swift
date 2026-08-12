// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC
import XCTest

final class IPCWindowOpaqueIDTests: XCTestCase {
    func testRoundTripsUUIDSessionToken() {
        let token = UUID().uuidString
        let opaque = IPCWindowOpaqueID.encode(pid: 12_345, windowId: 67, sessionToken: token)

        XCTAssertEqual(
            IPCWindowOpaqueID.validate(opaque, expectingSessionToken: token),
            .valid(pid: 12_345, windowId: 67)
        )
    }

    func testRoundTripsSessionTokenContainingColonDelimiter() {
        // The session token is a free-form String; a token that itself contains the `:` payload
        // delimiter must still round-trip instead of being reported as invalid.
        let token = "prefix:suffix"
        let opaque = IPCWindowOpaqueID.encode(pid: 42, windowId: 7, sessionToken: token)

        XCTAssertEqual(
            IPCWindowOpaqueID.validate(opaque, expectingSessionToken: token),
            .valid(pid: 42, windowId: 7)
        )
    }

    func testRoundTripsSessionTokenWithMultipleColons() {
        let token = "a:b:c:d"
        let opaque = IPCWindowOpaqueID.encode(pid: -3, windowId: 999_999, sessionToken: token)

        XCTAssertEqual(
            IPCWindowOpaqueID.validate(opaque, expectingSessionToken: token),
            .valid(pid: -3, windowId: 999_999)
        )
    }

    func testMismatchedSessionTokenReportsStale() {
        let opaque = IPCWindowOpaqueID.encode(pid: 5, windowId: 1, sessionToken: "session-a")

        XCTAssertEqual(
            IPCWindowOpaqueID.validate(opaque, expectingSessionToken: "session-b"),
            .stale
        )
    }

    func testMalformedOpaqueIDReportsInvalid() {
        for malformed in ["", "ow_", "not-a-prefix", "ow_not-base64$$"] {
            XCTAssertEqual(
                IPCWindowOpaqueID.validate(malformed, expectingSessionToken: "session"),
                .invalid
            )
        }
    }

    func testDecodeReturnsNilForStaleOrInvalid() {
        let token = "session"
        let valid = IPCWindowOpaqueID.encode(pid: 1, windowId: 2, sessionToken: token)

        XCTAssertNotNil(IPCWindowOpaqueID.decode(valid, expectingSessionToken: token))
        XCTAssertNil(IPCWindowOpaqueID.decode(valid, expectingSessionToken: "other"))
        XCTAssertNil(IPCWindowOpaqueID.decode("ow_bogus", expectingSessionToken: token))
    }
}
