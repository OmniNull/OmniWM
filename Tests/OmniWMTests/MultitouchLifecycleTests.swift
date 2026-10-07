// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreHID
import IOKit
@testable import OmniWM
import XCTest

@MainActor
final class MultitouchLifecycleTests: XCTestCase {
    private let deviceA = FakeMultitouchBackend.device(pointer: 0xA1, registryId: 101)
    private let deviceB = FakeMultitouchBackend.device(pointer: 0xB1, registryId: 202)

    func testProductionTopologyCriteriaUsesDigitizerDeviceUsages() throws {
        let criteria = MultitouchTopologyMonitor.topologyCriteria
        XCTAssertEqual(criteria.count, 1)
        let criterion = try XCTUnwrap(criteria.first)
        XCTAssertNil(criterion.primaryUsage)
        XCTAssertEqual(
            criterion.deviceUsages,
            [.digitizers(.touchPad), .digitizers(.multiplePointDigitizer)]
        )
        XCTAssertNil(criterion.vendorID)
        XCTAssertNil(criterion.productID)
    }

    func testNilEnumerationNeverBecomesRunning() async {
        let harness = makeHarness([FakeMultitouchBackend.failedEnumeration(.unavailable)])
        harness.source.startLifecycle()
        await runNext(harness)

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .retrying)
        XCTAssertEqual(snapshot.registeredDeviceCount, 0)
        XCTAssertEqual(snapshot.lastEnumeration, .unavailable)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 1)
        XCTAssertTrue(harness.backend.registeredGenerations.isEmpty)
        await shutdown(harness)
    }

    func testEmptyEnumerationNeverBecomesRunning() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([])])
        harness.source.startLifecycle()
        await runNext(harness)

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .retrying)
        XCTAssertEqual(snapshot.registeredDeviceCount, 0)
        XCTAssertEqual(snapshot.lastEnumeration, .empty)
        XCTAssertTrue(harness.backend.registeredGenerations.isEmpty)
        await shutdown(harness)
    }

    func testDelayedDeviceAppearanceStartsOnBoundedRetry() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .retrying)
        await runNext(harness)

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.registeredDeviceCount, 1)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.start(101)), 1)
        XCTAssertEqual(harness.sleeper.pendingCount, 0)
        await shutdown(harness)
    }

    func testWakeWaitsThenReplacesSameDeviceSetOnce() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        let firstGeneration = harness.source.diagnosticsSnapshot().activeGeneration

        harness.source.requestRevalidation(.wake)
        await harness.sleeper.waitForScheduledSleep(of: harness.source)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(1))
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 0)
        await harness.sleeper.resumeNext()

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertNotEqual(snapshot.activeGeneration, firstGeneration)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.unregister(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        await shutdown(harness)
    }

    func testWakeAndUnlockCoalesceIntoOneReplacement() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)

        harness.source.requestRevalidation(.wake)
        harness.source.requestRevalidation(.unlock)
        await harness.sleeper.waitForScheduledSleep(of: harness.source)
        XCTAssertEqual(harness.sleeper.pendingCount, 1)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(1))
        await harness.sleeper.resumeNext()

        XCTAssertEqual(harness.backend.callCount(.enumerate), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        await shutdown(harness)
    }

    func testTopologyConvergenceAfterWakeDoesNotRepeatLifecycleReplacement() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA, deviceB])
        ])
        harness.source.startLifecycle()
        await runNext(harness)

        harness.source.requestRevalidation(.wake)
        harness.source.receiveTopologySignal(.arrival)
        await runNext(harness)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)

        await runNext(harness)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)

        await runNext(harness)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 3)
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 2)
        await shutdown(harness)
    }

    func testEventInterpreterWakeAndServiceUnlockReachInstalledSource() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        let controller = WindowAdmissionTestSupport.controller()
        controller.mouseEventHandler.installMultitouchSource(harness.source)
        await runNext(harness)
        let initialGeneration = harness.source.diagnosticsSnapshot().activeGeneration

        controller.eventInterpreter.handleIntakeEvent(StampedIntakeEvent(seq: 1, event: .systemSleep))
        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .suspended)
        controller.eventInterpreter.handleIntakeEvent(StampedIntakeEvent(seq: 2, event: .systemWake))
        await harness.sleeper.waitForScheduledSleep(of: harness.source)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(1))
        await harness.sleeper.resumeNext()
        let wakeGeneration = harness.source.diagnosticsSnapshot().activeGeneration
        XCTAssertNotEqual(wakeGeneration, initialGeneration)

        controller.serviceLifecycleManager.handleUnlockDetected()
        await harness.sleeper.waitForScheduledSleep(of: harness.source)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(1))
        await harness.sleeper.resumeNext()
        XCTAssertNotEqual(harness.source.diagnosticsSnapshot().activeGeneration, wakeGeneration)

        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        await harness.sleeper.resumeAll()
    }

    func testArrivalRecoversSourceAfterEmptyStartup() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        let requests = harness.sleeper.requestedDurations.count
        harness.source.receiveTopologySignal(.arrival)
        await harness.sleeper.waitForRequests(requests + 1)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastTopologySignal, .arrival)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 1)
        await shutdown(harness)
    }

    func testArrivalRetriesUntilMultitouchEnumerationConverges() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA, deviceB])
        ])
        harness.source.startLifecycle()
        await runNext(harness)

        harness.source.receiveTopologySignal(.arrival)
        await runNext(harness)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .milliseconds(250))

        await runNext(harness)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().registeredDeviceCount, 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 3)
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 2)
        await shutdown(harness)
    }

    func testRemovalRebuildsChangedDeviceSet() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA, deviceB]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.receiveTopologySignal(.removal)
        await runNext(harness)

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.registeredDeviceCount, 1)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.stop(202)), 1)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        await shutdown(harness)
    }

    func testSameCountReplacementUsesRegistryIds() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceB])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        let firstGeneration = harness.source.diagnosticsSnapshot().activeGeneration
        harness.source.receiveTopologySignal(.arrival)
        await runNext(harness)

        XCTAssertNotEqual(harness.source.diagnosticsSnapshot().activeGeneration, firstGeneration)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        await shutdown(harness)
    }

    func testDuplicateTopologySignalsForceOneReplacementPerEpisode() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        let initialGeneration = harness.source.diagnosticsSnapshot().activeGeneration

        harness.source.receiveTopologySignal(.arrival)
        harness.source.receiveTopologySignal(.removal)
        harness.source.receiveTopologySignal(.arrival)
        await harness.sleeper.waitForScheduledSleep(of: harness.source)
        XCTAssertEqual(harness.sleeper.pendingCount, 1)
        await harness.sleeper.resumeNext()
        await harness.sleeper.waitForScheduledSleep(of: harness.source)

        let replacementGeneration = harness.source.diagnosticsSnapshot().activeGeneration
        XCTAssertNotEqual(replacementGeneration, initialGeneration)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)

        let requests = harness.sleeper.requestedDurations.count
        harness.source.receiveTopologySignal(.removal)
        await harness.sleeper.waitForRequests(requests + 1)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().activeGeneration, replacementGeneration)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 3)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        await shutdown(harness)
    }

    func testTopologySignalAcceleratesLongRetryWithoutResettingAttemptBudget() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.receiveTopologySignal(.arrival)
        for _ in 0 ..< 5 {
            await runNext(harness)
        }

        let attempt = harness.source.diagnosticsSnapshot().retryAttempt
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(4))
        let requests = harness.sleeper.requestedDurations.count
        harness.source.receiveTopologySignal(.removal)
        await harness.sleeper.waitForRequests(requests + 1)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().retryAttempt, attempt)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .milliseconds(100))
        XCTAssertEqual(harness.sleeper.pendingCount, 1)
        await shutdown(harness)
    }

    func testRetryCancellationOnSuspendAndShutdown() async {
        let suspended = makeHarness([FakeMultitouchBackend.enumeration([])])
        suspended.source.startLifecycle()
        await runNext(suspended)
        let suspendedEnumerationCount = suspended.backend.callCount(.enumerate)
        suspended.source.suspendForSleep()
        await suspended.sleeper.resumeAll()
        XCTAssertEqual(suspended.source.diagnosticsSnapshot().state, .suspended)
        XCTAssertEqual(suspended.backend.callCount(.enumerate), suspendedEnumerationCount)
        await shutdown(suspended)

        let stopped = makeHarness([FakeMultitouchBackend.enumeration([])])
        stopped.source.startLifecycle()
        await runNext(stopped)
        let stoppedEnumerationCount = stopped.backend.callCount(.enumerate)
        stopped.source.shutdown()
        await stopped.sleeper.resumeAll()
        XCTAssertEqual(stopped.source.diagnosticsSnapshot().state, .stopped)
        XCTAssertEqual(stopped.backend.callCount(.enumerate), stoppedEnumerationCount)
    }

    func testRetryExhaustionStopsScheduling() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([])])
        harness.source.startLifecycle()
        for _ in 0 ..< 7 {
            await runNext(harness)
        }

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .exhausted)
        XCTAssertEqual(snapshot.retryAttempt, 7)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 7)
        XCTAssertEqual(harness.sleeper.pendingCount, 0)
        XCTAssertEqual(
            harness.sleeper.requestedDurations,
            [
                .milliseconds(100),
                .milliseconds(250),
                .milliseconds(500),
                .seconds(1),
                .seconds(2),
                .seconds(4),
                .seconds(8)
            ]
        )
        await shutdown(harness)
    }

    func testStaleGenerationIsRejectedAfterReplacement() async throws {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        var snapshots: [MouseEventHandler.GestureEventSnapshot] = []
        var replacementCount = 0
        harness.source.onSnapshot = { snapshots.append($0) }
        harness.source.onSourceWillReplace = { replacementCount += 1 }
        harness.source.startLifecycle()
        await runNext(harness)
        let firstGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        harness.source.handleRawFrame(frame(count: 3, timestamp: 1), generation: firstGeneration, location: .zero)
        XCTAssertEqual(snapshots.last?.phaseRawValue, NSEvent.Phase.began.rawValue)

        harness.source.requestRevalidation(.wake)
        await runNext(harness)
        let secondGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        XCTAssertNotEqual(secondGeneration, firstGeneration)
        XCTAssertEqual(replacementCount, 1)

        let acceptedCount = snapshots.count
        harness.source.handleRawFrame(frame(count: 0, timestamp: 2), generation: firstGeneration, location: .zero)
        XCTAssertEqual(snapshots.count, acceptedCount)
        harness.source.handleRawFrame(frame(count: 3, timestamp: 3), generation: secondGeneration, location: .zero)
        XCTAssertEqual(snapshots.last?.phaseRawValue, NSEvent.Phase.began.rawValue)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastRawCallbackGeneration, secondGeneration)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastAcceptedCallbackGeneration, secondGeneration)
        await shutdown(harness)
    }

    func testStaleCallbackCannotRouteThroughNewSharedSource() async throws {
        let first = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        first.source.startLifecycle()
        await runNext(first)
        let staleGeneration = try XCTUnwrap(first.source.diagnosticsSnapshot().activeGeneration)

        let second = makeHarness([FakeMultitouchBackend.enumeration([deviceB])])
        var secondSnapshots = 0
        second.source.onSnapshot = { _ in secondSnapshots += 1 }
        second.source.startLifecycle()
        await runNext(second)
        XCTAssertTrue(MultitouchGestureSource.shared === second.source)

        MultitouchGestureSource.shared?.handleRawFrame(
            frame(count: 3, timestamp: 4),
            generation: staleGeneration,
            location: .zero
        )
        XCTAssertEqual(secondSnapshots, 0)
        await shutdown(first)
        await shutdown(second)
    }

    func testPartialStartFailureRollsBackEntireTransaction() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA, deviceB])])
        harness.backend.startResults[202] = [-1]
        harness.source.startLifecycle()
        await runNext(harness)

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .retrying)
        XCTAssertEqual(snapshot.registeredDeviceCount, 0)
        XCTAssertNil(snapshot.activeGeneration)
        XCTAssertEqual(snapshot.lastStart, .status(-1))
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.stop(202)), 1)
        XCTAssertEqual(harness.backend.callCount(.unregister(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.unregister(202)), 1)
        await shutdown(harness)
    }

    func testFailedStartTreatsNotOpenStopAsCompletedCleanup() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.backend.startResults[101] = [-1, KERN_SUCCESS]
        harness.backend.stopResults[101] = [kIOReturnNotOpen]
        harness.source.startLifecycle()
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastStop, .alreadyStopped(kIOReturnNotOpen))
        XCTAssertEqual(harness.source.diagnosticsSnapshot().registeredDeviceCount, 0)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        await shutdown(harness)
    }

    func testRemovalTreatsNotOpenStopAsCompletedCleanup() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceB])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.backend.stopResults[101] = [kIOReturnNotOpen]

        harness.source.receiveTopologySignal(.removal)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastStop, .alreadyStopped(kIOReturnNotOpen))
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        await shutdown(harness)
    }

    func testMissingUnregisterCallbackIsIdempotentCleanup() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.backend.unregisterResults[101] = [false]

        XCTAssertTrue(harness.source.shutdown())
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastUnregister, .alreadyUnregistered)
        XCTAssertNil(harness.source.diagnosticsSnapshot().activeGeneration)
        await harness.sleeper.resumeAll()
    }

    func testCleanupFailureBlocksReregistrationUntilCleanupSucceeds() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.backend.stopResults[101] = [-1, KERN_SUCCESS]
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.requestRevalidation(.wake)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .retrying)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 1)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        let secondRegister = harness.backend.calls.lastIndex(of: .register(101))
        let successfulCleanupStop = harness.backend.calls.lastIndex(of: .stop(101))
        XCTAssertNotNil(secondRegister)
        XCTAssertNotNil(successfulCleanupStop)
        if let secondRegister, let successfulCleanupStop {
            XCTAssertGreaterThan(secondRegister, successfulCleanupStop)
        }
        await shutdown(harness)
    }

    func testSourceReplacementWaitsForOldShutdownCleanup() async {
        let old = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        old.backend.stopResults[101] = [-1, KERN_SUCCESS]
        let replacement = makeHarness([FakeMultitouchBackend.enumeration([deviceB])])
        let controller = WindowAdmissionTestSupport.controller()

        XCTAssertTrue(controller.mouseEventHandler.installMultitouchSource(old.source))
        await runNext(old)
        XCTAssertFalse(controller.mouseEventHandler.installMultitouchSource(replacement.source))
        XCTAssertEqual(controller.mouseEventHandler.multitouchDiagnosticsSnapshot?.lastStop, .status(-1))
        XCTAssertEqual(replacement.backend.callCount(.register(202)), 0)
        XCTAssertTrue(MultitouchGestureSource.shared === old.source)

        XCTAssertTrue(controller.mouseEventHandler.installMultitouchSource(replacement.source))
        await runNext(replacement)
        XCTAssertEqual(replacement.backend.callCount(.register(202)), 1)
        XCTAssertTrue(MultitouchGestureSource.shared === replacement.source)

        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        await old.sleeper.resumeAll()
        await replacement.sleeper.resumeAll()
    }

    func testSuppliedDrainLocationDoesNotCountCursorSample() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.beginPerformanceCapture()
        var locations: [CGPoint] = []
        harness.source.onSnapshot = { locations.append($0.location) }
        harness.backend.emitFrame(registryId: 101, touches: [(0.4, 0.5)], timestamp: 1)
        harness.backend.emitFrame(registryId: 101, touches: [(0.5, 0.5)], timestamp: 1.01)
        harness.backend.emitFrame(registryId: 101, touches: [], timestamp: 1.02)

        let location = CGPoint(x: 200, y: 300)
        harness.source.drainRawFrameMailbox(location: location)

        XCTAssertEqual(locations, [location, location, location])
        XCTAssertEqual(harness.source.performanceSnapshot()?.drainBatches, 1)
        XCTAssertEqual(harness.source.performanceSnapshot()?.cursorSamples, 0)
        await drainMultitouchTasks()
        XCTAssertEqual(harness.source.endPerformanceCapture()?.cursorSamples, 0)
        await shutdown(harness)
    }

    func testDrainSamplesCursorOncePerNonemptyBatch() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.beginPerformanceCapture()
        harness.source.drainRawFrameMailbox()
        XCTAssertEqual(harness.source.performanceSnapshot()?.cursorSamples, 0)
        harness.backend.emitFrame(registryId: 101, touches: [(0.4, 0.5)], timestamp: 1)
        harness.backend.emitFrame(registryId: 101, touches: [(0.5, 0.5)], timestamp: 1.01)
        harness.backend.emitFrame(registryId: 101, touches: [], timestamp: 1.02)

        harness.source.drainRawFrameMailbox()

        XCTAssertEqual(harness.source.performanceSnapshot()?.drainBatches, 1)
        XCTAssertEqual(harness.source.performanceSnapshot()?.cursorSamples, 1)
        await drainMultitouchTasks()
        XCTAssertEqual(harness.source.endPerformanceCapture()?.cursorSamples, 1)
        await shutdown(harness)
    }

    func testPerformanceCountersSurviveSourceReplacement() async throws {
        let old = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        let replacement = makeHarness([FakeMultitouchBackend.enumeration([deviceB])])
        let controller = WindowAdmissionTestSupport.controller(prefix: "MultitouchMetricsReplacement")
        let handler = controller.mouseEventHandler

        XCTAssertTrue(handler.installMultitouchSource(old.source))
        await runNext(old)
        handler.beginPerformanceCapture()
        old.backend.emitFrame(registryId: 101, touches: [], timestamp: 1)

        XCTAssertTrue(handler.installMultitouchSource(replacement.source))
        await runNext(replacement)
        replacement.backend.emitFrame(registryId: 202, touches: [], timestamp: 2)

        let liveSnapshot = try XCTUnwrap(handler.performanceSnapshot()?.multitouch)
        XCTAssertEqual(liveSnapshot.rawCallbacks, 2)
        XCTAssertEqual(liveSnapshot.pendingFrames, 0)
        let snapshot = try XCTUnwrap(handler.endPerformanceCapture()?.multitouch)
        XCTAssertEqual(snapshot.rawCallbacks, 2)
        XCTAssertEqual(snapshot.staleCallbacks, 0)
        XCTAssertEqual(snapshot.pendingFrames, 0)

        controller.layoutRefreshController.resetState()
        handler.cleanup()
        await old.sleeper.resumeAll()
        await replacement.sleeper.resumeAll()
    }

    func testPerformanceCountersSurviveSourceDisable() async throws {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        let controller = WindowAdmissionTestSupport.controller(prefix: "MultitouchMetricsDisable")
        controller.settings.gestures.scrollEnabled = true
        controller.settings.gestures.workspaceSwipeEnabled = false
        controller.hasStartedServices = true
        let handler = controller.mouseEventHandler

        XCTAssertTrue(handler.installMultitouchSource(harness.source))
        await runNext(harness)
        handler.beginPerformanceCapture()
        harness.backend.emitFrame(registryId: 101, touches: [], timestamp: 1)
        harness.backend.emitFrame(registryId: 101, touches: [], timestamp: 2)

        controller.settings.gestures.scrollEnabled = false
        handler.reconcileMultitouchSource()

        let liveSnapshot = try XCTUnwrap(handler.performanceSnapshot()?.multitouch)
        XCTAssertEqual(liveSnapshot.rawCallbacks, 2)
        XCTAssertEqual(liveSnapshot.pendingFrames, 0)
        let snapshot = try XCTUnwrap(handler.endPerformanceCapture()?.multitouch)
        XCTAssertEqual(snapshot.rawCallbacks, 2)
        XCTAssertEqual(snapshot.staleCallbacks, 0)
        XCTAssertEqual(snapshot.pendingFrames, 0)
        XCTAssertNil(handler.multitouchDiagnosticsSnapshot)

        controller.hasStartedServices = false
        controller.layoutRefreshController.resetState()
        handler.cleanup()
        await harness.sleeper.resumeAll()
    }

    func testFeatureReenableRetriesRetainedSourceAfterDisableCleanupFailure() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        let controller = WindowAdmissionTestSupport.controller(prefix: "MultitouchDisableRecovery")
        controller.settings.gestures.scrollEnabled = true
        controller.settings.gestures.workspaceSwipeEnabled = false
        controller.hasStartedServices = true
        let handler = controller.mouseEventHandler
        var replacementCreations = 0
        handler.multitouchSourceFactory = {
            replacementCreations += 1
            return MultitouchGestureSource(operations: nil)
        }

        XCTAssertTrue(handler.installMultitouchSource(harness.source))
        await runNext(harness)
        harness.backend.stopResults[101] = [-1, KERN_SUCCESS]

        controller.settings.gestures.scrollEnabled = false
        handler.reconcileMultitouchSource()

        XCTAssertEqual(handler.multitouchDiagnosticsSnapshot?.state, .stopped)
        XCTAssertEqual(handler.multitouchDiagnosticsSnapshot?.lastStop, .status(-1))
        XCTAssertTrue(MultitouchGestureSource.shared === harness.source)

        controller.settings.gestures.scrollEnabled = true
        handler.reconcileMultitouchSource()
        await runNext(harness)

        XCTAssertEqual(handler.multitouchDiagnosticsSnapshot?.state, .running)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(replacementCreations, 0)
        XCTAssertTrue(MultitouchGestureSource.shared === harness.source)

        controller.hasStartedServices = false
        controller.layoutRefreshController.resetState()
        handler.cleanup()
        await harness.sleeper.resumeAll()
    }

    func testCleanupDiagnosticsPreserveFailureAcrossDevices() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA, deviceB])])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.backend.stopResults[101] = [-1, KERN_SUCCESS]

        XCTAssertFalse(harness.source.shutdown())
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastStop, .status(-1))
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastUnregister, .success)
        XCTAssertTrue(harness.source.shutdown())
        await harness.sleeper.resumeAll()
    }

    func testTopologyObserverExhaustionIsBoundedAndWakeRearmsIt() async {
        await assertTopologyObserverRearms(for: .wake)
    }

    func testTopologyObserverExhaustionIsBoundedAndUnlockRearmsIt() async {
        await assertTopologyObserverRearms(for: .unlock)
    }

    private func assertTopologyObserverRearms(for reason: MultitouchGestureSource.RevalidationReason) async {
        let backend = FakeMultitouchBackend()
        backend.enumerations = [FakeMultitouchBackend.enumeration([deviceA])]
        let lifecycleSleeper = ManualMultitouchSleeper()
        let topologyMonitor = FakeTopologyMonitor()
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: lifecycleSleeper),
            topologyMonitoringEnabled: true,
            topologyMonitoringOperations: topologyMonitor.operations()
        )
        let harness = (source: source, backend: backend, sleeper: lifecycleSleeper)

        source.startLifecycle()
        await runNext(harness)
        for request in 1 ..< 6 {
            await topologyMonitor.sleeper.waitForRequests(request)
            XCTAssertGreaterThan(topologyMonitor.sleeper.pendingCount, 0)
            await topologyMonitor.sleeper.resumeNext()
        }
        await topologyMonitor.sleeper.waitForRequests(6)
        XCTAssertEqual(topologyMonitor.sleeper.pendingCount, 1)
        XCTAssertEqual(lifecycleSleeper.pendingCount, 1)
        await lifecycleSleeper.resumeNext()
        let lifecycleRequests = lifecycleSleeper.requestedDurations.count
        await topologyMonitor.sleeper.resumeNext()
        await lifecycleSleeper.waitForRequests(lifecycleRequests + 1)

        XCTAssertEqual(topologyMonitor.streamCount, 7)
        XCTAssertEqual(source.diagnosticsSnapshot().topologyObserverState, .exhausted)
        XCTAssertEqual(topologyMonitor.sleeper.pendingCount, 0)

        source.requestRevalidation(reason)
        await topologyMonitor.sleeper.waitForRequests(7)
        XCTAssertEqual(topologyMonitor.streamCount, 8)
        XCTAssertEqual(source.diagnosticsSnapshot().topologyObserverState, .retrying(1))

        source.shutdown()
        await lifecycleSleeper.resumeAll()
        await topologyMonitor.sleeper.resumeAll()
    }

    func testTopologyObserverNotificationResetsConsecutiveFailureBudget() async {
        let backend = FakeMultitouchBackend()
        backend.enumerations = [FakeMultitouchBackend.enumeration([deviceA])]
        let lifecycleSleeper = ManualMultitouchSleeper()
        let topologyMonitor = FakeTopologyMonitor()
        topologyMonitor.signalsByStream = [[], [.arrival]]
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: lifecycleSleeper),
            topologyMonitoringEnabled: true,
            topologyMonitoringOperations: topologyMonitor.operations()
        )

        source.startLifecycle()
        await topologyMonitor.sleeper.waitForRequests(1)
        XCTAssertEqual(source.diagnosticsSnapshot().topologyObserverState, .retrying(1))
        await topologyMonitor.sleeper.resumeNext()
        await topologyMonitor.sleeper.waitForRequests(2)

        XCTAssertEqual(topologyMonitor.streamCount, 2)
        XCTAssertEqual(source.diagnosticsSnapshot().lastTopologySignal, .arrival)
        XCTAssertEqual(source.diagnosticsSnapshot().topologyObserverState, .retrying(1))
        XCTAssertEqual(
            topologyMonitor.sleeper.requestedDurations,
            [.milliseconds(250), .milliseconds(250)]
        )

        source.shutdown()
        await lifecycleSleeper.resumeAll()
        await topologyMonitor.sleeper.resumeAll()
    }

    func testDiagnosticsFormatExposesLifecycleWithoutDeviceIdentity() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        harness.source.startLifecycle()
        await runNext(harness)
        let formatted = harness.source.diagnosticsSnapshot().formatted()

        XCTAssertTrue(formatted.contains("state=running"))
        XCTAssertTrue(formatted.contains("registeredDevices=1"))
        XCTAssertTrue(formatted
            .contains("lastEnumeration=Optional(OmniWM.MultitouchBinding.EnumerationOutcome.success(1))"))
        XCTAssertTrue(formatted.contains("lastAcceptedCallbackTimestamp=nil"))
        XCTAssertFalse(formatted.contains("101"))
        await shutdown(harness)
    }

    func testTwoDevicesRegisterOneGenerationWithDistinctSlots() async throws {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA, deviceB])])
        harness.source.startLifecycle()
        await runNext(harness)

        let generation = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        XCTAssertEqual(harness.backend.registeredGenerations, [generation, generation])
        XCTAssertEqual(harness.backend.registeredSlots, [0, 1])
        await shutdown(harness)
    }

    func testInterleavedSecondDeviceCannotDisruptOwnerThroughCallbacks() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA, deviceB])])
        var snapshots: [MouseEventHandler.GestureEventSnapshot] = []
        harness.source.onSnapshot = { snapshots.append($0) }
        harness.source.startLifecycle()
        await runNext(harness)

        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.00)
        harness.backend.emitFrame(registryId: 202, touches: contacts(1), timestamp: 1.01)
        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.02)
        harness.backend.emitFrame(registryId: 202, touches: [], timestamp: 1.03)
        harness.backend.emitFrame(registryId: 101, touches: [], timestamp: 1.04)
        await drainMultitouchTasks()

        XCTAssertEqual(
            snapshots.map(\.phaseRawValue),
            [NSEvent.Phase.began.rawValue, NSEvent.Phase.changed.rawValue, NSEvent.Phase.ended.rawValue]
        )
        XCTAssertEqual(snapshots.map(\.touches.count), [3, 3, 0])
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastAcceptedCallbackTimestamp, 1.04)
        await shutdown(harness)
    }

    func testSequentialGesturesFromTwoDevicesBothDeliver() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA, deviceB])])
        var snapshots: [MouseEventHandler.GestureEventSnapshot] = []
        harness.source.onSnapshot = { snapshots.append($0) }
        harness.source.startLifecycle()
        await runNext(harness)

        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.00)
        harness.backend.emitFrame(registryId: 101, touches: [], timestamp: 1.01)
        harness.backend.emitFrame(registryId: 202, touches: contacts(1), timestamp: 1.02)
        harness.backend.emitFrame(registryId: 202, touches: [], timestamp: 1.03)
        await drainMultitouchTasks()

        XCTAssertEqual(
            snapshots.map(\.phaseRawValue),
            [
                NSEvent.Phase.began.rawValue,
                NSEvent.Phase.ended.rawValue,
                NSEvent.Phase.began.rawValue,
                NSEvent.Phase.ended.rawValue
            ]
        )
        XCTAssertEqual(snapshots.map(\.touches.count), [3, 0, 1, 0])
        await shutdown(harness)
    }

    func testReplacementMidGestureClearsOwnerForNewGeneration() async throws {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA, deviceB]),
            FakeMultitouchBackend.enumeration([deviceA, deviceB])
        ])
        var snapshots: [MouseEventHandler.GestureEventSnapshot] = []
        var replacementCount = 0
        harness.source.onSnapshot = { snapshots.append($0) }
        harness.source.onSourceWillReplace = { replacementCount += 1 }
        harness.source.startLifecycle()
        await runNext(harness)
        let firstGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)

        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.00)
        await drainMultitouchTasks()
        XCTAssertEqual(snapshots.map(\.phaseRawValue), [NSEvent.Phase.began.rawValue])

        harness.source.requestRevalidation(.wake)
        await runNext(harness)
        XCTAssertEqual(replacementCount, 1)
        XCTAssertNotEqual(harness.source.diagnosticsSnapshot().activeGeneration, firstGeneration)

        harness.source.beginPerformanceCapture()
        harness.backend.emitFrame(registryId: 202, touches: contacts(1), timestamp: 2.00)
        harness.backend.emitFrame(
            registryId: 101,
            touches: contacts(3),
            timestamp: 2.01,
            refcon: MultitouchGestureSource.RegistrationToken(generation: firstGeneration, slot: 0).refcon
        )
        await drainMultitouchTasks()

        XCTAssertEqual(
            snapshots.map(\.phaseRawValue),
            [NSEvent.Phase.began.rawValue, NSEvent.Phase.began.rawValue]
        )
        XCTAssertEqual(snapshots.last?.touches.count, 1)
        XCTAssertEqual(harness.source.endPerformanceCapture()?.staleCallbacks, 1)
        await shutdown(harness)
    }

    func testOwnerMissingLiftRecoversWithCancelledThenBegan() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        var snapshots: [MouseEventHandler.GestureEventSnapshot] = []
        harness.source.onSnapshot = { snapshots.append($0) }
        harness.source.startLifecycle()
        await runNext(harness)

        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.00)
        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.01)
        await drainMultitouchTasks()
        XCTAssertEqual(
            snapshots.map(\.phaseRawValue),
            [NSEvent.Phase.began.rawValue, NSEvent.Phase.changed.rawValue]
        )

        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.20)
        await drainMultitouchTasks()

        XCTAssertEqual(
            snapshots.map(\.phaseRawValue),
            [
                NSEvent.Phase.began.rawValue,
                NSEvent.Phase.changed.rawValue,
                NSEvent.Phase.cancelled.rawValue,
                NSEvent.Phase.began.rawValue
            ]
        )
        XCTAssertEqual(snapshots.map(\.timestamp), [1.00, 1.01, 1.20, 1.20])
        XCTAssertEqual(snapshots.map(\.touches.count), [3, 3, 0, 3])
        await shutdown(harness)
    }

    func testSecondDeviceRecoversAfterOwnerMissingLift() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA, deviceB])])
        var snapshots: [MouseEventHandler.GestureEventSnapshot] = []
        harness.source.onSnapshot = { snapshots.append($0) }
        harness.source.startLifecycle()
        await runNext(harness)

        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.00)
        harness.backend.emitFrame(registryId: 101, touches: contacts(3), timestamp: 1.01)
        await drainMultitouchTasks()
        harness.backend.emitFrame(registryId: 202, touches: contacts(1), timestamp: 1.20)
        await drainMultitouchTasks()

        XCTAssertEqual(
            snapshots.map(\.phaseRawValue),
            [
                NSEvent.Phase.began.rawValue,
                NSEvent.Phase.changed.rawValue,
                NSEvent.Phase.cancelled.rawValue,
                NSEvent.Phase.began.rawValue
            ]
        )
        XCTAssertEqual(snapshots.map(\.touches.count), [3, 3, 0, 1])
        await shutdown(harness)
    }

    func testIdleSteadyTouchesBelowTheGestureFloorNeverReachTheMainThread() async throws {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        let controller = WindowAdmissionTestSupport.controller(prefix: "MultitouchSteadyFloor")
        let gestures = controller.settings.gestures
        gestures.scrollEnabled = true
        gestures.fingerCount = .three
        gestures.workspaceSwipeEnabled = false
        gestures.windowMoveEnabled = false
        gestures.windowResizeEnabled = false
        let handler = controller.mouseEventHandler
        XCTAssertTrue(handler.installMultitouchSource(harness.source))
        await runNext(harness)
        harness.source.beginPerformanceCapture()

        harness.backend.emitFrame(registryId: 101, touches: contacts(1), timestamp: 1)
        harness.source.drainRawFrameMailbox(location: .zero)
        for tick in 1 ... 50 {
            harness.backend.emitFrame(registryId: 101, touches: contacts(1), timestamp: 1 + Double(tick) / 1_000)
        }
        harness.backend.emitFrame(registryId: 101, touches: contacts(2), timestamp: 1.06)
        harness.source.drainRawFrameMailbox(location: .zero)
        for tick in 1 ... 50 {
            harness.backend.emitFrame(registryId: 101, touches: contacts(2), timestamp: 1.06 + Double(tick) / 1_000)
        }
        harness.source.drainRawFrameMailbox(location: .zero)

        let snapshot = try XCTUnwrap(harness.source.endPerformanceCapture())
        XCTAssertEqual(snapshot.rawCallbacks, 102)
        XCTAssertEqual(snapshot.drainBatches, 2)
        XCTAssertEqual(snapshot.overwrittenChanges, 0)
        XCTAssertEqual(snapshot.pendingFrames, 0)

        controller.layoutRefreshController.resetState()
        handler.cleanup()
        await harness.sleeper.resumeAll()
    }

    private func contacts(_ count: Int) -> [(x: Float, y: Float)] {
        Array(repeating: (x: Float(0.5), y: Float(0.5)), count: count)
    }

    private func makeHarness(
        _ enumerations: [MultitouchBinding.Enumeration]
    ) -> (source: MultitouchGestureSource, backend: FakeMultitouchBackend, sleeper: ManualMultitouchSleeper) {
        let backend = FakeMultitouchBackend()
        backend.enumerations = enumerations
        let sleeper = ManualMultitouchSleeper()
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: sleeper),
            topologyMonitoringEnabled: false
        )
        return (source, backend, sleeper)
    }

    private func runNext(
        _ harness: (source: MultitouchGestureSource, backend: FakeMultitouchBackend, sleeper: ManualMultitouchSleeper)
    ) async {
        await harness.sleeper.waitForScheduledSleep(of: harness.source)
        XCTAssertGreaterThan(harness.sleeper.pendingCount, 0)
        await harness.sleeper.resumeNext()
        await harness.sleeper.waitForScheduledSleep(of: harness.source)
    }

    private func shutdown(
        _ harness: (source: MultitouchGestureSource, backend: FakeMultitouchBackend, sleeper: ManualMultitouchSleeper)
    ) async {
        harness.source.shutdown()
        await harness.sleeper.resumeAll()
    }

    private func frame(count: Int, timestamp: Double) -> MultitouchGestureSource.RawFrame {
        MultitouchGestureSource.RawFrame(
            touches: (0 ..< count).map { _ in MultitouchGestureSource.RawTouch(x: 0.5, y: 0.5) },
            timestamp: timestamp
        )
    }
}
