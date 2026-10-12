// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import IOSurface
@testable import OmniWM
import XCTest

@MainActor
final class OverviewPreviewDiagnosticsTests: XCTestCase {
    func testRequestsIdentifyConsumerAndCacheInstanceForTheSameWindow() async {
        let trace = OverviewFrameTrace.Recorder()
        trace.beginCapture()
        defer { trace.endCapture() }
        let handle = makeHandle(1)
        var cacheIds = Set<String>()
        for consumer: OverviewFrameTrace
            .PreviewConsumer in [.overview, .workspaceSwipe, .workspaceBarHover, .overview]
        {
            let driver = OverviewPreviewTestDriver()
            let capture = driver.makeCapture(consumer: consumer, traceRecorder: trace)
            capture.reconcile(represented: [handle], visible: [request(handle)], firstFrameOnly: true)
            await driver.waitForStarts(1)
            driver.completeAllStarts()
            capture.clear()
            await driver.waitForStops(1)
            let line = lines(trace, event: "previewRequested").last ?? ""
            XCTAssertTrue(line.contains(" consumer=\(consumer.rawValue) "), line)
            XCTAssertTrue(line.contains(" pid=123 wid=1 reason=cacheMiss mode=firstFrame pixels=80x60 bytes=0 "), line)
            cacheIds.insert(line.split(separator: " ").first { $0.hasPrefix("cache=") }.map(String.init) ?? "")
        }
        XCTAssertEqual(cacheIds.count, 4)
    }

    func testClearRetainsCachedFrameAndLiveRefreshIsNotReportedAsAMiss() async throws {
        let trace = OverviewFrameTrace.Recorder()
        trace.beginCapture()
        defer { trace.endCapture() }
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(consumer: .workspaceSwipe, traceRecorder: trace)
        let handle = makeHandle(1)
        capture.reconcile(represented: [handle], visible: [request(handle)], firstFrameOnly: true)
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        let frame = try makeOverviewPreviewFrame()
        await publish(frame, through: driver.streams[0], into: capture)
        capture.clear()
        await driver.waitForStops(1)
        XCTAssertTrue(capture.preview(for: handle) === frame)
        XCTAssertTrue(lines(trace, event: "previewEvicted").isEmpty)
        let cleared = lines(trace, event: "previewCacheCleared").last ?? ""
        XCTAssertTrue(cleared.contains("reason=retained"), cleared)
        XCTAssertTrue(cleared.contains("bytes=\(frame.surface.allocationSize) cached=1"), cleared)

        capture.reconcile(represented: [handle], visible: [request(handle)])
        await driver.waitForStarts(2)
        let refresh = lines(trace, event: "previewRequested").last ?? ""
        XCTAssertTrue(refresh.contains("reason=cachedRefresh mode=continuous"), refresh)
        XCTAssertTrue(refresh.contains("bytes=\(frame.surface.allocationSize)"), refresh)
        capture.clear()
        driver.completeAllStarts()
        await driver.waitForStops(2)
    }

    func testBudgetEvictsOnlyDiscardedFrameAndReportsItsAllocation() async throws {
        let trace = OverviewFrameTrace.Recorder()
        trace.beginCapture()
        defer { trace.endCapture() }
        let driver = OverviewPreviewTestDriver()
        let frames = try [makeOverviewPreviewFrame(), makeOverviewPreviewFrame()]
        let capture = driver.makeCapture(traceRecorder: trace, maximumRetainedBytes: frames[0].surface.allocationSize)
        let handles = [makeHandle(1), makeHandle(2)]
        capture.reconcile(represented: Set(handles), visible: handles.map(request), prioritizing: handles[1])
        await driver.waitForStarts(2)
        driver.completeAllStarts()
        for stream in driver.streams {
            let index = try XCTUnwrap(handles.firstIndex { $0 === stream.request.handle })
            await publish(frames[index], through: stream, into: capture)
        }
        capture.clear()
        await driver.waitForStops(2)
        XCTAssertNil(capture.preview(for: handles[0]))
        XCTAssertTrue(capture.preview(for: handles[1]) === frames[1])
        let evicted = lines(trace, event: "previewEvicted")
        XCTAssertEqual(evicted.count, 1)
        XCTAssertTrue(evicted[0].contains("pid=123 wid=1 reason=budget"), evicted[0])
        XCTAssertTrue(
            evicted[0].contains("pixels=80x60 bytes=\(frames[0].surface.allocationSize) cached=1"),
            evicted[0]
        )
    }

