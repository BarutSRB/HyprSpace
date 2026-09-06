// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class GhosttyNumericLocaleTests: XCTestCase {
    func testRestoreCNumericLocaleKeepsSymbolRasterizationWorkingUnderCommaDecimalLocale() {
        let previous = String(cString: setlocale(LC_ALL, nil))
        defer { _ = setlocale(LC_ALL, previous) }
        XCTAssertNotNil(setlocale(LC_ALL, "de_DE.UTF-8"))
        XCTAssertEqual(String(cString: setlocale(LC_NUMERIC, nil)), "de_DE.UTF-8")

        QuakeTerminalController.restoreCNumericLocale()

        XCTAssertEqual(String(cString: setlocale(LC_NUMERIC, nil)), "C")
        XCTAssertEqual(String(cString: setlocale(LC_CTYPE, nil)), "de_DE.UTF-8")

        let hostingView = NSHostingView(rootView: List {
            Label("Settings", systemImage: "gearshape")
        }.listStyle(.sidebar))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 320, height: 200))
        withExtendedLifetime(window) {}
    }
}
