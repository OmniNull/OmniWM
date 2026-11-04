// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AppAXContext {
    func cancelFrameJob(for windowId: Int) {
        frameDelivery.cancelFrameJob(for: windowId)
    }

    func cancelParkFrameJob(for windowId: Int) {
        frameDelivery.cancelParkFrameJob(for: windowId)
    }

    nonisolated static func performRetryRaise(
        _ window: AXWindowRef,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        suppression: LockedWindowIdSet,
        job: RunLoopJob,
        awaitingSubmittedFocus: () -> Void,
        allowsLayoutHiddenWindow: Bool = false,
        raiseWindow: (AXUIElement) -> Bool = {
            performAXAction($0, kAXRaiseAction as CFString, noteKey: "performRaiseFailed") == .success
        }
    ) -> Bool {
        awaitingSubmittedFocus()
        guard !job.isCancelled else { return false }
        let isSuppressed = allowsLayoutHiddenWindow
            ? suppression.isHardSuppressed(for: window.windowId) : suppression.contains(window.windowId)
        guard !isSuppressed,
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
