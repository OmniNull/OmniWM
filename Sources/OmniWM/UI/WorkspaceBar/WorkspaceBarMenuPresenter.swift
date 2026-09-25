// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class WorkspaceBarMenuPresenter: NSObject {
    private var actions: [WorkspaceBarMenuAction] = []
    private var selectedAction: WorkspaceBarMenuAction?
    private var activeMenu: NSMenu?

    func present(
        _ items: [WorkspaceBarMenuItem],
        at location: CGPoint,
        in view: NSView
    ) -> WorkspaceBarMenuAction? {
        guard activeMenu == nil, !items.isEmpty else { return nil }
        actions.removeAll(keepingCapacity: true)
        selectedAction = nil
        let menu = makeMenu(items)
        activeMenu = menu
        defer {
            activeMenu = nil
            actions.removeAll(keepingCapacity: true)
        }
        menu.popUp(positioning: nil, at: location, in: view)
        return selectedAction
    }

    func cancel() {
        activeMenu?.cancelTracking()
    }

    private func makeMenu(_ items: [WorkspaceBarMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(makeItem(item))
        }
        return menu
    }

    private func makeItem(_ item: WorkspaceBarMenuItem) -> NSMenuItem {
        switch item {
        case let .action(title, action, isEnabled, isChecked):
            let menuItem = NSMenuItem(title: title, action: #selector(select(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = actions.count
            menuItem.isEnabled = isEnabled
            menuItem.state = isChecked ? .on : .off
            actions.append(action)
            return menuItem
        case let .submenu(title, children, isEnabled):
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.submenu = makeMenu(children)
            menuItem.isEnabled = isEnabled && !children.isEmpty
            return menuItem
        case let .header(title):
            return NSMenuItem.sectionHeader(title: title)
        case .separator:
            return NSMenuItem.separator()
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        selectedAction = actions[sender.tag]
    }
}
