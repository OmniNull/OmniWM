// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSwipeSourceSnapshotTests: XCTestCase {
    func testSourceSnapshotReadyBeforeBeginCoversSourceWorkspace() async throws {
        let image = try makeImage()
        let gate = SnapshotGate()
        let preview = try makeSnapshotPreview(gate)
        defer { preview.stop() }

        preview.captureSource(monitor: monitor)
        await gate.deliver(image)
        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))
        XCTAssertTrue(preview.presentedSourceSnapshot as AnyObject? === image)
        XCTAssertEqual(gate.frames, [monitor.visibleFrame])
    }

    func testLateSourceSnapshotReplacesSourceWorkspaceDuringSwipe() async throws {
        let image = try makeImage()
        let gate = SnapshotGate()
        let preview = try makeSnapshotPreview(gate)
        defer { preview.stop() }

        preview.captureSource(monitor: monitor)
        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))
        XCTAssertNil(preview.presentedSourceSnapshot)
        await gate.deliver(image)
        XCTAssertTrue(preview.presentedSourceSnapshot as AnyObject? === image)
    }

    func testSourceSnapshotArrivingAfterStopOrFreezeIsDropped() async throws {
        let image = try makeImage()
        let gate = SnapshotGate()
        let preview = try makeSnapshotPreview(gate)
        defer { preview.stop() }

        preview.captureSource(monitor: monitor)
        preview.stop()
        await gate.deliver(image)
        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))
        XCTAssertNil(preview.presentedSourceSnapshot)
        preview.stop()

        preview.captureSource(monitor: monitor)
        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))
        preview.freezeSource()
        await gate.deliver(image)
        XCTAssertNil(preview.presentedSourceSnapshot)
    }

    func testSourceSnapshotNeedsCaptureAccess() async {
        let gate = SnapshotGate()
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            hasCaptureAccess: { false },
            captureDisplay: { _, frame in await gate.capture(frame) }
        )
        preview.captureSource(monitor: monitor)
        await gate.deliver(nil)
        XCTAssertTrue(gate.frames.isEmpty)
    }

    private func makeSnapshotPreview(_ gate: SnapshotGate) throws -> WorkspaceSwipePreview {
        try WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            backdrop: makeBackdrop(),
            hasCaptureAccess: { true },
            captureDisplay: { _, frame in await gate.capture(frame) }
        )
    }

    private func makeBackdrop() throws -> WorkspaceSwipeBackdrop {
        let cache = OverviewWallpaperCache()
        cache.desktopImageURL = { _ in nil }
        let image = try makeImage()
        cache.captureWallpaper = { _ in image }
        return WorkspaceSwipeBackdrop(wallpaperCache: cache)
    }

    private func makeImage() throws -> CGImage {
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

    @MainActor
    private final class SnapshotGate {
        var frames: [CGRect] = []
        private var pending: CheckedContinuation<CGImage?, Never>?

        func capture(_ frame: CGRect) async -> CGImage? {
            frames.append(frame)
            return await withCheckedContinuation { pending = $0 }
        }

        func deliver(_ image: CGImage?) async {
            for _ in 0 ..< 50 where pending == nil {
                await Task.yield()
            }
            pending?.resume(returning: image)
            pending = nil
            for _ in 0 ..< 50 {
                await Task.yield()
            }
        }
    }
}
