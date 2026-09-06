// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalScreenSelectionTests: XCTestCase {
    func testMainMonitorSelectsLowerPrimaryDespiteUpperKeyboardFocus() {
        let primary = Screen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let secondary = Screen(frame: CGRect(x: 0, y: 1440, width: 3440, height: 1440))
        let controller = makeController()

        for focusedScreen in [secondary, primary, secondary] {
            XCTAssertTrue(controller.targetScreen(screens: [primary, secondary], mainScreen: focusedScreen) === primary)
        }
    }

    func testMainMonitorUsesUpdatedPrimaryScreenOrder() {
        let first = Screen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let second = Screen(frame: CGRect(x: 0, y: 1440, width: 3440, height: 1440))
        let controller = makeController()

        XCTAssertTrue(controller.targetScreen(screens: [first, second], mainScreen: first) === first)
        XCTAssertTrue(controller.targetScreen(screens: [second, first], mainScreen: first) === second)
    }

    func testMainMonitorSelectsOnlyScreenWithoutKeyboardFocus() {
        let screen = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let controller = makeController()

        XCTAssertTrue(controller.targetScreen(screens: [screen], mainScreen: nil) === screen)
    }

    func testMainMonitorFallsBackWhenScreenListIsUnavailable() {
        let screen = Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let controller = makeController()

        XCTAssertTrue(controller.targetScreen(screens: [], mainScreen: screen) === screen)
    }

    func testFocusedWindowModePreservesProvidedSecondaryScreen() {
        let primary = Screen(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let secondary = Screen(frame: CGRect(x: 0, y: 1440, width: 3440, height: 1440))
        let controller = makeController(mode: .focusedWindow, focusedWindowScreenProvider: { secondary })

        XCTAssertTrue(controller.targetScreen(screens: [primary, secondary], mainScreen: primary) === secondary)
    }

    private func makeController(
        mode: QuakeTerminalMonitorMode = .mainMonitor,
        focusedWindowScreenProvider: @escaping @MainActor () -> NSScreen? = { nil }
    ) -> QuakeTerminalController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeScreenTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.quakeTerminalMonitorMode = mode
        return QuakeTerminalController(
            settings: settings,
            motionPolicy: MotionPolicy(),
            focusedWindowScreenProvider: focusedWindowScreenProvider
        )
    }

    private final class Screen: NSScreen {
        private let screenFrame: CGRect

        init(frame: CGRect) {
            screenFrame = frame
            super.init()
        }

        override var frame: CGRect {
            screenFrame
        }
    }
}
