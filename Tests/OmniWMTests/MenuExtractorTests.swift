// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class MenuExtractorTests: XCTestCase {
    func testSubmenuAutoenablesItemsIsDisabled() {
        let submenu = NSMenu(title: "Submenu")
        XCTAssertTrue(submenu.autoenablesItems, "NSMenu defaults autoenablesItems to true")

        // Set autoenablesItems = false as expected for extracted menus
        submenu.autoenablesItems = false
        XCTAssertFalse(submenu.autoenablesItems)

        let disabledItem = NSMenuItem(title: "Disabled Item", action: #selector(dummyAction), keyEquivalent: "")
        disabledItem.isEnabled = false
        disabledItem.target = self
        submenu.addItem(disabledItem)

        // When autoenablesItems is false, item.isEnabled remains false despite having target/action
        XCTAssertFalse(disabledItem.isEnabled)
    }

    func testMenuAnywhereControllerMenuWillOpenAndNeedsUpdateConfiguresSubmenu() {
        let controller = MenuAnywhereController.shared
        let submenu = NSMenu(title: "Submenu Test")
        XCTAssertTrue(submenu.autoenablesItems)

        controller.menuWillOpen(submenu)
        XCTAssertFalse(submenu.autoenablesItems, "menuWillOpen should set autoenablesItems = false")

        controller.menuNeedsUpdate(submenu)
        XCTAssertFalse(submenu.autoenablesItems, "menuNeedsUpdate should set autoenablesItems = false")
    }

    @objc private func dummyAction() {}
}
