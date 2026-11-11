// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class CommandPaletteNativeMenu: NSObject {
    enum Action: Equatable {
        case mode(CommandPaletteMode)
        case clipboardPastePlain(UUID)
        case clipboardPin(UUID, Bool)
        case clipboardDelete(UUID)
        case clipboardClear
        case launcherAdd(LauncherEntry.Kind)
        case launcherManage
        case launcherRefresh
        case launcherRun(LauncherSelection)
        case launcher(LauncherSelection, LauncherContextAction)
    }

    enum Item: Equatable {
        case action(String, Action, enabled: Bool = true, checked: Bool = false)
        case separator
    }

    private var actions: [Action] = []
    private var selectedAction: Action?
    private var activeMenu: NSMenu?
    private var revision = 0

    var isTracking: Bool {
        activeMenu != nil
    }

    func present(_ items: [Item], at anchor: ShellAnchor, in view: NSView) -> Action? {
        guard activeMenu == nil, !items.isEmpty, let location = Self.location(for: anchor, in: view) else {
            return nil
        }
        let request = revision
        selectedAction = nil
        let menu = makeMenu(items)
        activeMenu = menu
        defer {
            activeMenu = nil
            selectedAction = nil
            actions.removeAll(keepingCapacity: true)
        }
        menu.popUp(positioning: nil, at: location, in: view)
        return request == revision ? selectedAction : nil
    }

    func cancel() {
        revision &+= 1
        selectedAction = nil
        activeMenu?.cancelTracking()
    }

    static func location(for anchor: ShellAnchor, in view: NSView) -> CGPoint? {
        guard let window = view.window else { return nil }
        let rect = view.convert(window.convertFromScreen(anchor.frame), from: nil)
        return CGPoint(x: rect.minX, y: view.isFlipped ? rect.maxY : rect.minY)
    }

    func makeMenu(_ items: [Item]) -> NSMenu {
        actions.removeAll(keepingCapacity: true)
        actions.reserveCapacity(items.count)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case let .action(title, action, enabled, checked):
                let entry = NSMenuItem(title: title, action: #selector(select(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = actions.count
                entry.isEnabled = enabled
                entry.state = checked ? .on : .off
                actions.append(action)
                menu.addItem(entry)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    static func modes(selected: CommandPaletteMode, menuAvailable: Bool, clearHistory: Bool) -> [Item] {
        var items = CommandPaletteMode.allCases.map { mode in
            Item.action(
                String(
                    localized: "\(mode.localizedDisplayName)  \(CommandPalettePresentation.modeHint(for: mode).shortcut)"
                ),
                .mode(mode),
                enabled: mode != .menu || menuAvailable,
                checked: mode == selected
            )
        }
        if clearHistory {
            items.append(.separator)
            items.append(.action(String(localized: "Clear Unpinned History"), .clipboardClear))
        }
        return items
    }

    static func clipboard(_ item: ClipboardPaletteItem) -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(item.canPastePlainText ? 3 : 2)
        if item.canPastePlainText {
            items.append(.action(String(localized: "Paste Without Formatting"), .clipboardPastePlain(item.id)))
        }
        items.append(.action(
            item.isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
            .clipboardPin(item.id, !item.isPinned)
        ))
        items.append(.action(String(localized: "Delete"), .clipboardDelete(item.id)))
        return items
    }

    static let launcherAdd: [Item] = [
        .action(String(localized: "Add Application…"), .launcherAdd(.application)),
        .action(String(localized: "Add Command…"), .launcherAdd(.command)),
        .action(String(localized: "Add Script…"), .launcherAdd(.script)),
        .separator,
        .action(String(localized: "Manage Launcher…"), .launcherManage),
        .action(String(localized: "Refresh"), .launcherRefresh)
    ]

    static func launcher(_ selection: LauncherSelection, quickLook: Bool, suggestion: String?) -> [Item] {
        var items: [Item] = [
            .action(String(localized: "Open"), .launcher(selection, .open)),
            .action(String(localized: "Show in Finder"), .launcher(selection, .reveal))
        ]
        if quickLook { items.append(.action(String(localized: "Quick Look"), .launcher(selection, .quickLook))) }
        items.append(.separator)
        items.append(.action(String(localized: "Copy"), .launcher(selection, .copy)))
        items.append(.action(String(localized: "Copy Path"), .launcher(selection, .copyPath)))
        if let suggestion {
            items.append(.separator)
            items.append(.action(
                String(localized: "Don’t Suggest “\(suggestion)”"),
                .launcher(selection, .dontSuggest)
            ))
        }
        return items
    }

    static func saved(_ selection: LauncherSelection) -> [Item] {
        [
            .action(String(localized: "Run"), .launcherRun(selection)),
            .action(String(localized: "Edit"), .launcher(selection, .edit)),
            .action(String(localized: "Remove"), .launcher(selection, .remove))
        ]
    }

    static func executable(_ selection: LauncherSelection) -> [Item] {
        [
            .action(String(localized: "Run…"), .launcherRun(selection)),
            .action(String(localized: "Show in Finder"), .launcher(selection, .reveal)),
            .action(String(localized: "Copy Path"), .launcher(selection, .copyPath))
        ]
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard sender.menu === activeMenu, sender.isEnabled, actions.indices.contains(sender.tag) else { return }
        selectedAction = actions[sender.tag]
    }
}
