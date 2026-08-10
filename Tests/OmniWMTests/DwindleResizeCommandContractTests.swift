// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

final class DwindleResizeCommandContractTests: XCTestCase {
    private struct ExpectedAction {
        let id: String
        let command: HotkeyCommand
        let title: String
        let ipcCommandName: IPCCommandName
    }

    func testResizeActionsExposeSixDistinctGUICommands() throws {
        let expected = [
            ExpectedAction(
                id: "resizeGrow.horizontal",
                command: .resizeAlongAxis(.horizontal, true),
                title: "Grow Horizontally",
                ipcCommandName: .resize
            ),
            ExpectedAction(
                id: "resizeGrow.vertical",
                command: .resizeAlongAxis(.vertical, true),
                title: "Grow Vertically",
                ipcCommandName: .resize
            ),
            ExpectedAction(
                id: "resizeShrink.horizontal",
                command: .resizeAlongAxis(.horizontal, false),
                title: "Shrink Horizontally",
                ipcCommandName: .resize
            ),
            ExpectedAction(
                id: "resizeShrink.vertical",
                command: .resizeAlongAxis(.vertical, false),
                title: "Shrink Vertically",
                ipcCommandName: .resize
            ),
            ExpectedAction(
                id: "resizeFocusedWindow.grow",
                command: .resizeFocusedWindow(true),
                title: "Grow Focused Window",
                ipcCommandName: .resizeFocused
            ),
            ExpectedAction(
                id: "resizeFocusedWindow.shrink",
                command: .resizeFocusedWindow(false),
                title: "Shrink Focused Window",
                ipcCommandName: .resizeFocused
            )
        ]

        XCTAssertEqual(Set(expected.map(\.command)).count, expected.count)
        for action in expected {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: action.id))
            XCTAssertEqual(spec.command, action.command)
            XCTAssertEqual(spec.title, action.title)
            XCTAssertEqual(spec.category, .layout)
            XCTAssertEqual(spec.visibility, .advanced)
            XCTAssertEqual(spec.layoutCompatibility, .dwindle)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.ipcCommandName, action.ipcCommandName)
        }
    }

    func testDirectionalResizeActionIDsAreAbsent() {
        let oldIds = [
            "resizeGrow.left",
            "resizeGrow.right",
            "resizeGrow.up",
            "resizeGrow.down",
            "resizeShrink.left",
            "resizeShrink.right",
            "resizeShrink.up",
            "resizeShrink.down"
        ]

        for id in oldIds {
            XCTAssertNil(ActionCatalog.spec(for: id))
        }
    }
}
