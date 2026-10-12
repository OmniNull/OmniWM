// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let windowFieldCatalog: [String] = [
        "id",
        "pid",
        "window-id",
        "workspace",
        "display",
        "app",
        "title",
        "frame",
        "mode",
        "layout-reason",
        "manual-override",
        "is-focused",
        "is-fullscreen",
        "is-visible",
        "is-app-hidden",
        "is-scratchpad",
        "scratchpad-index",
        "hidden-reason",
        "column-index"
    ]

    public static let workspaceFieldCatalog: [String] = [
        "id",
        "raw-name",
        "display-name",
        "number",
        "layout",
        "display",
        "is-focused",
        "is-visible",
        "is-current",
        "window-counts",
        "focused-window-id",
        "columns"
    ]

    public static let displayFieldCatalog: [String] = [
        "id",
        "name",
        "is-main",
        "is-current",
        "frame",
        "visible-frame",
        "has-notch",
        "orientation",
        "inner-gap",
        "outer-gap-left",
        "outer-gap-right",
        "outer-gap-top",
        "outer-gap-bottom",
        "fullscreen-uses-outer-gaps",
        "active-workspace"
    ]

    public static let queryDescriptors: [IPCQueryDescriptor] = [
        IPCQueryDescriptor(
            name: .workspaceBar,
            summary: "Return the workspace bar projection for every monitor."
        ),
        IPCQueryDescriptor(
            name: .activeWorkspace,
            summary: "Return the current interaction monitor and active workspace snapshot."
        ),
        IPCQueryDescriptor(
            name: .focusedMonitor,
            summary: "Return the current interaction monitor and its active workspace snapshot."
        ),
        IPCQueryDescriptor(
            name: .apps,
            summary: "Return the managed app summary used by OmniWM surfaces."
        ),
        IPCQueryDescriptor(
            name: .metrics,
            summary: "Return always-on runtime metrics: AX frame-write attempts and wall time per app context, display tick timing, layout builds, and process energy."
        ),
        IPCQueryDescriptor(
            name: .focusedWindow,
            summary: "Return the focused managed window snapshot."
        ),
        IPCQueryDescriptor(
            name: .windows,
            summary: "Return managed OmniWM windows only.",
            selectors: [
                .init(name: .window, summary: "Filter by a session-scoped opaque window id."),
                .init(name: .workspace, summary: "Filter by workspace raw name, display name, or id."),
                .init(name: .display, summary: "Filter by display name or display id."),
                .init(name: .focused, summary: "Only include the focused managed window."),
                .init(
                    name: .visible,
                    summary: "Only include windows on visible workspaces that are neither hidden nor owned by a hidden app."
                ),
                .init(name: .floating, summary: "Only include floating managed windows."),
                .init(name: .scratchpad, summary: "Only include windows assigned to a scratchpad."),
                .init(name: .app, summary: "Filter by application display name."),
                .init(name: .bundleId, summary: "Filter by application bundle identifier.")
            ],
            fields: windowFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .workspaces,
            summary: "Return configured workspaces with live occupancy and monitor assignment.",
            selectors: [
                .init(name: .workspace, summary: "Filter by workspace raw name, display name, or id."),
                .init(name: .display, summary: "Filter by active monitor name or display id."),
                .init(name: .current, summary: "Only include the interaction monitor's active workspace."),
                .init(name: .visible, summary: "Only include visible workspaces."),
                .init(name: .focused, summary: "Only include the workspace containing the focused managed window.")
            ],
            fields: workspaceFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .displays,
            summary: "Return connected displays with live geometry and active workspace state.",
            selectors: [
                .init(name: .display, summary: "Filter by display name or display id."),
                .init(name: .main, summary: "Only include the main display."),
                .init(name: .current, summary: "Only include the interaction display.")
            ],
            fields: displayFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .rules,
            summary: "Return persisted user window rules with normalized public fields."
        ),
        IPCQueryDescriptor(
            name: .ruleActions,
            summary: "Return the public persisted-rule action registry."
        ),
        IPCQueryDescriptor(
            name: .queries,
            summary: "Return the public automation query registry."
        ),
        IPCQueryDescriptor(
            name: .commands,
            summary: "Return the public automation command registry."
        ),
        IPCQueryDescriptor(
            name: .subscriptions,
            summary: "Return the public subscription registry."
        ),
        IPCQueryDescriptor(
            name: .capabilities,
            summary: "Return protocol, command, query, selector, and subscription capabilities."
        )
    ]

    public static func queryDescriptor(for name: IPCQueryName) -> IPCQueryDescriptor? {
        queryDescriptors.first { $0.name == name }
    }
}
