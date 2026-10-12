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
