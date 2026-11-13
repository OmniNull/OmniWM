// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class EdgeResizeHoldTests: XCTestCase {
    private let screen: ClosedRange<CGFloat> = 12 ... 1488
    private let peeked: ClosedRange<CGFloat> = 100 ... 1400
    private let frame = CGRect(x: 300, y: 0, width: 800, height: 900)

    func testARightEdgeWithAPeekBeyondStopsThePointerWhereTheEdgeMeetsThePeek() throws {
        let hold = try XCTUnwrap(MouseEventHandler.edgeResizeHold(
            at: CGPoint(x: 1097, y: 400),
            frame: frame,
            edges: .right,
            centred: false,
            bounds: peeked,
            screenBounds: screen
        ))
        XCTAssertNil(hold.minX)
        XCTAssertEqual(try XCTUnwrap(hold.maxX), 1097 + (1400 - 1100), accuracy: 0.001)
    }

    func testALeftEdgeWithAPeekBeyondStopsThePointerWhereTheEdgeMeetsThePeek() throws {
        let hold = try XCTUnwrap(MouseEventHandler.edgeResizeHold(
            at: CGPoint(x: 303, y: 400),
            frame: frame,
            edges: .left,
            centred: false,
            bounds: peeked,
            screenBounds: screen
        ))
        XCTAssertNil(hold.maxX)
        XCTAssertEqual(try XCTUnwrap(hold.minX), 303 - (300 - 100), accuracy: 0.001)
    }

    func testAnEdgeWithNothingBeyondItIsNotHeld() {
        let atTheEnd: ClosedRange<CGFloat> = 100 ... 1488
        XCTAssertNil(MouseEventHandler.edgeResizeHold(
            at: CGPoint(x: 1097, y: 400),
            frame: frame,
            edges: .right,
            centred: false,
            bounds: atTheEnd,
            screenBounds: screen
        ))
        XCTAssertNil(MouseEventHandler.edgeResizeHold(
            at: CGPoint(x: 1097, y: 400),
            frame: frame,
            edges: .right,
            centred: false,
            bounds: screen,
            screenBounds: screen
        ))
    }

    func testAnEdgeAlreadyAtThePeekCannotGoFurther() throws {
        let wide = CGRect(x: 100, y: 0, width: 1300, height: 900)
        let hold = try XCTUnwrap(MouseEventHandler.edgeResizeHold(
            at: CGPoint(x: 1398, y: 400),
            frame: wide,
            edges: .right,
            centred: false,
            bounds: peeked,
            screenBounds: screen
        ))
        XCTAssertEqual(try XCTUnwrap(hold.maxX), 1398, accuracy: 0.001)
    }

    func testAnOptionResizeAroundTheCentreStopsAtTheNearerPeek() throws {
        let hold = try XCTUnwrap(MouseEventHandler.edgeResizeHold(
            at: CGPoint(x: 1097, y: 400),
            frame: frame,
            edges: .right,
            centred: true,
            bounds: peeked,
            screenBounds: screen
        ))
        XCTAssertEqual(try XCTUnwrap(hold.maxX), 1097 + (300 - 100), accuracy: 0.001)
    }

    func testTheBarrierClampsADragPastTheLineAndLetsADragBackThrough() throws {
        let barrier = PointerEdgeBarrier(installsTap: false)
        barrier.publishResizeHold(.init(minX: nil, maxX: 1200))
        let past = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: 1300, y: 400),
            mouseButton: .left
        ))
        barrier.applyResizeHold(to: past)
        XCTAssertEqual(past.location.x, 1200, accuracy: 0.001)
        XCTAssertEqual(past.location.y, 400, accuracy: 0.001)

        let back = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: 1100, y: 400),
            mouseButton: .left
        ))
        barrier.applyResizeHold(to: back)
        XCTAssertEqual(back.location.x, 1100, accuracy: 0.001)

        barrier.publishResizeHold(nil)
        XCTAssertNil(barrier.resizeHold)
    }

    @MainActor
    func testStoppingTheMouseHandlerLetsGoOfTheResizeHold() {
        let controller = WindowAdmissionTestSupport.controller()
        var hold = PointerEdgeBarrier.ResizeHold()
        hold.maxX = 1200
        controller.holdPointerForEdgeResize(hold)
        XCTAssertNotNil(controller.pointerEdgeBarrier.resizeHold)

        controller.mouseEventHandler.cleanup()

        XCTAssertNil(controller.pointerEdgeBarrier.resizeHold)
    }

    @MainActor
    func testTheResizeHoldRunsItsOwnTapUnlessMouseWarpRunsOne() {
        let controller = WindowAdmissionTestSupport.controller()
        let main = Monitor(
            id: .init(displayId: 88_101), displayId: 88_101,
            frame: CGRect(x: 0, y: 0, width: 1500, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1500, height: 900),
            hasNotch: false, name: "Main"
        )
        let side = Monitor(
            id: .init(displayId: 88_102), displayId: 88_102,
            frame: CGRect(x: 1500, y: 0, width: 1500, height: 900),
            visibleFrame: CGRect(x: 1500, y: 0, width: 1500, height: 900),
            hasNotch: false, name: "Side"
        )
        for (warp, monitors, owned) in [
            (true, [main], false),
            (true, [main, side], true),
            (false, [main, side], false)
        ] {
            controller.settings.pointer.enabled = warp
            controller.workspaceManager.applyMonitorConfigurationChange(monitors)
            XCTAssertEqual(controller.mouseWarpOwnsPointerEdgeTap, owned, "warp \(warp), \(monitors.count) displays")
        }
    }
}
