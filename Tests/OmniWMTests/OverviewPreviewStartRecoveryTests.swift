// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import ScreenCaptureKit
import XCTest

@MainActor
final class OverviewPreviewStartRecoveryTests: XCTestCase {
    @MainActor
    private final class DiscoveryProbe {
        var calls = 0
        var onDiscover: @MainActor () -> Void = {}
        private var pending: [CheckedContinuation<Void, Never>] = []

        func discover() async -> [SCWindow] {
            calls += 1
            onDiscover()
            await withCheckedContinuation { pending.append($0) }
            return []
        }

        func answerAll() {
            let waiting = pending
            pending.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }

    private let token = WindowToken(pid: 123, windowId: 1)

    private func handle(_ id: Int) -> WindowHandle {
        WindowHandle(id: WindowToken(pid: 123, windowId: id))
    }

    private func makeCoordinator(
        _ probe: DiscoveryProbe,
        _ sleeper: OverviewPreviewManualSleeper
    ) -> PreviewCaptureCoordinator {
        PreviewCaptureCoordinator(
            ownedWindowRegistry: OwnedWindowRegistry(),
            sleep: { try await sleeper.sleep(for: $0) },
            discoverWindows: { await probe.discover() }
        )
    }

    private func beginDiscovery(
        on coordinator: PreviewCaptureCoordinator,
        _ probe: DiscoveryProbe,
        released: XCTestExpectation? = nil
    ) async -> Task<Int?, Never> {
        let discovering = expectation(description: "discovery requested")
        discovering.assertForOverFulfill = false
        probe.onDiscover = { discovering.fulfill() }
        let lookup = lookUp(on: coordinator, released: released)
        await fulfillment(of: [discovering], timeout: 1)
        return lookup
    }

    private func joinDiscovery(
        on coordinator: PreviewCaptureCoordinator,
        released: XCTestExpectation? = nil
    ) async -> Task<Int?, Never> {
        let joining = expectation(description: "second caller running")
        let lookup = lookUp(on: coordinator, willCall: { joining.fulfill() }, released: released)
        await fulfillment(of: [joining], timeout: 1)
        return lookup
    }

    private func lookUp(
        on coordinator: PreviewCaptureCoordinator,
        willCall: @escaping @MainActor () -> Void = {},
        released: XCTestExpectation?
    ) -> Task<Int?, Never> {
        Task { [token] in
            willCall()
            let count = await coordinator.window(for: token).discoveredCount
            released?.fulfill()
            return count
        }
    }

    func testUnansweredStartsReleaseTheirSlotsAndAreRequestedAgain() async throws {
        let sleeper = OverviewPreviewManualSleeper()
        let driver = OverviewPreviewTestDriver()
        defer {
            driver.finish()
            sleeper.resumeAll()
        }
        let capture = driver.makeCapture(sleep: { try await sleeper.sleep(for: $0) })
        let handles = (1 ... 5).map(handle)
        let requests = handles.map { OverviewPreviewRequest(handle: $0, pixelWidth: 80, pixelHeight: 60) }
        capture.reconcile(represented: Set(handles), visible: requests)

        let slots = handles.count - 1
        try await driver.waitForStarts(slots)
        for _ in 0 ..< slots { sleeper.resumeNext() }
        try await driver.waitForStarts(handles.count)
        sleeper.resumeNext()
        try await driver.waitForStops(handles.count)
        XCTAssertFalse(capture.hasPendingFirstFrames)

        capture.reconcile(represented: Set(handles), visible: requests)
        try await driver.waitForStarts(handles.count + 1)
        let replacement = driver.streams[handles.count]
        let frame = try makeOverviewPreviewFrame()
        let published = expectation(description: "replacement preview published")
        capture.onPreview = { handle, delivered in
            if handle === replacement.request.handle, delivered === frame { published.fulfill() }
        }
        replacement.completeStart()
        replacement.output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(capture.preview(for: replacement.request.handle) === frame)
        try await driver.waitForStarts(handles.count * 2)
    }

    func testHungWindowDiscoveryReleasesItsCallersAndIsRequestedAgain() async throws {
        let sleeper = OverviewPreviewManualSleeper()
        let probe = DiscoveryProbe()
        defer {
            probe.answerAll()
            sleeper.resumeAll()
        }
        let coordinator = makeCoordinator(probe, sleeper)
        let released = expectation(description: "callers released")
        released.expectedFulfillmentCount = 2
        let first = await beginDiscovery(on: coordinator, probe, released: released)
        let second = await joinDiscovery(on: coordinator, released: released)

        sleeper.resumeNext()
        await fulfillment(of: [released], timeout: 1)
        probe.answerAll()
        let firstCount = await first.value
        let secondCount = await second.value
        XCTAssertNil(firstCount)
        XCTAssertNil(secondCount)
        XCTAssertEqual(probe.calls, 1)

        let retry = await beginDiscovery(on: coordinator, probe)
        XCTAssertEqual(probe.calls, 2)
        probe.answerAll()
        let retryCount = await retry.value
        XCTAssertEqual(retryCount, 0)
    }

    func testDiscoveryInFlightIsSharedUntilItsDeadline() async throws {
        let sleeper = OverviewPreviewManualSleeper()
        let probe = DiscoveryProbe()
        defer { sleeper.resumeAll() }
        let coordinator = makeCoordinator(probe, sleeper)
        let first = await beginDiscovery(on: coordinator, probe)
        let second = await joinDiscovery(on: coordinator)

        probe.answerAll()
        let firstCount = await first.value
        let secondCount = await second.value
        XCTAssertEqual(firstCount, 0)
        XCTAssertNil(secondCount)
        XCTAssertEqual(probe.calls, 1)
    }
}
