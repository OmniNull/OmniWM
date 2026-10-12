// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class PreviewCaptureCoordinatorTests: XCTestCase {
    func testProvisionalConsumerShowsNewestFrameFromAnotherConsumer() async throws {
        let driver = OverviewPreviewTestDriver()
        let overview = driver.makeCapture()
        let swipe = driver.makeCapture(consumer: .workspaceSwipe, adoptsProvisionalPreviews: false)
        let hover = driver.makeCapture(consumer: .workspaceBarHover)
        let window = handle(1)
        overview.reconcile(represented: [window], visible: [request(window)])
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        let older = try makeOverviewPreviewFrame()
        try await publish(older, for: window, into: overview, driver: driver)
        swipe.reconcile(
            represented: [window],
            visible: [request(window, width: 160, height: 120)],
            retainingUnrepresentedPreviews: true
        )
        await driver.waitForStarts(2)
        driver.completeAllStarts()
        let newer = try makeOverviewPreviewFrame(width: 160, height: 120)
        try await publish(newer, for: window, into: swipe, driver: driver)

        XCTAssertTrue(hover.preview(for: window) === newer)
        XCTAssertEqual(driver.streams.count, 2)
        overview.clear()
        swipe.clear()
        await driver.waitForStops(2)
    }

    func testSufficientOnlyConsumerAdoptsLargeEnoughFramesAndSkipsTheirWarmup() async throws {
        let driver = OverviewPreviewTestDriver()
        let overview = driver.makeCapture()
        let swipe = driver.makeCapture(consumer: .workspaceSwipe, adoptsProvisionalPreviews: false)
        let small = handle(1)
        let large = handle(2)
        overview.reconcile(represented: [small, large], visible: [request(small), request(large)])
        await driver.waitForStarts(2)
        driver.completeAllStarts()
        let smallFrame = try makeOverviewPreviewFrame(width: 80, height: 60)
        let largeFrame = try makeOverviewPreviewFrame(width: 800, height: 600)
        try await publish(smallFrame, for: small, into: overview, driver: driver)
        try await publish(largeFrame, for: large, into: overview, driver: driver)
        XCTAssertNil(swipe.preview(for: small))

        swipe.reconcile(
            represented: [small, large],
            visible: [request(small, width: 400, height: 300), request(large, width: 400, height: 300)],
            retainingUnrepresentedPreviews: true,
            firstFrameOnly: true
        )
        await driver.waitForStarts(3)

        XCTAssertEqual(driver.streams.count, 3)
        XCTAssertTrue(driver.streams[2].request.handle === small)
        XCTAssertTrue(swipe.preview(for: large) === largeFrame)
        XCTAssertNil(swipe.preview(for: small))
        driver.completeAllStarts()
        overview.clear()
        swipe.clear()
        await driver.waitForStops(3)
    }

    func testSufficientOnlyConsumerRejectsFramesShortOnEitherAxis() async throws {
        let driver = OverviewPreviewTestDriver()
        let overview = driver.makeCapture()
        let swipe = driver.makeCapture(consumer: .workspaceSwipe, adoptsProvisionalPreviews: false)
        let window = handle(1)
        overview.reconcile(represented: [window], visible: [request(window, width: 800, height: 200)])
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        let wide = try makeOverviewPreviewFrame(width: 800, height: 200)
        try await publish(wide, for: window, into: overview, driver: driver)

        swipe.reconcile(
            represented: [window],
            visible: [request(window, width: 400, height: 300)],
            retainingUnrepresentedPreviews: true,
            firstFrameOnly: true
        )

        XCTAssertNil(swipe.preview(for: window))
        XCTAssertTrue(swipe.hasPendingFirstFrames)
        guard swipe.hasPendingFirstFrames else { return }
        await driver.waitForStarts(2)
        XCTAssertTrue(driver.streams[1].request.handle === window)
        driver.completeAllStarts()
        overview.clear()
        swipe.clear()
        await driver.waitForStops(2)
    }

    func testSharedBudgetEvictsLeastRecentIdleFramesAndKeepsActiveConsumerFrames() async throws {
        let frames = try (0 ..< 3).map { _ in try makeOverviewPreviewFrame() }
        let budget = frames[0].surface.allocationSize * 2
        let driver = OverviewPreviewTestDriver()
        let active = driver.makeCapture(maximumRetainedBytes: budget)
        let idle = driver.makeCapture(consumer: .workspaceBarHover, maximumRetainedBytes: budget)
        let handles = (1 ... 3).map(handle)
        idle.reconcile(
            represented: [handles[1], handles[2]],
            visible: [request(handles[1]), request(handles[2])],
            prioritizing: handles[1]
        )
        await driver.waitForStarts(2)
        driver.completeAllStarts()
        try await publish(frames[1], for: handles[1], into: idle, driver: driver)
        try await publish(frames[2], for: handles[2], into: idle, driver: driver)
        idle.clear()
        await driver.waitForStops(2)
        XCTAssertEqual(idle.cachedByteCount, budget)

        active.reconcile(represented: [handles[0]], visible: [request(handles[0])])
        await driver.waitForStarts(3)
        driver.completeAllStarts()
        try await publish(frames[0], for: handles[0], into: active, driver: driver)
        driver.coordinator.trimRetainedPreviews()

        XCTAssertTrue(active.retainedPreview(matching: handles[0].token)?.frame === frames[0])
        XCTAssertTrue(idle.retainedPreview(matching: handles[1].token)?.frame === frames[1])
        XCTAssertNil(idle.retainedPreview(matching: handles[2].token))
        active.clear()
        await driver.waitForStops(3)
    }

    func testFrameSharedByConsumersCountsOnceAgainstBudget() async throws {
        let frame = try makeOverviewPreviewFrame()
        let driver = OverviewPreviewTestDriver()
        let owner = driver.makeCapture(maximumRetainedBytes: frame.surface.allocationSize)
        let adopter = driver.makeCapture(
            consumer: .workspaceBarHover,
            maximumRetainedBytes: frame.surface.allocationSize
        )
        let window = handle(1)
        owner.reconcile(represented: [window], visible: [request(window)])
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        try await publish(frame, for: window, into: owner, driver: driver)
        owner.clear()
        await driver.waitForStops(1)

        XCTAssertTrue(adopter.preview(for: window) === frame)
        driver.coordinator.trimRetainedPreviews()

        XCTAssertTrue(owner.retainedPreview(matching: window.token)?.frame === frame)
        XCTAssertTrue(adopter.retainedPreview(matching: window.token)?.frame === frame)
    }

    func testWindowRemovalReleasesTheFrameFromEveryConsumer() async throws {
        let frame = try makeOverviewPreviewFrame()
        let driver = OverviewPreviewTestDriver()
        let owner = driver.makeCapture()
        let adopter = driver.makeCapture(consumer: .workspaceBarHover)
        let window = handle(1)
        owner.reconcile(represented: [window], visible: [request(window)])
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        try await publish(frame, for: window, into: owner, driver: driver)
        owner.clear()
        await driver.waitForStops(1)
        XCTAssertTrue(adopter.preview(for: window) === frame)
        var released: [WindowHandle] = []
        adopter.onPreview = { handle, preview in if preview == nil { released.append(handle) } }

        driver.coordinator.windowRemoved(window.token)

        XCTAssertNil(owner.retainedPreview(matching: window.token))
        XCTAssertNil(adopter.retainedPreview(matching: window.token))
        XCTAssertEqual(released.count, 1)
        XCTAssertTrue(released.first === window)
    }

    private func handle(_ windowId: Int) -> WindowHandle {
        WindowHandle(id: WindowToken(pid: 321, windowId: windowId))
    }

    private func request(_ handle: WindowHandle, width: Int = 80, height: Int = 60) -> OverviewPreviewRequest {
        OverviewPreviewRequest(handle: handle, pixelWidth: width, pixelHeight: height)
    }

    private func publish(
        _ frame: OverviewPreviewFrame,
        for handle: WindowHandle,
        into capture: OverviewThumbnailCapture,
        driver: OverviewPreviewTestDriver
    ) async throws {
        let stream = try XCTUnwrap(driver.streams.last { $0.request.handle === handle })
        let published = expectation(description: "frame published")
        let forward = capture.onPreview
        capture.onPreview = { candidate, preview in
            forward(candidate, preview)
            if candidate === handle, preview === frame { published.fulfill() }
        }
        stream.output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
        capture.onPreview = forward
    }
}
