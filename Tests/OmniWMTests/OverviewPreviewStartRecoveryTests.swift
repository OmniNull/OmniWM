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

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testUnansweredStartsReleaseTheirSlotsForQueuedPreviews() async throws {
        let driver = OverviewPreviewTestDriver()
        defer { driver.finish() }
        let capture = driver.makeCapture(startTimeout: .milliseconds(50))
        let handles = (1 ... 5).map(handle)
        capture.reconcile(
            represented: Set(handles),
            visible: handles.map { OverviewPreviewRequest(handle: $0, pixelWidth: 80, pixelHeight: 60) }
        )

        try await driver.waitForStarts(4)
        XCTAssertEqual(driver.streams.count, 4)

        try await driver.waitForStarts(5)
        try await driver.waitForStops(4)
        XCTAssertEqual(driver.streams.count, 5)

        driver.streams[0].completeStart()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(driver.streams[0].stopCount, 1)
    }

    func testHungWindowDiscoveryIsReplacedAfterItsTimeout() async throws {
        let probe = DiscoveryProbe()
        let coordinator = PreviewCaptureCoordinator(
            ownedWindowRegistry: OwnedWindowRegistry(),
            discoveryTimeout: .milliseconds(50),
            discoverWindows: { await probe.discover() }
        )
        let token = WindowToken(pid: 123, windowId: 1)
        let hung = Task { await coordinator.window(for: token).discoveredCount }
        try await waitUntil { probe.calls == 1 }
        try await Task.sleep(for: .milliseconds(100))

        let replacement = Task {
            let result = await coordinator.window(for: token)
            return (found: result.window != nil, discoveredCount: result.discoveredCount)
        }
        try await waitUntil { probe.calls == 2 }
        XCTAssertEqual(probe.calls, 2)
        probe.answerAll()

        let replaced = await replacement.value
        XCTAssertFalse(replaced.found)
        XCTAssertEqual(replaced.discoveredCount, 0)
        _ = await hung.value
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
