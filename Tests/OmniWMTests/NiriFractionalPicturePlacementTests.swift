// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriFractionalPicturePlacementTests: XCTestCase {
    private let scale: CGFloat = 2
    private let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let origin = CGPoint(x: 21, y: 100)
    private let wholeSize = CGSize(width: 2518, height: 663)

    private final class PicturePanel: NiriEdgePictureWindow {
        var frameWrites: [CGRect] = []
        var moves: [CGRect] = []
        var movesSucceed = true
        var appKitMoveEvents = 0

        @objc(_windowMoved:) func recordAppKitMoveEvent(_: NSEvent) {
            appKitMoveEvents += 1
        }

        override func orderIn() {}

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            frameWrites.append(frameRect)
            super.setFrame(frameRect, display: flag)
        }

        override func moveInWindowServer(to target: CGRect) -> Bool {
            guard movesSucceed else { return false }
            moves.append(target)
            return true
        }
    }

    private final class OrderingPanel: NiriEdgePictureWindow {
        var appKitOrders = 0
        var windowServerOrders: [UInt32?] = []

        override func orderFrontRegardless() {
            appKitOrders += 1
            super.orderFrontRegardless()
        }

        override func orderInWindowServer(below target: UInt32?) {
            windowServerOrders.append(target)
        }

        override func moveInWindowServer(to _: CGRect) -> Bool {
            true
        }
    }

    private final class BorderPanel: BorderLayerPanel {
        var frameWrites: [CGRect] = []
        var moves: [CGRect] = []
        var reshapes: [CGRect] = []
        var movesSucceed = true

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            frameWrites.append(frameRect)
            super.setFrame(frameRect, display: flag)
        }

        override func moveInWindowServer(to target: CGRect) -> Bool {
            guard movesSucceed else { return false }
            moves.append(target)
            return true
        }

        override func reshapeInWindowServer(to target: CGRect) -> Bool {
            guard movesSucceed else { return false }
            reshapes.append(target)
            return true
        }
    }

    func testFractionalPictureMovesAndRestsWithoutFrameWrites() throws {
        let panel = PicturePanel()
        defer { panel.destroy() }
        let image = try image()
        let initial = fractionalFrame
        panel.update(geometry: try geometry(initial), content: .image(image), activate: {})
        let laidOut = panel.frame
        let writes = panel.frameWrites
        let layer = try XCTUnwrap(panel.contentView?.layer?.sublayers?.first)
        let layerFrame = layer.frame
        let bounds = panel.contentView?.frame
        XCTAssertEqual(panel.contentView?.subviews.first?.frame.size, initial.size)
        let moved = initial.offsetBy(dx: pixel, dy: pixel)
        panel.update(geometry: try geometry(moved), content: .image(image), activate: {})
        XCTAssertEqual(
            panel.moves,
            [CGRect(origin: CGPoint(x: origin.x + pixel * scale, y: origin.y + pixel * scale), size: wholeSize)]
        )
        XCTAssertEqual(panel.frameWrites, writes)
        XCTAssertEqual(panel.frame, laidOut)
        XCTAssertEqual(layer.frame, layerFrame)
        XCTAssertEqual(panel.contentView?.frame, bounds)
        let placement = try XCTUnwrap(panel.moves.last)
        panel.update(geometry: try geometry(moved), content: .image(image), activate: {})
        XCTAssertEqual(panel.moves, [placement])
        XCTAssertEqual(panel.frameWrites, writes)
        XCTAssertEqual(layer.frame, layerFrame)
        XCTAssertEqual(panel.convertToScreen(.zero).origin, placement.origin)
    }

    func testPictureLandingOffItsDisplayGoesThroughAppKit() throws {
        let panel = PicturePanel()
        defer { panel.destroy() }
        let image = try image()
        panel.update(geometry: try geometry(fractionalFrame), content: .image(image), activate: {})
        let writes = panel.frameWrites
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let away = fractionalFrame.offsetBy(dx: desktop.maxX + wholeSize.width, dy: 0)

        panel.update(
            geometry: try XCTUnwrap(NiriEdgePictureGeometry(frame: away, displayFrame: away)),
            content: .image(image),
            activate: {}
        )

        XCTAssertEqual(panel.frameWrites, writes + [SurfacePanelGeometry.backingFrame(for: away)])
    }

    func testRejectedPictureMoveGoesThroughAppKit() throws {
        let panel = PicturePanel()
        defer { panel.destroy() }
        let image = try image()
        panel.update(geometry: try geometry(fractionalFrame), content: .image(image), activate: {})
        let writes = panel.frameWrites
        panel.movesSucceed = false
        let moved = fractionalFrame.offsetBy(dx: pixel, dy: pixel)

        panel.update(geometry: try geometry(moved), content: .image(image), activate: {})

        XCTAssertEqual(panel.frameWrites, writes + [SurfacePanelGeometry.backingFrame(for: moved)])
    }

    func testReusedPictureOrdersInWithoutAppKit() throws {
        let panel = OrderingPanel()
        defer { panel.destroy() }
        let image = try image()
        let focusedWindowId = 41
        let geometry = try geometry(fractionalFrame)
        panel.setOrderingTarget(focusedWindowId)

        panel.update(geometry: geometry, content: .image(image), activate: {})
        XCTAssertEqual(panel.appKitOrders, 1)
        XCTAssertEqual(panel.windowServerOrders, [UInt32(focusedWindowId)])

        panel.hide()
        panel.update(geometry: geometry, content: .image(image), activate: {})

        XCTAssertEqual(panel.appKitOrders, 1)
        XCTAssertEqual(panel.windowServerOrders, [UInt32(focusedWindowId), UInt32(focusedWindowId)])
    }

    func testPictureIgnoresWindowServerMoveEvents() throws {
        let panel = PicturePanel()
        defer { panel.destroy() }
        panel.update(geometry: try geometry(fractionalFrame), content: .image(try image()), activate: {})

        panel.sendEvent(try XCTUnwrap(NSEvent.otherEvent(
            with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            subtype: NSEvent.EventSubtype.windowMoved.rawValue, data1: 0, data2: 0
        )))

        XCTAssertEqual(panel.appKitMoveEvents, 0)
    }

    func testChangedLogicalSizeReconfiguresEvenWhenRoundedBackingSizeIsUnchanged() throws {
        let panel = PicturePanel()
        defer { panel.destroy() }
        let image = try image()
        panel.update(geometry: try geometry(fractionalFrame), content: .image(image), activate: {})
        let backing = panel.frame.size
        var resized = fractionalFrame
        resized.size.height += pixel
        panel.update(geometry: try geometry(resized), content: .image(image), activate: {})
        XCTAssertTrue(panel.moves.isEmpty)
        XCTAssertEqual(panel.frame.size, backing)
        XCTAssertEqual(panel.contentView?.layer?.sublayers?.first?.frame.size, resized.size)
    }

    private func movingPlacement(for surface: CGRect) -> CGRect {
        CGRect(origin: surface.origin, size: SurfacePanelGeometry.backingFrame(for: surface).size)
    }

    private func assertRingOnTarget(_ panel: BorderPanel, _ target: CGRect, line: UInt = #line) throws {
        let placement = try XCTUnwrap(panel.moves.last ?? panel.reshapes.last, line: line)
        XCTAssertEqual(panel.placedFrame, placement, line: line)
        XCTAssertEqual(panel.borderLayer.frame.offsetBy(dx: placement.minX, dy: placement.minY), target, line: line)
    }

    func testPlainRingMovesInWindowServerToFractionalOriginsWithoutFrameOrLayerWrites() throws {
        let initial = fractionalFrame
        let panel = try XCTUnwrap(BorderPanel(frame: initial))
        defer { panel.close() }
        let inset = pixel * 2
        let target = initial.insetBy(dx: inset, dy: inset)
        panel.applyFrame(targetFrame: target, surfaceFrame: initial, isMoving: true)
        XCTAssertEqual(panel.reshapes, [movingPlacement(for: initial)])
        XCTAssertTrue(panel.moves.isEmpty)
        try assertRingOnTarget(panel, target)
        let writes = panel.frameWrites
        let layerFrame = panel.borderLayer.frame
        var expected: [CGRect] = []
        for step in 1 ... 3 {
            let moved = initial.offsetBy(dx: pixel * CGFloat(step), dy: 0)
            let movedTarget = moved.insetBy(dx: inset, dy: inset)
            panel.applyFrame(targetFrame: movedTarget, surfaceFrame: moved, isMoving: true)
            expected.append(movingPlacement(for: moved))
            try assertRingOnTarget(panel, movedTarget)
        }
        XCTAssertEqual(panel.moves, expected)
        XCTAssertEqual(panel.reshapes.count, 1)
        XCTAssertEqual(panel.frameWrites, writes)
        XCTAssertEqual(panel.borderLayer.frame, layerFrame)
    }

    func testAppKitScreenAdjustmentCannotMoveThePanel() throws {
        let initial = fractionalFrame
        let panel = try XCTUnwrap(BorderPanel(frame: initial))
        defer { panel.close() }
        let appKitFrame = panel.frame
        panel.applyFrame(targetFrame: initial, surfaceFrame: initial, isMoving: true)
        let placed = panel.placedFrame

        panel.setFrame(initial.offsetBy(dx: wholeSize.width, dy: wholeSize.height), display: false, animate: false)

        XCTAssertEqual(panel.frame, appKitFrame)
        XCTAssertEqual(panel.placedFrame, placed)
        XCTAssertTrue(panel.frameWrites.isEmpty)
    }

    func testWindowServerMoveEventRepairsAForeignWriteOnlyOnceSettled() throws {
        let initial = fractionalFrame
        let panel = try XCTUnwrap(BorderPanel(frame: initial))
        defer { panel.close() }
        let appKitFrame = panel.frame
        let event = try XCTUnwrap(NSEvent.otherEvent(
            with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            subtype: NSEvent.EventSubtype.windowMoved.rawValue, data1: 0, data2: 0
        ))
        panel.applyFrame(targetFrame: initial, surfaceFrame: initial, isMoving: true)
        let reshapesWhileMoving = panel.reshapes

        panel.sendEvent(event)

        XCTAssertEqual(panel.reshapes, reshapesWhileMoving)
        XCTAssertEqual(panel.frame, appKitFrame)
        let settled = initial.offsetBy(dx: wholeSize.width, dy: wholeSize.height)
        panel.applyFrame(targetFrame: settled, surfaceFrame: settled)
        let placed = try XCTUnwrap(panel.placedFrame)
        let reshapesSettled = panel.reshapes

        panel.sendEvent(event)

        XCTAssertEqual(panel.reshapes, reshapesSettled + [placed])
        XCTAssertEqual(panel.frame, appKitFrame)
    }

    func testPlainRingStaysOnTargetWhenTheWindowServerMoveIsRejected() throws {
        let initial = fractionalFrame
        let panel = try XCTUnwrap(BorderPanel(frame: initial))
        defer { panel.close() }
        panel.movesSucceed = false
        let inset = pixel * 2
        let target = initial.insetBy(dx: inset, dy: inset)
        panel.applyFrame(targetFrame: target, surfaceFrame: initial, isMoving: true)
        XCTAssertTrue(panel.moves.isEmpty)
        XCTAssertEqual(panel.frameWrites, [SurfacePanelGeometry.backingFrame(for: initial)])
        XCTAssertEqual(panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY), target)
        let moved = initial.offsetBy(dx: pixel, dy: 0)
        let movedTarget = moved.insetBy(dx: inset, dy: inset)
        panel.applyFrame(targetFrame: movedTarget, surfaceFrame: moved, isMoving: true)
        XCTAssertEqual(panel.frameWrites.last, SurfacePanelGeometry.backingFrame(for: moved))
        XCTAssertEqual(panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY), movedTarget)
    }

    func testPlainRingSettlesOnTheSameFrameAtItsUsualPlacement() throws {
        let initial = fractionalFrame
        let panel = try XCTUnwrap(BorderPanel(frame: initial))
        defer { panel.close() }
        let inset = pixel * 2
        let target = initial.insetBy(dx: inset, dy: inset)
        panel.applyFrame(targetFrame: target, surfaceFrame: initial, isMoving: true)
        let moved = initial.offsetBy(dx: pixel, dy: pixel)
        let movedTarget = moved.insetBy(dx: inset, dy: inset)
        panel.applyFrame(targetFrame: movedTarget, surfaceFrame: moved, isMoving: true)
        let writes = panel.frameWrites

        panel.applyFrame(targetFrame: movedTarget, surfaceFrame: moved)

        XCTAssertEqual(panel.placedFrame, moved.integral)
        XCTAssertEqual(panel.moves.last, moved.integral)
        XCTAssertEqual(panel.frameWrites, writes)
        try assertRingOnTarget(panel, movedTarget)
    }

    func testPlainRingStaysOnTargetWhenItsSizeChangesDuringMotion() throws {
        let initial = fractionalFrame
        let panel = try XCTUnwrap(BorderPanel(frame: initial))
        defer { panel.close() }
        let inset = pixel * 2
        panel.applyFrame(targetFrame: initial.insetBy(dx: inset, dy: inset), surfaceFrame: initial, isMoving: true)
        let writes = panel.frameWrites
        var resized = initial
        resized.size.width += 1
        let resizedTarget = resized.insetBy(dx: inset, dy: inset)
        panel.applyFrame(targetFrame: resizedTarget, surfaceFrame: resized, isMoving: true)
        XCTAssertEqual(panel.frameWrites, writes)
        XCTAssertEqual(panel.reshapes.last, movingPlacement(for: resized))
        try assertRingOnTarget(panel, resizedTarget)
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
        XCTAssertEqual(panel.placedFrame, placement)
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
