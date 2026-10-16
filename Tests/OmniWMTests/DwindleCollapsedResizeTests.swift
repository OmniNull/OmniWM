// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class DwindleCollapsedResizeTests: XCTestCase {
    func testFocusedResizeUsesVisibleBoundaryMinimums() throws {
        try assertVisibleResizeMinimums(interactive: false)
    }

    func testInteractiveResizeUsesVisibleBoundaryMinimums() throws {
        try assertVisibleResizeMinimums(interactive: true)
    }

    private func assertVisibleResizeMinimums(interactive: Bool) throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for hiddenFirst in [true, false] {
                let engine = DwindleLayoutEngine()
                let workspaceId = WorkspaceDescriptor.ID()
                let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
                let hidden = WindowToken(pid: 1, windowId: 1)
                let first = WindowToken(pid: 2, windowId: 2)
                let second = WindowToken(pid: 3, windowId: 3)
                let horizontal = orientation == .horizontal
                let forward: Direction = horizontal ? .right : .up
                let backward: Direction = horizontal ? .left : .down
                _ = engine.addWindow(token: hidden, to: workspaceId, activeWindowFrame: nil)
                XCTAssertTrue(engine.setPreselection(hiddenFirst ? forward : backward, in: workspaceId))
                _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
                XCTAssertTrue(engine.setPreselection(forward, in: workspaceId))
                _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
                for (token, minimum): (WindowToken, CGFloat) in [(first, 600), (second, 390)] {
                    engine.updateWindowConstraints(for: token, constraints: WindowSizeConstraints(
                        minSize: CGSize(width: horizontal ? minimum : 1, height: horizontal ? 1 : minimum),
                        maxSize: .zero, isFixed: false
                    ))
                }
                engine.setExcludedTokens([hidden], in: workspaceId)
                let before = engine.calculateLayout(for: workspaceId, screen: screen)
                let firstFrame = try XCTUnwrap(before[first])
                XCTAssertEqual(horizontal ? firstFrame.width : firstFrame.height, 600, accuracy: 0.001)
                XCTAssertNil(before[hidden])

                if interactive {
                    let start = firstFrame.center
                    XCTAssertTrue(engine.interactiveResizeBegin(
                        token: first, edges: horizontal ? .right : .top, startLocation: start,
                        in: workspaceId, innerGap: engine.settings.innerGap
                    ))
                    XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(
                        x: start.x + (horizontal ? 250 : 0), y: start.y + (horizontal ? 0 : 250)
                    )))
                    XCTAssertTrue(engine.interactiveResizeEnd())
                } else {
                    engine.setSelectedNode(engine.findNode(for: first, in: workspaceId), in: workspaceId)
                    XCTAssertTrue(engine.resizeFocusedWindow(by: 0.5, in: workspaceId))
                }

                let after = engine.calculateLayout(for: workspaceId, screen: screen)
                let resizedFirst = try XCTUnwrap(after[first])
                let resizedSecond = try XCTUnwrap(after[second])
                XCTAssertEqual(horizontal ? resizedFirst.width : resizedFirst.height, 602, accuracy: 0.001)
                XCTAssertEqual(horizontal ? resizedSecond.width : resizedSecond.height, 390, accuracy: 0.001)
            }
        }
    }
}
