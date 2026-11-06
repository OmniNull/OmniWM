// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriPictureContentTests: XCTestCase {
    private final class Panel: NiriEdgePictureWindow {
        override func orderIn() {}
    }

    func testPanelUsesSurfaceAndCropDirectlyAndStillResetsCrop() throws {
        let panel = Panel()
        defer { panel.destroy() }
        let size = CGSize(width: 80, height: 60)
        let crop = CGRect(origin: CGPoint(x: size.width / 4, y: size.height / 4), size: CGSize(
            width: size.width / 2, height: size.height / 2
        ))
        let preview = try makeOverviewPreviewFrame(width: Int(size.width), height: Int(size.height), contentRect: crop)
        let frame = CGRect(origin: .zero, size: size)
        let geometry = try XCTUnwrap(NiriEdgePictureGeometry(frame: frame, displayFrame: frame))
        panel.update(geometry: geometry, content: .preview(preview), activate: {})
        let layer = try XCTUnwrap(panel.contentView?.layer?.sublayers?.first)
        XCTAssertTrue(layer.contents as AnyObject? === preview.surface)
        XCTAssertEqual(layer.contentsRect, CGRect(
            x: crop.minX / size.width, y: crop.minY / size.height,
            width: crop.width / size.width, height: crop.height / size.height
        ))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        panel.setContent(.image(image))
        XCTAssertTrue(layer.contents as AnyObject? === image)
        XCTAssertEqual(layer.contentsRect, CGRect(origin: .zero, size: CGSize(width: 1, height: 1)))
    }

    func testPanelForwardsOnlyItsOcclusionNotificationsAndClearsObserverOnReuse() {
        let panel = Panel()
        let other = Panel()
        defer { panel.destroy()
            other.destroy()
        }
        var changes = 0
        panel.observeVisibility { changes += 1 }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: other)
        XCTAssertEqual(changes, 0)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        XCTAssertEqual(changes, 1)
        panel.hide()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        XCTAssertEqual(changes, 1)
    }
}
