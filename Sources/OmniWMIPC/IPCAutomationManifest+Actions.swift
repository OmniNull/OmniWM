// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation

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

    public static let windowActionDescriptors = IPCWindowActionForm.all.map { form in
        IPCWindowActionDescriptor(
            path: (["window", form.name.rawValue] + form.arguments.map { "<\($0.usagePlaceholder)>" })
                .joined(separator: " "),
            name: form.name,
            summary: windowActionSummary(for: form.name),
            arguments: form.arguments.map(\.rawValue)
        )
    }

    private static func windowActionSummary(for name: IPCWindowActionName) -> String {
        switch name {
        case .focus:
            "Focus a managed window by session-scoped opaque id."
        case .navigate:
            "Navigate to a managed window by session-scoped opaque id."
        case .summonRight:
            "Summon a managed window to the right of the focused window."
        case .close:
            "Close a managed window by session-scoped opaque id through its close button."
        case .moveToWorkspace:
            "Move a managed window to a workspace by raw id or unambiguous display name without changing focus."
        case .moveColumnToFirst:
            "Move the column containing a managed window to the first position without changing focus (Niri only)."
        case .moveColumnToLast:
            "Move the column containing a managed window to the last position without changing focus (Niri only)."
        case .moveColumnToIndex:
            "Move the column containing a managed window to a one-based column index without changing focus (Niri only)."
        case .moveColumn:
            "Move the column containing a managed window one step in a direction without changing focus (Niri only)."
        case .toggleContainerFullPrimarySpan:
            "Toggle full primary span for the column containing a managed window without changing focus (Niri only)."
        case .setContainerPrimarySpan:
            "Set the primary span of the column containing a managed window without changing focus (Niri only)."
        case .setWindowPrimarySpan:
            "Set the primary span of a managed window without changing focus (Niri only)."
        case .cycleWindowPrimarySpan:
            "Cycle the primary span preset of a managed window without changing focus (Niri only)."
        case .setWindowSecondarySpan:
            "Set the secondary span of a managed window within its column without changing focus (Niri only)."
        case .resetWindowSecondarySpan:
            "Reset the secondary span of a managed window within its column without changing focus (Niri only)."
        case .cycleWindowSecondarySpan:
            "Cycle the secondary span preset of a managed window without changing focus (Niri only)."
        case .toggleColumnTabbed:
            "Toggle tabbed display for the column containing a managed window without changing focus (Niri only)."
        case .toggleFloating:
            "Toggle a managed window between tiled and floating without changing focus."
        case .assignToScratchpad:
            "Assign a managed window to a numbered scratchpad slot, or release it when already there, without changing focus."
        }
    }

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
            flag: "--assign-to-workspace-for-all-windows",
            summary: "Apply the workspace assignment to every new matching window. Requires --assign-to-workspace."
        ),
        .init(
            flag: "--scratchpad",
            summary: "Join matching windows to a scratchpad slot from 1 to 10 when OmniWM starts managing them. Cannot be combined with --assign-to-workspace or --layout tile.",
            valuePlaceholder: "<1-10>"
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
        let catalog = workspaceActionDescriptors
        var matches: [IPCWorkspaceActionDescriptor] = []
        for index in catalog.indices
            where actionWords.count >= catalog[index].actionWords.count
            && actionWords.starts(with: catalog[index].actionWords)
        {
            matches.append(catalog[index])
        }
        matches.sort { $0.path < $1.path }
        return matches
    }
}

extension IPCWindowActionArgumentKind {
    var usagePlaceholder: String {
        switch self {
        case .direction: IPCDirection.allCases.map(\.rawValue).joined(separator: "|")
        case .cycleDirection: IPCCycleDirection.allCases.map(\.rawValue).joined(separator: "|")
        case .windowID,
             .workspace,
             .number,
             .sizeChange: rawValue
        }
    }
}
