// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class ViewportGestureTests: XCTestCase {
    private func columns(_ widths: [CGFloat]) -> [NiriContainer] {
        widths.map { width in
            let column = NiriContainer()
            column.cachedWidth = width
            return column
        }
    }

    private func portraitColumns(_ heights: [CGFloat]) -> [NiriContainer] {
        heights.map { height in
            let column = NiriContainer()
            column.cachedWidth = 700
            column.cachedHeight = height
            return column
        }
    }

    private func makeState(activeColumnIndex: Int = 0, viewOffset: CGFloat = 0) -> ViewportState {
        var state = ViewportState()
        state.activeColumnIndex = activeColumnIndex
        state.viewOffset = viewOffset
        return state
    }

    func testMomentumWithoutVelocityStaysAtCurrentColumn() {
        var state = makeState()
        state.endGesture(
            currentOffset: 0,
            projectedOffset: 0,
            columns: columns([100, 100, 100]),
            geometry: NiriViewportGeometry(
                gap: 10,
                viewportSpan: 150,
                orientation: .horizontal
            ),
            motion: .enabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 0)
        XCTAssertEqual(state.viewOffset, 0)
        XCTAssertEqual(state.offsetTransition.kind, .deceleration)
    }

    func testMomentumFlingRestsAtProjectedOffsetWithoutSnapping() {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            var state = makeState()
            state.endGesture(
                currentOffset: 20,
                projectedOffset: 65,
                columns: orientation == .horizontal ? columns([100, 100, 100]) : portraitColumns([100, 100, 100]),
                geometry: NiriViewportGeometry(
                    gap: 10,
                    viewportSpan: 150,
                    orientation: orientation
                ),
                motion: .enabled,
                snapToColumn: false
            )

            XCTAssertEqual(state.activeColumnIndex, 1)
            XCTAssertEqual(state.viewOffset, -45)
            XCTAssertEqual(state.offsetTransition.rebaseDelta, -110)
            XCTAssertEqual(state.offsetTransition.kind, .deceleration)

            let viewStart = 110 + state.viewOffset
            XCTAssertEqual(viewStart, 65)
        }
    }

    func testMomentumSpringsBackAtContentEdge() {
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns([100, 100, 100]),
            geometry: NiriViewportGeometry(
                gap: 10,
                viewportSpan: 150,
                orientation: .horizontal
            ),
            motion: .enabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertEqual(state.viewOffset, -50)
        XCTAssertEqual(state.offsetTransition.kind, .spring(.niriHorizontalViewMovement))
        XCTAssertEqual(220 + state.viewOffset, 170)
    }

    func testWithNaturalWindowDragAFlingPastTheEndRestsAGapBeyondTheLastColumn() {
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns([100, 100, 100]),
            geometry: NiriViewportGeometry(gap: 10, viewportSpan: 150, orientation: .horizontal),
            motion: .disabled,
            snapToColumn: false,
            keepsStripEndsOnScreen: true
        )

        let viewStart = 220 + state.viewOffset
        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertEqual(viewStart, 180)
    }

    func testWithAllowOverscrollOnAFlingPastTheEndRestsAtTheOverscrollBoundInsteadOfTheGap() {
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns([100, 100, 100]),
            geometry: NiriViewportGeometry(
                gap: 10,
                viewportSpan: 150,
                orientation: .horizontal,
                edgeOverscroll: .enabled(visibleFraction: 0.5)
            ),
            motion: .disabled,
            snapToColumn: false,
            keepsStripEndsOnScreen: true
        )

        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertEqual(220 + state.viewOffset, 260)
    }

    func testWithNaturalWindowDragAFlingPastTheStartRestsAGapBeforeTheFirstColumn() {
        var state = makeState(activeColumnIndex: 1, viewOffset: 0)
        state.endGesture(
            currentOffset: -30,
            projectedOffset: -500,
            columns: columns([100, 100, 100]),
            geometry: NiriViewportGeometry(gap: 10, viewportSpan: 150, orientation: .horizontal),
            motion: .disabled,
            snapToColumn: false,
            keepsStripEndsOnScreen: true
        )

        XCTAssertEqual(state.activeColumnIndex, 0)
        XCTAssertEqual(state.viewOffset, -10)
    }

    func testDisabledAnimationsJumpToClampedLandingWithoutDeceleration() {
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns([100, 100, 100]),
            geometry: NiriViewportGeometry(
                gap: 10,
                viewportSpan: 150,
                orientation: .horizontal
            ),
            motion: .disabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertEqual(state.viewOffset, -50)
        XCTAssertEqual(state.offsetTransition.kind, .jump)
    }

    func testPortraitSnapUsesContainerHeights() {
        var state = makeState()
        state.endGesture(
            currentOffset: 0,
            projectedOffset: 65,
            columns: portraitColumns([100, 100, 100]),
            geometry: NiriViewportGeometry(
                gap: 10,
                viewportSpan: 150,
                orientation: .vertical
            ),
            motion: .disabled
        )

        XCTAssertEqual(state.activeColumnIndex, 1)
        XCTAssertEqual(state.viewOffset, -40)
        XCTAssertEqual(state.offsetTransition.kind, .jump)
    }
}
