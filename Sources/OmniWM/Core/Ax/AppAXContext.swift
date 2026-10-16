// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

@MainActor
final class AppAXContext {
    private struct PendingRetryRaise {
        let window: AXWindowRef
        let job: RunLoopJob
        let completion: @MainActor @Sendable () -> Void
    }

    nonisolated static let pendingNotificationRemovalLimit = 512
    nonisolated static let pendingNotificationRemovalAttemptLimit: UInt8 = 3

    let pid: pid_t
    let nsApp: NSRunningApplication

    private let axApp: ThreadGuardedValue<AXUIElement>
    private let windows: ThreadGuardedValue<[Int: AXUIElement]>
    private nonisolated(unsafe) var thread: Thread?
    nonisolated var axThread: Thread? {
        thread
    }

    let frameDelivery = AppAXFrameDelivery()
    private var pendingRetryRaise: PendingRetryRaise?
    private let windowBindingEpoch = LockedGenerationEpoch()
    private let axObserver: ThreadGuardedValue<AXObserver?>
    private let focusedWindowObserver: ThreadGuardedValue<AXObserver?>
    private let subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>
    private let pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>
    private let axObserverCallbackKey: UInt?
    private let focusedWindowObserverCallbackKey: UInt?
    let callbackGeneration: UInt64
    let writeMetricsToken: AXWriteMetrics.ContextToken

    private var windowOperationState: AppAXWindowOperationState {
        AppAXWindowOperationState(
            windows: windows,
            windowBindingEpoch: windowBindingEpoch,
            axObserver: axObserver,
            subscribedWindows: subscribedWindows,
            pendingNotificationRemovals: pendingNotificationRemovals
        )
    }

    nonisolated init(
        _ nsApp: NSRunningApplication,
        pid: pid_t,
        _ axApp: ThreadGuardedValue<AXUIElement>,
        _ windows: ThreadGuardedValue<[Int: AXUIElement]>,
        _ observer: ThreadGuardedValue<AXObserver?>,
        _ focusedWindowObserver: ThreadGuardedValue<AXObserver?>,
        _ subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        _ pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>,
        _ axObserverCallbackKey: UInt?,
        _ focusedWindowObserverCallbackKey: UInt?,
        _ callbackGeneration: UInt64,
        _ thread: Thread
    ) {
        self.nsApp = nsApp
        self.pid = pid
        self.axApp = axApp
        self.windows = windows
        axObserver = observer
        self.focusedWindowObserver = focusedWindowObserver
        self.subscribedWindows = subscribedWindows
        self.pendingNotificationRemovals = pendingNotificationRemovals
        self.axObserverCallbackKey = axObserverCallbackKey
        self.focusedWindowObserverCallbackKey = focusedWindowObserverCallbackKey
        self.callbackGeneration = callbackGeneration
        self.thread = thread
        writeMetricsToken = AXWriteMetrics.ContextToken(pid: pid, callbackGeneration: callbackGeneration)
        AXWriteMetrics.shared.register(
            writeMetricsToken,
            app: nsApp.localizedName,
            bundleId: nsApp.bundleIdentifier
        )
    }

    func registerCallbacks(serviceGeneration: UInt64) -> Bool {
        let observerRegistered = axObserverCallbackKey.map {
            appAXCallbackGenerationRegistry.register(
                observerKey: $0,
                serviceGeneration: serviceGeneration,
                callbackGeneration: callbackGeneration,
                windowSubscriptions: subscribedWindows
            )
        } ?? true
        let focusedObserverRegistered = focusedWindowObserverCallbackKey.map {
            appAXCallbackGenerationRegistry.register(
                observerKey: $0,
                serviceGeneration: serviceGeneration,
                callbackGeneration: callbackGeneration
            )
        } ?? true
        return observerRegistered && focusedObserverRegistered
    }

    func cancelFrameJob(for windowId: Int) {
        frameDelivery.cancelFrameJob(for: windowId)
    }

    func cancelParkFrameJob(for windowId: Int) {
        frameDelivery.cancelParkFrameJob(for: windowId)
    }

