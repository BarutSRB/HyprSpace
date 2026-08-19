// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import ServiceManagement
import XCTest

@MainActor
final class LoginItemManagerTests: XCTestCase {
    private struct StubError: LocalizedError {
        var errorDescription: String? { "registration denied" }
    }

    private final class FakeLoginItemService: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var registerCalls = 0
        var unregisterCalls = 0
        var errorToThrow: Error?

        func register() throws {
            registerCalls += 1
            if let errorToThrow { throw errorToThrow }
            status = .enabled
        }

        func unregister() throws {
            unregisterCalls += 1
            if let errorToThrow { throw errorToThrow }
            status = .notRegistered
        }
    }

    func testInitReflectsCurrentStatus() {
        let service = FakeLoginItemService()
        service.status = .enabled

        let manager = LoginItemManager(service: service)

        XCTAssertTrue(manager.isEnabled)
        XCTAssertFalse(manager.requiresApproval)
    }

    func testEnablingRegistersAndRefreshes() {
        let service = FakeLoginItemService()
        let manager = LoginItemManager(service: service)

        manager.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertNil(manager.lastErrorDescription)
    }

    func testDisablingUnregistersAndRefreshes() {
        let service = FakeLoginItemService()
        service.status = .enabled
        let manager = LoginItemManager(service: service)

        manager.setEnabled(false)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNil(manager.lastErrorDescription)
    }

    func testRedundantToggleDoesNotCallService() {
        let service = FakeLoginItemService()
        service.status = .enabled
        let manager = LoginItemManager(service: service)

        manager.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testPendingApprovalCountsAsRequestedState() {
        let service = FakeLoginItemService()
        service.status = .requiresApproval
        let manager = LoginItemManager(service: service)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.requiresApproval)

        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 0)

        manager.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    func testRegistrationFailureIsSurfacedAndStateRefreshed() {
        let service = FakeLoginItemService()
        service.errorToThrow = StubError()
        let manager = LoginItemManager(service: service)

        manager.setEnabled(true)

        XCTAssertEqual(manager.lastErrorDescription, "registration denied")
        XCTAssertFalse(manager.isEnabled)

        service.errorToThrow = nil
        manager.setEnabled(true)

        XCTAssertTrue(manager.isEnabled)
        XCTAssertNil(manager.lastErrorDescription)
    }
}
