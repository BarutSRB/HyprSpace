// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

final class ConsumeOrExpelCommandContractTests: XCTestCase {
    func testUnassignableActionsRetainCommandMetadata() throws {
        let cases: [(String, HotkeyCommand, IPCCommandName)] = [
            ("consumeOrExpelWindowLeft", .consumeOrExpelWindowLeft, .consumeOrExpelWindowLeft),
            ("consumeOrExpelWindowRight", .consumeOrExpelWindowRight, .consumeOrExpelWindowRight)
        ]

        for (id, command, ipcName) in cases {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))

            XCTAssertEqual(spec.id, id)
            XCTAssertEqual(spec.command, command)
            XCTAssertEqual(spec.visibility, .unassignable)
            XCTAssertEqual(spec.layoutCompatibility, .niri)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.ipcCommandName, ipcName)
            XCTAssertNotNil(spec.ipcDescriptor)
        }
    }

    func testUnassignableActionsAreAbsentFromBindingRegistry() {
        let ids = [
            "consumeOrExpelWindowLeft",
            "consumeOrExpelWindowRight"
        ]
        let defaultIDs = Set(HotkeyBindingRegistry.defaults().map(\.id))

        for id in ids {
            XCTAssertFalse(defaultIDs.contains(id))
            XCTAssertNil(HotkeyBindingRegistry.command(for: id))
            XCTAssertNil(HotkeyBindingRegistry.makeBinding(id: id, binding: .unassigned))
            XCTAssertNil(HotkeyBindingRegistry.makeBinding(id: id, trigger: .unassigned))
        }
    }

    func testAdvancedConsumeIntoColumnActionRemainsAssignable() throws {
        let id = "consumeWindowIntoColumn"
        let binding = try XCTUnwrap(
            HotkeyBindingRegistry.defaults().first { $0.id == id }
        )
        let spec = try XCTUnwrap(ActionCatalog.spec(for: id))

        XCTAssertEqual(binding.command, .consumeWindowIntoColumn)
        XCTAssertEqual(binding.binding, .unassigned)
        XCTAssertEqual(spec.visibility, .advanced)
        XCTAssertEqual(HotkeyBindingRegistry.command(for: id), .consumeWindowIntoColumn)
    }

    func testEveryRegistryDefaultMapsToAnAssignableCatalogSpec() throws {
        for binding in HotkeyBindingRegistry.defaults() {
            let spec = try XCTUnwrap(
                ActionCatalog.spec(for: binding.id),
                "Missing catalog spec for \(binding.id)"
            )

            XCTAssertNotEqual(spec.visibility, .unassignable, binding.id)
        }
    }
}
