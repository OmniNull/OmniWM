// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class HoverScrollAmountTests: XCTestCase {
    private let workingExtent: CGFloat = 1000
    private let gap: CGFloat = 10
    private let columnSpan: CGFloat = 400
    private let scale: CGFloat = 2

    private struct Fixture {
        let columns: [NiriContainer]
        let context: NiriInteractionContext
        var state: ViewportState
    }

    private func makeFixture(
        columnCount: Int,
        orientation: Monitor.Orientation = .horizontal
    ) -> Fixture {
        let engine = NiriLayoutEngine(visibleContainerCount: 3)
        let workspaceId = WorkspaceDescriptor.ID()
        for windowId in 1 ... columnCount {
            _ = engine.addWindow(
                token: WindowToken(pid: 770, windowId: windowId),
                to: workspaceId,
                afterSelection: nil
            )
        }
        let columns = engine.columns(in: workspaceId)
        for column in columns {
            column.width = .fixed(columnSpan)
            column.cachedWidth = columnSpan
            column.height = .fixed(columnSpan)
            column.cachedHeight = columnSpan
        }
        let workingFrame = CGRect(x: 0, y: 0, width: workingExtent, height: workingExtent)
        var state = ViewportState()
        state.viewOffset = -gap
        return Fixture(
            columns: columns,
            context: NiriInteractionContext(
                workspaceId: workspaceId,
                motion: .disabled,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation
            ),
            state: state
        )
    }

    private func amount(
        _ fixture: Fixture,
        columnIndex: Int,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) -> CGFloat {
        NiriHoverScroll.scrollAmount(
            state: fixture.state,
            columnIndex: columnIndex,
            columns: fixture.columns,
            context: fixture.context,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            scale: scale,
            viewFrame: nil
        )
    }

    func testFullyVisibleColumnNeedsNoScroll() {
        let fixture = makeFixture(columnCount: 3)

        XCTAssertEqual(amount(fixture, columnIndex: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(amount(fixture, columnIndex: 1), 0, accuracy: 0.0001)
    }

    func testColumnPastTrailingEdgeNeedsScrollEqualToOvershootPlusGapPadding() {
        let fixture = makeFixture(columnCount: 3)
        let thirdColumnEnd = 2 * (columnSpan + gap) + columnSpan
        let viewEndWithLeadingGap = workingExtent - gap
        let expectedOvershoot = thirdColumnEnd + gap - viewEndWithLeadingGap

        XCTAssertEqual(expectedOvershoot, 240, accuracy: 0.0001)
        XCTAssertEqual(amount(fixture, columnIndex: 2), expectedOvershoot, accuracy: 0.0001)
    }

    func testColumnBeforeLeadingEdgeNeedsScrollBackToItsStart() {
        var fixture = makeFixture(columnCount: 3)
        fixture.state.activeColumnIndex = 2
        fixture.state.viewOffset = -(workingExtent - gap - columnSpan)
        let thirdColumnStart = 2 * (columnSpan + gap)
        let viewStart = thirdColumnStart + fixture.state.viewOffset
        let firstColumnPreferredStart = -gap
        let expectedScrollBack = viewStart - firstColumnPreferredStart

        XCTAssertEqual(expectedScrollBack, 240, accuracy: 0.0001)
        XCTAssertEqual(amount(fixture, columnIndex: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(amount(fixture, columnIndex: 0), expectedScrollBack, accuracy: 0.0001)
    }

    func testSingleColumnOffCenterNeedsScrollWhenAlwaysCenterSingleColumn() {
        let fixture = makeFixture(columnCount: 1)
        let centeredViewStart = -(workingExtent - columnSpan) / 2
        let expectedCenterScroll = abs(centeredViewStart - fixture.state.viewOffset)

        XCTAssertEqual(expectedCenterScroll, 290, accuracy: 0.0001)
        XCTAssertEqual(
            amount(fixture, columnIndex: 0, alwaysCenterSingleColumn: true),
            expectedCenterScroll,
            accuracy: 0.0001
        )
        XCTAssertEqual(amount(fixture, columnIndex: 0, alwaysCenterSingleColumn: false), 0, accuracy: 0.0001)
    }

    func testCenterAlwaysScrollsEvenWhenColumnIsFullyVisible() {
        let fixture = makeFixture(columnCount: 3)

        XCTAssertGreaterThan(amount(fixture, columnIndex: 1, centerMode: .always), 0)
    }

    func testVerticalColumnPastTrailingEdgeNeedsScrollAlongVerticalAxis() {
        let fixture = makeFixture(columnCount: 3, orientation: .vertical)

        XCTAssertEqual(amount(fixture, columnIndex: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(amount(fixture, columnIndex: 2), 240, accuracy: 0.0001)
    }

    func testOutOfRangeColumnIndexNeedsNoScroll() {
        let fixture = makeFixture(columnCount: 2)

        XCTAssertEqual(amount(fixture, columnIndex: 5), 0, accuracy: 0.0001)
    }

    func testGeometricAmountMeasuresOverflowAlongScrollAxis() {
        let workingFrame = CGRect(x: 100, y: 50, width: 1000, height: 600)
        let overflowingRight = CGRect(x: 900, y: 60, width: 400, height: 100)
        let overflowingLeft = CGRect(x: 40, y: 60, width: 400, height: 100)
        let overflowingBottom = CGRect(x: 200, y: 600, width: 100, height: 200)
        let inside = CGRect(x: 200, y: 100, width: 300, height: 300)

        XCTAssertEqual(
            NiriHoverScroll.geometricScrollAmount(
                frame: overflowingRight, workingFrame: workingFrame, orientation: .horizontal
            ),
            200,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NiriHoverScroll.geometricScrollAmount(
                frame: overflowingLeft, workingFrame: workingFrame, orientation: .horizontal
            ),
            60,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NiriHoverScroll.geometricScrollAmount(
                frame: overflowingBottom, workingFrame: workingFrame, orientation: .vertical
            ),
            150,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NiriHoverScroll.geometricScrollAmount(
                frame: inside, workingFrame: workingFrame, orientation: .horizontal
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testLimitComparesAmountToPercentOfExtentWithPixelTolerance() {
        let extent: CGFloat = 1000
        let pixelTolerance = 1 / scale

        XCTAssertTrue(NiriHoverScroll.allows(amount: 0, percent: 0, extent: extent, scale: scale))
        XCTAssertTrue(NiriHoverScroll.allows(amount: pixelTolerance, percent: 0, extent: extent, scale: scale))
        XCTAssertFalse(NiriHoverScroll.allows(amount: pixelTolerance + 0.01, percent: 0, extent: extent, scale: scale))
        XCTAssertTrue(NiriHoverScroll.allows(amount: 300, percent: 50, extent: extent, scale: scale))
        XCTAssertFalse(NiriHoverScroll.allows(amount: 300, percent: 20, extent: extent, scale: scale))
        XCTAssertTrue(NiriHoverScroll.allows(amount: 200, percent: 20, extent: extent, scale: scale))
    }
}
