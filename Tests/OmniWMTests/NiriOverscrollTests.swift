// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriOverscrollTests: XCTestCase {
    private func columns(_ spans: [CGFloat], orientation: Monitor.Orientation) -> [NiriContainer] {
        spans.map { span in
            let column = NiriContainer()
            column.cachedWidth = orientation == .horizontal ? span : 700
            column.cachedHeight = orientation == .vertical ? span : 700
            return column
        }
    }

    func testGestureLimitsKeepConfiguredStripVisibleOnBothAxes() {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for snap in [false, true] {
                for percent in [5, 25, 100] {
                    let columns = columns([100, 100, 200], orientation: orientation)
                    let geometry = NiriViewportGeometry(
                        gap: 10, viewportSpan: 300, orientation: orientation,
                        edgeOverscroll: .init(allowed: true, visibleStripPercent: percent)
                    )
                    for projected in [-10_000.0, 10_000.0] {
                        var state = ViewportState()
                        state.endGesture(
                            currentOffset: 0, projectedOffset: projected, columns: columns, geometry: geometry,
                            motion: .disabled, snapToColumn: snap
                        )
                        let position = state.containerPosition(
                            at: state.activeColumnIndex, containers: columns, gap: 10,
                            sizeKeyPath: orientation.renderedSpanKeyPath
                        ) + state.viewOffset
                        let expected = projected < 0
                            ? CGFloat(percent) + 10 - 300
                            : 420 - CGFloat(percent) * 2 - 10
                        XCTAssertEqual(position, expected, accuracy: 0.001)
                        XCTAssertEqual(state.activeColumnIndex, projected < 0 ? 0 : 2)
                    }
                }
            }
        }
    }

    func testCenteringDoesNotRemoveOverscrollBoundarySnaps() {
        for centerMode in CenterFocusedColumn.allCases {
            for count in [1, 3] {
                let columns = columns(Array(repeating: 100, count: count), orientation: .horizontal)
                for projected in [-10_000.0, 10_000.0] {
                    var state = ViewportState()
                    state.endGesture(
                        currentOffset: 0, projectedOffset: projected, columns: columns,
                        geometry: NiriViewportGeometry(
                            gap: 10, viewportSpan: 300, orientation: .horizontal,
                            edgeOverscroll: .enabled(visibleFraction: 0.05)
                        ),
                        motion: .disabled, centerMode: centerMode, alwaysCenterSingleColumn: true
                    )
                    XCTAssertEqual(state.viewOffset, projected < 0 ? -285 : 85, accuracy: 0.001)
                }
            }
        }
    }

    func testContinuousScrollCanRestBetweenContentAndOverscrollLimit() {
        var state = ViewportState()
        state.endGesture(
            currentOffset: 0, projectedOffset: -80,
            columns: columns([100, 100, 100], orientation: .horizontal),
            geometry: NiriViewportGeometry(
                gap: 10, viewportSpan: 150, orientation: .horizontal,
                edgeOverscroll: .enabled(visibleFraction: 0.05)
            ),
            motion: .enabled, snapToColumn: false
        )
        XCTAssertEqual(state.viewOffset, -80)
        XCTAssertEqual(state.offsetTransition.kind, .deceleration)
    }

    func testFlingBeyondOverscrollLimitSpringsToVisibleStrip() {
        var state = ViewportState()
        state.endGesture(
            currentOffset: 0, projectedOffset: -10_000,
            columns: columns([100], orientation: .horizontal),
            geometry: NiriViewportGeometry(
                gap: 10, viewportSpan: 150, orientation: .horizontal,
                edgeOverscroll: .enabled(visibleFraction: 0.25)
            ),
            motion: .enabled, snapToColumn: false
        )
        XCTAssertEqual(state.viewOffset, -115)
        XCTAssertEqual(state.offsetTransition.kind, .spring(.niriHorizontalViewMovement))
    }

    func testOversizedColumnStripIsCappedAtViewportSpan() throws {
        let bounds = try XCTUnwrap(NiriEdgeOverscroll.enabled(visibleFraction: 0.25).bounds(
            firstSpan: 2_000, lastSpan: 2_000, totalSpan: 2_000, viewportSpan: 1_000, gap: 10
        ))
        XCTAssertEqual(bounds.lowerBound, -740)
        XCTAssertEqual(bounds.upperBound, 1_740)
    }

    func testDisabledOverscrollKeepsExistingContentLimits() {
        var state = ViewportState()
        state.endGesture(
            currentOffset: 0, projectedOffset: -10_000,
            columns: columns([100, 100, 100], orientation: .horizontal),
            geometry: NiriViewportGeometry(gap: 10, viewportSpan: 150, orientation: .horizontal),
            motion: .disabled, snapToColumn: false
        )
        XCTAssertEqual(state.viewOffset, 0)
    }

    func testExplicitFocusNavigationReleasesGestureOffset() {
        var state = ViewportState()
        state.preservesGestureOffset = true
        state.viewOffset = -130
        let columns = columns([100, 100], orientation: .horizontal)
        state.transitionToColumn(
            0, columns: columns,
            context: .init(
                workspaceId: WorkspaceDescriptor.ID(), motion: .disabled,
                workingFrame: CGRect(x: 0, y: 0, width: 150, height: 100), gaps: 10,
                orientation: .horizontal
            ),
            animate: false, centerMode: .never
        )
        XCTAssertFalse(state.preservesGestureOffset)
        XCTAssertEqual(state.viewOffset, -40)
    }
}
