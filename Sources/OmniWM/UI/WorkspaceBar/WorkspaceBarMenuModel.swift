// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum WorkspaceBarMenuAction: Equatable {
    case focusWorkspace(WorkspaceDescriptor.ID)
    case moveFocusedWindow(toWorkspace: WorkspaceDescriptor.ID)
    case renameWorkspace(WorkspaceDescriptor.ID)
    case setLayout(WorkspaceDescriptor.ID, LayoutType)
    case moveWorkspaceToMonitor(WorkspaceDescriptor.ID, Monitor.ID)
    case moveWindowsToWorkspace([WindowToken], WorkspaceDescriptor.ID)
    case moveWindowsToMonitor([WindowToken], Monitor.ID)
    case toggleFloating(WindowToken)
    case summonRight(WindowToken)
    case assignToScratchpad(WindowToken, ScratchpadIndex)
    case createAppRule(WindowToken)
    case closeWindow(WindowToken)
}

indirect enum WorkspaceBarMenuItem: Equatable {
    case action(String, WorkspaceBarMenuAction, isEnabled: Bool = true, isChecked: Bool = false)
    case submenu(String, [WorkspaceBarMenuItem], isEnabled: Bool = true)
    case header(String)
    case separator
}

struct WorkspaceBarMenuFacts: Equatable {
    struct Workspace: Equatable {
        let id: WorkspaceDescriptor.ID
        let name: String
    }

    struct Display: Equatable {
        let id: Monitor.ID
        let name: String
        let workspaces: [Workspace]
    }

    struct ScratchpadSlot: Equatable {
        let index: ScratchpadIndex
        let name: String
    }

    let displays: [Display]
    let focusedWindowWorkspaceId: WorkspaceDescriptor.ID?
    let scratchpadSlots: [ScratchpadSlot]
}

struct WorkspaceBarWorkspaceMenuTarget: Equatable {
    let id: WorkspaceDescriptor.ID
    let monitorId: Monitor.ID
    let isConfigured: Bool
    let layout: ActiveLayoutKind
}

struct WorkspaceBarWindowMenuTarget: Equatable {
    let token: WindowToken
    let title: String
    let workspaceId: WorkspaceDescriptor.ID
    let monitorId: Monitor.ID
    let isFloating: Bool
    let canMove: Bool
    let canSummon: Bool
}

enum WorkspaceBarMenuBuilder {
    static func workspaceMenu(
        for target: WorkspaceBarWorkspaceMenuTarget,
        facts: WorkspaceBarMenuFacts
    ) -> [WorkspaceBarMenuItem] {
        let canMoveFocusedWindow = facts.focusedWindowWorkspaceId.map { $0 != target.id } ?? false
        let otherDisplays = facts.displays.filter { $0.id != target.monitorId }
        return [
            .action(String(localized: "Focus Workspace"), .focusWorkspace(target.id)),
            .action(
                String(localized: "Move Focused Window Here"),
                .moveFocusedWindow(toWorkspace: target.id),
                isEnabled: canMoveFocusedWindow
            ),
            .separator,
            .action(
                target.isConfigured
                    ? String(localized: "Rename…")
                    : String(localized: "Rename… (configured workspaces only)"),
                .renameWorkspace(target.id),
                isEnabled: target.isConfigured
            ),
            .submenu(
                target.isConfigured
                    ? String(localized: "Layout")
                    : String(localized: "Layout (configured workspaces only)"),
                layoutItems(for: target),
                isEnabled: target.isConfigured
            ),
            .submenu(
                String(localized: "Move Workspace to Monitor"),
                otherDisplays.map { .action($0.name, .moveWorkspaceToMonitor(target.id, $0.id)) },
                isEnabled: !otherDisplays.isEmpty
            )
        ]
    }

