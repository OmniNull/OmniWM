// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class WorkspaceBarIslandPanel {
    let panel: WorkspaceBarPanel
    let hostingView: NSHostingView<WorkspaceBarView>
    let interaction: WorkspaceBarIslandInteraction
    var slice: WorkspaceBarIslandSlice
    var showsSystemStatsButton: Bool
    var lastRequestedFrame: NSRect?

    init(
        panel: WorkspaceBarPanel,
        rootView: WorkspaceBarView,
        interaction: WorkspaceBarIslandInteraction = WorkspaceBarIslandInteraction(),
        resolved: ResolvedBarSettings
    ) {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        let appearance = NSApplication.shared.appearance
        panel.appearance = appearance
        hostingView.appearance = appearance
        self.panel = panel
        self.hostingView = hostingView
        self.interaction = interaction
        slice = rootView.slice
        showsSystemStatsButton = rootView.showsSystemStatsButton
        lastRequestedFrame = nil
        applySettings(resolved: resolved)
    }

    func applySettings(resolved: ResolvedBarSettings) {
        let fillsMenuBar = resolved.notchMode == .fillLeftOfNotch
        panel.collectionBehavior = fillsMenuBar
            ? [.canJoinAllSpaces, .stationary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = fillsMenuBar
            ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            : resolved.windowLevel.nsWindowLevel
    }

    func applyFrame(
        _ frame: NSRect,
        using frameApplier: (WorkspaceBarPanel, NSRect) -> Void
    ) {
        guard lastRequestedFrame != frame else { return }
        frameApplier(panel, frame)
        lastRequestedFrame = frame
    }
}
