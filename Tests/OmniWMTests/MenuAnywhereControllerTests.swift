// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class MenuAnywhereControllerTests: XCTestCase {
    func testLoadedItemsCommitOnceAndPreserveDisabledState() {
        let enabled = NSMenuItem(title: "Enabled", action: nil, keyEquivalent: "")
        let disabled = NSMenuItem(title: "Disabled", action: nil, keyEquivalent: "")
        disabled.isEnabled = false
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return .loaded([enabled, disabled])
        }
        let menu = rootedMenu()

        controller.menuNeedsUpdate(menu)
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(loadCount, 1)
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.count, 2)
        XCTAssertTrue(menu.items[0] === enabled)
        XCTAssertTrue(menu.items[1] === disabled)
        XCTAssertFalse(menu.items[1].isEnabled)
    }

    func testAuthoritativeEmptyCommitsDisabledStatusOnce() {
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return .loaded([])
        }
        let menu = rootedMenu()

        controller.menuNeedsUpdate(menu)
        let status = menu.items.first
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertTrue(menu.items.first === status)
        XCTAssertEqual(status?.title, "(No items)")
        XCTAssertFalse(status?.isEnabled ?? true)
    }

    func testUnavailableCommitsStatusAndFreshMenuCanRecover() {
        let recovered = NSMenuItem(title: "Recovered", action: nil, keyEquivalent: "")
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return loadCount == 1 ? .unavailable : .loaded([recovered])
        }
        let firstMenu = rootedMenu()

        controller.menuNeedsUpdate(firstMenu)
        controller.menuNeedsUpdate(firstMenu)

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(firstMenu.items.count, 1)
        XCTAssertEqual(firstMenu.items.first?.title, "(Unavailable)")
        XCTAssertFalse(firstMenu.items.first?.isEnabled ?? true)

        let secondMenu = rootedMenu()
        controller.menuNeedsUpdate(secondMenu)

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(secondMenu.items.count, 1)
        XCTAssertTrue(secondMenu.items.first === recovered)
    }

    func testLiteralLoadingTitleIsNotTreatedAsPlaceholder() {
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return .unavailable
        }
        let menu = rootedMenu()
        let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        menu.addItem(item)

        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertTrue(menu.items.first === item)
        XCTAssertFalse(menu.autoenablesItems)
    }

    func testRootlessMenuDoesNotLoad() {
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return .unavailable
        }
        let menu = NSMenu(title: "Rootless")

        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(loadCount, 0)
        XCTAssertTrue(menu.items.isEmpty)
        XCTAssertFalse(menu.autoenablesItems)
    }

    func testControllerDoesNotImplementMenuWillOpen() {
        let controller = MenuAnywhereController { _, _, _ in .unavailable }

        XCTAssertFalse(controller.responds(to: #selector(NSMenuDelegate.menuWillOpen(_:))))
    }

    private func rootedMenu() -> NSMenu {
        let menu = NSMenu(title: "Submenu")
        menu.axRootElement = AXUIElementCreateApplication(91_500)
        return menu
    }
}
