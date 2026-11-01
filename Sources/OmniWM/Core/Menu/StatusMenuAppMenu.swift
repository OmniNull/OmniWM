// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@preconcurrency import ApplicationServices

struct StatusMenuAppMenuItem: Identifiable {
    let id: String
    let title: String
    let shortcut: String?
    let isEnabled: Bool
    let isSeparator: Bool
    let hasSubmenu: Bool
    let element: AXUIElement?
    let pid: pid_t

    static func separator(id: String, pid: pid_t) -> Self {
        Self(
            id: id,
            title: "",
            shortcut: nil,
            isEnabled: false,
            isSeparator: true,
            hasSubmenu: false,
            element: nil,
            pid: pid
        )
    }
}

struct StatusMenuAppMenuGroup: Identifiable {
    let id: String
    let title: String
    let submenuRoot: AXUIElement?
}

struct StatusMenuAppMenu {
    let groups: [StatusMenuAppMenuGroup]

    var isEmpty: Bool {
        groups.isEmpty
    }
}

/// Reads the focused application's menu bar so the status menu can present it.
/// Top-level menus are read eagerly; each menu's items are read the first time
/// the section expands them, since subtree reads are the expensive part.
@MainActor
final class StatusMenuAppMenuLoader {
    static let menuReadTimeout: Float = 0.25
    static let submenuReadTimeout: TimeInterval = 0.25

    private static let kAXPressAction = "AXPress" as CFString
    private static let pressMessagingTimeout: Float = 0.25

    private let extractor = MenuExtractor(submenuTimeout: submenuReadTimeout)
    private let reader = MenuAXReader(environment: .live, submenuTimeout: submenuReadTimeout)
    private var menuCache: [pid_t: StatusMenuAppMenu] = [:]
    private var itemCache: [ItemCacheKey: [StatusMenuAppMenuItem]] = [:]

    private struct ItemCacheKey: Hashable {
        let pid: pid_t
        let groupID: String
    }

    func menu(for pid: pid_t) -> StatusMenuAppMenu? {
        if let cached = menuCache[pid] {
            return cached
        }
        guard let menuBar = extractor.getMenuBar(for: pid, messagingTimeout: Self.menuReadTimeout) else {
            Log.config.debug("status menu: no menu bar for pid \(pid)")
            return nil
        }
        let snapshots: [MenuItemSnapshot]
        do {
            snapshots = try reader.readMenuBarSnapshots(from: menuBar, content: .all)
        } catch {
            Log.config.error("status menu: menu bar read failed for pid \(pid): \(error)")
            return nil
        }
        let menu = StatusMenuAppMenu(
            groups: snapshots.enumerated().compactMap { Self.makeGroup($0.element, index: $0.offset) }
        )
        guard !menu.isEmpty else { return nil }
        menuCache[pid] = menu
        return menu
    }

    func items(for group: StatusMenuAppMenuGroup, pid: pid_t) -> [StatusMenuAppMenuItem] {
        let key = ItemCacheKey(pid: pid, groupID: group.id)
        if let cached = itemCache[key] {
            return cached
        }
        guard let root = group.submenuRoot else { return [] }
        let snapshots: [MenuItemSnapshot]
        do {
            snapshots = try reader.readSubmenuSnapshots(from: root)
        } catch {
            Log.config.error("status menu: submenu read failed for \(group.title): \(error)")
            return []
        }
        let items = Self.makeItems(from: snapshots, groupID: group.id, pid: pid)
        // Do not cache an empty read: a transient failure must be retryable.
        guard !items.isEmpty else { return items }
        itemCache[key] = items
        return items
    }

    func invalidate(pid: pid_t) {
        menuCache.removeValue(forKey: pid)
        itemCache = itemCache.filter { $0.key.pid != pid }
    }

    func invalidateAll() {
        menuCache.removeAll()
        itemCache.removeAll()
    }

    static func makeGroup(_ snapshot: MenuItemSnapshot, index: Int) -> StatusMenuAppMenuGroup? {
        let title = snapshot.attributes["AXTitle"] as? String ?? ""
        guard !title.isEmpty, snapshot.submenuRoot != nil else { return nil }
        // The system Apple menu is not part of the app's own menu bar.
        guard !MenuAXReader.isAppleMenuItem(snapshot.attributes) else { return nil }
        return StatusMenuAppMenuGroup(id: "\(title)#\(index)", title: title, submenuRoot: snapshot.submenuRoot)
    }

    static func makeItems(
        from snapshots: [MenuItemSnapshot],
        groupID: String,
        pid: pid_t
    ) -> [StatusMenuAppMenuItem] {
        var items: [StatusMenuAppMenuItem] = []
        items.reserveCapacity(snapshots.count)

        for (index, snapshot) in snapshots.enumerated() {
            let attributes = snapshot.attributes
            let role = attributes["AXRole"] as? String ?? ""
            let title = attributes["AXTitle"] as? String ?? ""
            let itemID = "\(groupID)#\(index)"

            if role == "AXSeparator" {
                items.append(.separator(id: itemID, pid: pid))
                continue
            }
            guard !title.isEmpty else { continue }

            items.append(
                StatusMenuAppMenuItem(
                    id: itemID,
                    title: title,
                    shortcut: MenuShortcutFormatter.format(attributes: attributes),
                    // MenuAXReader normalizes a missing AXEnabled to false, so a nil
                    // value here means the item reported no usable state.
                    isEnabled: attributes["AXEnabled"] as? Bool ?? false,
                    isSeparator: false,
                    hasSubmenu: snapshot.submenuRoot != nil,
                    element: snapshot.element,
                    pid: pid
                )
            )
        }

        // Drop leading, trailing, and doubled separators.
        var trimmed: [StatusMenuAppMenuItem] = []
        for item in items {
            if item.isSeparator {
                if trimmed.isEmpty || trimmed.last?.isSeparator == true { continue }
            }
            trimmed.append(item)
        }
        while trimmed.last?.isSeparator == true {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Triggers the application's own menu item. The target app keeps focus while
    /// the status panel is open, so a direct accessibility press is enough.
    static func press(_ item: StatusMenuAppMenuItem) {
        guard !item.hasSubmenu, let element = item.element else { return }
        guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated else { return }
        if !app.isActive {
            app.activate()
        }
        AXUIElementSetMessagingTimeout(element, pressMessagingTimeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        let result = AXUIElementPerformAction(element, kAXPressAction)
        if result != .success {
            Log.config.error("status menu: AXPress failed for \(item.title): \(result.rawValue)")
        }
    }
}