    func invalidateWindowIdentity() {
        cancelRetryRaise()
        _ = windowBindingEpoch.advance()
    }

    func enqueueRetryRaise(
        _ window: AXWindowRef,
        job: RunLoopJob,
        awaitingSubmittedFocus: @escaping @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let thread, !job.isCancelled else { return false }
        cancelRetryRaise()
        pendingRetryRaise = PendingRetryRaise(window: window, job: job, completion: completion)
        let frameWriteSuppression = frameDelivery.retryRaiseSuppression
        let pid = pid
        let postedNs = WindowFocusDispatchTrace.retryRaise.isActive ? DispatchTime.now().uptimeNanoseconds : 0
        thread.runInLoopAsync(job: job) { [weak self, windows, frameWriteSuppression] job in
            WindowFocusDispatchTrace
                .traceRetryRaise(pid: pid, windowId: window.windowId, postedNs: postedNs) { waited in
                    Self.performRetryRaise(
                        window, windows: windows, suppression: frameWriteSuppression, job: job,
                        awaitingSubmittedFocus: {
                            awaitingSubmittedFocus()
                            waited()
                        }
                    )
                }
            scheduleOnMainRunLoop { [weak self] in
                self?.finishRetryRaise(job: job)
            }
        }
        return true
    }

    private func finishRetryRaise(job: RunLoopJob) {
        guard let pending = pendingRetryRaise, pending.job === job else { return }
        pendingRetryRaise = nil
        pending.completion()
    }

    private func cancelRetryRaise(for windowId: Int? = nil) {
        guard let pending = pendingRetryRaise,
              windowId == nil || pending.window.windowId == windowId
        else { return }
        pendingRetryRaise = nil
        pending.job.cancel()
        scheduleOnMainRunLoop(pending.completion)
    }

    func prepareWindowRebind(from oldWindowId: Int, to newWindowId: Int) {
        cancelRetryRaise(for: oldWindowId)
        cancelRetryRaise(for: newWindowId)
        frameDelivery.prepareWindowRebind(from: oldWindowId, to: newWindowId)
        _ = windowBindingEpoch.advance()
    }

    func prepareWindowRemoval(for windowId: Int) {
        cancelRetryRaise(for: windowId)
        frameDelivery.prepareWindowRemoval(for: windowId)
    }

    func retainFrameState(only windowIds: Set<Int>) {
        if let pending = pendingRetryRaise, !windowIds.contains(pending.window.windowId) {
            cancelRetryRaise()
        }
        frameDelivery.retainFrameState(only: windowIds)
    }

    func suppressFrameWrites(for windowIds: [Int]) {
        guard !windowIds.isEmpty else { return }
        for windowId in windowIds {
            cancelRetryRaise(for: windowId)
            frameDelivery.cancelFrameJob(for: windowId)
            frameDelivery.suppressFrameWrite(for: windowId)
        }
    }

    func unsuppressFrameWrites(for windowIds: [Int]) {
        guard !windowIds.isEmpty else { return }
        for windowId in windowIds {
            frameDelivery.unsuppressFrameWrite(for: windowId)
        }
    }

    func setMacOSAppHidden(_ hidden: Bool, for windowIds: [Int]) {
        frameDelivery.setHardSuppressed(hidden)
        if hidden {
            cancelRetryRaise()
            frameDelivery.invalidateClosingFrames()
        }
        for windowId in windowIds {
            frameDelivery.cancelFrameJob(for: windowId)
            frameDelivery.cancelParkFrameJob(for: windowId)
        }
    }

    func setWindowNativeSuppressed(_ suppressed: Bool, for windowId: Int) {
        if suppressed {
            cancelRetryRaise(for: windowId)
        }
        frameDelivery.setWindowNativeSuppressed(suppressed, for: windowId)
    }

