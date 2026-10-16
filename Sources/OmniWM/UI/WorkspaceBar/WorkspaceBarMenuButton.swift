// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
enum WorkspaceBarMenuButton {
    static func contains(_ event: NSEvent?, in window: NSWindow) -> Bool {
        guard let event, event.window === window,
              let content = window.contentView
        else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let candidate = view {
            if let shell = candidate as? ShellSurfaceView {
                return shell.command(at: event) == ShellRequest.statusMenuCommand
            }
            view = candidate.superview
        }
        return false
    }
}
