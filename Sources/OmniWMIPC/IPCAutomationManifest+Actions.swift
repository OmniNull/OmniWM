// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let workspaceActionDescriptors: [IPCWorkspaceActionDescriptor] = [
        .init(
            actionWords: ["focus-name"],
            name: .focusName,
            summary: "Focus a workspace by raw workspace ID or unambiguous configured display name.",
            arguments: ["name"]
        ),
        .init(
            actionWords: ["move-to-monitor"],
            name: .moveToMonitor,
            summary: "Move a workspace to an adjacent monitor; --force temporarily overrides its configured assignment.",
            arguments: ["workspace", "left|right|up|down"],
            optionalFlags: ["--force"]
        ),
        .init(
            actionWords: ["rename"],
            name: .rename,
            summary: "Set or clear a workspace display name; an empty name restores the raw workspace ID.",
            arguments: ["workspace", "display-name"]
        )
    ]

    public static let windowActionDescriptors: [IPCWindowActionDescriptor] = [
        .init(
            path: "window focus <opaque-id>",
            name: .focus,
            summary: "Focus a managed window by session-scoped opaque id.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window navigate <opaque-id>",
            name: .navigate,
            summary: "Navigate to a managed window by session-scoped opaque id.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window summon-right <opaque-id>",
            name: .summonRight,
            summary: "Summon a managed window to the right of the focused window.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window close <opaque-id>",
            name: .close,
            summary: "Close a managed window by session-scoped opaque id through its close button.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window move-to-workspace <opaque-id> <workspace>",
            name: .moveToWorkspace,
            summary: "Move a managed window to a workspace by raw id or unambiguous display name without changing focus.",
            arguments: ["opaque-id", "workspace"]
        ),
        .init(
            path: "window move-column-to-first <opaque-id>",
            name: .moveColumnToFirst,
            summary: "Move the column containing a managed window to the first position without changing focus (Niri only).",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window move-column-to-last <opaque-id>",
            name: .moveColumnToLast,
            summary: "Move the column containing a managed window to the last position without changing focus (Niri only).",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window move-column-to-index <opaque-id> <number>",
            name: .moveColumnToIndex,
            summary: "Move the column containing a managed window to a one-based column index without changing focus (Niri only).",
            arguments: ["opaque-id", "number"]
        ),
        .init(
            path: "window move-column <opaque-id> <left|right|up|down>",
            name: .moveColumn,
            summary: "Move the column containing a managed window one step in a direction without changing focus (Niri only).",
            arguments: ["opaque-id", "direction"]
        ),
        .init(
            path: "window toggle-container-full-primary-span <opaque-id>",
            name: .toggleContainerFullPrimarySpan,
            summary: "Toggle full primary span for the column containing a managed window without changing focus (Niri only).",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window set-container-primary-span <opaque-id> <size-change>",
            name: .setContainerPrimarySpan,
            summary: "Set the primary span of the column containing a managed window without changing focus (Niri only).",
            arguments: ["opaque-id", "size-change"]
        ),
        .init(
            path: "window set-window-primary-span <opaque-id> <size-change>",
            name: .setWindowPrimarySpan,
            summary: "Set the primary span of a managed window without changing focus (Niri only).",
            arguments: ["opaque-id", "size-change"]
        ),
        .init(
            path: "window cycle-window-primary-span <opaque-id> <forward|backward>",
            name: .cycleWindowPrimarySpan,
            summary: "Cycle the primary span preset of a managed window without changing focus (Niri only).",
            arguments: ["opaque-id", "cycle-direction"]
        ),
        .init(
            path: "window set-window-secondary-span <opaque-id> <size-change>",
            name: .setWindowSecondarySpan,
            summary: "Set the secondary span of a managed window within its column without changing focus (Niri only).",
            arguments: ["opaque-id", "size-change"]
        ),
        .init(
            path: "window reset-window-secondary-span <opaque-id>",
            name: .resetWindowSecondarySpan,
            summary: "Reset the secondary span of a managed window within its column without changing focus (Niri only).",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window cycle-window-secondary-span <opaque-id> <forward|backward>",
            name: .cycleWindowSecondarySpan,
            summary: "Cycle the secondary span preset of a managed window without changing focus (Niri only).",
            arguments: ["opaque-id", "cycle-direction"]
        ),
        .init(
            path: "window toggle-column-tabbed <opaque-id>",
            name: .toggleColumnTabbed,
            summary: "Toggle tabbed display for the column containing a managed window without changing focus (Niri only).",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window toggle-floating <opaque-id>",
            name: .toggleFloating,
            summary: "Toggle a managed window between tiled and floating without changing focus.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window assign-to-scratchpad <opaque-id> <number>",
            name: .assignToScratchpad,
            summary: "Assign a managed window to a numbered scratchpad slot, or release it when already there, without changing focus.",
            arguments: ["opaque-id", "number"]
        )
    ]

    public static let captureActionDescriptors: [IPCCaptureActionDescriptor] = [
        .init(
            path: "capture start <trace|performance>",
            name: .start,
            summary: "Start a trace or performance capture.",
            arguments: ["trace|performance"]
        ),
        .init(
            path: "capture stop",
            name: .stop,
            summary: "Finalize the active capture."
        ),
        .init(
            path: "capture status",
            name: .status,
            summary: "Return the current capture state and remembered artifact."
        )
    ]

    public static let ruleDefinitionOptionDescriptors: [IPCRuleActionOptionDescriptor] = [
        .init(
            flag: "--bundle-id",
            summary: "Match windows by application bundle identifier.",
            valuePlaceholder: "<bundle-id>"
        ),
        .init(
            flag: "--app-name-substring",
            summary: "Match windows by application display-name substring.",
            valuePlaceholder: "<text>"
        ),
        .init(
            flag: "--title-substring",
            summary: "Match windows by title substring.",
            valuePlaceholder: "<text>"
        ),
        .init(
            flag: "--title-regex",
            summary: "Match windows by title regular expression.",
            valuePlaceholder: "<pattern>"
        ),
        .init(
            flag: "--ax-role",
            summary: "Match windows by accessibility role.",
            valuePlaceholder: "<role>"
        ),
        .init(
            flag: "--ax-subrole",
            summary: "Match windows by accessibility subrole.",
            valuePlaceholder: "<subrole>"
        ),
        .init(
            flag: "--layout",
            summary: "Set the rule layout action.",
            valuePlaceholder: "<auto|tile|float>"
        ),
        .init(
            flag: "--assign-to-workspace",
            summary: "Assign matching windows to a workspace name.",
            valuePlaceholder: "<name>"
        ),
        .init(
            flag: "--initial-container-primary-span",
            summary: "Set the initial Niri container primary-span proportion for resizable windows (0.05 through 1.0).",
            valuePlaceholder: "<proportion>"
        ),
        .init(
            flag: "--min-width",
            summary: "Set the minimum floating width in points.",
            valuePlaceholder: "<points>"
        ),
        .init(
            flag: "--min-height",
            summary: "Set the minimum floating height in points.",
            valuePlaceholder: "<points>"
        )
    ]

    public static let ruleActionDescriptors: [IPCRuleActionDescriptor] = [
        .init(
            path: "rule add [options]",
            name: .add,
            summary: "Append a new persisted user rule.",
            options: ruleDefinitionOptionDescriptors
        ),
        .init(
            path: "rule replace <rule-id> [options]",
            name: .replace,
            summary: "Replace a persisted user rule in place.",
            arguments: ["rule-id"],
            options: ruleDefinitionOptionDescriptors
        ),
        .init(
            path: "rule remove <rule-id>",
            name: .remove,
            summary: "Remove a persisted user rule.",
            arguments: ["rule-id"]
        ),
        .init(
            path: "rule move <rule-id> <position>",
            name: .move,
            summary: "Move a persisted user rule to a one-based position.",
            arguments: ["rule-id", "position"]
        ),
        .init(
            path: "rule apply [--focused|--window <opaque-id>|--pid <pid>]",
            name: .apply,
            summary: "Reapply the current rule set to a focused window, explicit window id, or process.",
            options: [
                .init(
                    flag: "--focused",
                    summary: "Reapply rules to the currently focused automation target.",
                    exclusiveGroup: "target"
                ),
                .init(
                    flag: "--window",
                    summary: "Reapply rules to a specific managed window by opaque id.",
                    valuePlaceholder: "<opaque-id>",
                    exclusiveGroup: "target"
                ),
                .init(
                    flag: "--pid",
                    summary: "Reapply rules to all managed windows for a process id.",
                    valuePlaceholder: "<pid>",
                    exclusiveGroup: "target"
                )
            ]
        )
    ]

    public static func ruleActionDescriptor(for name: IPCRuleActionName) -> IPCRuleActionDescriptor? {
        ruleActionDescriptors.first { $0.name == name }
    }

    public static func workspaceActionDescriptors(matching actionWords: [String]) -> [IPCWorkspaceActionDescriptor] {
        workspaceActionDescriptors
            .sorted { $0.path < $1.path }
            .filter { descriptor in
                guard actionWords.count >= descriptor.actionWords.count else { return false }
                return Array(actionWords.prefix(descriptor.actionWords.count)) == descriptor.actionWords
            }
    }
}
