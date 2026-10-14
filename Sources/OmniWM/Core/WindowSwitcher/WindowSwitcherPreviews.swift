// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

/// Keeps each window's preview stable for one switcher session while capture
/// refreshes its cache independently for the next opening.
@MainActor
struct WindowSwitcherPreviews {
    private var frames: [WindowHandle: OverviewPreviewFrame] = [:]

    func isReady(for handles: [WindowHandle]) -> Bool {
        handles.allSatisfy { frames[$0] != nil }
    }

    mutating func preview(for handle: WindowHandle, candidate: OverviewPreviewFrame?) -> OverviewPreviewFrame? {
        if let frame = frames[handle] { return frame }
        frames[handle] = candidate
        return candidate
    }

    mutating func removeAll() {
        frames.removeAll()
    }
}
