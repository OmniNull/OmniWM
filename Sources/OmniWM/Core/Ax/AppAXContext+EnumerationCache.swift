// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AppAXContext {
    nonisolated static func shouldRemoveMissingWindow(windowId: Int) -> Bool {
        if let uintWindowId = UInt32(exactly: windowId),
           AXWindowService.hasPinnedAXElement(for: uintWindowId)
        {
            return false
        }
        return true
    }

    nonisolated static func replaceEnumeratedWindowCache(
        with newWindows: [Int: AXUIElement],
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        bindingGeneration: UInt64,
        windowBindingEpoch: LockedGenerationEpoch,
        retryRaiseBinding: AppAXRetryRaiseBinding
    ) -> Bool {
        windowBindingEpoch.performIfCurrent(bindingGeneration) {
            retryRaiseBinding.invalidateChangedBinding(in: newWindows)
            windows.value = newWindows
            return true
        } ?? false
    }

    nonisolated static func recordFinalEnumeratedWindow(
        _ window: AXEnumeratedWindow,
        in windows: inout [AXEnumeratedWindow],
        isFirstOccurrence: Bool
    ) {
        let windowId = window.axRef.windowId
        if isFirstOccurrence {
            windows.append(window)
        } else if let index = windows.firstIndex(where: { $0.axRef.windowId == windowId }) {
            windows[index] = window
        }
    }
}
