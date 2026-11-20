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

    private func restingOffsetAGapPastTheEnd(widths: [CGFloat], gap: CGFloat, viewportSpan: CGFloat) -> CGFloat {
        let contentSpan = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        let lastColumnStart = contentSpan - widths[widths.count - 1]
        return contentSpan + gap - viewportSpan - lastColumnStart
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

    func testMomentumSpringsBackToAGapPastTheContentEdge() {
        let widths: [CGFloat] = [100, 100, 100]
        let gap: CGFloat = 10
        let viewportSpan: CGFloat = 150
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns(widths),
            geometry: NiriViewportGeometry(
                gap: gap,
                viewportSpan: viewportSpan,
                orientation: .horizontal
            ),
            motion: .enabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, widths.count - 1)
        XCTAssertEqual(
            state.viewOffset,
            restingOffsetAGapPastTheEnd(widths: widths, gap: gap, viewportSpan: viewportSpan)
        )
        XCTAssertEqual(state.offsetTransition.kind, .spring(.niriHorizontalViewMovement))
    }

    func testAFlingPastTheEndRestsAGapBeyondTheLastColumn() {
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns([100, 100, 100]),
            geometry: NiriViewportGeometry(gap: 10, viewportSpan: 150, orientation: .horizontal),
            motion: .disabled,
            snapToColumn: false
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
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertEqual(220 + state.viewOffset, 260)
    }

    func testAFlingPastTheStartRestsAGapBeforeTheFirstColumn() {
        var state = makeState(activeColumnIndex: 1, viewOffset: 0)
        state.endGesture(
            currentOffset: -30,
            projectedOffset: -500,
            columns: columns([100, 100, 100]),
            geometry: NiriViewportGeometry(gap: 10, viewportSpan: 150, orientation: .horizontal),
            motion: .disabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 0)
        XCTAssertEqual(state.viewOffset, -10)
    }

    func testDisabledAnimationsJumpToClampedLandingWithoutDeceleration() {
        let widths: [CGFloat] = [100, 100, 100]
        let gap: CGFloat = 10
        let viewportSpan: CGFloat = 150
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns(widths),
            geometry: NiriViewportGeometry(
                gap: gap,
                viewportSpan: viewportSpan,
                orientation: .horizontal
            ),
            motion: .disabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, widths.count - 1)
        XCTAssertEqual(
            state.viewOffset,
            restingOffsetAGapPastTheEnd(widths: widths, gap: gap, viewportSpan: viewportSpan)
        )
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
