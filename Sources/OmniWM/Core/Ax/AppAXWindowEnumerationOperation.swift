// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AppAXWindowEnumerationOperation: Sendable {
    private struct EnumerationResult {
        var results: [AXEnumeratedWindow] = []
        var seenIds: Set<Int>
        var newWindows: [Int: AXUIElement]

        init(capacity: Int) {
            results.reserveCapacity(capacity)
            seenIds = Set(minimumCapacity: capacity)
            newWindows = Dictionary(minimumCapacity: capacity)
        }
    }

    let pid: pid_t
    let axApp: ThreadGuardedValue<AXUIElement>
    let state: AppAXWindowOperationState
    let retryRaiseBinding: AppAXRetryRaiseBinding
    let inspectionContext: AXWindowInspectionContext
    let includedWindowIds: Set<Int>?
    let enumerationCallbackGeneration: UInt64
    let enumerationBindingGeneration: UInt64
    let deadline: TimeInterval

    func perform(job: RunLoopJob) throws -> [AXEnumeratedWindow] {
        let observer = state.axObserver.value
        if let observer {
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
        }
        let windowElements = try AXWindowEnumerationInspector.applicationWindowElements(
            axApp.value,
            deadline: deadline,
            checkCancellation: { try job.checkCancellation() }
        )
        if windowElements.isEmpty {
            WindowAdmissionTrace.record(
                .init(
                    action: .enumerationEmpty,
                    pid: pid,
                    count: 0,
                    callbackGeneration: enumerationCallbackGeneration
                )
            )
        }

        var enumeration = EnumerationResult(capacity: windowElements.count)
        try inspect(windowElements, result: &enumeration, job: job)
        try retainMissingWindows(result: &enumeration, job: job)
        try job.performUnlessCancelled {
            guard AppAXContext.replaceEnumeratedWindowCache(
                with: enumeration.newWindows,
                windows: state.windows,
                bindingGeneration: enumerationBindingGeneration,
                windowBindingEpoch: state.windowBindingEpoch, retryRaiseBinding: retryRaiseBinding
            ) else { throw CancellationError() }
        }
        if let observer {
            try AppAXContext.drainPendingNotificationRemovals(
                state.pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
        }
        WindowAdmissionTrace.record(
            .init(
                action: .enumerationCompleted,
                pid: pid,
                count: enumeration.results.count,
                callbackGeneration: enumerationCallbackGeneration
            )
        )
        return enumeration.results
    }

    private func inspect(_ windowElements: [AXUIElement], result: inout EnumerationResult, job: RunLoopJob) throws {
        for element in windowElements {
            try job.checkCancellation()
            guard let windowId = try AXWindowEnumerationInspector.windowId(
                for: element,
                deadline: deadline,
                checkCancellation: { try job.checkCancellation() }
            ) else {
                continue
            }
            if let includedWindowIds, !includedWindowIds.contains(windowId) {
                if let existingElement = state.windows[windowId] {
                    result.newWindows[windowId] = existingElement
                    result.seenIds.insert(windowId)
                }
                continue
            }
            guard let enumeratedWindow = try AXWindowEnumerationInspector.inspect(
                element,
                windowId: windowId,
                deadline: deadline,
                context: inspectionContext,
                checkCancellation: { try job.checkCancellation() }
            ) else {
                continue
            }
            recordAcceptedWindow(enumeratedWindow, windowId: windowId)
            result.newWindows[windowId] = element
            let isFirstOccurrence = result.seenIds.insert(windowId).inserted
            AppAXContext.recordFinalEnumeratedWindow(
                enumeratedWindow,
                in: &result.results,
                isFirstOccurrence: isFirstOccurrence
            )
        }
    }

    private func retainMissingWindows(result: inout EnumerationResult, job: RunLoopJob) throws {
        let existingWindowIds = Array(state.windows.value.keys)
        for existingId in existingWindowIds where !result.seenIds.contains(existingId) {
            let existingElement = state.windows[existingId]
            try job.checkCancellation()
            let shouldRemove = AppAXContext.shouldRemoveMissingWindow(
                windowId: existingId
            )
            try job.checkCancellation()
            if shouldRemove {
                WindowAdmissionTrace.record(
                    .init(
                        action: .admissionDisappeared,
                        pid: pid,
                        windowId: existingId,
                        reason: "missing_from_ax_windows",
                        callbackGeneration: enumerationCallbackGeneration,
                        axRef: existingElement.map {
                            AXWindowRef(element: $0, windowId: existingId)
                        }
                    )
                )
            } else if let existingElement {
                result.newWindows[existingId] = existingElement
            }
        }
    }

    private func recordAcceptedWindow(_ enumeratedWindow: AXEnumeratedWindow, windowId: Int) {
        if let resolvedElementPid = enumeratedWindow.axPid, resolvedElementPid != pid {
            DiagnosticsEventRecorder.shared.recordLifecycle(
                name: "ax.pidMismatch.expected=\(pid)",
                pid: resolvedElementPid,
                windowId: CGWindowID(windowId)
            )
        }

        WindowAdmissionTrace.record(
            .init(
                action: .topLevelAccepted,
                pid: pid,
                windowId: windowId,
                axPid: enumeratedWindow.axPid,
                role: enumeratedWindow.role,
                subrole: enumeratedWindow.subrole,
                callbackGeneration: enumerationCallbackGeneration,
                axRef: enumeratedWindow.axRef
            )
        )
    }
}
