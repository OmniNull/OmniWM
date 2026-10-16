// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import ObjectiveC

enum MenuContent: Equatable, Sendable {
    case all
    case application
    case apple
}

@MainActor
final class MenuExtractor {
    private let boldFont = NSFontManager.shared.convert(
        NSFont.menuFont(ofSize: NSFont.systemFontSize), toHaveTrait: .boldFontMask
    )
    private let reader: MenuAXReader

    init(
        environment: MenuExtractorEnvironment = .live,
        submenuTimeout: TimeInterval = 0.25
    ) {
        reader = MenuAXReader(environment: environment, submenuTimeout: submenuTimeout)
    }

    func getMenuBar(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarValue)
        guard result == .success else { return nil }
        return AXUIElement.from(menuBarValue)
    }

    func buildMenu(from element: AXUIElement, target: AnyObject?, action: Selector?) -> [NSMenuItem] {
        autoreleasepool {
            buildMenuItems(from: element, target: target, action: action, isSubmenu: false)
        }
    }

    func buildMenu(
        from element: AXUIElement,
        content: MenuContent,
        target: AnyObject?,
        action: Selector?
    ) throws -> [NSMenuItem] {
        if content == .all {
            return buildMenu(from: element, target: target, action: action)
        }
        return try autoreleasepool {
            let snapshots = try reader.readMenuBarSnapshots(from: element, content: content)
            return buildMenuItems(
                from: snapshots,
                target: target,
                action: action,
                isSubmenu: content == .apple
            )
        }
    }

    func buildSubmenu(
        from element: AXUIElement,
        target: AnyObject?,
        action: Selector?
    ) throws -> [NSMenuItem] {
        try autoreleasepool {
            let snapshots = try reader.readSubmenuSnapshots(from: element)
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
                guard let itemData = child.getMultipleAttributes(MenuAXReader.itemAttributeKeys) else { return }

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
                    if excludeAppleMenu, depth == 0, MenuAXReader.isAppleMenuItem(itemData) {
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

        let snapshots = autoreleasepool {
            var results: [MenuItemSnapshot] = []
            results.reserveCapacity(children.count)

            for child in children {
                let attributes = child.getMultipleAttributes(MenuAXReader.itemAttributeKeys) ?? [:]
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
                let isApple = MenuAXReader.isAppleMenuItem(itemData)
                if let item = buildSingleMenuItem(
                    from: snapshot,
                    target: target,
                    action: action
                ) {
                    if item.isSeparatorItem {
                        needsSeparator = true
                        return
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
        action: Selector?
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
}

@MainActor private var kAXRootElementAssociatedKey: UInt8 = 0

@MainActor
extension NSMenu {
    var axRootElement: AXUIElement? {
        get {
            guard let value = objc_getAssociatedObject(self, &kAXRootElementAssociatedKey) else {
                return nil
            }
            return AXUIElement.from(value as CFTypeRef)
        }
        set {
            objc_setAssociatedObject(
                self, &kAXRootElementAssociatedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
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
