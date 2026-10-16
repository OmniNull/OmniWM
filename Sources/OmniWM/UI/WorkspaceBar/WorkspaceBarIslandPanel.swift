// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class WorkspaceBarIslandPanel {
    let panel: WorkspaceBarPanel
    let hostingView: NSHostingView<WorkspaceBarView>
    var slice: WorkspaceBarIslandSlice
    var lastAppliedFrame: NSRect?

    init(panel: WorkspaceBarPanel, rootView: WorkspaceBarView, resolved: ResolvedBarSettings, monitor: Monitor) {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        let appearance = NSApplication.shared.appearance
        panel.appearance = appearance
        hostingView.appearance = appearance
        self.panel = panel
        self.hostingView = hostingView
        slice = rootView.slice
        lastAppliedFrame = nil
        applySettings(resolved: resolved, monitor: monitor)
    }

    func applySettings(resolved: ResolvedBarSettings, monitor: Monitor) {
        let fillsMenuBar = resolved.notchMode == .fillLeftOfNotch
        panel.collectionBehavior = fillsMenuBar
            ? [.canJoinAllSpaces, .stationary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let level = resolved.windowLevel.nsWindowLevel
        panel.level = if fillsMenuBar {
            NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        } else if resolved.fullWidth,
                  WorkspaceBarGeometry.effectivePosition(for: monitor, resolved: resolved) == .overlappingMenuBar
        {
            NSWindow.Level(rawValue: max(level.rawValue, NSWindow.Level.statusBar.rawValue + 1))
        } else {
            level
        }
    }

    func applyFrame(
        _ frame: NSRect,
        using frameApplier: (WorkspaceBarPanel, NSRect) -> Void
    ) {
        guard lastAppliedFrame != frame else { return }
        frameApplier(panel, frame)
        lastAppliedFrame = frame
    }
}