    func makeFrameDrainExecution(drainId: UInt64, lane: AppAXFrameLane) -> AppAXFrameDrainExecution {
        AppAXFrameDrainExecution(
            writer: frameDelivery.writer(
                trace: .init(
                    context: writeMetricsToken,
                    bundleId: AXWriteLatencyTrace.shared.isActive ? nsApp.bundleIdentifier : nil,
                    lane: lane,
                    drainId: drainId
                )
            ),
            axApp: axApp
        )
    }

    func prepareForStopRestoration() {
        cancelRetryRaise()
        frameDelivery.shutdown()
    }

    func destroy() {
        cancelRetryRaise()
        if thread != nil {
            WindowAdmissionTrace.record(
                .init(
                    action: .endpointDestroyed,
                    pid: pid,
                    bundleId: nsApp.bundleIdentifier,
                    callbackGeneration: callbackGeneration
                )
            )
        }
        if let axObserverCallbackKey {
            appAXCallbackGenerationRegistry.unregister(observerKey: axObserverCallbackKey)
        }
        if let focusedWindowObserverCallbackKey {
            appAXCallbackGenerationRegistry.unregister(observerKey: focusedWindowObserverCallbackKey)
        }

        AppAXContextRegistry.remove(self)
        AXWriteMetrics.shared.retire(writeMetricsToken)
        LockedEnhancedUIStateMap.shared.invalidate(pid)

        frameDelivery.shutdown()

        nonisolated(unsafe) let appThread = thread
        let shutdown = AppAXContextShutdown(
            state: windowOperationState,
            axApp: axApp,
            focusedWindowObserver: focusedWindowObserver
        )
        appThread?.runInLoopAsync { _ in shutdown.perform() }
        thread = nil
    }
}

extension AppAXContext {
    func setWindowTitleNotifications(_ enabled: Bool) {
        nonisolated(unsafe) let appThread = thread
        appThread?.runInLoopAsync { [axApp, focusedWindowObserver] _ in
            AppAXContext.setTitleNotifications(enabled, app: axApp, observer: focusedWindowObserver)
        }
    }

    func makeWindowEnumerationOperation(
        inspectionContext: AXWindowInspectionContext,
        includedWindowIds: Set<Int>?,
        deadline: TimeInterval
    ) -> AppAXWindowEnumerationOperation {
        let enumerationCallbackGeneration = callbackGeneration
        let enumerationBindingGeneration = windowBindingEpoch.current()
        return AppAXWindowEnumerationOperation(
            pid: pid,
            axApp: axApp,
            state: windowOperationState,
            inspectionContext: inspectionContext,
            includedWindowIds: includedWindowIds,
            enumerationCallbackGeneration: enumerationCallbackGeneration,
            enumerationBindingGeneration: enumerationBindingGeneration,
            deadline: deadline
        )
    }

    func updateWindowBindings(
        _ boundWindows: [Int: AXWindowRef],
        pruningUnboundState: Bool,
        timeoutSeconds: TimeInterval,
        completion: @escaping @MainActor @Sendable (AppAXWindowBindingResult) -> Void
    ) {
        if let pending = pendingRetryRaise {
            if let replacement = boundWindows[pending.window.windowId] {
                if !CFEqual(replacement.element, pending.window.element) {
                    cancelRetryRaise()
                }
            } else if pruningUnboundState {
                cancelRetryRaise()
            }
        }
        guard pruningUnboundState || !boundWindows.isEmpty else {
            completion(.bound)
            return
        }
        guard let thread else {
            completion(.retryRequired)
            return
        }
        let bindingGeneration = windowBindingEpoch.advance()
        nonisolated(unsafe) let appThread = thread
        let state = windowOperationState
        let options = AppAXWindowBindingOptions(
            generation: bindingGeneration,
            pruningUnboundState: pruningUnboundState,
            timeoutSeconds: timeoutSeconds
        )
        appThread.runInLoopAsync { job in
            let result: AppAXWindowBindingResult
            do {
                result = try AppAXContext.performWindowBinding(
                    boundWindows,
                    options: options,
                    state: state,
                    job: job
                )
            } catch is AppAXWindowBindingSuperseded {
                result = .superseded
            } catch is CancellationError {
                result = .superseded
            } catch {
                result = .retryRequired
            }
            scheduleOnMainRunLoop {
                completion(result)
            }
        }
    }

