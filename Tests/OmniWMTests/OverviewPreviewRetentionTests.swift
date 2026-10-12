// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import IOSurface
@testable import OmniWM
import XCTest

@MainActor
final class OverviewPreviewRetentionTests: XCTestCase {
    func testSelectedRequestStartsFirstAndReprioritizesQueuedSourcesWithoutRestarting() async {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let handles = handles(count: 7)
        let requests = requests(for: handles)
        capture.reconcile(represented: Set(handles), visible: requests, prioritizing: handles[6])
        await driver.waitForStarts(4)
        XCTAssertEqual(driver.streams.map(\.request.handle), [handles[6]] + Array(handles.prefix(3)))

        capture.reconcile(represented: Set(handles), visible: requests, prioritizing: handles[5])
        XCTAssertEqual(driver.streams.count, 4)
        XCTAssertTrue(driver.streams.allSatisfy { $0.stopCount == 0 })
        driver.streams[0].completeStart()
        await driver.waitForStarts(5)
        XCTAssertTrue(driver.streams[4].request.handle === handles[5])
        capture.clear()
        driver.completeAllStarts()
        await driver.waitForStops(5)
    }

    func testBudgetPreservesLiveAndClosingFramesThenKeepsRecentRequestsInsteadOfLatestVideo() async throws {
        let frames = try (0 ..< 3).map { _ in try makeOverviewPreviewFrame() }
        let budget = frames[0].surface.allocationSize + frames[1].surface.allocationSize
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(maximumRetainedBytes: budget)
        let handles = handles(count: 3)
        let requests = requests(for: handles)
        capture.reconcile(represented: Set(handles), visible: requests)
        await driver.waitForStarts(3)
        driver.completeAllStarts()
        for index in frames.indices {
            await publish(frames[index], through: driver.streams[index], into: capture)
        }
        XCTAssertGreaterThan(capture.cachedByteCount, budget)
        capture.releaseCache()
        XCTAssertGreaterThan(capture.cachedByteCount, budget)

        capture.reconcile(represented: Set(handles), visible: requests, prioritizing: handles[1])
        await publish(frames[2], through: driver.streams[2], into: capture)
        capture.reconcile(represented: Set(handles), visible: [])
        XCTAssertGreaterThan(capture.cachedByteCount, budget)
        driver.makeCapture(consumer: .workspaceBarHover, maximumRetainedBytes: budget).clear()
        XCTAssertGreaterThan(capture.cachedByteCount, budget)
        driver.coordinator.releaseCaches(reason: .memoryPressure)
        XCTAssertGreaterThan(capture.cachedByteCount, budget)
        var removed: [WindowHandle] = []
        capture.onPreview = { handle, frame in if frame == nil { removed.append(handle) } }
        capture.clear()
        await driver.waitForStops(3)

        XCTAssertEqual(capture.cachedByteCount, budget)
        XCTAssertTrue(capture.preview(for: handles[0]) === frames[0])
        XCTAssertTrue(capture.preview(for: handles[1]) === frames[1])
        XCTAssertNil(capture.preview(for: handles[2]))
        XCTAssertEqual(removed, [handles[2]])
        driver.streams[2].output.offer(frames[2])
        XCTAssertNil(driver.streams[2].output.take())
        XCTAssertNil(capture.preview(for: handles[2]))
        capture.releaseCache()
        XCTAssertEqual(capture.cachedByteCount, 0)
    }

    func testBudgetUsesReplacementAllocationAndSkipsOversizedRecentFrame() async throws {
        let small = try makeOverviewPreviewFrame()
        let replacement = try makeOverviewPreviewFrame(width: 160, height: 120)
        let oversized = try makeOverviewPreviewFrame(width: 1024, height: 1024)
        let budget = replacement.surface.allocationSize + small.surface.allocationSize
        XCTAssertGreaterThan(oversized.surface.allocationSize, budget)
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(maximumRetainedBytes: budget)
        let handles = handles(count: 3)
        let requests = requests(for: handles)
        capture.reconcile(represented: Set(handles), visible: requests)
        await driver.waitForStarts(3)
        driver.completeAllStarts()
        await publish(small, through: driver.streams[0], into: capture)
        await publish(oversized, through: driver.streams[1], into: capture)
        await publish(small, through: driver.streams[2], into: capture)
        await publish(replacement, through: driver.streams[0], into: capture)
        XCTAssertEqual(capture.cachedByteCount, budget + oversized.surface.allocationSize)
        capture.reconcile(represented: Set(handles), visible: requests, prioritizing: handles[1])
        capture.clear()
        await driver.waitForStops(3)

        XCTAssertEqual(capture.cachedByteCount, budget)
        XCTAssertTrue(capture.preview(for: handles[0]) === replacement)
        XCTAssertNil(capture.preview(for: handles[1]))
        XCTAssertTrue(capture.preview(for: handles[2]) === small)
        capture.reconcile(represented: Set(handles), visible: [requests[0]])
        XCTAssertTrue(capture.preview(for: handles[0]) === replacement)
        await driver.waitForStarts(4)
        capture.clear()
        driver.completeAllStarts()
        await driver.waitForStops(4)
    }

    func testCacheHitRecencySurvivesLaterLiveFramePublication() async throws {
        let frames = try (0 ..< 3).map { _ in try makeOverviewPreviewFrame() }
        let driver = OverviewPreviewTestDriver()
        let budget = frames[0].surface.allocationSize * 2
        let capture = driver.makeCapture(maximumRetainedBytes: budget)
        let handles = handles(count: 3)
        capture.reconcile(
            represented: Set(handles), visible: requests(for: handles), prioritizing: handles[1]
        )
        await driver.waitForStarts(3)
        driver.completeAllStarts()
        for stream in driver.streams {
            let index = try XCTUnwrap(handles.firstIndex(of: stream.request.handle))
            await publish(frames[index], through: stream, into: capture)
        }
        XCTAssertTrue(capture.preview(for: handles[2]) === frames[2])
        let replacement = try makeOverviewPreviewFrame()
        let stream = try XCTUnwrap(driver.streams.first { $0.request.handle === handles[2] })
        await publish(replacement, through: stream, into: capture)
        capture.clear()
        await driver.waitForStops(3)
        XCTAssertEqual(capture.cachedByteCount, budget)
        XCTAssertNil(capture.preview(for: handles[0]))
        XCTAssertTrue(capture.preview(for: handles[1]) === frames[1])
        XCTAssertTrue(capture.preview(for: handles[2]) === replacement)
        capture.releaseCache()
    }

    private func handles(count: Int) -> [WindowHandle] {
        (1 ... count).map { WindowHandle(id: WindowToken(pid: 123, windowId: $0)) }
    }

    private func requests(for handles: [WindowHandle]) -> [OverviewPreviewRequest] {
        handles.map { OverviewPreviewRequest(handle: $0, pixelWidth: 80, pixelHeight: 60) }
    }

    private func publish(
        _ frame: OverviewPreviewFrame,
        through stream: OverviewPreviewTestStream,
        into capture: OverviewThumbnailCapture
    ) async {
        let published = expectation(description: "requested preview published")
        capture.onPreview = { handle, preview in
            if handle === stream.request.handle, preview === frame { published.fulfill() }
        }
        stream.output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
    }
}
