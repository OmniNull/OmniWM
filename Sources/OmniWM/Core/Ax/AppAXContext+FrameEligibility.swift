// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation
import Synchronization

extension AppAXContext {
    func cancelFrameJob(for windowId: Int) {
        frameDelivery.cancelFrameJob(for: windowId)
    }

    func cancelParkFrameJob(for windowId: Int) {
        frameDelivery.cancelParkFrameJob(for: windowId)
    }

    nonisolated static func performRetryRaise(
        _ window: AXWindowRef,
        binding: AppAXRetryRaiseBinding,
        job: RunLoopJob,
        isSuppressed: () -> Bool,
        raiseWindow: (AXUIElement) -> Bool
    ) -> Bool {
        let canRaise = !job.isCancelled && !isSuppressed()
        guard let boundWindow = binding.claim(matching: window, for: job, canRaise: canRaise) else { return false }
        return raiseWindow(boundWindow.element)
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

extension LockedWindowIdSet {
    func retryRaiseCheck(for windowId: Int, allowHidden: Bool = false) -> @Sendable () -> Bool {
        { allowHidden ? self.isHardSuppressed(for: windowId) : self.contains(windowId) }
    }
}

final class AppAXRetryRaiseBinding: Sendable {
    private struct Pending: Sendable {
        let window: AXWindowRef
        let job: RunLoopJob
    }

    private let pending = Mutex<Pending?>(nil)

    func record(_ window: AXWindowRef?, for job: RunLoopJob) {
        pending.withLock { $0 = window.map { Pending(window: $0, job: job) } }
    }

    func claim(matching window: AXWindowRef, for job: RunLoopJob, canRaise: Bool) -> AXWindowRef? {
        pending.withLock { state in
            guard let binding = state, binding.job === job else { return nil }
            defer { state = nil }
            guard canRaise, sameAXWindowIdentity(window, binding.window), !job.isCancelled else { return nil }
            return binding.window
        }
    }

    func invalidateChangedBinding(in windows: [Int: AXUIElement]) {
        pending.withLock { state in
            guard let binding = state,
                  !AppAXContext.sameElement(binding.window.element, windows[binding.window.windowId])
            else { return }
            binding.job.cancel()
            state = nil
        }
    }
}

struct AppAXRetryRaiseOperation: Sendable {
    let window: AXWindowRef
    let pid: pid_t
    let job: RunLoopJob
    let binding: AppAXRetryRaiseBinding
    let isSuppressed: @Sendable () -> Bool
    let awaitingSubmittedFocus: @Sendable () -> Void
    let raiseWindow: @Sendable (AXUIElement) -> Bool

    func enqueue(
        on queue: DispatchQueue,
        appThread: Thread,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        completion: @escaping @Sendable () -> Void
    ) {
        let postedNs = WindowFocusDispatchTrace.retryRaise.isActive ? DispatchTime.now().uptimeNanoseconds : 0
        nonisolated(unsafe) let appThread = appThread
        queue.async {
            guard !job.isCancelled else {
                completion()
                return
            }
            let startedNs = postedNs == 0 ? 0 : DispatchTime.now().uptimeNanoseconds
            awaitingSubmittedFocus()
            let timing = WindowFocusDispatchTrace.RetryRaiseTiming(
                postedNs: postedNs,
                startedNs: startedNs,
                waitedNs: postedNs == 0 ? 0 : DispatchTime.now().uptimeNanoseconds
            )
            appThread.runInLoopAsync { _ in
                guard !job.isCancelled else {
                    completion()
                    return
                }
                let boundWindow = windows[window.windowId].map {
                    AXWindowRef(element: $0, windowId: window.windowId)
                }
                binding.record(boundWindow, for: job)
                queue.async {
                    WindowFocusDispatchTrace.traceRetryRaise(pid: pid, windowId: window.windowId, timing: timing) {
                        AppAXContext.performRetryRaise(
                            window, binding: binding, job: job, isSuppressed: isSuppressed, raiseWindow: raiseWindow
                        )
                    }
                    completion()
                }
            }
        }
    }
}