    static func windowMenu(
        for windows: [WorkspaceBarWindowMenuTarget],
        facts: WorkspaceBarMenuFacts
    ) -> [WorkspaceBarMenuItem] {
        guard let first = windows.first else { return [] }
        guard windows.count > 1 else { return singleWindowItems(for: first, facts: facts) }
        let movable = windows.filter(\.canMove).map(\.token)
        var items = moveItems(
            tokens: movable,
            sourceWorkspaceId: first.workspaceId,
            facts: facts,
            workspaceTitle: String(localized: "Move All to Workspace"),
            monitorTitle: String(localized: "Move All to Monitor")
        )
        items.append(.separator)
        items += windows.map { window in
            .submenu(window.title, singleWindowItems(for: window, facts: facts))
        }
        return items
    }

    private static func singleWindowItems(
        for window: WorkspaceBarWindowMenuTarget,
        facts: WorkspaceBarMenuFacts
    ) -> [WorkspaceBarMenuItem] {
        var items = moveItems(
            tokens: window.canMove ? [window.token] : [],
            sourceWorkspaceId: window.workspaceId,
            facts: facts,
            workspaceTitle: String(localized: "Move to Workspace"),
            monitorTitle: String(localized: "Move to Monitor")
        )
        items += [
            .separator,
            .action(
                window.isFloating ? String(localized: "Tile Window") : String(localized: "Float Window"),
                .toggleFloating(window.token),
                isEnabled: window.canMove
            ),
            .action(
                String(localized: "Summon to the Right"),
                .summonRight(window.token),
                isEnabled: window.canSummon
            ),
            .submenu(
                String(localized: "Assign to Scratchpad"),
                facts.scratchpadSlots.map { .action($0.name, .assignToScratchpad(window.token, $0.index)) },
                isEnabled: window.canMove
            ),
            .action(String(localized: "Create App Rule…"), .createAppRule(window.token)),
            .separator,
            .action(String(localized: "Close Window"), .closeWindow(window.token))
        ]
        return items
    }

    private static func moveItems(
        tokens: [WindowToken],
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        facts: WorkspaceBarMenuFacts,
        workspaceTitle: String,
        monitorTitle: String
    ) -> [WorkspaceBarMenuItem] {
        let workspaceTargets = workspaceTargetItems(
            tokens: tokens,
            excluding: sourceWorkspaceId,
            facts: facts
        )
        let monitorTargets = facts.displays.filter { display in
            !display.workspaces.contains { $0.id == sourceWorkspaceId }
        }
        return [
            .submenu(
                workspaceTitle,
                workspaceTargets,
                isEnabled: !tokens.isEmpty && !workspaceTargets.isEmpty
            ),
            .submenu(
                monitorTitle,
                monitorTargets.map { .action($0.name, .moveWindowsToMonitor(tokens, $0.id)) },
                isEnabled: !tokens.isEmpty && !monitorTargets.isEmpty
            )
        ]
    }

    private static func workspaceTargetItems(
        tokens: [WindowToken],
        excluding sourceWorkspaceId: WorkspaceDescriptor.ID,
        facts: WorkspaceBarMenuFacts
    ) -> [WorkspaceBarMenuItem] {
        let sections = facts.displays.compactMap { display -> (String, [WorkspaceBarMenuItem])? in
            let items = display.workspaces
                .filter { $0.id != sourceWorkspaceId }
                .map { WorkspaceBarMenuItem.action($0.name, .moveWindowsToWorkspace(tokens, $0.id)) }
            return items.isEmpty ? nil : (display.name, items)
        }
        guard facts.displays.count > 1 else { return sections.flatMap(\.1) }
        return sections.flatMap { [.header($0.0)] + $0.1 }
    }

    private static func layoutItems(for target: WorkspaceBarWorkspaceMenuTarget) -> [WorkspaceBarMenuItem] {
        [(LayoutType.niri, ActiveLayoutKind.niri), (.dwindle, .dwindle)].map { layout, kind in
            .action(
                layout.localizedDisplayName,
                .setLayout(target.id, layout),
                isChecked: target.layout == kind
            )
        }
    }
}
