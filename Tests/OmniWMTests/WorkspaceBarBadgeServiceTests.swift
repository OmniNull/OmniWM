// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

final class WorkspaceBarBadgeServiceTests: XCTestCase {
    @MainActor
    func testInitialReadAndIntervalChangesRescheduleWithoutReading() async {
        let harness = BadgeServiceHarness()
        let service = makeService(harness)
        defer { service.stop() }

        service.configure(mode: .dot, interval: 5, bundleIDs: ["com.example.App"])
        await harness.waitForReads(1)
        let initialRead = await harness.reads[0]
        XCTAssertEqual(initialRead.bundleIDs, ["com.example.app"])
        await harness.completeRead(0, result: DockBadgeReadResult(labels: ["com.example.app": "3"], dockPID: 42))
        await harness.waitForSleeps(1)
        XCTAssertEqual(service.label(for: "com.example.App"), "3")

        service.configure(mode: .text, interval: 1, bundleIDs: ["com.example.App"])
        await harness.waitForSleeps(2)
        service.configure(mode: .text, interval: 60, bundleIDs: ["com.example.App"])
        await harness.waitForSleeps(3)

        let durations = await harness.sleepDurations
        let readCount = await harness.reads.count
        XCTAssertEqual(durations, [.seconds(5), .seconds(1), .seconds(60)])
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(service.mode, .text)

        await harness.wakeSleep(2)
        await harness.waitForReads(2)
        await harness.completeRead(1, result: DockBadgeReadResult(labels: ["com.example.app": "4"], dockPID: 42))
        await harness.waitForSleeps(4)
        XCTAssertEqual(service.label(for: "com.example.app"), "4")
    }

    @MainActor
    func testTargetAndLifecycleChangesDuringReadDoNotOverlapOrPublishStaleLabels() async {
        let harness = BadgeServiceHarness()
        let service = makeService(harness)
        defer { service.stop() }

        service.configure(mode: .text, interval: 5, bundleIDs: ["com.example.first"])
        await harness.waitForReads(1)
        service.configure(mode: .text, interval: 1, bundleIDs: ["com.example.second"])
        service.applicationChanged(bundleID: "com.example.second", terminated: false)
        await harness.completeRead(
            0,
            result: DockBadgeReadResult(labels: ["com.example.first": "stale"], dockPID: 42)
        )
        await harness.waitForReads(2)

        let reads = await harness.reads
        let maxConcurrentReads = await harness.maxConcurrentReads
        XCTAssertEqual(reads[1].bundleIDs, ["com.example.second"])
        XCTAssertGreaterThan(reads[1].generation, reads[0].generation)
        XCTAssertEqual(maxConcurrentReads, 1)
        XCTAssertTrue(service.labels.isEmpty)

        await harness.completeRead(
            1,
            result: DockBadgeReadResult(labels: ["com.example.second": "!"], dockPID: 42)
        )
        await harness.waitForSleeps(1)
        let durations = await harness.sleepDurations
        XCTAssertEqual(durations, [.seconds(1)])
        XCTAssertEqual(service.labels, ["com.example.second": "!"])
    }

    @MainActor
    func testRapidStopAndEnableRejectsCancelledRead() async {
        let harness = BadgeServiceHarness()
        let service = makeService(harness)
        defer { service.stop() }

        service.configure(mode: .text, interval: 5, bundleIDs: ["com.example.app"])
        await harness.waitForReads(1)
        service.stop()
        service.configure(mode: .text, interval: 5, bundleIDs: ["com.example.app"])
        await harness.waitForResets(1)
        await harness.completeRead(
            0,
            result: DockBadgeReadResult(labels: ["com.example.app": "stale"], dockPID: 42)
        )
        await harness.waitForReads(2)

        let reads = await harness.reads
        let resets = await harness.resetGenerations
        let maxConcurrentReads = await harness.maxConcurrentReads
        XCTAssertGreaterThan(resets[0], reads[0].generation)
        XCTAssertGreaterThan(reads[1].generation, resets[0])
        XCTAssertEqual(maxConcurrentReads, 1)
        XCTAssertTrue(service.labels.isEmpty)

        await harness.completeRead(1, result: DockBadgeReadResult(labels: ["com.example.app": "7"], dockPID: 42))
        await harness.waitForSleeps(1)
        XCTAssertEqual(service.label(for: "com.example.app"), "7")
    }

