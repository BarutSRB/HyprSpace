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
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === activeMenu { return }
        guard let axRoot = menu.axRootElement else { return }
        menu.autoenablesItems = false

        let isPlaceholderOnly = menu.items.count == 1 && menu.items.first?.title == "Loading..."
        guard menu.items.isEmpty || isPlaceholderOnly else { return }

        let items = menuExtractor.buildSubmenu(
            from: axRoot, target: self, action: #selector(menuAction(_:))
        )
        menu.removeAllItems()
        if items.isEmpty {
            let empty = NSMenuItem(title: "(No items)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            items.forEach(menu.addItem)
        }
    }
}
