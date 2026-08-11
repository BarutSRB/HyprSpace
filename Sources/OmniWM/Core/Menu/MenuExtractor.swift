// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import ObjectiveC

final class MenuExtractor: @unchecked Sendable {
    private static let itemAttributeKeys = [
        "AXTitle", "AXRole", "AXRoleDescription", "AXEnabled",
        "AXMenuItemMarkChar", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXChildren"
    ]

    private let boldFont = NSFontManager.shared.convert(
        NSFont.menuFont(ofSize: NSFont.systemFontSize), toHaveTrait: .boldFontMask
    )

    func getMenuBar(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var menuBarValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarValue)
        guard result == .success, let menuBar = menuBarValue else { return nil }
        return (menuBar as! AXUIElement)
    }

    func buildMenu(from element: AXUIElement, target: AnyObject?, action: Selector?) -> [NSMenuItem] {
        autoreleasepool {
            buildMenuItems(from: element, target: target, action: action, isSubmenu: false)
        }
    }

    func buildSubmenu(from element: AXUIElement, target: AnyObject?, action: Selector?) -> [NSMenuItem] {
        autoreleasepool {
            buildMenuItems(from: element, target: target, action: action, isSubmenu: true)
        }
    }

    func buildSubmenu(
        fromChildren children: [AXUIElement],
        itemsData: [[String: Any]],
        target: AnyObject?,
        action: Selector?
    ) -> [NSMenuItem] {
        buildMenuItems(
            children: children,
            itemsData: itemsData,
            target: target,
            action: action,
            isSubmenu: true
        )
    }

    func flattenMenuItems(
        from menuBar: AXUIElement,
        appName _: String? = nil,
        excludeAppleMenu: Bool = false
    ) -> [MenuItemModel] {
        var items: [MenuItemModel] = []
        flattenMenuItemsRecursive(
            from: menuBar,
            parentPath: [],
            depth: 0,
            excludeAppleMenu: excludeAppleMenu,
            into: &items
        )
        return items
    }

    private func flattenMenuItemsRecursive(
        from element: AXUIElement,
        parentPath: [String],
        depth: Int,
        excludeAppleMenu: Bool,
        into items: inout [MenuItemModel]
    ) {
        guard let children = element.getChildren() else { return }

        for child in children {
            autoreleasepool {
                guard let itemData = child.getMultipleAttributes(Self.itemAttributeKeys) else { return }

                let title = itemData["AXTitle"] as? String ?? ""
                let role = itemData["AXRole"] as? String ?? ""

                if title.isEmpty || role == "AXSeparator" { return }

                let isEnabled = itemData["AXEnabled"] as? Bool ?? true

                var shortcut: String?
                if let cmd = itemData["AXMenuItemCmdChar"] as? String, !cmd.isEmpty {
                    let flags = NSEvent.ModifierFlags.fromAXModifiers(itemData["AXMenuItemCmdModifiers"] as? Int)
                    shortcut = formatKeyboardShortcut(cmd, modifiers: flags)
                }

                if let subChildren = itemData["AXChildren"] as? [AXUIElement],
                   !subChildren.isEmpty,
                   let firstSub = subChildren.first,
                   let subRole = firstSub.getAttribute("AXRole") as? String,
                   subRole == "AXMenu"
                {
                    if excludeAppleMenu, depth == 0, isAppleMenuItem(title: title, itemData: itemData) {
                        return
                    }
                    let newPath = parentPath + [title]
                    flattenMenuItemsRecursive(
                        from: firstSub,
                        parentPath: newPath,
                        depth: depth + 1,
                        excludeAppleMenu: excludeAppleMenu,
                        into: &items
                    )
                } else if isEnabled {
                    let fullPath = (parentPath + [title]).joined(separator: " > ")
                    let item = MenuItemModel(
                        title: title,
                        fullPath: fullPath,
                        keyboardShortcut: shortcut,
                        axElement: child,
                        parentTitles: parentPath
                    )
                    items.append(item)
                }
            }
        }
    }

    private func formatKeyboardShortcut(_ key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    private func buildMenuItems(
        from element: AXUIElement, target: AnyObject?, action: Selector?, isSubmenu: Bool
    ) -> [NSMenuItem] {
        guard let children = element.getChildren() else { return [] }

        let itemsData = autoreleasepool {
            var results: [[String: Any]] = []
            results.reserveCapacity(children.count)

            for child in children {
                if let values = child.getMultipleAttributes(Self.itemAttributeKeys) {
                    results.append(values)
                } else {
                    results.append([:])
                }
            }

            return results
        }

        return buildMenuItems(
            children: children, itemsData: itemsData, target: target, action: action, isSubmenu: isSubmenu
        )
    }

    private func buildMenuItems(
        children: [AXUIElement],
        itemsData: [[String: Any]],
        target: AnyObject?,
        action: Selector?,
        isSubmenu: Bool
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items.reserveCapacity(children.count)

        var appleItem: NSMenuItem?
        var isFirst = true
        var needsSeparator = false

        for (index, child) in children.enumerated() {
            autoreleasepool {
                let itemData = itemsData[index]
                let isApple = isAppleMenuItem(
                    title: itemData["AXTitle"] as? String, itemData: itemData
                )
                if let item = buildSingleMenuItem(
                    from: child,
                    itemData: itemData,
                    target: target,
                    action: action,
                    isSubmenu: isSubmenu,
                    isFirst: &isFirst,
                    isApple: isApple
                ) {
                    if item.isSeparatorItem {
                        needsSeparator = true
                        return
                    }

                    if needsSeparator, !items.isEmpty {
                        items.append(.separator())
                        needsSeparator = false
                    }

                    if isApple {
                        appleItem = item
                    } else {
                        items.append(item)
                    }
                }
            }
        }

        if let apple = appleItem {
            if !items.isEmpty, !(items.last?.isSeparatorItem ?? true) {
                items.append(.separator())
            }
            items.append(apple)
        }

        return items
    }

    private func buildSingleMenuItem(
        from child: AXUIElement,
        itemData: [String: Any],
        target: AnyObject?,
        action: Selector?,
        isSubmenu: Bool,
        isFirst: inout Bool,
        isApple: Bool
    ) -> NSMenuItem? {
        let title = itemData["AXTitle"] as? String ?? ""
        let role = itemData["AXRole"] as? String ?? ""

        if title.isEmpty || role == "AXSeparator" {
            return .separator()
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = child

        item.isEnabled = itemData["AXEnabled"] as? Bool ?? true

        if let mark = itemData["AXMenuItemMarkChar"] as? String, !mark.isEmpty {
            item.state = mark == "✓" ? .on : (mark == "•" ? .mixed : .off)
        }

        setKeyboardShortcut(for: item, from: itemData)

        let hasSubmenu = handleSubmenu(for: item, from: itemData, target: target, action: action)

        if !hasSubmenu && item.isEnabled {
            item.target = target
            item.action = action
        }

        if !isSubmenu, isFirst || isApple {
            item.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.font: boldFont]
            )
            if !isApple {
                isFirst = false
            }
        }

        return item
    }

    private func setKeyboardShortcut(for item: NSMenuItem, from values: [String: Any]) {
        guard let cmd = values["AXMenuItemCmdChar"] as? String, !cmd.isEmpty else { return }

        item.keyEquivalent = cmd.lowercased()
        let flags = NSEvent.ModifierFlags.fromAXModifiers(values["AXMenuItemCmdModifiers"] as? Int)
        item.keyEquivalentModifierMask = flags
    }

    private func handleSubmenu(
        for item: NSMenuItem,
        from values: [String: Any],
        target: AnyObject?,
        action _: Selector?
    ) -> Bool {
        guard let subChildren = values["AXChildren"] as? [AXUIElement],
              !subChildren.isEmpty,
              let firstSub = subChildren.first,
              let subRole = firstSub.getAttribute("AXRole") as? String,
              subRole == "AXMenu"
        else {
            return false
        }

        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false

        submenu.delegate = target as? NSMenuDelegate
        submenu.axRootElement = firstSub
        item.submenu = submenu

        return true
    }

    private func isAppleMenuItem(title: String?, itemData: [String: Any]) -> Bool {
        title == "Apple" || (itemData["AXRoleDescription"] as? String) == "Apple menu"
    }
}

