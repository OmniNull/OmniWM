// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeWindowInteractionTests: XCTestCase {
    func testOrderingWindowPreservesOffscreenSlideOrigins() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let size = CGSize(width: 400, height: 200)

        for position in QuakeTerminalPosition.allCases {
            let window = QuakeTerminalWindow()
            defer { window.close() }
            let frame = CGRect(
                origin: position.initialOrigin(visibleFrame: screen.visibleFrame, windowSize: size),
                size: size
            )
            window.alphaValue = 0
            window.setFrame(frame, display: false)
            window.level = .popUpMenu
            window.orderBack(nil)

            XCTAssertEqual(window.frame, frame, "\(position) slide origin changed when ordering the window")
        }
    }

    func testWindowContentFillsFrameWithoutNativeTitlebarDragRegion() throws {
        let (window, view) = makeSurface()
        defer { window.close() }

        for size in [CGSize(width: 400, height: 200), CGSize(width: 600, height: 350)] {
            window.setFrame(CGRect(origin: window.frame.origin, size: size), display: false)
            let content = try XCTUnwrap(window.contentView)
            let frameView = try XCTUnwrap(content.superview)

            XCTAssertEqual(content.frame, CGRect(origin: .zero, size: size))
            XCTAssertEqual(window.contentLayoutRect, content.frame)
            XCTAssertEqual(view.frame, content.bounds)
            let point = view.convert(CGPoint(x: size.width / 2, y: size.height - 16), to: frameView)
            XCTAssertTrue(frameView.hitTest(point) === view)
            XCTAssertTrue(window.makeFirstResponder(view))
        }
        XCTAssertFalse(window.isVisible)
    }

    func testDetachedEventsRemainTerminalEvents() throws {
        let interaction = QuakeWindowInteraction()
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let event = try mouseEvent(.leftMouseDown, at: .zero, modifiers: .option)

        XCTAssertFalse(interaction.handleMouseDown(event, in: view))
        XCTAssertFalse(interaction.handleMouseDrag(in: view))
        XCTAssertFalse(interaction.handleMouseUp(in: view, onFrameChanged: { _ in XCTFail("Unexpected frame change") }))
        interaction.finishMouseUp()
        XCTAssertFalse(interaction.isInteracting)
    }

    func testInteriorUnmodifiedEventsRemainTerminalEvents() throws {
        let (window, view) = makeSurface()
        let interaction = QuakeWindowInteraction()
        let event = try mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 100), in: window)

        XCTAssertFalse(interaction.handleMouseDown(event, in: view))
        XCTAssertFalse(interaction.handleMouseDrag(in: view))
        XCTAssertFalse(interaction.handleMouseUp(in: view, onFrameChanged: nil))
        interaction.finishMouseUp()
        XCTAssertFalse(interaction.isInteracting)
        XCTAssertFalse(window.isVisible)
    }

    func testPerimeterResizeTakesPriorityOverOptionAndReportsBeforeReset() throws {
        let (window, view) = makeSurface()
        let down = try mouseEvent(.leftMouseDown, at: CGPoint(x: 1, y: 100), modifiers: .option, in: window)
        let up = try mouseEvent(.leftMouseUp, at: CGPoint(x: 1, y: 100), in: window)
        var deliveredFrames: [CGRect] = []
        var interactionDuringCallback: [Bool] = []
        view.onFrameChanged = { [weak view] frame in
            deliveredFrames.append(frame)
            interactionDuringCallback.append(view?.isInteracting == true)
        }
        defer { view.onFrameChanged = nil }

        view.mouseDown(with: down)
        XCTAssertTrue(view.isInteracting)
        var changedFrame = window.frame
        changedFrame.size.width += 20
        window.setFrame(changedFrame, display: false)
        view.mouseUp(with: up)

        XCTAssertEqual(deliveredFrames, [window.frame])
        XCTAssertEqual(interactionDuringCallback, [true])
        XCTAssertFalse(view.isInteracting)
        XCTAssertFalse(window.isVisible)
    }

    func testOptionMoveIgnoresSizeOnlyChanges() throws {
        let (window, view) = makeSurface()
        let down = try mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 100), modifiers: .option, in: window)
        let up = try mouseEvent(.leftMouseUp, at: CGPoint(x: 200, y: 100), in: window)
        view.onFrameChanged = { _ in XCTFail("Size-only change must not count as a move") }
        defer { view.onFrameChanged = nil }

        view.mouseDown(with: down)
        XCTAssertTrue(view.isInteracting)
        var changedFrame = window.frame
        changedFrame.size.width += 20
        window.setFrame(changedFrame, display: false)
        view.mouseUp(with: up)

        XCTAssertFalse(view.isInteracting)
        XCTAssertFalse(window.isVisible)
    }

    func testMoveCallbackCanReenterAndFinalResetStillCompletes() throws {
        let (window, view) = makeSurface()
        let down = try mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 100), modifiers: .option, in: window)
        let up = try mouseEvent(.leftMouseUp, at: CGPoint(x: 200, y: 100), in: window)
        var deliveredFrames: [CGRect] = []
        view.onFrameChanged = { [weak view] frame in
            deliveredFrames.append(frame)
            XCTAssertEqual(view?.isInteracting, true)
            view?.mouseDown(with: down)
            XCTAssertEqual(view?.isInteracting, true)
        }
        defer { view.onFrameChanged = nil }

        view.mouseDown(with: down)
        window.setFrameOrigin(CGPoint(x: window.frame.minX + 20, y: window.frame.minY))
        view.mouseUp(with: up)

        XCTAssertEqual(deliveredFrames, [window.frame])
        XCTAssertFalse(view.isInteracting)
        view.mouseUp(with: up)
        XCTAssertEqual(deliveredFrames.count, 1)
        XCTAssertFalse(window.isVisible)
    }

    func testUnchangedResizeFinishesWithoutReportingFrame() throws {
        let (window, view) = makeSurface()
        let down = try mouseEvent(.leftMouseDown, at: CGPoint(x: 1, y: 100), in: window)
        let up = try mouseEvent(.leftMouseUp, at: CGPoint(x: 1, y: 100), in: window)
        view.onFrameChanged = { _ in XCTFail("Unchanged frame must not be reported") }
        defer { view.onFrameChanged = nil }

        view.mouseDown(with: down)
        XCTAssertTrue(view.isInteracting)
        view.mouseUp(with: up)

        XCTAssertFalse(view.isInteracting)
        XCTAssertFalse(window.isVisible)
    }

    private func makeSurface() -> (NSWindow, GhosttySurfaceView) {
        let window = QuakeTerminalWindow()
        window.setFrame(CGRect(x: 100, y: 100, width: 400, height: 200), display: false)
        let view = GhosttySurfaceView(occlusionHandlerForTests: { _ in })
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        return (window, view)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow? = nil
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
