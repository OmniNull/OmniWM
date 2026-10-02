// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

extension AXWindowService {
    static func restoreMinimizedWindow(_ window: AXWindowRef) -> Bool {
        guard AXUIElementSetAttributeValue(
            window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse
        ) == .success else { return false }
        return isMinimized(window) == false
    }

    static func isMinimized(_ window: AXWindowRef) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window.element,
            kAXMinimizedAttribute as CFString,
            &value
        )
        return result == .success ? value as? Bool : nil
    }
}