    func rebindWindowAsync(
        oldWindowId: Int,
        newWindow: AXWindowRef,
        timeoutSeconds: TimeInterval = 0.5
    ) async throws -> AppAXWindowRebindBinding? {
        guard let thread else { return nil }
        nonisolated(unsafe) let appThread = thread
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        let preparation = AppAXWindowRebindPreparation(
            oldWindowId: oldWindowId,
            newWindow: newWindow,
            timeoutSeconds: timeoutSeconds,
            state: windowOperationState
        )
        return try await appThread.runInLoop(
            timeout: timeout,
            onUndeliveredSuccess: { [
                axObserver,
                subscribedWindows,
                pendingNotificationRemovals
            ] binding in
                guard let binding,
                      let observer = axObserver.value
                else {
                    return
                }
                AppAXContext.cleanUpUnpublishedWindowRebind(
                    binding,
                    observer: observer,
                    subscribedWindows: subscribedWindows,
                    pendingNotificationRemovals: pendingNotificationRemovals
                )
            },
            { job in
                try preparation.perform(job: job)
            }
        )
    }

    func rollbackWindowRebind(_ binding: AppAXWindowRebindBinding, newWindow: AXWindowRef) {
        guard !binding.newlyInstalledNotifications.isEmpty,
              let thread
        else {
            return
        }
        nonisolated(unsafe) let appThread = thread
        appThread.runInLoopAsync { [
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] _ in
            guard let observer = axObserver.value else { return }
            AppAXContext.cleanUpUnpublishedWindowRebind(
                binding,
                observer: observer,
                subscribedWindows: subscribedWindows,
                pendingNotificationRemovals: pendingNotificationRemovals
            )
        }
    }

    func commitWindowRebindAsync(
        oldWindow: AXWindowRef,
        newWindow: AXWindowRef,
        binding: AppAXWindowRebindBinding,
        retireOldWindowState: Bool,
        timeoutSeconds: TimeInterval = 0.5
    ) async throws -> Bool {
        guard let thread else { return false }
        nonisolated(unsafe) let appThread = thread
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        let operation = AppAXWindowRebindCommitOperation(
            oldWindow: oldWindow,
            newWindow: newWindow,
            binding: binding,
            retireOldWindowState: retireOldWindowState,
            state: windowOperationState
        )
        return try await appThread.runInLoop(timeout: timeout) { job in
            try operation.perform(job: job)
        }
    }

    func removeWindowStateAsync(
        expectedWindow: AXWindowRef,
        timeoutSeconds: TimeInterval = 0.5
    ) async throws -> AppAXWindowStateRemovalOutcome {
        guard let thread else {
            return .init(removedCachedWindow: false, removedSubscription: false)
        }
        nonisolated(unsafe) let appThread = thread
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        return try await appThread.runInLoop(timeout: timeout) { [
            windows,
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] job in
            let outcome = try job.performUnlessCancelled {
                let outcome = AppAXContext.removeExactWindowState(
                    expectedWindow: expectedWindow,
                    windows: windows,
                    subscribedWindows: subscribedWindows,
                    pendingNotificationRemovals: pendingNotificationRemovals,
                    observerKey: axObserver.value.map(axCallbackObserverKey)
                )
                return outcome
            }
            if let observer = axObserver.value {
                try AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: { try job.checkCancellation() }
                )
            }
            return outcome
        }
    }

    func removeWindowState(expectedWindow: AXWindowRef) {
        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread

        appThread.runInLoopAsync { [
            windows,
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] _ in
            _ = AppAXContext.removeExactWindowState(
                expectedWindow: expectedWindow,
                windows: windows,
                subscribedWindows: subscribedWindows,
                pendingNotificationRemovals: pendingNotificationRemovals,
                observerKey: axObserver.value.map(axCallbackObserverKey)
            )
            if let observer = axObserver.value {
                try? AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: {}
                )
            }
        }
    }
}
