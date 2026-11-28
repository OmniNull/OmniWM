// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

func appendScriptShell(_ report: borrowing ShellWidgetReport, to output: inout ConfigScriptSnapshotWriter) {
    let countOffset = output.bytes.count
    guard output.row({ $0.count(0) && $0.string(report.profile) }) else { return }
    var widgetCount: UInt16 = 0
    defer { output.patch(widgetCount, at: countOffset) }
    for index in report.widgets.indices {
        guard output.row({ writeShellWidget(report.widgets[index], to: &$0) }) else { return }
        widgetCount += 1
    }
    for index in report.problems.indices {
        guard output.row({ $0.string(report.problems[index]) }) else { return }
    }
}

private func writeShellWidget(
    _ widget: borrowing ShellWidgetReport.Widget,
    to row: inout ConfigScriptSnapshotWriter
) -> Bool {
    guard let count = UInt16(exactly: widget.placements.count),
          row.string(widget.name), row.flag(widget.state.snapshotCode),
          row.string(widget.source), row.string(widget.error), row.count(count)
    else { return false }
    for index in widget.placements.indices {
        guard row.string(widget.placements[index]) else { return false }
    }
    return true
}

extension ShellWidgetReport.State {
    fileprivate var snapshotCode: UInt8 {
        switch self {
        case .loading: UInt8(OMNI_CONFIG_SHELL_STATE_LOADING)
        case .loaded: UInt8(OMNI_CONFIG_SHELL_STATE_LOADED)
        case .failed: UInt8(OMNI_CONFIG_SHELL_STATE_FAILED)
        case .fallback: UInt8(OMNI_CONFIG_SHELL_STATE_FALLBACK)
        }
    }
}
