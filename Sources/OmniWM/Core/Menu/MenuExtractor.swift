// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import ObjectiveC

enum MenuExtractionError: Error, Equatable {
    case ax(AXError)
    case invalidResponse
    case deadlineExceeded
}

struct MenuAXDeadline {
    let expiresAt: TimeInterval

    init(start: TimeInterval, timeout: TimeInterval) {
        expiresAt = start + timeout
    }

    func remaining(at time: TimeInterval) throws -> Float {
        let remaining = expiresAt - time
        guard remaining > 0 else { throw MenuExtractionError.deadlineExceeded }
        return Float(remaining)
    }
}

@MainActor
struct MenuExtractorEnvironment {
    var now: @MainActor () -> TimeInterval
    var readAttribute: @MainActor (AXUIElement, CFString, Float) throws -> Any?
    var readAttributes: @MainActor (AXUIElement, CFArray, Float) throws -> [Any]

    static var live: MenuExtractorEnvironment {
        MenuExtractorEnvironment(
            now: { ProcessInfo.processInfo.systemUptime },
            readAttribute: readMenuAttribute,
            readAttributes: readMenuAttributes
        )
    }
}

struct MenuItemSnapshot {
    let element: AXUIElement
    let attributes: [String: Any]
    let submenuRoot: AXUIElement?
}

@MainActor
final class MenuExtractor {
    private static let itemAttributeKeys = [
        "AXTitle", "AXRole", "AXRoleDescription", "AXEnabled",
        "AXMenuItemMarkChar", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXChildren"
    ]

    private let boldFont = NSFontManager.shared.convert(
        NSFont.menuFont(ofSize: NSFont.systemFontSize), toHaveTrait: .boldFontMask
    )
    private let environment: MenuExtractorEnvironment
    private let submenuTimeout: TimeInterval

    init(
        environment: MenuExtractorEnvironment = .live,
        submenuTimeout: TimeInterval = 0.25
    ) {
        self.environment = environment
        self.submenuTimeout = submenuTimeout
    }

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

    func buildSubmenu(
        from element: AXUIElement,
        target: AnyObject?,
        action: Selector?
    ) throws -> [NSMenuItem] {
        try autoreleasepool {
            let deadline = MenuAXDeadline(start: environment.now(), timeout: submenuTimeout)
            let snapshots = try readSubmenuSnapshots(from: element, deadline: deadline)
            return makeSubmenuItems(from: snapshots, target: target, action: action)
        }
    }

