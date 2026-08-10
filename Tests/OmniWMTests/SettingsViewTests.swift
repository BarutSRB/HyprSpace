// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class SettingsViewTests: XCTestCase {
    func testAppReactivationRefreshesDiagnosticsFromGeneralSection() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsViewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        settings.hotkeyBindings = []
        let controller = WMController(
            settings: settings,
            diagnosticsDirectory: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let navigation = SettingsNavigationModel()
        navigation.section = .general
        let cornerPreferences = GlobalWindowCornerPreferences(
            operations: GlobalWindowCornerPreferences.Operations(
                copyMultiple: { [:] },
                setMultiple: { _, _ in },
                synchronize: { true },
                isForced: { _ in false }
            ),
            isSupported: false
        )
        let hostingView = NSHostingView(rootView: SettingsView(
            settings: settings,
            controller: controller,
            windowCornerPreferences: cornerPreferences,
            updateCoordinator: nil,
            navigation: navigation
        ))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        let issueID = "hotkey-sided-hyper:settings-reactivation"
        XCTAssertFalse(controller.diagnosticsIssues.contains { $0.id == issueID })

        let sidedHyper = KeyBinding(
            keyCode: UInt32(kVK_ANSI_1),
            modifiers: KeySymbolMapper.hyperModifiers
        ).settingSide(.left)
        settings.hotkeyBindings = [HotkeyBinding(
            id: "settings-reactivation",
            command: .focusPrevious,
            binding: sidedHyper
        )]
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertFalse(controller.diagnosticsIssues.contains { $0.id == issueID })

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertTrue(controller.diagnosticsIssues.contains { $0.id == issueID })
        withExtendedLifetime(window) {}
    }
}
