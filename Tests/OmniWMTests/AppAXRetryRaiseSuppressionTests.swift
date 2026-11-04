// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class AppAXRetryRaiseSuppressionTests: XCTestCase {
    func testLayoutHiddenRaiseSurvivesFrameSuppressionButNotNativeSuppression() {
        for allowsLayoutHiddenWindow in [false, true] {
            withContext { context, window in
                let job = RunLoopJob()
                XCTAssertTrue(context.enqueueRetryRaise(
                    window, job: job, awaitingSubmittedFocus: {},
                    allowsLayoutHiddenWindow: allowsLayoutHiddenWindow, completion: {}
                ))

                context.suppressFrameWrites(for: [window.windowId])

                XCTAssertEqual(job.isCancelled, !allowsLayoutHiddenWindow)
                XCTAssertTrue(context.frameDelivery.retryRaiseSuppression.contains(window.windowId))
                context.setWindowNativeSuppressed(true, for: window.windowId)
                XCTAssertTrue(job.isCancelled)
            }
        }
    }

    func testLayoutHiddenRaiseStillCancelsWhenApplicationHides() {
        withContext { context, window in
            let job = RunLoopJob()
            XCTAssertTrue(context.enqueueRetryRaise(
                window, job: job, awaitingSubmittedFocus: {},
                allowsLayoutHiddenWindow: true, completion: {}
            ))
            context.suppressFrameWrites(for: [window.windowId])
            XCTAssertFalse(job.isCancelled)

            context.setMacOSAppHidden(true, for: [window.windowId])

            XCTAssertTrue(job.isCancelled)
            XCTAssertTrue(context.frameDelivery.retryRaiseSuppression.isHardSuppressed(for: window.windowId))
        }
    }

    private func withContext(_ body: (AppAXContext, AXWindowRef) -> Void) {
        let pid: pid_t = 831_009
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 831_109)
        $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let app = ThreadGuardedValue(window.element)
            let windows = ThreadGuardedValue([window.windowId: window.element])
            let observer = ThreadGuardedValue<AXObserver?>(nil)
            let focusedObserver = ThreadGuardedValue<AXObserver?>(nil)
            let subscriptions = ThreadGuardedValue<[Int: AppAXWindowSubscription]>([:])
            let removals = ThreadGuardedValue<[AppAXPendingNotificationRemoval]>([])
            let context = AppAXContext(
                .current, pid: pid, app, windows, observer, focusedObserver, subscriptions, removals,
                nil, nil, UInt64(pid), Thread.current
            )
            defer {
                context.prepareForStopRestoration()
                AXWriteMetrics.shared.retire(context.writeMetricsToken)
                app.destroy()
                windows.destroy()
                observer.destroy()
                focusedObserver.destroy()
                subscriptions.destroy()
                removals.destroy()
            }
            body(context, window)
        }
    }
}
