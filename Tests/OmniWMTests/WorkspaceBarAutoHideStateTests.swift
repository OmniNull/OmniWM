// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class WorkspaceBarAutoHideStateTests: XCTestCase {
    private let monitor = Monitor(
        id: .init(displayId: 7), displayId: 7,
        frame: CGRect(x: -800, y: -600, width: 800, height: 600),
        visibleFrame: CGRect(x: -780, y: -580, width: 760, height: 560),
        hasNotch: false, name: "Test"
    )

    func testAllEdgesRevealOnlyNearTheBarAndHideImmediately() {
        let cases: [(WorkspaceBarPosition, CGRect, CGPoint)] = [
            (.overlappingMenuBar, CGRect(x: -500, y: -24, width: 200, height: 24), CGPoint(x: -790, y: -1)),
            (.belowMenuBar, CGRect(x: -500, y: -44, width: 200, height: 24), CGPoint(x: -790, y: -1)),
            (.bottom, CGRect(x: -500, y: -580, width: 200, height: 24), CGPoint(x: -790, y: -580)),
            (.left, CGRect(x: -780, y: -400, width: 24, height: 200), CGPoint(x: -780, y: -590)),
            (.right, CGRect(x: -44, y: -400, width: 24, height: 200), CGPoint(x: -20, y: -590))
        ]
        for (position, frame, unrelatedEdge) in cases {
            var state = WorkspaceBarAutoHideState()
            let target = WorkspaceBarAutoHideTarget(
                monitor: monitor, frames: [frame], position: position, isVisible: false, isPinned: false
            )
            state.update(targets: [target], pointer: unrelatedEdge)
            XCTAssertTrue(state.revealed.isEmpty, "\(position)")
            state.update(targets: [target], pointer: frame.center)
            XCTAssertEqual(state.revealed, [monitor.id], "\(position)")
            state.update(targets: [target], pointer: unrelatedEdge)
            XCTAssertTrue(state.revealed.isEmpty, "\(position)")
        }
    }

    func testSpatialHysteresisAndInteractionsDoNotSummonHiddenBars() {
        let frame = CGRect(x: -500, y: -580, width: 200, height: 24)
        let target = WorkspaceBarAutoHideTarget(
            monitor: monitor, frames: [frame], position: .bottom, isVisible: false, isPinned: false
        )
        var state = WorkspaceBarAutoHideState()
        let hiddenPinned = WorkspaceBarAutoHideTarget(
            monitor: monitor, frames: [frame], position: .bottom, isVisible: false, isPinned: true
        )
        state.update(targets: [hiddenPinned], pointer: .zero)
        XCTAssertTrue(state.revealed.isEmpty)
        let margin = CGPoint(x: frame.minX - 15, y: frame.midY)
        state.update(targets: [target], pointer: margin)
        XCTAssertTrue(state.revealed.isEmpty)
        state.update(targets: [target], pointer: frame.center)
        state.update(targets: [target], pointer: margin)
        XCTAssertEqual(state.revealed, [monitor.id])
        let pinned = WorkspaceBarAutoHideTarget(
            monitor: monitor, frames: [frame], position: .bottom, isVisible: true, isPinned: true
        )
        state.update(targets: [pinned], pointer: .zero)
        XCTAssertEqual(state.revealed, [monitor.id])
        state.update(targets: [target], pointer: .zero)
        XCTAssertTrue(state.revealed.isEmpty)
        state.update(targets: [pinned], pointer: .zero)
        state.update(targets: [], pointer: frame.center)
        XCTAssertTrue(state.revealed.isEmpty)
    }

    func testSplitBarDoesNotRevealInNotchGap() {
        let target = WorkspaceBarAutoHideTarget(
            monitor: monitor,
            frames: [
                CGRect(x: -700, y: -24, width: 200, height: 24),
                CGRect(x: -300, y: -24, width: 200, height: 24)
            ],
            position: .overlappingMenuBar, isVisible: false, isPinned: false
        )
        var state = WorkspaceBarAutoHideState()
        state.update(targets: [target], pointer: CGPoint(x: -400, y: -1))
        XCTAssertTrue(state.revealed.isEmpty)
        for x in [-600.0, -200.0] {
            state.update(targets: [target], pointer: CGPoint(x: x, y: -1))
            XCTAssertEqual(state.revealed, [monitor.id])
            state.reset()
        }
    }
}