private nonisolated(unsafe) var kAXRootElementAssociatedKey: UInt8 = 0
private nonisolated(unsafe) var kIsPopulatingAssociatedKey: UInt8 = 0

extension NSMenu {
    var axRootElement: AXUIElement? {
        get {
            guard let obj = objc_getAssociatedObject(self, &kAXRootElementAssociatedKey) else {
                return nil
            }
            return (obj as! AXUIElement)
        }
        set {
            objc_setAssociatedObject(
                self, &kAXRootElementAssociatedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var isPopulatingAsynchronously: Bool {
        get {
            (objc_getAssociatedObject(self, &kIsPopulatingAssociatedKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self, &kIsPopulatingAssociatedKey, NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

extension AXUIElement {
    func getAttribute(_ name: String) -> Any? {
        autoreleasepool {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success
                ? value : nil
        }
    }

    func getChildren() -> [AXUIElement]? {
        autoreleasepool {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(self, "AXChildren" as CFString, &value) == .success,
                  let children = value as? [AXUIElement], !children.isEmpty
            else {
                return nil
            }
            return children
        }
    }

    func getMultipleAttributes(_ names: [String]) -> [String: Any]? {
        autoreleasepool {
            let attrs = names as CFArray
            var values: CFArray?
            let options = AXCopyMultipleAttributeOptions(rawValue: 0)

            guard AXUIElementCopyMultipleAttributeValues(self, attrs, options, &values) == .success,
                  let results = values as? [Any], results.count == names.count
            else { return nil }

            var dict: [String: Any] = [:]
            dict.reserveCapacity(names.count)

            for i in 0 ..< names.count {
                let value = results[i]
                if !(value is NSNull) {
                    dict[names[i]] = value
                }
            }
            return dict.isEmpty ? nil : dict
        }
    }
}

extension NSEvent.ModifierFlags {
    static func fromAXModifiers(_ maybeMods: Int?) -> NSEvent.ModifierFlags {
        guard let mods = maybeMods else { return [.command] }
        var flags: NSEvent.ModifierFlags = []
        if mods & 1 != 0 { flags.insert(.shift) }
        if mods & 2 != 0 { flags.insert(.option) }
        if mods & 4 != 0 { flags.insert(.control) }
        if mods & 8 != 0 { flags.insert(.command) }
        if flags.isEmpty { flags.insert(.command) }
        return flags
    }
}
