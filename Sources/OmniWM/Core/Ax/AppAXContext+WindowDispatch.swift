// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct WindowMinimizationObservation: Sendable {
    let isMinimized: Bool
    let sequence: UInt64
}

extension AppAXContext {
    func windowMinimizationAsync(
        _ window: AXWindowRef,
        read: @escaping @Sendable (AXWindowRef) -> Bool? = {
            AXWindowService.isMinimized($0, messagingTimeout: 0.05)
        }
    ) async -> WindowMinimizationObservation? {
        guard let thread = axThread else { return nil }
        return try? await thread.runInLoop(timeout: .milliseconds(50)) { _ -> WindowMinimizationObservation? in
            guard let isMinimized = read(window) else { return nil }
            return WindowMinimizationObservation(isMinimized: isMinimized, sequence: EventIntake.currentSeq())
        }
    }

    func windowRefAsync(windowId: UInt32) async throws -> AXWindowRef? {
        try Task.checkCancellation()
        guard let thread = axThread else { throw AXWindowEnumerationError.contextUnavailable }
        let pid = pid
        let deadline = ProcessInfo.processInfo.systemUptime + AXManager.perAppTimeout
        let timeout = Duration.milliseconds(Int64(AXManager.perAppTimeout * 1_000))
        return try await thread.runInLoop(timeout: timeout) { job in
            try AXWindowService.uncachedWindowRef(
                windowId: windowId,
                pid: pid,
                deadline: deadline,
                checkCancellation: { try job.checkCancellation() }
            )
        }
    }

    func getWindowsAsync(
        timeoutSeconds: TimeInterval = 0.5,
        includeTitle: Bool = false,
        includedWindowIds: Set<Int>? = nil
    ) async throws -> [AXEnumeratedWindow] {
        guard let thread = axThread else {
            WindowAdmissionTrace.record(
                .init(
                    action: .enumerationFailed,
                    pid: pid,
                    bundleId: nsApp.bundleIdentifier,
                    reason: "context_thread_unavailable",
                    callbackGeneration: callbackGeneration
                )
            )
            throw AXWindowEnumerationError.contextUnavailable
        }
        nonisolated(unsafe) let appThread = thread
        WindowAdmissionTrace.record(
            .init(
                action: .enumerationStarted,
                pid: pid,
                bundleId: nsApp.bundleIdentifier,
                callbackGeneration: callbackGeneration
            )
        )

        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        let inspectionContext = AXWindowInspectionContext(
            appPolicy: nsApp.activationPolicy,
            bundleId: nsApp.bundleIdentifier,
            includeTitle: includeTitle
        )
        let operation = makeWindowEnumerationOperation(
            inspectionContext: inspectionContext,
            includedWindowIds: includedWindowIds,
            deadline: deadline
        )
        return try await appThread.runInLoop(timeout: timeout) { job in
            try operation.perform(job: job)
        }
    }

    func bindWindows(
        _ boundWindows: [Int: AXWindowRef],
        timeoutSeconds: TimeInterval = 0.5,
        completion: @escaping @MainActor @Sendable (AppAXWindowBindingResult) -> Void
    ) {
        updateWindowBindings(
            boundWindows,
            pruningUnboundState: false,
            timeoutSeconds: timeoutSeconds,
            completion: completion
        )
    }

    func reconcileWindowBindings(
        _ boundWindows: [Int: AXWindowRef],
        timeoutSeconds: TimeInterval = 0.5,
        completion: @escaping @MainActor @Sendable (AppAXWindowBindingResult) -> Void
    ) {
        updateWindowBindings(
            boundWindows,
            pruningUnboundState: true,
            timeoutSeconds: timeoutSeconds,
            completion: completion
        )
    }
}
