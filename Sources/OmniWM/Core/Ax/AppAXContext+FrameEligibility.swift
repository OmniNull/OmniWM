// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AppAXContext {
    nonisolated static func performRetryRaise(
        _ window: AXWindowRef,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        suppression: LockedWindowIdSet,
        job: RunLoopJob,
        awaitingSubmittedFocus: () -> Void,
        raiseWindow: (AXUIElement) -> Bool = {
            performAXAction($0, kAXRaiseAction as CFString, noteKey: "performRaiseFailed") == .success
        }
    ) -> Bool {
        awaitingSubmittedFocus()
        guard !job.isCancelled, !suppression.contains(window.windowId),
              let element = windows.valueIfExists?[window.windowId],
              CFEqual(element, window.element), !job.isCancelled
        else { return false }
        return raiseWindow(element)
    }

    nonisolated static func acceptsRefreshedFrameElement(
        cachedElement: AXUIElement,
        refreshedElement: AXUIElement,
        windowId: Int,
        requestGeneration: UInt64,
        generations: LockedWindowGenerationMap
    ) -> Bool {
        guard generations.isCurrent(requestGeneration, for: windowId) else { return false }
        guard CFEqual(cachedElement, refreshedElement) else {
            _ = generations.nextGeneration(for: windowId)
            return false
        }
        return generations.isCurrent(requestGeneration, for: windowId)
    }
}
