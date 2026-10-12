// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
                shape.fill(tint).background(.ultraThinMaterial, in: shape)
            }
        }
    }

    private var tint: Color {
        colorScheme == .dark
            ? Color.white.opacity(backgroundOpacity)
            : Color.black.opacity(backgroundOpacity * 0.5)
    }
}
