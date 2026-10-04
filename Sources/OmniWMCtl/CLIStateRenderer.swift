// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum CLIStateRenderer {
    static func formattedActiveWorkspace(
        _ payload: IPCActiveWorkspaceQueryResult,
        format: CLIOutputFormat
    ) -> String {
        CLITableRenderer.formatRows(
            headers: ["DISPLAY", "WORKSPACE", "APP"],
            rows: [[
                payload.display?.name ?? "-",
                payload.workspace?.displayName ?? "-",
                payload.focusedApp?.name ?? "-"
            ]],
            format: format
        )
    }

    static func formattedFocusedMonitor(
        _ payload: IPCFocusedMonitorQueryResult,
        format: CLIOutputFormat
    ) -> String {
        CLITableRenderer.formatRows(
            headers: ["DISPLAY", "ACTIVE WORKSPACE"],
            rows: [[payload.display?.name ?? "-", payload.activeWorkspace?.displayName ?? "-"]],
            format: format
        )
    }

    static func formattedFocusedWindow(
        _ payload: IPCFocusedWindowQueryResult,
        format: CLIOutputFormat
    ) -> String {
        guard let window = payload.window else {
            return "no focused window"
        }

        return CLITableRenderer.formatRows(
            headers: ["ID", "PID", "APP", "TITLE", "WORKSPACE", "FRAME"],
            rows: [[
                window.id,
                pidDescription(window.pid),
                window.app?.name ?? "-",
                window.title ?? "-",
                window.workspace?.displayName ?? "-",
                frameDescription(window.frame)
            ]],
            format: format
        )
    }

    static func formattedWindows(_ payload: IPCWindowsQueryResult, format: CLIOutputFormat) -> String {
        var rows = payload.windows.map { window in
            [
                window.id ?? "-",
                pidDescription(window.pid),
                window.app?.name ?? "-",
                window.title ?? "-",
                window.workspace?.displayName ?? "-",
                window.display?.name ?? "-",
                window.mode?.rawValue ?? "-",
                CLITableRenderer.boolDescription(window.isFocused),
                CLITableRenderer.boolDescription(window.isVisible),
                window.scratchpadIndex.map(String.init) ?? CLITableRenderer.boolDescription(window.isScratchpad)
            ]
        }
        var headers = ["ID", "PID", "APP", "TITLE", "WORKSPACE", "DISPLAY", "MODE", "FOCUSED", "VISIBLE", "SCRATCHPAD"]
        appendColumn(
            "WINDOW ID",
            values: payload.windows.map { $0.windowId.map(String.init) },
            headers: &headers,
            rows: &rows
        )
        appendColumn(
            "COLUMN",
            values: payload.windows.map { $0.columnIndex.map(String.init) },
            headers: &headers,
            rows: &rows
        )

        return CLITableRenderer.formatRows(headers: headers, rows: rows, format: format)
    }

    static func formattedWorkspaces(_ payload: IPCWorkspacesQueryResult, format: CLIOutputFormat) -> String {
        var headers = ["ID", "WORKSPACE", "DISPLAY", "LAYOUT", "CURRENT", "VISIBLE", "COUNTS", "FOCUSED WINDOW"]
        var rows = payload.workspaces.map { workspace in
            [
                workspace.id ?? "-",
                workspace.displayName ?? workspace.rawName ?? "-",
                workspace.display?.name ?? "-",
                workspace.layout?.rawValue ?? "-",
                CLITableRenderer.boolDescription(workspace.isCurrent),
                CLITableRenderer.boolDescription(workspace.isVisible),
                countsDescription(workspace.counts),
                workspace.focusedWindowId ?? "-"
            ]
        }
        appendColumn(
            "COLUMNS",
            values: payload.workspaces.map { $0.columns.map(columnsDescription) },
            headers: &headers,
            rows: &rows
        )

        return CLITableRenderer.formatRows(headers: headers, rows: rows, format: format)
    }

    static func formattedDisplays(_ payload: IPCDisplaysQueryResult, format: CLIOutputFormat) -> String {
        var headers = ["ID", "NAME", "MAIN", "CURRENT", "ORIENTATION", "ACTIVE WORKSPACE", "FRAME"]
        var rows = payload.displays.map { display in
            [
                display.id ?? "-",
                display.name ?? "-",
                CLITableRenderer.boolDescription(display.isMain),
                CLITableRenderer.boolDescription(display.isCurrent),
                display.orientation?.rawValue ?? "-",
                display.activeWorkspace?.displayName ?? "-",
                frameDescription(display.frame)
            ]
        }

        appendDisplayColumn("INNER GAP", values: payload.displays.map(\.innerGap), headers: &headers, rows: &rows)
        appendDisplayColumn("OUTER LEFT", values: payload.displays.map(\.outerGapLeft), headers: &headers, rows: &rows)
        appendDisplayColumn(
            "OUTER RIGHT",
            values: payload.displays.map(\.outerGapRight),
            headers: &headers,
            rows: &rows
        )
        appendDisplayColumn("OUTER TOP", values: payload.displays.map(\.outerGapTop), headers: &headers, rows: &rows)
        appendDisplayColumn(
            "OUTER BOTTOM",
            values: payload.displays.map(\.outerGapBottom),
            headers: &headers,
            rows: &rows
        )
        appendDisplayBooleanColumn(
            "FULLSCREEN GAPS",
            values: payload.displays.map(\.fullscreenUsesOuterGaps),
            headers: &headers,
            rows: &rows
        )

        return CLITableRenderer.formatRows(headers: headers, rows: rows, format: format)
    }

    private static func appendDisplayBooleanColumn(
        _ header: String,
        values: [Bool?],
        headers: inout [String],
        rows: inout [[String]]
    ) {
        appendColumn(header, values: values.map { $0.map { String($0) } }, headers: &headers, rows: &rows)
    }

    private static func appendDisplayColumn(
        _ header: String,
        values: [Double?],
        headers: inout [String],
        rows: inout [[String]]
    ) {
        appendColumn(header, values: values.map { $0.map(gapValueDescription) }, headers: &headers, rows: &rows)
    }

    private static func appendColumn(
        _ header: String,
        values: [String?],
        headers: inout [String],
        rows: inout [[String]]
    ) {
        guard values.contains(where: { $0 != nil }) else { return }
        headers.append(header)
        for index in rows.indices {
            rows[index].append(values[index] ?? "-")
        }
    }

    private static func gapValueDescription(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        return value == value.rounded()
            ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
            : String(value)
    }

    static func formattedRules(_ payload: IPCRulesQueryResult, format: CLIOutputFormat) -> String {
        let rows = payload.rules.map { rule in
            [
                String(rule.position),
                rule.id,
                rule.bundleId.isEmpty ? "—" : rule.bundleId,
                rule.layout.rawValue,
                rule.assignToWorkspace ?? "-",
                percentageDescription(rule.initialContainerPrimarySpan),
                rule.titleRegex ?? "-",
                String(rule.specificity),
                ruleValidityDescription(rule)
            ]
        }

        return CLITableRenderer.formatRows(
            headers: [
                "POS",
                "ID",
                "BUNDLE ID",
                "LAYOUT",
                "WORKSPACE",
                "INITIAL PRIMARY SPAN",
                "TITLE REGEX",
                "SPECIFICITY",
                "VALID"
            ],
            rows: rows,
            format: format
        )
    }

    private static func percentageDescription(_ proportion: Double?) -> String {
        guard let proportion else { return "-" }
        var percentage = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            proportion * 100
        )
        while percentage.last == "0" {
            percentage.removeLast()
        }
        if percentage.last == "." {
            percentage.removeLast()
        }
        return percentage + "%"
    }

    private static func ruleValidityDescription(_ rule: IPCRuleSnapshot) -> String {
        if rule.isValid { return CLITableRenderer.boolDescription(true) }
        return rule.validationMessages.isEmpty
            ? CLITableRenderer.boolDescription(false)
            : "no: " + rule.validationMessages.joined(separator: "; ")
    }

    static func formatAppSummary(_ apps: [IPCManagedAppSummary], format: CLIOutputFormat) -> String {
        let rows = apps.map { app in
            [app.appName, app.bundleId.isEmpty ? "—" : app.bundleId, sizeDescription(app.windowSize)]
        }
        return CLITableRenderer.formatRows(headers: ["APP", "BUNDLE ID", "WINDOW SIZE"], rows: rows, format: format)
    }

    private static func countsDescription(_ counts: IPCWorkspaceWindowCounts?) -> String {
        guard let counts else { return "-" }
        return "total=\(counts.total), tiled=\(counts.tiled), floating=\(counts.floating), scratchpad=\(counts.scratchpad)"
    }

    private static func columnsDescription(_ columns: [IPCWorkspaceColumn]) -> String {
        IPCColumnViewport.allCases.map { viewport in
            "\(viewport.rawValue)=\(columns.count { $0.viewport == viewport })"
        }
        .joined(separator: ", ")
    }

    private static func frameDescription(_ rect: IPCRect?) -> String {
        guard let rect else { return "-" }
        return "\(Int(rect.x)),\(Int(rect.y)) \(Int(rect.width))x\(Int(rect.height))"
    }

    private static func pidDescription(_ pid: Int32?) -> String {
        guard let pid else { return "-" }
        return String(pid)
    }

    private static func sizeDescription(_ size: IPCSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }
}
