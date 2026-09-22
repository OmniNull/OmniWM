// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

enum WorkspaceBarOrientation: Equatable {
    case horizontal, vertical

    var isVertical: Bool {
        self == .vertical
    }

    @MainActor
    func stack<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let layout = isVertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        return layout { content() }
    }
}

extension EnvironmentValues {
    @Entry var workspaceBarOrientation = WorkspaceBarOrientation.horizontal
}
