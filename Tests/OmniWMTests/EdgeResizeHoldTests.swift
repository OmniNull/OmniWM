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
    private let grabInset: CGFloat = 3

    private var holdAtThePeek: PointerEdgeBarrier.ResizeHold {
        .init(minimum: nil, maximum: peeked.upperBound)
    }

    private func rightGrab(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.maxX - grabInset, y: frame.midY)
    }

    private func leftGrab(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + grabInset, y: frame.midY)
    }

    private func leftDrag(at point: CGPoint) throws -> CGEvent {
        try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: point,
            mouseButton: .left
        ))
    }

    private func resizeHold(
        at location: CGPoint,
        frame: CGRect,
        edges: ResizeEdge,
        centred: Bool,
        bounds: ClosedRange<CGFloat>
    ) -> PointerEdgeBarrier.ResizeHold? {
        let room = MouseEventHandler.edgeResizeRoom(of: frame, in: bounds, screenBounds: screen)
        return MouseEventHandler.edgeResizeHold(
            at: location,
            edges: edges,
            centred: centred,
            room: room
        )
    }

    func testARightEdgeWithAPeekBeyondStopsThePointerWhereTheEdgeMeetsThePeek() {
        let press = rightGrab(of: frame)
        let hold = resizeHold(at: press, frame: frame, edges: .right, centred: false, bounds: peeked)
        let roomToThePeek = peeked.upperBound - frame.maxX
        XCTAssertEqual(hold, .init(minimum: nil, maximum: press.x + roomToThePeek))
    }

    func testALeftEdgeWithAPeekBeyondStopsThePointerWhereTheEdgeMeetsThePeek() {
        let press = leftGrab(of: frame)
        let hold = resizeHold(at: press, frame: frame, edges: .left, centred: false, bounds: peeked)
        let roomToThePeek = frame.minX - peeked.lowerBound
        XCTAssertEqual(hold, .init(minimum: press.x - roomToThePeek, maximum: nil))
    }

    func testAnEdgeWithNothingBeyondItIsNotHeld() {
        let press = rightGrab(of: frame)
        let endingAtTheScreen = peeked.lowerBound ... screen.upperBound
        XCTAssertNil(resizeHold(at: press, frame: frame, edges: .right, centred: false, bounds: endingAtTheScreen))
        XCTAssertNil(resizeHold(at: press, frame: frame, edges: .right, centred: false, bounds: screen))
    }

    func testAnEdgeAlreadyAtThePeekCannotGoFurther() {
        let reachingThePeeks = CGRect(
            x: peeked.lowerBound,
            y: frame.minY,
            width: peeked.upperBound - peeked.lowerBound,
            height: frame.height
        )
        let press = rightGrab(of: reachingThePeeks)
        let hold = resizeHold(at: press, frame: reachingThePeeks, edges: .right, centred: false, bounds: peeked)
        XCTAssertEqual(hold, .init(minimum: nil, maximum: press.x))
    }

    func testAnOptionResizeAroundTheCentreStopsAtTheNearerPeek() {
        let press = rightGrab(of: frame)
        let hold = resizeHold(at: press, frame: frame, edges: .right, centred: true, bounds: peeked)
        let leftRoom = frame.minX - peeked.lowerBound
        let rightRoom = peeked.upperBound - frame.maxX
        XCTAssertLessThan(leftRoom, rightRoom)
        XCTAssertEqual(hold, .init(minimum: nil, maximum: press.x + leftRoom))
    }

    func testTheBarrierClampsADragPastTheLineAndLetsADragBackThrough() throws {
        let barrier = PointerEdgeBarrier(installsTap: false)
        barrier.publishResizeHold(holdAtThePeek)
        let line = try XCTUnwrap(holdAtThePeek.maximum)
        let pastTheLine = CGPoint(x: screen.upperBound, y: frame.midY)
        let insideTheLine = CGPoint(x: frame.maxX, y: frame.midY)

        let past = try leftDrag(at: pastTheLine)
        _ = barrier.handleTapEvent(.leftMouseDragged, past)
        XCTAssertEqual(past.location, CGPoint(x: line, y: pastTheLine.y))

        let back = try leftDrag(at: insideTheLine)
        _ = barrier.handleTapEvent(.leftMouseDragged, back)
        XCTAssertEqual(back.location, insideTheLine)

        barrier.publishResizeHold(nil)
        XCTAssertNil(barrier.resizeHold)
    }

    func testPortraitPrimaryEdgesClampInWindowServerCoordinatesAndLetThePointerReturn() throws {
        let offset: CGFloat = 200
        let vertical = CGRect(x: offset, y: frame.minX + offset, width: frame.height, height: frame.width)
        let screenY = (screen.lowerBound + offset) ... (screen.upperBound + offset)
        let peeksY = (peeked.lowerBound + offset) ... (peeked.upperBound + offset)
        let room = MouseEventHandler.edgeResizeRoom(
            of: vertical, in: peeksY, screenBounds: screenY, orientation: .vertical
        )
        for top in [false, true] {
            let press = CGPoint(x: vertical.midX, y: top ? vertical.maxY - grabInset : vertical.minY + grabInset)
            let hold = try XCTUnwrap(MouseEventHandler.edgeResizeHold(
                at: press, edges: top ? .top : .bottom, centred: false, room: room, orientation: .vertical
            ))
            let travel = top ? peeksY.upperBound - vertical.maxY : vertical.minY - peeksY.lowerBound
            let limit = ScreenCoordinateSpace.toWindowServer(
                point: CGPoint(x: press.x, y: press.y + (top ? travel : -travel))
            )
            XCTAssertEqual(hold.minimum, top ? limit.y : nil)
            XCTAssertEqual(hold.maximum, top ? nil : limit.y)
            let barrier = PointerEdgeBarrier(installsTap: false)
            barrier.publishResizeHold(hold)
            let past = try leftDrag(at: ScreenCoordinateSpace.toWindowServer(
                point: CGPoint(x: press.x, y: top ? screenY.upperBound : screenY.lowerBound)
            ))
            let x = past.location.x
            _ = barrier.handleTapEvent(.leftMouseDragged, past)
            XCTAssertEqual(past.location, CGPoint(x: x, y: limit.y))
            let backPoint = ScreenCoordinateSpace.toWindowServer(point: press)
            let back = try leftDrag(at: backPoint)
            _ = barrier.handleTapEvent(.leftMouseDragged, back)
            XCTAssertEqual(back.location, backPoint)
            barrier.publishResizeHold(nil)
            XCTAssertNil(barrier.resizeHold)
        }
    }

    func testPortraitCenteredResizeUsesTheNearerPeekAndUnboundedEdgesHaveNoHold() throws {
        let vertical = CGRect(x: frame.minY, y: frame.minX, width: frame.height, height: frame.width)
        let room = MouseEventHandler.edgeResizeRoom(
            of: vertical, in: peeked, screenBounds: screen, orientation: .vertical
        )
        let nearest = min(try XCTUnwrap(room.leading), try XCTUnwrap(room.trailing))
        for top in [false, true] {
            let press = CGPoint(x: vertical.midX, y: top ? vertical.maxY - grabInset : vertical.minY + grabInset)
            let hold = try XCTUnwrap(MouseEventHandler.edgeResizeHold(
                at: press, edges: top ? .top : .bottom, centred: true, room: room, orientation: .vertical
            ))
            let limit = ScreenCoordinateSpace.toWindowServer(
                point: CGPoint(x: press.x, y: press.y + (top ? nearest : -nearest))
            ).y
            XCTAssertEqual(top ? hold.minimum : hold.maximum, limit)
            let noRoom = MouseEventHandler.edgeResizeRoom(
                of: vertical, in: screen, screenBounds: screen, orientation: .vertical
            )
            XCTAssertNil(MouseEventHandler.edgeResizeHold(
                at: press, edges: top ? .top : .bottom, centred: true, room: noRoom, orientation: .vertical
            ))
        }
        let touching = CGRect(
            x: vertical.minX, y: peeked.lowerBound, width: vertical.width,
            height: peeked.upperBound - peeked.lowerBound
        )
        let touchingRoom = MouseEventHandler.edgeResizeRoom(
            of: touching, in: peeked, screenBounds: screen, orientation: .vertical
        )
        let press = CGPoint(x: touching.midX, y: touching.maxY - grabInset)
        let hold = try XCTUnwrap(MouseEventHandler.edgeResizeHold(
            at: press, edges: .top, centred: false, room: touchingRoom, orientation: .vertical
        ))
        XCTAssertEqual(hold.minimum, ScreenCoordinateSpace.toWindowServer(point: press).y)
    }

    @MainActor
    func testStoppingTheMouseHandlerLetsGoOfTheResizeHold() {
        let controller = WindowAdmissionTestSupport.controller()
        controller.holdPointerForEdgeResize(holdAtThePeek)
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