    @MainActor
    func testTransientReadPreservesLabelsAndExplicitClearsRemoveThem() async {
        let harness = BadgeServiceHarness()
        let service = makeService(harness)
        defer { service.stop() }

        service.configure(mode: .text, interval: 5, bundleIDs: ["com.example.first", "com.example.second"])
        await harness.waitForReads(1)
        await harness.completeRead(
            0,
            result: DockBadgeReadResult(labels: ["com.example.first": "12", "com.example.second": "●"], dockPID: 42)
        )
        await harness.waitForSleeps(1)
        await harness.wakeSleep(0)
        await harness.waitForReads(2)
        await harness.completeRead(1, result: DockBadgeReadResult(dockPID: 42))
        await harness.waitForSleeps(2)
        XCTAssertEqual(service.labels, ["com.example.first": "12", "com.example.second": "●"])

        await harness.wakeSleep(1)
        await harness.waitForReads(3)
        await harness.completeRead(
            2,
            result: DockBadgeReadResult(
                labels: ["com.example.second": ""],
                clearedBundleIDs: ["com.example.first"],
                dockPID: 42
            )
        )
        await harness.waitForSleeps(3)
        XCTAssertTrue(service.labels.isEmpty)
    }

    @MainActor
    func testDockReplacementDropsOldLabelsAndLifecycleRequestsFreshRead() async {
        let harness = BadgeServiceHarness()
        let service = makeService(harness)
        defer { service.stop() }

        service.configure(mode: .text, interval: 5, bundleIDs: ["com.example.first", "com.example.second"])
        await harness.waitForReads(1)
        await harness.completeRead(
            0,
            result: DockBadgeReadResult(labels: ["com.example.first": "2", "com.example.second": "5"], dockPID: 42)
        )
        await harness.waitForSleeps(1)
        await harness.wakeSleep(0)
        await harness.waitForReads(2)
        await harness.completeRead(
            1,
            result: DockBadgeReadResult(labels: ["com.example.first": "1"], dockPID: 43)
        )
        await harness.waitForSleeps(2)
        XCTAssertEqual(service.labels, ["com.example.first": "1"])

        service.applicationChanged(bundleID: "com.apple.dock", terminated: false)
        XCTAssertTrue(service.labels.isEmpty)
        await harness.waitForReads(3)
        let reads = await harness.reads
        XCTAssertGreaterThan(reads[2].generation, reads[1].generation)
        await harness.completeRead(
            2,
            result: DockBadgeReadResult(labels: ["com.example.second": "9"], dockPID: 44)
        )
        await harness.waitForSleeps(3)
        XCTAssertEqual(service.labels, ["com.example.second": "9"])
    }

    @MainActor
    func testRemovingTargetsAndDisablingClearStateWithoutFurtherReads() async {
        let harness = BadgeServiceHarness()
        let service = makeService(harness)
        defer { service.stop() }

        service.configure(mode: .off, interval: 5, bundleIDs: ["com.example.first"])
        XCTAssertTrue(service.bundleIDs.isEmpty)
        service.configure(mode: .text, interval: 5, bundleIDs: ["com.example.first", "com.example.second"])
        await harness.waitForReads(1)
        await harness.completeRead(
            0,
            result: DockBadgeReadResult(labels: ["com.example.first": "2", "com.example.second": "5"], dockPID: 42)
        )
        await harness.waitForSleeps(1)
        service.configure(mode: .text, interval: 5, bundleIDs: ["com.example.second"])
        XCTAssertEqual(service.labels, ["com.example.second": "5"])
        await harness.waitForReads(2)
        await harness.completeRead(
            1,
            result: DockBadgeReadResult(labels: ["com.example.first": "3", "com.example.second": "6"], dockPID: 42)
        )
        await harness.waitForSleeps(2)
        XCTAssertEqual(service.labels, ["com.example.second": "6"])

        service.configure(mode: .off, interval: 5, bundleIDs: ["com.example.second"])
        await harness.waitForResets(1)
        service.configure(mode: .text, interval: 5, bundleIDs: [])
        XCTAssertTrue(service.bundleIDs.isEmpty)
        XCTAssertTrue(service.labels.isEmpty)
        XCTAssertNil(service.label(for: nil))
        let readCount = await harness.reads.count
        XCTAssertEqual(readCount, 2)
    }

