// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSwipePreviewTests: XCTestCase {
    func testMissingPreviewDoesNotShowPanelWhenLateFrameArrives() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            previewCapture: capture,
            backdrop: try makeBackdrop(),
            hasCaptureAccess: { true }
        )
        let item = item()
        preview.prepare(source: [item], destination: [], monitor: monitor)
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        XCTAssertFalse(preview.begin(source: [item], destination: [], monitor: monitor))
        let frame = try makeOverviewPreviewFrame()
        await publish(frame, through: driver.streams[0], into: capture)
        XCTAssertFalse(preview.isVisible)
        XCTAssertTrue(capture.preview(for: item.handle) === frame)
        preview.stop()
        await driver.waitForStops(1)
    }

    func testStopRetainsCacheAndRetiresCaptureUntilNextPreparation() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            previewCapture: capture,
            backdrop: try makeBackdrop(),
            hasCaptureAccess: { true }
        )
        let item = item()
        preview.prepare(source: [item], destination: [], monitor: monitor)
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        let frame = try makeOverviewPreviewFrame()
        await publish(frame, through: driver.streams[0], into: capture)
        preview.stop()
        await driver.waitForStops(1)
        XCTAssertTrue(capture.preview(for: item.handle) === frame)
        driver.streams[0].output.offer(try makeOverviewPreviewFrame())
        XCTAssertNil(driver.streams[0].output.take())
        XCTAssertEqual(driver.streams.count, 1)

        preview.prepare(source: [item], destination: [], monitor: monitor)
        await driver.waitForStarts(2)
        XCTAssertTrue(capture.preview(for: item.handle) === frame)
        driver.completeAllStarts()
        preview.stop()
        await driver.waitForStops(2)
    }

    func testRekeyedParticipantCannotUseOldPreview() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            previewCapture: capture,
            backdrop: try makeBackdrop(),
            hasCaptureAccess: { true }
        )
        let item = item()
        preview.prepare(source: [item], destination: [], monitor: monitor)
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        await publish(try makeOverviewPreviewFrame(), through: driver.streams[0], into: capture)
        preview.stop()
        await driver.waitForStops(1)

        item.handle.id = WindowToken(pid: 123, windowId: 457)
        preview.prepare(source: [item], destination: [], monitor: monitor)
        await driver.waitForStarts(2)
        XCTAssertNil(capture.preview(for: item.handle))
        XCTAssertFalse(preview.begin(source: [item], destination: [], monitor: monitor))
        driver.completeAllStarts()
        preview.stop()
        await driver.waitForStops(2)
    }

    func testCapturePermissionDenialKeepsOverlayHidden() {
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            hasCaptureAccess: { false }
        )
        XCTAssertFalse(preview.begin(source: [], destination: [], monitor: monitor))
        XCTAssertFalse(preview.isVisible)
    }

    func testIdleStopsReuseWallpaperButVisiblePreviewStopRefreshesIt() throws {
        let image = try makeWallpaperImage()
        var captures = 0
        let cache = OverviewWallpaperCache()
        cache.desktopImageURL = { _ in nil }
        cache.captureWallpaper = { _ in
            captures += 1
            return image
        }
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            backdrop: WorkspaceSwipeBackdrop(wallpaperCache: cache),
            hasCaptureAccess: { true }
        )
        defer { preview.stop() }
        preview.prepare(source: [], destination: [], monitor: monitor)
        preview.stop()
        preview.prepare(source: [], destination: [], monitor: monitor)
        XCTAssertEqual(captures, 1, "Ordinary trackpad touch cleanup must not trigger another wallpaper capture")

        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))
        preview.stop()
        preview.prepare(source: [], destination: [], monitor: monitor)
        XCTAssertEqual(captures, 2, "A new visible swipe must refresh the wallpaper")
    }

    func testFailedWallpaperCaptureRecoversOnNextSwipeWithoutRecapturingIdleTouches() throws {
        let image = try makeWallpaperImage()
        var wallpaper: CGImage?
        var captures = 0
        let cache = OverviewWallpaperCache()
        cache.desktopImageURL = { _ in nil }
        cache.captureWallpaper = { _ in
            captures += 1
            return wallpaper
        }
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            backdrop: WorkspaceSwipeBackdrop(wallpaperCache: cache),
            hasCaptureAccess: { true }
        )
        defer { preview.stop() }

        preview.warm(source: [], destination: [], monitor: monitor)
        preview.stop()
        preview.warm(source: [], destination: [], monitor: monitor)
        XCTAssertEqual(captures, 1)
        XCTAssertFalse(preview.begin(source: [], destination: [], monitor: monitor))
        XCTAssertFalse(preview.isVisible)
        preview.stop()

        wallpaper = image
        preview.warm(source: [], destination: [], monitor: monitor)
        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))
        XCTAssertTrue(preview.isVisible)
        XCTAssertEqual(captures, 2)
    }

    private func makeBackdrop() throws -> WorkspaceSwipeBackdrop {
        let cache = OverviewWallpaperCache()
        cache.desktopImageURL = { _ in nil }
        let image = try makeWallpaperImage()
        cache.captureWallpaper = { _ in image }
        return WorkspaceSwipeBackdrop(wallpaperCache: cache)
    }

    private func makeWallpaperImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 4800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private var monitor: Monitor {
        Monitor(
            id: .init(displayId: 999), displayId: 999,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 30, width: 1200, height: 750),
            hasNotch: false, name: "Preview test"
        )
    }

    private func item() -> WorkspaceSwipePreview.Item {
        .init(
            handle: WindowHandle(id: WindowToken(pid: 123, windowId: 456)),
            frame: CGRect(x: 50, y: 50, width: 400, height: 300)
        )
    }

    private func publish(
        _ frame: OverviewPreviewFrame,
        through stream: OverviewPreviewTestStream,
        into capture: OverviewThumbnailCapture
    ) async {
        let published = expectation(description: "swipe preview published")
        capture.onPreview = { _, preview in if preview === frame { published.fulfill() } }
        stream.output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
    }
}
