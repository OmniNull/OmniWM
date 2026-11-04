// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriFractionalPicturePlacementTests: XCTestCase {
    private let scale: CGFloat = 2
    private let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let origin = CGPoint(x: 21, y: 1300)
    private let wholeSize = CGSize(width: 2518, height: 663)

    private final class PicturePanel: NiriEdgePictureWindow {
        var frameWrites: [CGRect] = []
        var moves: [CGRect] = []

        override func orderIn() {}

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            frameWrites.append(frameRect)
            super.setFrame(frameRect, display: flag)
        }

        override func moveInWindowServer(to target: CGRect) -> Bool {
            moves.append(target)
            return true
        }
    }

    private final class BorderPanel: BorderLayerPanel {
        var frameWrites: [CGRect] = []
        var moves: [CGRect] = []

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            frameWrites.append(frameRect)
            super.setFrame(frameRect, display: flag)
        }

        override func moveInWindowServer(to target: CGRect) -> Bool {
            moves.append(target)
            return true
        }
    }

    func testFractionalPictureMovesWithoutFrameWritesAndLandsAtTheSamePlacement() throws {
        let panel = PicturePanel()
        defer { panel.destroy() }
        let image = try image()
        let initial = fractionalFrame
        panel.update(geometry: try geometry(initial), image: image, isMoving: true, activate: {})
        let laidOut = panel.frame
        let writes = panel.frameWrites
        let layer = try XCTUnwrap(panel.contentView?.layer?.sublayers?.first)
        let layerFrame = layer.frame
        let bounds = panel.contentView?.frame
        XCTAssertEqual(panel.contentView?.subviews.first?.frame.size, initial.size)
        let moved = initial.offsetBy(dx: pixel, dy: pixel)
        panel.update(geometry: try geometry(moved), image: image, isMoving: true, activate: {})
        XCTAssertEqual(
            panel.moves,
            [CGRect(origin: CGPoint(x: origin.x + pixel * scale, y: origin.y + pixel * scale), size: wholeSize)]
        )
        XCTAssertEqual(panel.frameWrites, writes)
        XCTAssertEqual(panel.frame, laidOut)
        XCTAssertEqual(layer.frame, layerFrame)
        XCTAssertEqual(panel.contentView?.frame, bounds)
        let placement = try XCTUnwrap(panel.moves.last)
        panel.update(geometry: try geometry(moved), image: image, isMoving: false, activate: {})
        XCTAssertEqual(panel.frame, placement)
        XCTAssertEqual(layer.frame, layerFrame)
        XCTAssertEqual(panel.convertToScreen(.zero).origin, placement.origin)
    }

    func testChangedLogicalSizeReconfiguresEvenWhenRoundedBackingSizeIsUnchanged() throws {
        let panel = PicturePanel()
        defer { panel.destroy() }
        let image = try image()
        panel.update(geometry: try geometry(fractionalFrame), image: image, isMoving: true, activate: {})
        let backing = panel.frame.size
        var resized = fractionalFrame
        resized.size.height += pixel
        panel.update(geometry: try geometry(resized), image: image, isMoving: true, activate: {})
        XCTAssertTrue(panel.moves.isEmpty)
        XCTAssertEqual(panel.frame.size, backing)
        XCTAssertEqual(panel.contentView?.layer?.sublayers?.first?.frame.size, resized.size)
    }

    func testFractionalBorderMovesWithoutFrameWritesAndKeepsGeometryAtLanding() throws {
        let initial = fractionalFrame
        let panel = try XCTUnwrap(BorderPanel(frame: initial))
        defer { panel.close() }
        let inset = pixel * 2
        var presentation = BorderPresentation(windowId: 1, displayFrame: display, scale: scale, isMoving: true)
        panel.applyFrame(
            targetFrame: initial.insetBy(dx: inset, dy: inset), surfaceFrame: initial, presentation: presentation
        )
        let writes = panel.frameWrites
        let layerFrame = panel.borderLayer.frame
        let moved = initial.offsetBy(dx: pixel, dy: pixel)
        panel.applyFrame(
            targetFrame: moved.insetBy(dx: inset, dy: inset), surfaceFrame: moved, presentation: presentation
        )
        XCTAssertEqual(
            panel.moves,
            [CGRect(origin: CGPoint(x: origin.x + pixel * scale, y: origin.y + pixel * scale), size: wholeSize)]
        )
        XCTAssertEqual(panel.frameWrites, writes)
        XCTAssertEqual(panel.borderLayer.frame, layerFrame)
        let placement = try XCTUnwrap(panel.moves.last)
        presentation.isMoving = false
        panel.applyFrame(
            targetFrame: moved.insetBy(dx: inset, dy: inset), surfaceFrame: moved, presentation: presentation
        )
        XCTAssertEqual(panel.frame, placement)
        XCTAssertEqual(panel.borderLayer.frame, layerFrame)
    }

    func testBackingDimensionsDoNotDependOnFractionalOrigin() {
        let initial = fractionalFrame
        let initialBacking = SurfacePanelGeometry.backingFrame(for: initial)
        let moved = initial.offsetBy(dx: pixel, dy: pixel)
        let movedBacking = SurfacePanelGeometry.backingFrame(for: moved)
        XCTAssertEqual(initialBacking, CGRect(origin: origin, size: wholeSize))
        XCTAssertEqual(movedBacking.size, wholeSize)
        let whole = CGRect(origin: initial.origin, size: wholeSize)
        XCTAssertEqual(SurfacePanelGeometry.backingFrame(for: whole).size, wholeSize)
        XCTAssertNotEqual(whole.integral.size, whole.offsetBy(dx: pixel, dy: pixel).integral.size)
    }

    private var pixel: CGFloat {
        1 / scale
    }

    private var fractionalFrame: CGRect {
        CGRect(
            x: origin.x + pixel, y: origin.y + pixel,
            width: wholeSize.width - pixel, height: wholeSize.height - pixel
        )
    }

    private func geometry(_ frame: CGRect) throws -> NiriEdgePictureGeometry {
        try XCTUnwrap(NiriEdgePictureGeometry(frame: frame, displayFrame: display))
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }
}
