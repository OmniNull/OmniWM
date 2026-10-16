// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class LockScreenObserverTests: XCTestCase {
    func testStartReportsLockedSessionAsLocked() {
        let observer = LockScreenObserver()
        observer.screenLockedProvider = { true }
        var lockDetections = 0
        observer.onLockDetected = { lockDetections += 1 }

        observer.start()
        defer { observer.stop() }
        observer.start()

        XCTAssertEqual(lockDetections, 1)
        guard case .locked = observer.state else {
            return XCTFail("expected locked state")
        }
        XCTAssertTrue(observer.isFrontmostAppLockScreen())
    }

    func testServiceRestartReconcilesUnlockMissedWhileObserverWasStopped() {
        let controller = WindowAdmissionTestSupport.controller()
        let observer = controller.lockScreenObserver
        observer.screenLockedProvider = { true }
        defer {
            observer.stop()
            controller.layoutRefreshController.resetState()
            controller.isLockScreenActive = false
        }

        controller.serviceLifecycleManager.startLockScreenObserver()
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)

        XCTAssertTrue(controller.isLockScreenActive)
        XCTAssertTrue(controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertNotNil(controller.layoutRefreshController.layoutState.pendingRefresh)

        observer.stop()
        observer.screenLockedProvider = { false }
        controller.serviceLifecycleManager.startLockScreenObserver()

        XCTAssertFalse(controller.isLockScreenActive)
        XCTAssertFalse(observer.isFrontmostAppLockScreen())
        XCTAssertTrue(controller.layoutRefreshController.layoutState.isAwaitingPostUnlockTopologySample)
    }

    func testServiceRestartWhileStillLockedRestoresRefreshSuspension() {
        let controller = WindowAdmissionTestSupport.controller()
        let observer = controller.lockScreenObserver
        observer.screenLockedProvider = { true }
        defer {
            observer.stop()
            controller.layoutRefreshController.resetState()
            controller.isLockScreenActive = false
        }

        controller.serviceLifecycleManager.startLockScreenObserver()
        observer.stop()
        controller.layoutRefreshController.resetState()

        XCTAssertTrue(controller.isLockScreenActive)
        XCTAssertFalse(controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen)

        controller.serviceLifecycleManager.startLockScreenObserver()

        XCTAssertTrue(controller.isLockScreenActive)
        XCTAssertTrue(controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen)
    }

    func testRepeatedUnlockReportsOnce() {
        let observer = LockScreenObserver()
        observer.screenLockedProvider = { true }
        var unlockDetections = 0
        observer.onUnlockDetected = { unlockDetections += 1 }
        observer.start()
        defer { observer.stop() }

        observer.handleUnlockEvent()
        observer.handleUnlockEvent()

        XCTAssertEqual(unlockDetections, 1)
        XCTAssertFalse(observer.isFrontmostAppLockScreen())
        guard case .transitioning = observer.state else {
            return XCTFail("expected transitioning state")
        }
    }

    func testQueuedLockFromStoppedGenerationCannotOverrideRestartSample() async {
        let observer = LockScreenObserver()
        observer.screenLockedProvider = { false }
        var lockDetections = 0
        observer.onLockDetected = { lockDetections += 1 }
        observer.start()

        observer.enqueueLockEventForTests()
        observer.stop()
        observer.start()
        defer { observer.stop() }
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        XCTAssertEqual(lockDetections, 0)
        guard case .unlocked = observer.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertFalse(observer.isFrontmostAppLockScreen())
    }

    func testUnknownSessionLockStatePreservesLockedStateOnRestart() {
        let observer = LockScreenObserver()
        observer.screenLockedProvider = { true }
        observer.start()
        observer.stop()
        observer.screenLockedProvider = { nil }

        observer.start()
        defer { observer.stop() }

        guard case .locked = observer.state else {
            return XCTFail("expected locked state")
        }
        XCTAssertTrue(observer.isFrontmostAppLockScreen())
    }

    func testAppActivationWhileLockedDoesNotUnlock() async {
        let observer = LockScreenObserver()
        observer.screenLockedProvider = { false }
        var unlockDetections = 0
        let lockHandled = expectation(description: "lock event handled")
        observer.onLockDetected = { lockHandled.fulfill() }
        observer.onUnlockDetected = { unlockDetections += 1 }
        observer.start()
        defer { observer.stop() }

        observer.screenLockedProvider = { true }
        observer.enqueueLockEventForTests()
        await fulfillment(of: [lockHandled], timeout: 1)
        let sessionChecked = expectation(description: "activation checks session")
        sessionChecked.assertForOverFulfill = false
        observer.screenLockedProvider = {
            sessionChecked.fulfill()
            return true
        }
        postActivation()
        await fulfillment(of: [sessionChecked], timeout: 1)

        XCTAssertEqual(unlockDetections, 0)
        guard case .locked = observer.state else {
            return XCTFail("expected locked state")
        }
        XCTAssertTrue(observer.isFrontmostAppLockScreen())
    }

    func testAppActivationAfterMissedUnlockReconcilesFromSession() async {
        let observer = LockScreenObserver()
        observer.screenLockedProvider = { false }
        let lockHandled = expectation(description: "lock event handled")
        let unlockHandled = expectation(description: "unlock reconciled")
        observer.onLockDetected = { lockHandled.fulfill() }
        observer.onUnlockDetected = { unlockHandled.fulfill() }
        observer.start()
        defer { observer.stop() }

        observer.screenLockedProvider = { true }
        observer.enqueueLockEventForTests()
        await fulfillment(of: [lockHandled], timeout: 1)
        observer.screenLockedProvider = { false }
        postActivation()
        await fulfillment(of: [unlockHandled], timeout: 1)

        XCTAssertFalse(observer.isFrontmostAppLockScreen())
    }

    private func postActivation() {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared
        )
    }
}