    @MainActor
    func testUnchangedReadDoesNotPublishLabelsAgain() async {
        let harness = BadgeServiceHarness()
        let service = makeService(harness)
        defer { service.stop() }

        service.configure(mode: .dot, interval: 5, bundleIDs: ["com.example.app"])
        await harness.waitForReads(1)
        let result = DockBadgeReadResult(labels: ["com.example.app": "3"], dockPID: 42)
        await harness.completeRead(0, result: result)
        await harness.waitForSleeps(1)
        let changes = Mutex(0)
        withObservationTracking {
            _ = service.label(for: "com.example.app")
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        await harness.wakeSleep(0)
        await harness.waitForReads(2)
        await harness.completeRead(1, result: result)
        await harness.waitForSleeps(2)
        XCTAssertEqual(changes.withLock { $0 }, 0)

        await harness.wakeSleep(1)
        await harness.waitForReads(3)
        await harness.completeRead(2, result: DockBadgeReadResult(labels: ["com.example.app": "4"], dockPID: 42))
        await harness.waitForSleeps(3)
        XCTAssertEqual(changes.withLock { $0 }, 1)
    }

    @MainActor
    private func makeService(_ harness: BadgeServiceHarness) -> WorkspaceBarBadgeService {
        WorkspaceBarBadgeService(
            notificationCenter: NotificationCenter(),
            read: { await harness.read(bundleIDs: $0, generation: $1) },
            reset: { await harness.reset(generation: $0) },
            sleep: { try await harness.sleep(for: $0) }
        )
    }
}

private actor BadgeServiceHarness {
    struct Read: Sendable {
        let bundleIDs: Set<String>
        let generation: UInt64
    }

    private(set) var reads: [Read] = []
    private(set) var sleepDurations: [Duration] = []
    private(set) var resetGenerations: [UInt64] = []
    private(set) var maxConcurrentReads = 0
    private var readContinuations: [Int: CheckedContinuation<DockBadgeReadResult, Never>] = [:]
    private var sleepContinuations: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var sleepWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resetWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func read(bundleIDs: Set<String>, generation: UInt64) async -> DockBadgeReadResult {
        let index = reads.count
        reads.append(Read(bundleIDs: bundleIDs, generation: generation))
        return await withCheckedContinuation { continuation in
            readContinuations[index] = continuation
            maxConcurrentReads = max(maxConcurrentReads, readContinuations.count)
            let ready = readWaiters.filter { $0.count <= reads.count }
            readWaiters.removeAll { $0.count <= reads.count }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func completeRead(_ index: Int, result: DockBadgeReadResult) {
        readContinuations.removeValue(forKey: index)?.resume(returning: result)
    }

    func reset(generation: UInt64) {
        resetGenerations.append(generation)
        let ready = resetWaiters.filter { $0.count <= resetGenerations.count }
        resetWaiters.removeAll { $0.count <= resetGenerations.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func sleep(for duration: Duration) async throws {
        let index = sleepDurations.count
        sleepDurations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepContinuations[index] = continuation
                }
                let ready = sleepWaiters.filter { $0.count <= sleepDurations.count }
                sleepWaiters.removeAll { $0.count <= sleepDurations.count }
                for waiter in ready { waiter.continuation.resume() }
            }
        } onCancel: {
            Task { await self.cancelSleep(index) }
        }
    }

    func wakeSleep(_ index: Int) {
        sleepContinuations.removeValue(forKey: index)?.resume()
    }

    func waitForReads(_ count: Int) async {
        guard reads.count < count else { return }
        await withCheckedContinuation { readWaiters.append((count, $0)) }
    }

    func waitForSleeps(_ count: Int) async {
        guard sleepDurations.count < count else { return }
        await withCheckedContinuation { sleepWaiters.append((count, $0)) }
    }

    func waitForResets(_ count: Int) async {
        guard resetGenerations.count < count else { return }
        await withCheckedContinuation { resetWaiters.append((count, $0)) }
    }

    private func cancelSleep(_ index: Int) {
        sleepContinuations.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }
}
