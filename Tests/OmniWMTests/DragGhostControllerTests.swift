// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class DragGhostControllerTests: XCTestCase {
    private final class CaptureLog {
        var pixelSizes: [CGSize] = []
        var images: [CGImage] = []
    }

    private let originalFrame = CGRect(x: 0, y: 0, width: 200, height: 150)
    private let start = CGPoint(x: 400, y: 300)

    func testSharedPreviewShowsImmediatelyThenAFreshCaptureReplacesIt() async throws {
        let driver = OverviewPreviewTestDriver()
        let window = WindowHandle(id: WindowToken(pid: 77, windowId: 1))
        let frame = try await publishSharedFrame(width: 400, height: 300, for: window, driver: driver)
        let surfaces = SurfaceCoordinator(scene: SurfaceScene())
        let log = CaptureLog()
        let ghost = makeGhost(surfaces: surfaces, previews: driver.coordinator, log: log)

        ghost.beginDrag(token: window.token, originalFrame: originalFrame, cursorLocation: start)
        XCTAssertEqual(surfaces.visibleSurfaceIDs(kind: .dragGhost).count, 1)
        XCTAssertTrue(contents(of: ghost) === frame.surface)
        await ghost.captureTask?.value

        let scale = NSScreen.screen(containing: start)?.backingScaleFactor ?? 2
        XCTAssertEqual(log.pixelSizes, [CGSize(width: (100 * scale).rounded(), height: (75 * scale).rounded())])
        XCTAssertEqual(log.images.count, 1)
        XCTAssertTrue(contents(of: ghost) === log.images.first)
        ghost.destroy()
    }

    func testCapturedGhostAppearsAtTheLatestCursorLocation() async throws {
        let surfaces = SurfaceCoordinator(scene: SurfaceScene())
        let log = CaptureLog()
        let ghost = makeGhost(
            surfaces: surfaces,
            previews: PreviewCaptureCoordinator(ownedWindowRegistry: OwnedWindowRegistry()),
            log: log
        )
        let later = CGPoint(x: 600, y: 500)

        ghost.beginDrag(token: WindowToken(pid: 77, windowId: 3), originalFrame: originalFrame, cursorLocation: start)
        XCTAssertTrue(surfaces.visibleSurfaceIDs(kind: .dragGhost).isEmpty)
        ghost.updatePosition(cursorLocation: later)
        await ghost.captureTask?.value

        let window = try XCTUnwrap(ghost.ghostWindow)
        XCTAssertEqual(log.pixelSizes.count, 1)
        XCTAssertEqual(window.frame.origin, CGPoint(x: later.x + 10, y: later.y - window.frame.height - 10))
        ghost.destroy()
    }

    private func makeGhost(
        surfaces: SurfaceCoordinator,
        previews: PreviewCaptureCoordinator,
        log: CaptureLog
    ) -> DragGhostController {
        DragGhostController(
            surfaceCoordinator: surfaces,
            previews: previews,
            captureAccessAllowed: { true },
            captureImage: { _, pixelSize in
                log.pixelSizes.append(pixelSize)
                let image = Self.makeImage()
                if let image { log.images.append(image) }
                return image
            }
        )
    }

    private func contents(of ghost: DragGhostController) -> AnyObject? {
        ghost.ghostWindow?.contentView?.layer?.contents as AnyObject?
    }

    private func publishSharedFrame(
        width: Int,
        height: Int,
        for window: WindowHandle,
        driver: OverviewPreviewTestDriver
    ) async throws -> OverviewPreviewFrame {
        let capture = driver.makeCapture()
        capture.reconcile(
            represented: [window],
            visible: [OverviewPreviewRequest(handle: window, pixelWidth: width, pixelHeight: height)]
        )
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        let frame = try makeOverviewPreviewFrame(width: width, height: height)
        let published = expectation(description: "shared frame published")
        capture.onPreview = { _, preview in if preview === frame { published.fulfill() } }
        driver.streams[0].output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
        capture.clear()
        await driver.waitForStops(1)
        addTeardownBlock { withExtendedLifetime(capture) {} }
        return frame
    }

    private static func makeImage() -> CGImage? {
        CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
}
