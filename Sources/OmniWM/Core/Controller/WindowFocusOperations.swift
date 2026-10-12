// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct WindowFocusOperations {
    let activateApp: (pid_t) -> Void
    let focusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let submitFocusSpecificWindow: (pid_t, UInt32, AXUIElement) -> Void
    let afterSubmittedFocus: (@escaping @MainActor () -> Void) -> Void
    let deactivateSameAppWindow: (pid_t, UInt32) -> Bool
    let activateAndFocusSameAppWindow: (pid_t, UInt32, AXUIElement) -> Bool
    let raiseWindow: (AXUIElement) -> Void
    let orderWindow: (UInt32) -> Void
    let hasOverlappingWindowsAbove: (UInt32, Set<UInt32>) -> Bool?
    let enqueueRetryRaise: (pid_t, AXWindowRef, RunLoopJob, @escaping @MainActor @Sendable () -> Void) -> Bool

    init(
        activateApp: @escaping (pid_t) -> Void,
        focusSpecificWindow: @escaping (pid_t, UInt32, AXUIElement) -> Void,
        submitFocusSpecificWindow: ((pid_t, UInt32, AXUIElement) -> Void)? = nil,
        afterSubmittedFocus: ((@escaping @MainActor () -> Void) -> Void)? = nil,
        deactivateSameAppWindow: @escaping (pid_t, UInt32) -> Bool = { _, _ in false },
        activateAndFocusSameAppWindow: @escaping (pid_t, UInt32, AXUIElement) -> Bool = { _, _, _ in false },
        raiseWindow: @escaping (AXUIElement) -> Void,
        orderWindow: @escaping (UInt32) -> Void = { _ in },
        hasOverlappingWindowsAbove: @escaping (UInt32, Set<UInt32>) -> Bool? = { _, _ in nil },
        enqueueRetryRaise: @escaping (
            pid_t, AXWindowRef, RunLoopJob, @escaping @MainActor @Sendable () -> Void
        ) -> Bool = { pid, window, job, completion in
            guard let context = AppAXContextRegistry.contexts[pid] else { return false }
            return context.enqueueRetryRaise(
                window,
                job: job,
                awaitingSubmittedFocus: WindowFocusDispatcher.shared.waitForSubmitted,
                completion: completion
            )
        }
    ) {
        self.activateApp = activateApp
        self.focusSpecificWindow = focusSpecificWindow
        self.submitFocusSpecificWindow = submitFocusSpecificWindow ?? focusSpecificWindow
        self.afterSubmittedFocus = afterSubmittedFocus ?? { $0() }
        self.deactivateSameAppWindow = deactivateSameAppWindow
        self.activateAndFocusSameAppWindow = activateAndFocusSameAppWindow
        self.raiseWindow = raiseWindow
        self.orderWindow = orderWindow
        self.hasOverlappingWindowsAbove = hasOverlappingWindowsAbove
        self.enqueueRetryRaise = enqueueRetryRaise
    }

    static let live = WindowFocusOperations(
        activateApp: { pid in
            WindowFocusDispatcher.shared.drain()
            MainThreadAXSpanTrace.measure(.activateApp, pid: pid) {
                if let runningApp = NSRunningApplication(processIdentifier: pid) {
                    runningApp.activate(options: [])
                }
            }
        },
        focusSpecificWindow: { pid, windowId, _ in
            WindowFocusDispatcher.shared.drain()
            MainThreadAXSpanTrace.measure(.privateFocus, pid: pid, windowId: Int(windowId)) {
                OmniWM.focusWindow(pid: pid, windowId: windowId)
            }
        },
        submitFocusSpecificWindow: { pid, windowId, _ in
            WindowFocusDispatcher.shared.submit(pid: pid, windowId: windowId)
        },
        afterSubmittedFocus: { WindowFocusDispatcher.shared.afterSubmitted($0) },
        deactivateSameAppWindow: { pid, windowId in
            WindowFocusDispatcher.shared.drain()
            return MainThreadAXSpanTrace.measure(.sameAppDeactivate, pid: pid, windowId: Int(windowId)) {
                OmniWM.deactivateSameAppWindow(pid: pid, windowId: windowId)
            } succeeded: { $0 }
        },
        activateAndFocusSameAppWindow: { pid, windowId, element in
            WindowFocusDispatcher.shared.drain()
            return MainThreadAXSpanTrace.measure(.sameAppHandoff, pid: pid, windowId: Int(windowId)) {
                OmniWM.activateAndFocusSameAppWindow(
                    pid: pid,
                    windowId: windowId,
                    windowRef: element
                )
            } succeeded: { $0 }
        },
        raiseWindow: { element in
            WindowFocusDispatcher.shared.drain()
            _ = MainThreadAXSpanTrace.measure(.axRaise) {
                performAXAction(element, kAXRaiseAction as CFString, noteKey: "performRaiseFailed")
            } succeeded: { $0 == .success } status: { $0.rawValue }
        },
        orderWindow: { windowId in
            WindowFocusDispatcher.shared.drain()
            MainThreadAXSpanTrace.measure(.orderWindow, windowId: Int(windowId)) {
                SkyLight.shared.orderWindow(windowId, relativeTo: 0, order: .above)
            }
        },
        hasOverlappingWindowsAbove: { windowId, candidates in
            SkyLight.shared.hasOverlappingWindowsAbove(windowId, among: candidates)
        }
    )
}
