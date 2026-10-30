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
        var pending: [CheckedContinuation<Void, Never>] = []

        func discover() async -> [SCWindow] {
            calls += 1
            await withCheckedContinuation { pending.append($0) }
            return []
        }

        func answerAll() {
            let waiting = pending
            pending.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }

    private func handle(_ id: Int) -> WindowHandle {
        WindowHandle(id: WindowToken(pid: 123, windowId: id))
    }

    private struct ConditionTimedOut: Error {}

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition not met within one second", file: file, line: line)
                throw ConditionTimedOut()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testUnansweredStartsReleaseTheirSlotsAndAreRequestedAgain() async throws {
        let driver = OverviewPreviewTestDriver()
        defer { driver.finish() }
        let capture = driver.makeCapture(startTimeout: .milliseconds(200))
        let handles = (1 ... 5).map(handle)
        let requests = handles.map { OverviewPreviewRequest(handle: $0, pixelWidth: 80, pixelHeight: 60) }
        capture.reconcile(represented: Set(handles), visible: requests)

        try await driver.waitForStarts(5)
        try await driver.waitForStops(5)
        XCTAssertFalse(capture.hasPendingFirstFrames)

        capture.reconcile(represented: Set(handles), visible: requests)
        try await driver.waitForStarts(6)
        let replacement = driver.streams[5]
        replacement.completeStart()
        let frame = try makeOverviewPreviewFrame()
        let published = expectation(description: "replacement preview published")
        capture.onPreview = { handle, delivered in
            if handle === replacement.request.handle, delivered === frame { published.fulfill() }
        }
        replacement.output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(capture.preview(for: replacement.request.handle) === frame)
        try await driver.waitForStarts(10)

        driver.streams[0].completeStart()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(driver.streams[0].stopCount, 1)
    }

    func testHungWindowDiscoveryReleasesItsCallersAndIsRequestedAgain() async throws {
        let probe = DiscoveryProbe()
        let coordinator = PreviewCaptureCoordinator(
            ownedWindowRegistry: OwnedWindowRegistry(),
            discoveryTimeout: .milliseconds(50),
            discoverWindows: { await probe.discover() }
        )
        let token = WindowToken(pid: 123, windowId: 1)
        var released = 0
        let first = Task {
            let result = await coordinator.window(for: token)
            released += 1
            return result.discoveredCount
        }
        try await waitUntil { probe.calls == 1 }
        let second = Task {
            let result = await coordinator.window(for: token)
            released += 1
            return result.discoveredCount
        }
        try await waitUntil { released == 2 }
        let firstCount = await first.value
        let secondCount = await second.value
        XCTAssertNil(firstCount)
        XCTAssertNil(secondCount)
        XCTAssertEqual(probe.calls, 1)

        let retry = Task { await coordinator.window(for: token).discoveredCount }
        try await waitUntil { probe.calls == 2 }
        probe.answerAll()
        let retryCount = await retry.value
        XCTAssertEqual(retryCount, 0)
    }

    func testDiscoveryInFlightIsSharedUntilItsTimeout() async throws {
        let probe = DiscoveryProbe()
        let coordinator = PreviewCaptureCoordinator(
            ownedWindowRegistry: OwnedWindowRegistry(),
            discoveryTimeout: .seconds(60),
            discoverWindows: { await probe.discover() }
        )
        let token = WindowToken(pid: 123, windowId: 1)
        let first = Task { await coordinator.window(for: token).discoveredCount }
        try await waitUntil { probe.calls == 1 }
        let second = Task { await coordinator.window(for: token).discoveredCount }
        try await Task.sleep(for: .milliseconds(50))
        probe.answerAll()

        _ = await first.value
        _ = await second.value
        XCTAssertEqual(probe.calls, 1)
    }
}
