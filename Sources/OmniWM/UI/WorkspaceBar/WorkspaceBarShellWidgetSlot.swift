// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
struct ShellWidgetSlot: View {
    let widget: WorkspaceBarShellWidget
    let view: NSView?

    var body: some View {
        HStack(spacing: 4) {
            if let failure = widget.failure {
                ShellWidgetFailureBadge(name: widget.id, failure: failure)
            }
            if widget.size.width > 0, widget.size.height > 0 {
                Group {
                    if let view {
                        ShellWidgetSlotHost(view: view)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: widget.size.width, height: widget.size.height)
            }
        }
    }
}

@MainActor
private struct ShellWidgetFailureBadge: View {
    let name: String
    let failure: ShellWidgetFailure

    var body: some View {
        Button {
            let source = failure.source
            NSWorkspace.shared.open(source, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in
                    NSWorkspace.shared.activateFileViewerSelecting([source])
                }
            }
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "\(name): \(failure.message)"))
    }
}

@MainActor
private struct ShellWidgetSlotHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context _: Context) -> NSView {
        view
    }

    func updateNSView(_: NSView, context _: Context) {}
}
