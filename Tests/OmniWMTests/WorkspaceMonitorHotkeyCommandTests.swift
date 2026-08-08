// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

final class WorkspaceMonitorHotkeyCommandTests: XCTestCase {
    func testDirectionalWorkspaceMoveActionsAreRegistered() throws {
        let cases: [(direction: Direction, id: String, title: String)] = [
            (.left, "moveWorkspaceToMonitor.left", "Move Workspace to Left Monitor"),
            (.right, "moveWorkspaceToMonitor.right", "Move Workspace to Right Monitor"),
            (.up, "moveWorkspaceToMonitor.up", "Move Workspace to Up Monitor"),
            (.down, "moveWorkspaceToMonitor.down", "Move Workspace to Down Monitor")
        ]

        for entry in cases {
            let command = HotkeyCommand.moveWorkspaceToMonitor(entry.direction)
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))

            XCTAssertEqual(spec.id, entry.id)
            XCTAssertEqual(spec.title, entry.title)
            XCTAssertEqual(spec.category, .monitor)
            XCTAssertEqual(spec.visibility, .normal)
            XCTAssertEqual(spec.layoutCompatibility, .shared)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertNil(spec.ipcCommandName)
            XCTAssertNil(spec.ipcDescriptor)
            XCTAssertEqual(HotkeyBindingRegistry.command(for: entry.id), command)

            let searchTerms = Set(spec.searchTerms.map(ActionCatalog.normalizedSearchTerm))
            for term in ["display", "home monitor", "force", "runtime override"] {
                XCTAssertTrue(searchTerms.contains(term))
            }
        }
    }

    func testDirectionalWindowMoveActionsAreRegistered() throws {
        let cases: [(direction: Direction, id: String, title: String)] = [
            (.left, "moveWindowToMonitor.left", "Move Window to Left Monitor"),
            (.right, "moveWindowToMonitor.right", "Move Window to Right Monitor"),
            (.up, "moveWindowToMonitor.up", "Move Window to Up Monitor"),
            (.down, "moveWindowToMonitor.down", "Move Window to Down Monitor")
        ]

        for entry in cases {
            let command = HotkeyCommand.moveWindowToMonitor(entry.direction)
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))

            XCTAssertEqual(spec.id, entry.id)
            XCTAssertEqual(spec.title, entry.title)
            XCTAssertEqual(spec.category, .monitor)
            XCTAssertEqual(spec.visibility, .normal)
            XCTAssertEqual(spec.layoutCompatibility, .shared)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.ipcCommandName, .moveToMonitor)
            let descriptor = try XCTUnwrap(spec.ipcDescriptor)
            XCTAssertEqual(descriptor.name, .moveToMonitor)
            XCTAssertEqual(descriptor.commandWords, ["move-to-monitor"])
            XCTAssertEqual(descriptor.layoutCompatibility, .shared)
            XCTAssertEqual(HotkeyBindingRegistry.command(for: entry.id), command)

            let searchTerms = Set(spec.searchTerms.map(ActionCatalog.normalizedSearchTerm))
            for term in ["display", "adjacent monitor", "send window", "active workspace", "current workspace"] {
                XCTAssertTrue(searchTerms.contains(term))
            }
        }
    }
}
