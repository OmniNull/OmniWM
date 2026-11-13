// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct WorkspaceBarSurfaceFill<Surface: Shape>: View {
    let shape: Surface
    let backgroundStyle: WorkspaceBarSnapshot.BackgroundStyle
    let backgroundOpacity: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch backgroundStyle {
        case .transparent:
            EmptyView()
        case .solidBlack:
            shape.fill(Color.black)
        case .material:
            if reduceTransparency {
                shape.fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
            } else {
                shape.fill(Color.white.opacity(backgroundOpacity)).background(.ultraThinMaterial, in: shape)
            }
        case let .palette(fill, _):
            shape.fill(Color(nsColor: fill.color(dark: colorScheme == .dark)).opacity(backgroundOpacity))
        }
    }
}

extension WorkspaceBarSnapshot.BackgroundStyle {
    func outline(contrast: ColorSchemeContrast, colorScheme: ColorScheme) -> (color: Color, width: CGFloat)? {
        switch self {
        case .material:
            contrast == .increased ? (Color.primary.opacity(0.45), 1) : (Color.secondary.opacity(0.18), 0.5)
        case let .palette(_, border?):
            (Color(nsColor: border.color(dark: colorScheme == .dark)), 1)
        default:
            nil
        }
    }
}
