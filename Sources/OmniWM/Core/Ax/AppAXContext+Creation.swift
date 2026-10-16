// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

private final class AppAXContextCreationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppAXContext?, Error>?

    init(_ continuation: CheckedContinuation<AppAXContext?, Error>) {
        self.continuation = continuation
    }

    func takeContinuation() -> CheckedContinuation<AppAXContext?, Error>? {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }

    @MainActor
    func scheduleDeadline() -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            self.takeContinuation()?.resume(returning: nil)
        }
    }
}

extension AppAXContext {
    @MainActor
    static func createContext(
        _ nsApp: NSRunningApplication,
        pid: pid_t,
        generation: UInt64
    ) async throws -> AppAXContext? {
        let callbackGeneration = appAXCallbackGenerationRegistry
            .reserveCallbackGeneration(serviceGeneration: generation)
        guard let callbackGeneration else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            let state = AppAXContextCreationState(continuation)
            let timeoutTask = state.scheduleDeadline()
            AppAXContextRegistry.workerLifetime.started(callbackGeneration)

            let thread = Thread {
                $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                    let axApp = AXUIElementCreateApplication(pid)

                    let (observer, focusObserver) = installContextObservers(pid: pid, axApp: axApp)

                    let guardedAxApp = ThreadGuardedValue(axApp)
                    let guardedWindows = ThreadGuardedValue([Int: AXUIElement]())
                    let guardedObserver = ThreadGuardedValue(observer)
                    let guardedFocusedWindowObserver = ThreadGuardedValue(focusObserver)
                    let guardedSubscribedWindows = ThreadGuardedValue([Int: AppAXWindowSubscription]())
                    let guardedPendingNotificationRemovals = ThreadGuardedValue(
                        [AppAXPendingNotificationRemoval]()
                    )
                    let observerCallbackKey = observer.map(axCallbackObserverKey)
                    let focusedWindowObserverCallbackKey = focusObserver.map(axCallbackObserverKey)
                    let currentThread = Thread.current

                    scheduleOnMainRunLoop {
                        timeoutTask.cancel()

                        let context = AppAXContext(
                            nsApp,
                            pid: pid,
                            guardedAxApp,
                            guardedWindows,
                            guardedObserver,
                            guardedFocusedWindowObserver,
                            guardedSubscribedWindows,
                            guardedPendingNotificationRemovals,
                            observerCallbackKey,
                            focusedWindowObserverCallbackKey,
                            callbackGeneration,
                            currentThread
                        )
                        completeContextCreation(context, state: state, generation: generation)
                    }

                    let port = NSMachPort()
                    RunLoop.current.add(port, forMode: .default)

                    CFRunLoopRun()
                }
                scheduleOnMainRunLoop { AppAXContextRegistry.workerLifetime.finished(callbackGeneration) }
            }
            thread.name = "OmniWM-AX-\(nsApp.bundleIdentifier ?? "pid:\(pid)")"
            thread.start()
        }
    }

    private nonisolated static func installContextObservers(
        pid: pid_t,
        axApp: AXUIElement
    ) -> (AXObserver?, AXObserver?) {
        var observer: AXObserver?
        if AXObserverCreate(pid, axWindowNotificationCallback, &observer) != .success {
            FallbackFiringRecorder.shared.note(.ax, "observerCreateFailed")
        }

        if let obs = observer {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        } else {
            FallbackFiringRecorder.shared.note(.ax, "observerRunLoopSourceSkipped")
        }

        var focusObserver: AXObserver?
        if AXObserverCreate(pid, axApplicationNotificationCallback, &focusObserver) != .success {
            FallbackFiringRecorder.shared.note(.ax, "focusObserverCreateFailed")
        }

        if let focusObs = focusObserver {
            if AXObserverAddNotification(
                focusObs,
                axApp,
                kAXFocusedWindowChangedNotification as CFString,
                nil
            ) != .success {
                FallbackFiringRecorder.shared.note(.ax, "focusedWindowSubscribeFailed")
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(focusObs), .defaultMode)
        } else {
            FallbackFiringRecorder.shared.note(.ax, "focusObserverRunLoopSourceSkipped")
        }

        return (observer, focusObserver)
    }

    nonisolated static func setTitleNotifications(
        _ enabled: Bool,
        app: ThreadGuardedValue<AXUIElement>,
        observer: ThreadGuardedValue<AXObserver?>
    ) {
        guard let observer = observer.valueIfExists.flatMap({ $0 }), let app = app.valueIfExists else { return }
        let notification = kAXTitleChangedNotification as CFString
        guard enabled else {
            _ = AXObserverRemoveNotification(observer, app, notification)
            return
        }
        let result = AXObserverAddNotification(observer, app, notification, nil)
        if result != .success, result != .notificationUnsupported {
            FallbackFiringRecorder.shared.note(.ax, "titleChangedSubscribeFailed")
        }
    }

    private static func completeContextCreation(
        _ context: AppAXContext,
        state: AppAXContextCreationState,
        generation: UInt64
    ) {
        guard let continuation = state.takeContinuation() else {
            context.destroy()
            return
        }

        guard context.registerCallbacks(serviceGeneration: generation) else {
            context.destroy()
            continuation.resume(returning: nil)
            return
        }
        WindowAdmissionTrace.record(
            .init(
                action: .endpointCreated,
                pid: context.pid,
                bundleId: context.nsApp.bundleIdentifier,
                callbackGeneration: context.callbackGeneration
            )
        )
        continuation.resume(returning: context)
    }
}