    func testIdentityRemovalAndRepresentationEvictionsKeepOriginalToken() async throws {
        let trace = OverviewFrameTrace.Recorder()
        trace.beginCapture()
        defer { trace.endCapture() }
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(traceRecorder: trace)
        let handles = [makeHandle(1), makeHandle(2), makeHandle(3)]
        capture.reconcile(represented: Set(handles), visible: handles.map(request))
        await driver.waitForStarts(3)
        driver.completeAllStarts()
        let frame = try makeOverviewPreviewFrame()
        for stream in driver.streams { await publish(frame, through: stream, into: capture) }
        handles[0].id = WindowToken(pid: 456, windowId: 99)
        capture.reconcile(represented: [handles[0], handles[2]], visible: [])
        capture.remove(handle: handles[2])
        await driver.waitForStops(3)
        let evicted = lines(trace, event: "previewEvicted")
        XCTAssertEqual(evicted.count, 3)
        for (windowId, reason) in [(1, "tokenChanged"), (2, "unrepresented"), (3, "removed")] {
            XCTAssertEqual(evicted.filter { $0.contains("pid=123 wid=\(windowId) reason=\(reason)") }.count, 1)
        }
        XCTAssertFalse(evicted.contains { $0.contains("pid=456") })
    }

    func testCacheReleaseReasonsAndActiveSourceProtection() async throws {
        let trace = OverviewFrameTrace.Recorder()
        trace.beginCapture()
        defer { trace.endCapture() }
        for reason: OverviewThumbnailCapture.CacheReleaseReason in [.memoryPressure, .shutdown, .explicitRelease] {
            let driver = OverviewPreviewTestDriver()
            let capture = driver.makeCapture(traceRecorder: trace)
            let handles = [makeHandle(1), makeHandle(2)]
            capture.reconcile(represented: Set(handles), visible: handles.map(request))
            await driver.waitForStarts(2)
            driver.completeAllStarts()
            let frame = try makeOverviewPreviewFrame()
            for stream in driver.streams { await publish(frame, through: stream, into: capture) }
            let before = lines(trace, event: "previewEvicted").count
            capture.releaseCache(reason: reason)
            XCTAssertEqual(lines(trace, event: "previewEvicted").count, before)
            XCTAssertTrue(capture.preview(for: handles[0]) === frame)
            capture.clear()
            await driver.waitForStops(2)
            capture.onPreview = { _, preview in
                XCTAssertNil(preview)
                XCTAssertTrue(handles.allSatisfy { capture.preview(for: $0) == nil })
            }
            capture.releaseCache(reason: reason)
            capture.onPreview = { _, _ in }
            let evicted = Array(lines(trace, event: "previewEvicted").dropFirst(before))
            XCTAssertEqual(evicted.count, 2)
            XCTAssertTrue(evicted.allSatisfy { $0.contains("reason=\(reason.traceReason.rawValue)") })
            XCTAssertTrue(evicted.allSatisfy { $0.contains("bytes=\(frame.surface.allocationSize) cached=0") })
        }
    }

    func testInactiveDiagnosticsDoNotRecordPreviewOrEvictionWork() async throws {
        let trace = OverviewFrameTrace.Recorder()
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(traceRecorder: trace)
        let handle = makeHandle(1)
        capture.reconcile(represented: [handle], visible: [request(handle)])
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        let frame = try makeOverviewPreviewFrame()
        await publish(frame, through: driver.streams[0], into: capture)
        XCTAssertTrue(capture.preview(for: handle) === frame)
        capture.clear()
        await driver.waitForStops(1)
        capture.releaseCache()
        XCTAssertFalse(trace.dump().contains("event="))
        XCTAssertNil(capture.preview(for: handle))
    }

    private func makeHandle(_ windowId: Int) -> WindowHandle {
        WindowHandle(id: WindowToken(pid: 123, windowId: windowId))
    }

    private func request(_ handle: WindowHandle) -> OverviewPreviewRequest {
        OverviewPreviewRequest(handle: handle, pixelWidth: 80, pixelHeight: 60)
    }

    private func lines(_ trace: OverviewFrameTrace.Recorder, event: String) -> [String] {
        trace.dump().split(separator: "\n").map(String.init).filter { $0.hasPrefix("event=\(event) ") }
    }

    private func publish(
        _ frame: OverviewPreviewFrame,
        through stream: OverviewPreviewTestStream,
        into capture: OverviewThumbnailCapture
    ) async {
        let published = expectation(description: "preview published")
        capture.onPreview = { handle, preview in
            if handle === stream.request.handle, preview === frame { published.fulfill() }
        }
        stream.output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
    }
}
