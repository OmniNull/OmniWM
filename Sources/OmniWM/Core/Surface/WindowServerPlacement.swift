// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMLayerCorners

extension NSWindow {
    func order(_ place: NSWindow.OrderingMode, directlyRelativeTo otherWindow: UInt32) {
        guard !omniwm_window_manager_order(self, place, otherWindow) else { return }
        order(place, relativeTo: Int(otherWindow))
    }

    func staysOnItsDisplay(at target: CGRect) -> Bool {
        WindowServerPlacementPolicy.staysOnDisplay(
            target,
            current: screen?.frame,
            centerIsOnADisplay: NSScreen.screens.contains { $0.frame.contains(target.center) }
        )
    }
}

extension NSEvent {
    var isWindowServerMove: Bool {
        type == .appKitDefined && subtype == .windowMoved
    }
}

enum WindowServerPlacementPolicy {
    static func staysOnDisplay(
        _ target: CGRect,
        current: CGRect?,
        centerIsOnADisplay: @autoclosure () -> Bool
    ) -> Bool {
        guard let current, current.intersects(target) else { return false }
        return current.contains(target.center) || !centerIsOnADisplay()
    }
}
