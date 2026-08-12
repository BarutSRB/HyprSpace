// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@preconcurrency import AppKit
@preconcurrency import ApplicationServices

enum MenuSubmenuLoadResult {
    case loaded([NSMenuItem])
    case unavailable
}

@MainActor
final class MenuAnywhereController: NSObject, NSMenuDelegate {
    typealias SubmenuLoader = @MainActor (AXUIElement, AnyObject?, Selector?) -> MenuSubmenuLoadResult

    static let shared = MenuAnywhereController()

    private let menuExtractor: MenuExtractor
    private let submenuLoader: SubmenuLoader
    private weak var currentApp: NSRunningApplication?
    private var activeMenu: NSMenu?
    var onMenuTrackingChanged: ((Bool) -> Void)?

    private static let kAXPressAction = "AXPress" as CFString
    private static let appActivationDelay: TimeInterval = 0.1

    override private init() {
        let extractor = MenuExtractor()
        menuExtractor = extractor
        submenuLoader = { root, target, action in
            do {
                return .loaded(
                    try extractor.buildSubmenu(from: root, target: target, action: action)
                )
            } catch {
                return .unavailable
            }
        }
        super.init()
    }

    init(submenuLoader: @escaping SubmenuLoader) {
        menuExtractor = MenuExtractor()
        self.submenuLoader = submenuLoader
        super.init()
    }

    func showNativeMenu() {
        guard activeMenu == nil else { return }

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
        defer { cleanupActiveMenu() }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func cleanupActiveMenu() {
        guard let menu = activeMenu else { return }

        cleanupMenuItems(menu.items)
        menu.removeAllItems()
        activeMenu = nil
        currentApp = nil
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === activeMenu { return }
        menu.autoenablesItems = false
        guard menu.items.isEmpty, let axRoot = menu.axRootElement else { return }

        switch submenuLoader(axRoot, self, #selector(menuAction(_:))) {
        case let .loaded(items) where !items.isEmpty:
            items.forEach(menu.addItem)
        case .loaded:
            menu.addItem(statusItem(title: "(No items)"))
        case .unavailable:
            menu.addItem(statusItem(title: "(Unavailable)"))
        }
    }

    private func statusItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
