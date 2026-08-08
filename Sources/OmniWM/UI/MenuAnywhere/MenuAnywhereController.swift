// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@preconcurrency import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class MenuAnywhereController: NSObject, NSMenuDelegate {
    static let shared = MenuAnywhereController()

    private let menuExtractor = MenuExtractor()
    private weak var currentApp: NSRunningApplication?
    private var activeMenu: NSMenu?
    private let axFetchQueue = DispatchQueue(label: "com.omniwm.menufetch", qos: .userInitiated)
    var onMenuTrackingChanged: ((Bool) -> Void)?

    private static let kAXPressAction = "AXPress" as CFString
    private static let appActivationDelay: TimeInterval = 0.1

    override private init() {
        super.init()
    }

    func showNativeMenu() {
        cleanupActiveMenu()

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        currentApp = app

        guard let menuBar = menuExtractor.getMenuBar(for: app.processIdentifier) else { return }

        let items = menuExtractor.buildMenu(
            from: menuBar,
            target: self,
            action: #selector(menuAction(_:))
        )

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.axRootElement = menuBar
        items.forEach(menu.addItem)
        activeMenu = menu

        onMenuTrackingChanged?(true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func cleanupActiveMenu() {
        guard let menu = activeMenu else { return }

        cleanupMenuItems(menu.items)
        menu.removeAllItems()
        activeMenu = nil
        onMenuTrackingChanged?(false)
    }

    private func cleanupMenuItems(_ items: [NSMenuItem]) {
        for item in items {
            if let submenu = item.submenu {
                cleanupMenuItems(submenu.items)
                submenu.removeAllItems()
            }
            item.representedObject = nil
            item.target = nil
            item.action = nil
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let obj = sender.representedObject,
              CFGetTypeID(obj as CFTypeRef) == AXUIElementGetTypeID(),
              let app = currentApp, !app.isTerminated
        else { return }

        let element = obj as! AXUIElement

        if !app.isActive {
            app.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.appActivationDelay) {
                performAXAction(element, Self.kAXPressAction, noteKey: "performPressFailed")
            }
        } else {
            performAXAction(element, Self.kAXPressAction, noteKey: "performPressFailed")
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === activeMenu {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupActiveMenu()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === activeMenu { return }
        menu.autoenablesItems = false

        guard menu.items.isEmpty, let axRoot = menu.axRootElement else { return }
        guard menu.isPopulatingAsynchronously == false else { return }

        menu.isPopulatingAsynchronously = true

        let placeholder = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        menu.addItem(placeholder)
        populateSubmenuAsync(menu: menu, axRoot: axRoot)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === activeMenu { return }
        guard let axRoot = menu.axRootElement else { return }
        menu.autoenablesItems = false
        let items = menuExtractor.buildSubmenu(
            from: axRoot, target: self, action: #selector(menuAction(_:))
        )
        if !items.isEmpty {
            menu.removeAllItems()
            items.forEach(menu.addItem)
        }
    }

    private func populateSubmenuAsync(menu: NSMenu, axRoot: AXUIElement) {
        nonisolated(unsafe) let menu = menu
        let extractor = menuExtractor
        axFetchQueue.async { [weak self] in
            guard let children = axRoot.getChildren() else {
                DispatchQueue.main.async {
                    menu.removeAllItems()
                    let empty = NSMenuItem(title: "(No items)", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    menu.addItem(empty)
                    menu.isPopulatingAsynchronously = false
                }
                return
            }

            let attrs = [
                "AXTitle", "AXRole", "AXRoleDescription", "AXEnabled",
                "AXMenuItemMarkChar", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXChildren"
            ]
            var itemsData: [[String: Any]] = []
            itemsData.reserveCapacity(children.count)
            for child in children {
                if let values = child.getMultipleAttributes(attrs) {
                    itemsData.append(values)
                } else {
                    itemsData.append([:])
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                let submenuItems = extractor.buildSubmenu(
                    fromChildren: children, itemsData: itemsData, target: self,
                    action: #selector(self.menuAction(_:))
                )
                menu.removeAllItems()
                for item in submenuItems {
                    menu.addItem(item)
                }
                if submenuItems.isEmpty {
                    let empty = NSMenuItem(title: "(No items)", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    menu.addItem(empty)
                }
                menu.isPopulatingAsynchronously = false
            }
        }
    }
}