    func makeSubmenuItems(
        from snapshots: [MenuItemSnapshot],
        target: AnyObject?,
        action: Selector?
    ) -> [NSMenuItem] {
        buildMenuItems(from: snapshots, target: target, action: action, isSubmenu: true)
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

    private func readSubmenuSnapshots(
        from element: AXUIElement,
        deadline: MenuAXDeadline
    ) throws -> [MenuItemSnapshot] {
        let childrenValue = try environment.readAttribute(
            element,
            kAXChildrenAttribute as CFString,
            deadline.remaining(at: environment.now())
        )
        guard let childrenValue,
              let children = childrenValue as? [AXUIElement]
        else {
            throw MenuExtractionError.invalidResponse
        }

        let attributes = Self.itemAttributeKeys as CFArray
        var snapshots: [MenuItemSnapshot] = []
        snapshots.reserveCapacity(children.count)

        for child in children {
            let values = try environment.readAttributes(
                child,
                attributes,
                deadline.remaining(at: environment.now())
            )
            var decoded = try Self.decodeAttributeValues(
                names: Self.itemAttributeKeys,
                values: values
            )
            let role = try Self.validateMenuItemAttributes(&decoded)
            let submenuRoot = try readSubmenuRoot(
                from: decoded,
                role: role,
                deadline: deadline
            )
            snapshots.append(
                MenuItemSnapshot(
                    element: child,
                    attributes: decoded,
                    submenuRoot: submenuRoot
                )
            )
        }

        return snapshots
    }

    private func readSubmenuRoot(
        from attributes: [String: Any],
        role: String,
        deadline: MenuAXDeadline
    ) throws -> AXUIElement? {
        guard role != "AXSeparator",
              let childrenValue = attributes[kAXChildrenAttribute as String]
        else {
            return nil
        }
        guard let children = childrenValue as? [AXUIElement] else {
            throw MenuExtractionError.invalidResponse
        }
        guard let submenuRoot = children.first else { return nil }

        let roleValue = try environment.readAttribute(
            submenuRoot,
            kAXRoleAttribute as CFString,
            deadline.remaining(at: environment.now())
        )
        guard let submenuRole = roleValue as? String,
              submenuRole == (kAXMenuRole as String)
        else {
            throw MenuExtractionError.invalidResponse
        }
        return submenuRoot
    }

    static func decodeAttributeValues(
        names: [String],
        values: [Any]
    ) throws -> [String: Any] {
        guard names.count == values.count else {
            throw MenuExtractionError.invalidResponse
        }

        var decoded: [String: Any] = [:]
        decoded.reserveCapacity(names.count)
        for (name, value) in zip(names, values) {
            if let value = try decodedAttributeValue(value) {
                decoded[name] = value
            }
        }
        return decoded
    }

    private static func decodedAttributeValue(_ value: Any) throws -> Any? {
        let cfValue = value as CFTypeRef
        let typeId = CFGetTypeID(cfValue)
        if typeId == CFNullGetTypeID() {
            return nil
        }
        guard typeId == AXValueGetTypeID() else {
            return value
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else {
            return value
        }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error) else {
            throw MenuExtractionError.invalidResponse
        }
        switch error {
        case .attributeUnsupported,
             .noValue:
            return nil
        default:
            throw MenuExtractionError.ax(error)
        }
    }

    private static func validateMenuItemAttributes(_ attributes: inout [String: Any]) throws -> String {
        guard let role = attributes[kAXRoleAttribute as String] as? String else {
            throw MenuExtractionError.invalidResponse
        }
        if role != "AXSeparator" {
            guard attributes[kAXTitleAttribute as String] is String else {
                throw MenuExtractionError.invalidResponse
            }
        }
        try validateOptionalType(String.self, key: kAXRoleDescriptionAttribute as String, in: attributes)
        try validateOptionalType(Bool.self, key: kAXEnabledAttribute as String, in: attributes)
        try validateOptionalType(String.self, key: kAXMenuItemMarkCharAttribute as String, in: attributes)
        try validateOptionalType(String.self, key: kAXMenuItemCmdCharAttribute as String, in: attributes)
        try validateOptionalType(Int.self, key: kAXMenuItemCmdModifiersAttribute as String, in: attributes)
        try validateOptionalType([AXUIElement].self, key: kAXChildrenAttribute as String, in: attributes)
        if attributes[kAXEnabledAttribute as String] == nil {
            attributes[kAXEnabledAttribute as String] = false
        }
        return role
    }

    private static func validateOptionalType<T>(
        _: T.Type,
        key: String,
        in attributes: [String: Any]
    ) throws {
        guard let value = attributes[key] else { return }
        guard value is T else { throw MenuExtractionError.invalidResponse }
    }

    private func buildMenuItems(
        from element: AXUIElement, target: AnyObject?, action: Selector?, isSubmenu: Bool
    ) -> [NSMenuItem] {
        guard let children = element.getChildren() else { return [] }

        let snapshots = autoreleasepool {
            var results: [MenuItemSnapshot] = []
            results.reserveCapacity(children.count)

            for child in children {
                let attributes = child.getMultipleAttributes(Self.itemAttributeKeys) ?? [:]
                let submenuRoot = legacySubmenuRoot(from: attributes)
                results.append(
                    MenuItemSnapshot(
                        element: child,
                        attributes: attributes,
                        submenuRoot: submenuRoot
                    )
                )
            }

            return results
        }

        return buildMenuItems(
            from: snapshots,
            target: target,
            action: action,
            isSubmenu: isSubmenu
        )
    }

    private func buildMenuItems(
        from snapshots: [MenuItemSnapshot],
        target: AnyObject?,
        action: Selector?,
        isSubmenu: Bool
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items.reserveCapacity(snapshots.count)

        var appleItem: NSMenuItem?
        var isFirst = true
        var needsSeparator = false

        for snapshot in snapshots {
            autoreleasepool {
                let itemData = snapshot.attributes
                let isApple = isAppleMenuItem(
                    title: itemData["AXTitle"] as? String, itemData: itemData
                )
                if let item = buildSingleMenuItem(
                    from: snapshot,
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
        from snapshot: MenuItemSnapshot,
        target: AnyObject?,
        action: Selector?,
        isSubmenu: Bool,
        isFirst: inout Bool,
        isApple: Bool
    ) -> NSMenuItem? {
        let itemData = snapshot.attributes
        let title = itemData["AXTitle"] as? String ?? ""
        let role = itemData["AXRole"] as? String ?? ""

        if title.isEmpty || role == "AXSeparator" {
            return .separator()
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = snapshot.element

        item.isEnabled = itemData["AXEnabled"] as? Bool ?? true

        if let mark = itemData["AXMenuItemMarkChar"] as? String, !mark.isEmpty {
            item.state = mark == "✓" ? .on : (mark == "•" ? .mixed : .off)
        }

        setKeyboardShortcut(for: item, from: itemData)

        let hasSubmenu = handleSubmenu(for: item, root: snapshot.submenuRoot, target: target)

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
        root: AXUIElement?,
        target: AnyObject?
    ) -> Bool {
        guard let root else { return false }

        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false

        submenu.delegate = target as? NSMenuDelegate
        submenu.axRootElement = root
        item.submenu = submenu

        return true
    }

    private func legacySubmenuRoot(from attributes: [String: Any]) -> AXUIElement? {
        guard let children = attributes[kAXChildrenAttribute as String] as? [AXUIElement],
              let root = children.first,
              let role = root.getAttribute(kAXRoleAttribute as String) as? String,
              role == (kAXMenuRole as String)
        else {
            return nil
        }
        return root
    }

    private func isAppleMenuItem(title: String?, itemData: [String: Any]) -> Bool {
        title == "Apple" || (itemData["AXRoleDescription"] as? String) == "Apple menu"
    }
}

@MainActor
private func readMenuAttribute(
    _ element: AXUIElement,
    _ attribute: CFString,
    _ timeout: Float
) throws -> Any? {
    try MenuExtractor.withMessagingTimeout(on: element, timeout: timeout) {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { throw MenuExtractionError.ax(result) }
        return value
    }
}

@MainActor
private func readMenuAttributes(
    _ element: AXUIElement,
    _ attributes: CFArray,
    _ timeout: Float
) throws -> [Any] {
    try MenuExtractor.withMessagingTimeout(on: element, timeout: timeout) {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )
        guard result == .success else { throw MenuExtractionError.ax(result) }
        guard let values = values as? [Any] else {
            throw MenuExtractionError.invalidResponse
        }
        return values
    }
}

@MainActor
extension MenuExtractor {
    static func withMessagingTimeout<T>(
        on element: AXUIElement,
        timeout: Float,
        setter: (AXUIElement, Float) -> AXError = { AXUIElementSetMessagingTimeout($0, $1) },
        operation: () throws -> T
    ) throws -> T {
        let result = setter(element, timeout)
        guard result == .success else { throw MenuExtractionError.ax(result) }
        defer { _ = setter(element, 0) }
        return try operation()
    }
}

@MainActor private var kAXRootElementAssociatedKey: UInt8 = 0

@MainActor
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
}

@MainActor
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
