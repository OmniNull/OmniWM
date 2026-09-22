// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
struct SystemStatsButtonView: View {
    let itemHeight: CGFloat
    let showItemBackgrounds: Bool
    let showAccentHighlights: Bool
    let accentColor: Color?
    let textColor: Color?
    let onToggle: () -> Void
    let onAnchorChange: (NSView?) -> Void

    @State private var isHovered = false

    private var buttonSize: CGFloat {
        max(18, itemHeight)
    }

    private var iconColor: Color {
        if isHovered, showAccentHighlights {
            return accentColor ?? .accentColor
        }
        return textColor ?? .secondary
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: max(11, itemHeight * 0.58), weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: buttonSize, height: buttonSize)
                .background {
                    if showItemBackgrounds {
                        buttonShape
                            .fill(isHovered ? .regularMaterial : .thinMaterial)
                            .overlay {
                                buttonShape.strokeBorder(
                                    Color.secondary.opacity(isHovered ? 0.3 : 0.18),
                                    lineWidth: 0.75
                                )
                            }
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
