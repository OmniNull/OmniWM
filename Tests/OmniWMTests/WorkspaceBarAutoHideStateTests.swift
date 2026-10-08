// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarAutoHideStateTests: XCTestCase {
    private let monitor = Monitor(
        id: .init(displayId: 7), displayId: 7,
        frame: CGRect(x: -800, y: -600, width: 800, height: 600),
        visibleFrame: CGRect(x: -780, y: -580, width: 760, height: 560),
        hasNotch: false, name: "Test"
    )

    func testEdgeActivationAndPerpendicularRetentionAtEveryPosition() {
        let cases: [(WorkspaceBarPosition, CGPoint, CGPoint, CGPoint, CGPoint)] = [
            (
                .overlappingMenuBar,
                CGPoint(x: -400, y: 0),
                CGPoint(x: -790, y: 0),
                CGPoint(x: -790, y: -20),
                CGPoint(x: -790, y: -20.5)
            ),
            (
                .belowMenuBar,
                CGPoint(x: -400, y: 0),
                CGPoint(x: -790, y: 0),
                CGPoint(x: -790, y: -44),
                CGPoint(x: -790, y: -44.5)
            ),
            (
                .bottom,
                CGPoint(x: -400, y: -580),
                CGPoint(x: -790, y: -580),
                CGPoint(x: -790, y: -556),
                CGPoint(x: -790, y: -555.5)
            ),
            (
                .left,
                CGPoint(x: -780, y: -300),
                CGPoint(x: -780, y: -590),
                CGPoint(x: -756, y: -590),
                CGPoint(x: -755.5, y: -590)
            ),
            (
                .right,
                CGPoint(x: -20.5, y: -300),
                CGPoint(x: -20.5, y: -590),
                CGPoint(x: -44, y: -590),
                CGPoint(x: -44.5, y: -590)
            )
        ]
        for (position, edge, outsideSpan, boundary, outsideDepth) in cases {
            let target = makeTarget(position: position)
            var state = WorkspaceBarAutoHideState()
            let inside = position.isVertical
                ? CGPoint(x: (edge.x + boundary.x) / 2, y: edge.y)
                : CGPoint(x: edge.x, y: (edge.y + boundary.y) / 2)
            for point in [inside, outsideSpan, boundary] {
                state.update(targets: [target], pointer: point)
                XCTAssertTrue(state.revealed.isEmpty, "\(position)")
            }
            state.update(targets: [target], pointer: edge)
            XCTAssertEqual(state.revealed, [monitor.id], "\(position)")
            for point in [outsideSpan, boundary] {
                state.update(targets: [target], pointer: point)
                XCTAssertEqual(state.revealed, [monitor.id], "\(position)")
            }
            state.update(targets: [target], pointer: outsideDepth)
            XCTAssertTrue(state.revealed.isEmpty, "\(position)")
        }
    }

    func testOffsetsUseTheBarEdgeWithoutAnActivationGapOrExtraRetention() {
        let cases: [(WorkspaceBarPosition, Double, Double, CGPoint, CGPoint, CGPoint)] = [
            (.bottom, 48, 200, CGPoint(x: -400, y: -380), CGPoint(x: -790, y: -332), CGPoint(x: -400, y: -580)),
            (.belowMenuBar, 24, -4, CGPoint(x: -400, y: -24.5), CGPoint(x: -790, y: -48), CGPoint(x: -400, y: -1))
        ]
        for (position, height, offset, edge, boundary, displayEdge) in cases {
            let target = makeTarget(position: position, height: height, yOffset: offset)
            var state = WorkspaceBarAutoHideState()
            state.update(targets: [target], pointer: displayEdge)
            XCTAssertTrue(state.revealed.isEmpty)
            state.update(targets: [target], pointer: edge)
            XCTAssertEqual(state.revealed, [monitor.id])
            state.update(targets: [target], pointer: boundary)
            XCTAssertEqual(state.revealed, [monitor.id])
            let outside = CGPoint(x: boundary.x, y: boundary.y + (position == .bottom ? 0.5 : -0.5))
            state.update(targets: [target], pointer: outside)
            XCTAssertTrue(state.revealed.isEmpty)
        }
    }

    func testInteractionsRetainVisibleBarsButDoNotSummonHiddenBars() {
        let target = makeTarget(position: .bottom)
        let hiddenPinned = makeTarget(position: .bottom, isPinned: true)
        let visiblePinned = makeTarget(position: .bottom, isVisible: true, isPinned: true)
        var state = WorkspaceBarAutoHideState()
        state.update(targets: [hiddenPinned], pointer: monitor.frame.center)
        XCTAssertTrue(state.revealed.isEmpty)
        state.update(targets: [target], pointer: CGPoint(x: -400, y: -580))
        state.update(targets: [hiddenPinned], pointer: monitor.frame.center)
        XCTAssertEqual(state.revealed, [monitor.id])
        state.update(targets: [target], pointer: monitor.frame.center)
        XCTAssertTrue(state.revealed.isEmpty)
        state.update(targets: [visiblePinned], pointer: monitor.frame.center)
        XCTAssertEqual(state.revealed, [monitor.id])
        state.update(targets: [], pointer: monitor.frame.center)
        XCTAssertTrue(state.revealed.isEmpty)
    }

    func testSplitBarOnlyActivatesAlongItsIslands() {
        let settings = WorkspaceBarSettings()
        settings.position = .overlappingMenuBar
        let target = WorkspaceBarAutoHideTarget(
            monitor: monitor,
            frames: [
                CGRect(x: -700, y: -24, width: 200, height: 24),
                CGRect(x: -300, y: -24, width: 200, height: 24)
            ],
            resolved: settings.resolved(for: monitor), isVisible: false, isPinned: false
        )
        var state = WorkspaceBarAutoHideState()
        state.update(targets: [target], pointer: CGPoint(x: -400, y: -1))
        XCTAssertTrue(state.revealed.isEmpty)
        state.update(targets: [target], pointer: CGPoint(x: -600, y: -1))
        XCTAssertEqual(state.revealed, [monitor.id])
        state.update(targets: [target], pointer: CGPoint(x: -400, y: -12))
        XCTAssertEqual(state.revealed, [monitor.id])
    }

    private func makeTarget(
        position: WorkspaceBarPosition, height: Double = 24, yOffset: Double = 0,
        isVisible: Bool = false, isPinned: Bool = false
    ) -> WorkspaceBarAutoHideTarget {
        let settings = WorkspaceBarSettings()
        settings.position = position
        settings.notchMode = .off
        settings.height = height
        settings.yOffset = yOffset
        let resolved = settings.resolved(for: monitor)
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        return WorkspaceBarAutoHideTarget(
            monitor: monitor, frames: [geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved)],
            resolved: resolved, isVisible: isVisible, isPinned: isPinned
        )
    }
}
