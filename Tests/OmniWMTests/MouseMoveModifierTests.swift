// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class MouseMoveModifierTests: XCTestCase {
    func testModifiedBodyDragsPassToApplicationsInEveryLayout() throws {
        for kind in TrackpadWindowMoveFrameTests.MoveKind.allCases {
            let fixture = try TrackpadWindowMoveFrameTests().makeMoveFixture(kind)
            defer { fixture.finish() }
            let handler = fixture.handler
            let point = fixture.startFrame.center
            let worldSeq = fixture.base.manager.worldSeq
            for flags in [
                CGEventFlags.maskAlternate,
                .maskControl,
                .maskCommand,
                .maskShift,
                [.maskControl, .maskShift]
            ] {
                XCTAssertFalse(handler.dispatchMouseDown(
                    at: point, modifiers: flags, windowIdUnderPointer: fixture.moved.windowId,
                    windowServerFramesAtMouseDown: [fixture.moved: ScreenCoordinateSpace
                        .toWindowServer(rect: fixture.startFrame)]
                ))
                handler.dispatchMouseDragged(at: CGPoint(x: point.x + fixture.startFrame.width / 8, y: point.y))
                XCTAssertFalse(handler.state.isMoving)
                XCTAssertFalse(handler.state.isResizing)
                XCTAssertNil(handler.state.activeInteractionButton)
                XCTAssertNil(handler.tapInputs.capturedInteractionButton)
                XCTAssertNil(fixture.base.niri.interactiveMove)
                XCTAssertNil(fixture.base.dwindle.interactiveMove)
                handler.dispatchMouseUp(at: point)
                XCTAssertEqual(fixture.base.manager.worldSeq, worldSeq)
                XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
            }
        }
    }

    func testModifiedRightDragPassesThroughWithoutStartingAResize() throws {
        for kind in TrackpadWindowMoveFrameTests.MoveKind.allCases {
            let fixture = try TrackpadWindowMoveFrameTests().makeMoveFixture(kind)
            defer { fixture.finish() }
            let handler = fixture.handler
            let frame = fixture.startFrame
            let edge = CGPoint(x: frame.maxX - FrameTolerance.frameWrite, y: frame.midY)
            for point in [frame.center, edge] {
                for flags in [CGEventFlags.maskAlternate, .maskControl, .maskCommand] {
                    XCTAssertFalse(handler.dispatchMouseDown(at: point, modifiers: flags, button: .right))
                    handler.dispatchMouseDragged(at: CGPoint(x: point.x + frame.width / 8, y: point.y), button: .right)
                    XCTAssertFalse(handler.state.isResizing)
                    XCTAssertFalse(handler.state.isMoving)
                    XCTAssertNil(handler.state.activeInteractionButton)
                    XCTAssertNil(handler.tapInputs.capturedInteractionButton)
                    XCTAssertNil(fixture.base.niri.interactiveResize)
                    XCTAssertNil(fixture.base.dwindle.interactiveResize)
                    handler.dispatchMouseUp(at: point, button: .right)
                    XCTAssertNil(fixture.base.niri.interactiveResize)
                    XCTAssertNil(fixture.base.dwindle.interactiveResize)
                }
            }
        }
    }
}
