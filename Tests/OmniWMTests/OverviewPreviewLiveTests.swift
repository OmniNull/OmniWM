// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import IOSurface
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import Synchronization
import XCTest

@MainActor
final class OverviewPreviewLiveTests: XCTestCase {
    private final class Quadrants: NSView {
        var swapped = false
        override var isFlipped: Bool {
            true
        }

        override func draw(_: NSRect) {
            let colors: [NSColor] = swapped ? [.blue, .yellow, .red, .green] : [.red, .green, .blue, .yellow]
            for (index, color) in colors.enumerated() {
                color.setFill()
                NSRect(
                    x: CGFloat(index % 2) * bounds.width / 2,
                    y: CGFloat(index / 2) * bounds.height / 2,
                    width: bounds.width / 2,
                    height: bounds.height / 2
                ).fill()
            }
        }
    }

    func testNativeStreamCropsNonSquareWindowAndPreservesRetainedFrame() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_OVERVIEW_PREVIEW_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live preview checks require OMNIWM_RUN_OVERVIEW_PREVIEW_LIVE_TESTS=1")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = NSPanel(
            contentRect: CGRect(x: screen.frame.midX - 160, y: screen.frame.midY - 80, width: 320, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let quadrants = Quadrants(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        panel.contentView = quadrants
        panel.orderBack(nil)
        panel.displayIfNeeded()
        CATransaction.flush()
        defer { panel.close() }

        let content = try await SCShareableContent.currentProcess
        let window = try XCTUnwrap(content.windows.first { Int($0.windowID) == panel.windowNumber })
        let firstReady = expectation(description: "first complete native preview")
        let signal = Mutex(firstReady)
        let output = OverviewPreviewStream(onReady: {
            signal.withLock { $0.fulfill() }
        }, onFailure: {})
        let handle = WindowHandle(id: WindowToken(pid: getpid(), windowId: panel.windowNumber))
        let control = try OverviewNativePreviewStream(
            window: window,
            request: OverviewPreviewRequest(handle: handle, pixelWidth: 200, pixelHeight: 200),
            output: output
        )
        defer {
            output.invalidate()
            control.stop()
        }
        try await control.start()
        await fulfillment(of: [firstReady], timeout: 5)
        let first = try XCTUnwrap(output.take())
        XCTAssertEqual(first.contentsRect.width, 1, accuracy: 0.01)
        XCTAssertEqual(first.contentsRect.height, 0.5, accuracy: 0.01)
        XCTAssertEqual(try dominantColor(first, x: 0.25, y: 0.25), .red)
        XCTAssertEqual(try dominantColor(first, x: 0.75, y: 0.25), .green)
        XCTAssertEqual(try dominantColor(first, x: 0.25, y: 0.75), .blue)
        XCTAssertEqual(try dominantColor(first, x: 0.75, y: 0.75), .yellow)

        for update in 1 ... 5 {
            let nextReady = expectation(description: "updated native preview \(update)")
            signal.withLock { $0 = nextReady }
            // Keep the first landscape frame alive while the producer draws
            // portrait frames into its pool. Its pixels and crop must not change.
            panel.setContentSize(CGSize(width: 160, height: 320))
            quadrants.swapped.toggle()
            quadrants.needsDisplay = true
            panel.displayIfNeeded()
            CATransaction.flush()
            await fulfillment(of: [nextReady], timeout: 5)
            let latest = try XCTUnwrap(output.take())
            XCTAssertEqual(try dominantColor(latest, x: 0.25, y: 0.25), quadrants.swapped ? .blue : .red)
            XCTAssertEqual(try dominantColor(first, x: 0.25, y: 0.25), .red)
            XCTAssertEqual(try dominantColor(first, x: 0.75, y: 0.25), .green)
            XCTAssertEqual(try dominantColor(first, x: 0.25, y: 0.75), .blue)
            XCTAssertEqual(try dominantColor(first, x: 0.75, y: 0.75), .yellow)
        }
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testRetainedDiscoveryServesReopensWithoutAnotherLookup() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_OVERVIEW_PREVIEW_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live preview checks require OMNIWM_RUN_OVERVIEW_PREVIEW_LIVE_TESTS=1")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = NSPanel(
            contentRect: CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 100, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .systemRed
        panel.orderBack(nil)
        panel.displayIfNeeded()
        CATransaction.flush()
        defer { panel.close() }

        let trace = OverviewFrameTrace.shared
        trace.beginCapture()
        defer {
            trace.endCapture()
            trace.releaseStorage()
        }
        let capture = OverviewThumbnailCapture(
            coordinator: PreviewCaptureCoordinator(
                ownedWindowRegistry: OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
            )
        )
        let handle = WindowHandle(id: WindowToken(pid: getpid(), windowId: panel.windowNumber))
        let request = OverviewPreviewRequest(handle: handle, pixelWidth: 200, pixelHeight: 200)

        for round in 1 ... 2 {
            let frame = expectation(description: "frame after open \(round)")
            frame.assertForOverFulfill = false
            capture.onPreview = { _, preview in if preview != nil { frame.fulfill() } }
            capture.reconcile(represented: [handle], visible: [request])
            await fulfillment(of: [frame], timeout: 5)
            capture.clear()
            let discoveries = trace.dump().split(separator: "\n").filter { $0.hasPrefix("event=previewDiscovery ") }
            XCTAssertEqual(discoveries.count, 1, "Reopening must reuse the retained window table")
        }
    }

    func testReopenedPreviewAfterWindowDoublesInWidth() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_OVERVIEW_PREVIEW_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live preview checks require OMNIWM_RUN_OVERVIEW_PREVIEW_LIVE_TESTS=1")
        }
        // currentProcess exposes only this test's windows and needs no TCC grant.
        _ = NSApplication.shared
        let panel = NSPanel(
            contentRect: CGRect(x: 100, y: 100, width: 320, height: 320),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let quadrants = Quadrants(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        panel.contentView = quadrants
        panel.orderBack(nil)
        panel.displayIfNeeded()
        CATransaction.flush()
        defer { panel.close() }

        let content = try await SCShareableContent.currentProcess
        let originalWindow = try XCTUnwrap(content.windows.first { Int($0.windowID) == panel.windowNumber })
        let handle = WindowHandle(id: WindowToken(pid: getpid(), windowId: panel.windowNumber))
        let request = OverviewPreviewRequest(handle: handle, pixelWidth: 200, pixelHeight: 200)

        func captureFirstFrame(_ window: SCWindow) async throws -> OverviewPreviewFrame {
            let ready = expectation(description: "first complete frame after opening capture")
            ready.assertForOverFulfill = false
            let output = OverviewPreviewStream(onReady: { ready.fulfill() }, onFailure: {})
            let stream = try OverviewNativePreviewStream(window: window, request: request, output: output)
            defer {
                output.invalidate()
                stream.stop()
            }
            try await stream.start()
            await fulfillment(of: [ready], timeout: 5)
            return try XCTUnwrap(output.take())
        }

        let original = try await captureFirstFrame(originalWindow)
        XCTAssertEqual(original.contentsRect.height, 1, accuracy: 0.01)
        panel.setContentSize(CGSize(width: 640, height: 320))
        quadrants.needsDisplay = true
        panel.displayIfNeeded()
        CATransaction.flush()

        let reused = try await captureFirstFrame(originalWindow)
        let refreshed = try await SCShareableContent.currentProcess
        let freshWindow = try XCTUnwrap(refreshed.windows.first { Int($0.windowID) == panel.windowNumber })
        let fresh = try await captureFirstFrame(freshWindow)
        for frame in [reused, fresh] {
            XCTAssertEqual(frame.contentsRect.width, 1, accuracy: 0.01)
            XCTAssertEqual(frame.contentsRect.height, 0.5, accuracy: 0.01)
            XCTAssertEqual(try dominantColor(frame, x: 0.25, y: 0.25), .red)
            XCTAssertEqual(try dominantColor(frame, x: 0.75, y: 0.25), .green)
            XCTAssertEqual(try dominantColor(frame, x: 0.25, y: 0.75), .blue)
            XCTAssertEqual(try dominantColor(frame, x: 0.75, y: 0.75), .yellow)
        }
        panel.setContentSize(CGSize(width: 320, height: 320))
        quadrants.needsDisplay = true
        panel.displayIfNeeded()
        CATransaction.flush()
        let narrowed = try await captureFirstFrame(originalWindow)
        XCTAssertEqual(narrowed.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 1))

        // Exercise the real layer-backed card as well as the capture metadata.
        let item = WindowSwitcherItem(
            handle: handle, title: "Resize", appName: "Test", icon: nil,
            workspaceName: "1", isMinimized: false
        )
        let tile = WindowSwitcherTile(
            item: item, size: CGSize(width: 220, height: 207), selected: false,
            content: .init(items: [item], selected: nil, scope: .activeWorkspace, hasCaptureAccess: true)
        )
        let tilePanel = NSPanel(
            contentRect: CGRect(origin: CGPoint(x: 800, y: 100), size: tile.bounds.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        tilePanel.isReleasedWhenClosed = false
        tilePanel.ignoresMouseEvents = true
        tilePanel.contentView = tile
        tilePanel.orderBack(nil)
        defer { tilePanel.close() }
        for frame in [original, reused, fresh, narrowed] {
            tile.updatePreview(frame)
            tilePanel.displayIfNeeded()
            CATransaction.flush()
            let tileContent = try await SCShareableContent.currentProcess
            let tileWindow = try XCTUnwrap(tileContent.windows.first { Int($0.windowID) == tilePanel.windowNumber })
            let rendered = try await captureFirstFrame(tileWindow)
            XCTAssertEqual(try dominantColor(rendered, x: 0.25, y: 0.25), .red)
            XCTAssertEqual(try dominantColor(rendered, x: 0.75, y: 0.25), .green)
            XCTAssertEqual(try dominantColor(rendered, x: 0.25, y: 0.75), .blue)
            XCTAssertEqual(try dominantColor(rendered, x: 0.75, y: 0.75), .yellow)
        }
    }

    private enum SampleColor {
        case red, green, blue, yellow, unknown
    }

    private func dominantColor(_ frame: OverviewPreviewFrame, x: CGFloat, y: CGFloat) throws -> SampleColor {
        let surface = frame.surface
        XCTAssertEqual(surface.lock(options: .readOnly, seed: nil), 0)
        defer { _ = surface.unlock(options: .readOnly, seed: nil) }
        let rect = frame.contentsRect
        let column = Int((rect.minX + rect.width * x) * CGFloat(surface.width))
        let row = Int((rect.minY + rect.height * y) * CGFloat(surface.height))
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let offset = row * surface.bytesPerRow + column * 4
        let blue = bytes[offset]
        let green = bytes[offset + 1]
        let red = bytes[offset + 2]
        if red > 180, green < 80, blue < 80 { return .red }
        if green > 180, red < 80, blue < 80 { return .green }
        if blue > 180, red < 80, green < 80 { return .blue }
        if red > 180, green > 180, blue < 80 { return .yellow }
        return .unknown
    }
}
