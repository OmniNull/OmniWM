// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class TabRailDragGestureTests: XCTestCase {
    func testADragPastTheThresholdStartsOnce() {
        var gesture = TabRailDragGesture(threshold: 10)
        gesture.press(visualIndex: 2, token: nil, at: CGPoint(x: 100, y: 100))

        XCTAssertNil(gesture.drag(to: CGPoint(x: 106, y: 104)))
        XCTAssertEqual(
            gesture.drag(to: CGPoint(x: 112, y: 100)),
            .init(visualIndex: 2, token: nil, pressPoint: CGPoint(x: 100, y: 100))
        )
        XCTAssertNil(gesture.drag(to: CGPoint(x: 140, y: 90)))
    }

    func testAPressWithoutADragIsOnlyAClick() {
        var gesture = TabRailDragGesture(threshold: 10)
        gesture.press(visualIndex: 0, token: nil, at: CGPoint(x: 10, y: 10))

        XCTAssertNil(gesture.drag(to: CGPoint(x: 15, y: 12)))
        gesture.release()
        XCTAssertNil(gesture.drag(to: CGPoint(x: 50, y: 50)))
    }

    func testADragFollowsThePressedTabWhenTheTabsChangeBeforeIt() throws {
        let first = WindowToken(pid: 970, windowId: 1)
        let pressed = WindowToken(pid: 970, windowId: 2)
        let third = WindowToken(pid: 970, windowId: 3)
        var gesture = TabRailDragGesture(threshold: 10)
        gesture.press(visualIndex: 1, token: pressed, at: CGPoint(x: 100, y: 100))
        let event = try XCTUnwrap(gesture.drag(to: CGPoint(x: 120, y: 100)))

        let afterAClose = [tab(0, pressed), tab(1, third)]
        XCTAssertEqual(event.pressedTab(in: afterAClose)?.token, pressed)
        XCTAssertEqual(event.pressedTab(in: afterAClose)?.visualIndex, 0)
        XCTAssertNil(event.pressedTab(in: [tab(0, first), tab(1, third)]))
    }

    private func tab(_ visualIndex: Int, _ token: WindowToken) -> TabRailTabInfo {
        .init(
            visualIndex: visualIndex,
            token: token,
            windowId: token.windowId,
            appName: nil,
            title: nil,
            isActive: false
        )
    }

    func testNothingHappensWithoutAPress() {
        var gesture = TabRailDragGesture()

        XCTAssertNil(gesture.drag(to: CGPoint(x: 500, y: 500)))
    }
}
