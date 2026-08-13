// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteControllerTests: XCTestCase {
    func testTabCyclesForwardAndWrapsAcrossAvailableModes() {
        let transitions: [(CommandPaletteMode, CommandPaletteMode)] = [
            (.windows, .menu),
            (.menu, .clipboard),
            (.clipboard, .windows)
        ]

        for (currentMode, expectedMode) in transitions {
            XCTAssertEqual(
                modeNavigationTarget(currentMode: currentMode),
                expectedMode
            )
        }
    }

    func testShiftTabCyclesBackwardAndWrapsAcrossAvailableModes() {
        let transitions: [(CommandPaletteMode, CommandPaletteMode)] = [
            (.windows, .clipboard),
            (.menu, .windows),
            (.clipboard, .menu)
        ]

        for (currentMode, expectedMode) in transitions {
            XCTAssertEqual(
                modeNavigationTarget(currentMode: currentMode, modifiers: .shift),
                expectedMode
            )
        }
    }

    func testCycleSkipsUnavailableMenuAndStillIncludesClipboard() {
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .windows, isMenuModeAvailable: false),
            .clipboard
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .clipboard, isMenuModeAvailable: false),
            .windows
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .windows, isMenuModeAvailable: false, modifiers: .shift),
            .clipboard
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .clipboard, isMenuModeAvailable: false, modifiers: .shift),
            .windows
        )
    }

    func testModifiedTabDoesNotNavigateModes() {
        let modifiers: [NSEvent.ModifierFlags] = [
            .control,
            .option,
            .command,
            [.control, .shift],
            [.option, .shift],
            [.command, .shift]
        ]

        for modifierFlags in modifiers {
            XCTAssertNil(
                modeNavigationTarget(currentMode: .windows, modifiers: modifierFlags)
            )
        }
    }

    func testCommandShortcutsSelectModesAndPreserveMenuAvailability() {
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_1), characters: "1"),
            .windows
        )
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_2), characters: "2"),
            .menu
        )
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_3), characters: "3"),
            .clipboard
        )
        XCTAssertNil(
            directModeTarget(
                keyCode: UInt16(kVK_ANSI_2),
                characters: "2",
                isMenuModeAvailable: false
            )
        )
    }

    func testModeHintsKeepDirectShortcutsVisible() {
        XCTAssertEqual(
            CommandPaletteController.modeHint(for: .windows),
            .init(title: "Windows", shortcut: "⌘1")
        )
        XCTAssertEqual(
            CommandPaletteController.modeHint(for: .menu),
            .init(title: "Menu", shortcut: "⌘2")
        )
        XCTAssertEqual(
            CommandPaletteController.modeHint(for: .clipboard),
            .init(title: "Clipboard", shortcut: "⌘3")
        )
    }

    func testHiddenManagedRowsRemainSearchableAndSortAfterVisibleRows() throws {
        let (wmController, visibleToken, hiddenToken) = try makeWindowFixture()
        let palette = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: false)
        )

        let items = palette.buildWindowItems(from: wmController)

        XCTAssertEqual(items.map(\.id), [visibleToken, hiddenToken])
        XCTAssertEqual(items.map(\.isAppHidden), [false, true])
        XCTAssertTrue(items[0].handle === wmController.workspaceManager.handle(for: visibleToken))
        XCTAssertTrue(items[1].handle === wmController.workspaceManager.handle(for: hiddenToken))
        XCTAssertEqual(palette.filterWindowItems(items, query: "hidden").map(\.id), [hiddenToken])
        XCTAssertTrue(CommandPaletteController.allowsSummonRight(items[0]))
        XCTAssertFalse(CommandPaletteController.allowsSummonRight(items[1]))
    }

    private func modeNavigationTarget(
        currentMode: CommandPaletteMode,
        isMenuModeAvailable: Bool = true,
        modifiers: NSEvent.ModifierFlags = []
    ) -> CommandPaletteMode? {
        CommandPaletteController.modeNavigationTarget(
            currentMode: currentMode,
            isMenuModeAvailable: isMenuModeAvailable,
            keyCode: UInt16(kVK_Tab),
            relevantModifiers: modifiers,
            charactersIgnoringModifiers: "\t"
        )
    }

    private func directModeTarget(
        keyCode: UInt16,
        characters: String,
        isMenuModeAvailable: Bool = true
    ) -> CommandPaletteMode? {
        CommandPaletteController.modeNavigationTarget(
            currentMode: .windows,
            isMenuModeAvailable: isMenuModeAvailable,
            keyCode: keyCode,
            relevantModifiers: .command,
            charactersIgnoringModifiers: characters
        )
    }

    private func makeWindowFixture() throws -> (WMController, WindowToken, WindowToken) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCommandPaletteTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let hiddenToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(92_001), windowId: 92_101),
            pid: 92_001,
            windowId: 92_101,
            to: workspaceId
        )
        let visibleToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(92_002), windowId: 92_102),
            pid: 92_002,
            windowId: 92_102,
            to: workspaceId
        )
        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .service)
        return (controller, visibleToken, hiddenToken)
    }
}
