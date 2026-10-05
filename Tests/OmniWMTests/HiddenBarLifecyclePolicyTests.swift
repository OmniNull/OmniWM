// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarLifecyclePolicyTests: XCTestCase {
    func testRefreshRequiresEnabledAvailableAndConfiguredHiddenApp() {
        XCTAssertFalse(HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: false,
            available: true,
            hiddenBundleIDs: ["a"]
        ))
        XCTAssertFalse(HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: true,
            available: false,
            hiddenBundleIDs: ["a"]
        ))
        XCTAssertFalse(HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: true,
            available: true,
            hiddenBundleIDs: []
        ))
        XCTAssertTrue(HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: true,
            available: true,
            hiddenBundleIDs: ["a"]
        ))
    }

    func testTemporaryRevealAndPendingCaptureStayAllowed() {
        XCTAssertEqual(
            HiddenBarConcealmentPolicy.effectiveHiddenBundleIDs(
                configured: ["revealed", "capturing", "concealed"],
                temporarilyRevealed: ["revealed"],
                pendingCapture: ["capturing"]
            ),
            ["concealed"]
        )
    }

    @MainActor
    func testDisabledSetupLeavesObserversAndItemServiceStopped() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarDisabledSetup")
        controller.settings.hiddenBar.enabled = false
        let hiddenBar = controller.hiddenBarController

        hiddenBar.setup()

        XCTAssertFalse(hiddenBar.observation.hasRunningApplicationsObservationForTests)
        XCTAssertFalse(hiddenBar.isItemServiceRunningForTests)
        hiddenBar.cleanup()
    }

    @MainActor
    func testDisableReleasesServicesAndReenableRestartsThem() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarToggleServices")
        let hiddenBar = controller.hiddenBarController
        hiddenBar.setup()
        XCTAssertTrue(hiddenBar.observation.hasRunningApplicationsObservationForTests)
        XCTAssertTrue(hiddenBar.isItemServiceRunningForTests)

        hiddenBar.setEnabled(false)
        XCTAssertFalse(hiddenBar.observation.hasRunningApplicationsObservationForTests)
        XCTAssertFalse(hiddenBar.isItemServiceRunningForTests)

        hiddenBar.setEnabled(true)
        XCTAssertTrue(hiddenBar.observation.hasRunningApplicationsObservationForTests)
        XCTAssertTrue(hiddenBar.isItemServiceRunningForTests)
        hiddenBar.cleanup()
    }

    @MainActor
    func testWorkspaceBarOffReleasesServicesAndReenableRestartsThem() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarWorkspaceBarToggle")
        let hiddenBar = controller.hiddenBarController
        hiddenBar.setup()
        XCTAssertTrue(hiddenBar.isItemServiceRunningForTests)

        controller.setWorkspaceBarEnabled(false)
        XCTAssertTrue(controller.settings.hiddenBar.enabled)
        XCTAssertFalse(controller.settings.effectiveHiddenBarEnabled)
        XCTAssertFalse(hiddenBar.observation.hasRunningApplicationsObservationForTests)
        XCTAssertFalse(hiddenBar.isItemServiceRunningForTests)

        controller.setWorkspaceBarEnabled(true)
        XCTAssertTrue(controller.settings.effectiveHiddenBarEnabled)
        XCTAssertTrue(hiddenBar.observation.hasRunningApplicationsObservationForTests)
        XCTAssertTrue(hiddenBar.isItemServiceRunningForTests)
        hiddenBar.cleanup()
        controller.workspaceBarManager.cleanup()
    }

    @MainActor
    func testCleanupRejectsQueuedObserverEventFromStoppedGeneration() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarObserverCleanup")
        let hiddenBar = controller.hiddenBarController
        hiddenBar.setup()
        hiddenBar.performance.begin()

        let observerEvent = hiddenBar.observation.enqueueDidBecomeActiveForTests()
        hiddenBar.cleanup()
        await observerEvent.value

        XCTAssertEqual(hiddenBar.performance.end()?.refreshEvents, 0)
    }

    @MainActor
    func testRunningApplicationsRefreshesCoalesceWhileQueued() async throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarRunningAppsCoalesce")
        let hiddenBar = controller.hiddenBarController
        var refreshes = 0
        hiddenBar.observation.onRunningApplicationsRefreshForTests = { refreshes += 1 }

        let firstRefresh = try XCTUnwrap(hiddenBar.observation.queueRunningApplicationsRefreshForTests())
        for _ in 0 ..< 2 {
            XCTAssertNil(hiddenBar.observation.queueRunningApplicationsRefreshForTests())
        }
        await firstRefresh.value
        XCTAssertEqual(refreshes, 1)

        let laterRefresh = try XCTUnwrap(hiddenBar.observation.queueRunningApplicationsRefreshForTests())
        await laterRefresh.value
        XCTAssertEqual(refreshes, 2)
        hiddenBar.cleanup()
    }

    @MainActor
    func testCleanupRejectsQueuedRunningApplicationsObserverEvent() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarRunningAppsObserverCleanup")
        let hiddenBar = controller.hiddenBarController
        var refreshes = 0
        hiddenBar.observation.onRunningApplicationsRefreshForTests = { refreshes += 1 }
        hiddenBar.setup()

        let observerEvent = hiddenBar.observation.enqueueRunningApplicationsChangedForTests()
        hiddenBar.cleanup()
        await observerEvent.value
        XCTAssertEqual(refreshes, 0)
    }

    @MainActor
    func testCleanupDropsQueuedRunningApplicationsRefreshWithoutBlockingLaterOnes() async throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarRunningAppsCleanup")
        let hiddenBar = controller.hiddenBarController
        var refreshes = 0
        hiddenBar.observation.onRunningApplicationsRefreshForTests = { refreshes += 1 }
        hiddenBar.setup()

        // Queue the refresh directly so cleanup retires its generation before
        // it can run, without relying on the timing of the observer-event hop.
        let queuedRefresh = try XCTUnwrap(hiddenBar.observation.queueRunningApplicationsRefreshForTests())
        hiddenBar.cleanup()
        await queuedRefresh.value
        XCTAssertEqual(refreshes, 0)

        hiddenBar.setup()
        let laterObserverEvent = hiddenBar.observation.enqueueRunningApplicationsChangedForTests()
        await laterObserverEvent.value
        let refreshed = await waitUntil { refreshes >= 1 }
        XCTAssertTrue(refreshed)
        hiddenBar.cleanup()
    }

    func testLaunchCaptureStaysAllowedDuringAnotherAppsReveal() {
        let effectiveHidden = HiddenBarConcealmentPolicy.effectiveHiddenBundleIDs(
            configured: ["revealed", "newly-launched", "concealed"],
            temporarilyRevealed: ["revealed"],
            pendingCapture: ["newly-launched"]
        )
        XCTAssertEqual(effectiveHidden, ["concealed"])
    }

    func testOpenMenuDoesNotConsumeRehideTime() {
        XCTAssertEqual(
            HiddenBarMenuGuardPolicy.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: false,
                menuOpen: true
            ),
            .seconds(5)
        )
    }

    func testUnknownMenuStateDoesNotConsumeRehideTime() {
        XCTAssertEqual(
            HiddenBarMenuGuardPolicy.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: false,
                menuOpen: nil
            ),
            .seconds(5)
        )
    }

    func testClosedIntervalsAccumulateUntilRehideExpires() {
        var remaining = Duration.seconds(5)
        remaining = HiddenBarMenuGuardPolicy.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(2),
            previousMenuOpen: false,
            menuOpen: false
        )
        remaining = HiddenBarMenuGuardPolicy.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(4),
            previousMenuOpen: false,
            menuOpen: true
        )
        remaining = HiddenBarMenuGuardPolicy.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(3),
            previousMenuOpen: true,
            menuOpen: false
        )
        remaining = HiddenBarMenuGuardPolicy.rehideRemaining(
            remaining: remaining,
            elapsed: .seconds(3),
            previousMenuOpen: false,
            menuOpen: false
        )
        XCTAssertEqual(remaining, .zero)
    }

    func testNegativeElapsedTimeDoesNotIncreaseCountdown() {
        XCTAssertEqual(
            HiddenBarMenuGuardPolicy.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(-2),
                previousMenuOpen: false,
                menuOpen: false
            ),
            .seconds(5)
        )
    }

    func testFirstClosedSampleStartsCountdownWithFullInterval() {
        XCTAssertEqual(
            HiddenBarMenuGuardPolicy.rehideRemaining(
                remaining: .seconds(5),
                elapsed: .seconds(2),
                previousMenuOpen: nil,
                menuOpen: false
            ),
            .seconds(5)
        )
    }

    func testMenuGuardPollingBacksOffAndCaps() {
        XCTAssertEqual(HiddenBarMenuGuardPolicy.menuGuardRetryDelay(consecutiveDeferrals: 0), .milliseconds(250))
        XCTAssertEqual(HiddenBarMenuGuardPolicy.menuGuardRetryDelay(consecutiveDeferrals: 1), .milliseconds(500))
        XCTAssertEqual(HiddenBarMenuGuardPolicy.menuGuardRetryDelay(consecutiveDeferrals: 2), .seconds(1))
        XCTAssertEqual(HiddenBarMenuGuardPolicy.menuGuardRetryDelay(consecutiveDeferrals: 20), .seconds(2))
    }

    func testMenuGuardUnknownStateHasThreeQueryBound() {
        XCTAssertFalse(HiddenBarMenuGuardPolicy.shouldTerminateMenuGuardForUnknownState(consecutiveUnknownStates: 2))
        XCTAssertTrue(HiddenBarMenuGuardPolicy.shouldTerminateMenuGuardForUnknownState(consecutiveUnknownStates: 3))
    }

    func testMenuGuardWatchdogHasSixtySecondBound() {
        XCTAssertFalse(HiddenBarMenuGuardPolicy.menuGuardWatchdogExpired(elapsed: .seconds(59)))
        XCTAssertTrue(HiddenBarMenuGuardPolicy.menuGuardWatchdogExpired(elapsed: .seconds(60)))
    }

    @MainActor
    func testUnknownMenuStateTerminatesAfterThreeInjectedQueries() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarUnknownGuard")
        let hiddenBar = controller.hiddenBarController
        var now = ContinuousClock().now
        hiddenBar.reconcealment.menuGuardNow = { now }
        hiddenBar.reconcealment.menuGuardSleeper = { delay in
            now = now.advanced(by: delay)
            await Task.yield()
        }
        hiddenBar.reconcealment.menuOpenProviderForTests = { _ in nil }
        hiddenBar.performance.begin()

        hiddenBar.startReconcealForTests(revealedBundleIDs: ["com.omniwm.unknown"])
        await driveReconcealTask(hiddenBar)

        let snapshot = hiddenBar.performance.end()
        XCTAssertEqual(snapshot?.menuGuardQueries, 3)
        XCTAssertEqual(snapshot?.terminalReason, .unknownStateLimit)
        XCTAssertTrue(hiddenBar.temporarilyRevealedBundleIDsForTests.isEmpty)
        hiddenBar.cleanup()
    }

    @MainActor
    func testDefinitelyOpenMenuUsesWatchdogInsteadOfUnknownBound() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HiddenBarWatchdog")
        let hiddenBar = controller.hiddenBarController
        var now = ContinuousClock().now
        hiddenBar.reconcealment.menuGuardNow = { now }
        hiddenBar.reconcealment.menuGuardSleeper = { delay in
            now = now.advanced(by: delay)
            await Task.yield()
        }
        hiddenBar.reconcealment.menuOpenProviderForTests = { _ in true }
        hiddenBar.performance.begin()

        hiddenBar.startReconcealForTests(revealedBundleIDs: ["com.omniwm.open"])
        await driveReconcealTask(hiddenBar)

        let terminalSnapshot = hiddenBar.performance.snapshot()
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        XCTAssertEqual(
            hiddenBar.performance.snapshot()?.menuGuardQueries,
            terminalSnapshot?.menuGuardQueries
        )
        let snapshot = hiddenBar.performance.end()
        XCTAssertGreaterThan(snapshot?.menuGuardQueries ?? 0, 3)
        XCTAssertEqual(snapshot?.terminalReason, .watchdog)
        XCTAssertTrue(hiddenBar.temporarilyRevealedBundleIDsForTests.isEmpty)
        hiddenBar.cleanup()
    }

    func testFailedRevealDoesNotStartCountdownDuringPriorActivation() {
        XCTAssertFalse(HiddenBarActivationPolicy.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: true,
            activationInFlight: true
        ))
        XCTAssertTrue(HiddenBarActivationPolicy.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: true,
            activationInFlight: false
        ))
        XCTAssertFalse(HiddenBarActivationPolicy.shouldResumeReconcealAfterFailedReveal(
            hasTemporaryReveals: false,
            activationInFlight: false
        ))
    }

    func testActivationContextRequiresConfigurationRevealAndExactPID() {
        let candidates = [
            MenuBarAppCandidate(bundleID: "target", pid: 42),
            MenuBarAppCandidate(bundleID: "target", pid: 43)
        ]
        XCTAssertTrue(HiddenBarActivationPolicy.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarActivationPolicy.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: [],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarActivationPolicy.activationContextIsValid(
            bundleID: "target",
            pid: 42,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: [],
            runningCandidates: candidates
        ))
        XCTAssertFalse(HiddenBarActivationPolicy.activationContextIsValid(
            bundleID: "target",
            pid: 44,
            configuredBundleIDs: ["target"],
            temporarilyRevealedBundleIDs: ["target"],
            runningCandidates: candidates
        ))
    }

    @MainActor
    private func driveReconcealTask(_ hiddenBar: HiddenBarController) async {
        for _ in 0 ..< 256 {
            if hiddenBar.performance.snapshot()?.terminalReason != nil {
                return
            }
            await Task.yield()
        }
        XCTFail("Reconceal task did not reach a terminal state")
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0 ..< 128 {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}
