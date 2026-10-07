// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
struct SystemStatsButtonView: View {
    let itemHeight: CGFloat
    let showItemBackgrounds: Bool
    let textColor: Color?
    let onToggle: () -> Void
    let onAnchorChange: (NSView?) -> Void

    @State private var isHovered = false

    private var buttonSize: CGFloat {
        max(18, itemHeight)
    }

    private var symbolSize: CGFloat {
        max(11, (itemHeight - 6) * 0.8)
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6)
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: symbolSize))
                .foregroundStyle(textColor ?? .primary)
                .frame(width: buttonSize, height: buttonSize)
                .background {
                    if showItemBackgrounds, isHovered {
                        buttonShape.fill(.regularMaterial)
                    }
                }
                .contentShape(buttonShape)
                .background(WorkspaceBarAnchorReporter(onChange: onAnchorChange))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("System stats")
        .help("Show system stats")
    }
}

private struct WorkspaceBarAnchorReporter: NSViewRepresentable {
    let onChange: (NSView?) -> Void

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(frame: .zero)
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.onChange = onChange
        nsView.report()
    }

    @MainActor
    final class AnchorView: NSView {
        var onChange: (NSView?) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onChange(self)
            }
        }
    }
}
