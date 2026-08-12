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

        let willOpenMenu = NSMenu(title: "WillOpen Test")
        XCTAssertTrue(willOpenMenu.autoenablesItems)
        controller.menuWillOpen(willOpenMenu)
        XCTAssertFalse(willOpenMenu.autoenablesItems, "menuWillOpen should set autoenablesItems = false")

        let needsUpdateMenu = NSMenu(title: "NeedsUpdate Test")
        XCTAssertTrue(needsUpdateMenu.autoenablesItems)
        controller.menuNeedsUpdate(needsUpdateMenu)
        XCTAssertFalse(needsUpdateMenu.autoenablesItems, "menuNeedsUpdate should set autoenablesItems = false even without axRoot")
    }

    @objc private func dummyAction() {}
}
