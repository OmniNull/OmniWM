// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriAccordionGeometryTests: XCTestCase {
    private func pairs(_ insets: [NiriAccordionInset]) -> [[CGFloat]] {
        insets.map { [$0.leading, $0.trailing] }
    }

    func testSingleWindowHasNoInset() {
        XCTAssertEqual(pairs(NiriAccordionGeometry.insets(count: 1, activeIndex: 0, padding: 30, span: 800)), [[0, 0]])
    }

    func testEmptyColumnHasNoInsets() {
        XCTAssertTrue(NiriAccordionGeometry.insets(count: 0, activeIndex: 0, padding: 30, span: 800).isEmpty)
    }

    func testTwoWindowsPeekOnOppositeSides() {
        XCTAssertEqual(
            pairs(NiriAccordionGeometry.insets(count: 2, activeIndex: 0, padding: 30, span: 800)),
            [[0, 30], [30, 0]]
        )
    }

    func testThreeWindowsActiveInMiddle() {
        XCTAssertEqual(
            pairs(NiriAccordionGeometry.insets(count: 3, activeIndex: 1, padding: 30, span: 800)),
            [[0, 30], [30, 30], [30, 0]]
        )
    }

    func testFiveWindowsActiveInMiddleNeighborsGetDoublePadding() {
        XCTAssertEqual(
            pairs(NiriAccordionGeometry.insets(count: 5, activeIndex: 2, padding: 30, span: 800)),
            [[0, 30], [0, 60], [30, 30], [60, 0], [30, 0]]
        )
    }

    func testFiveWindowsActiveFirst() {
        XCTAssertEqual(
            pairs(NiriAccordionGeometry.insets(count: 5, activeIndex: 0, padding: 30, span: 800)),
            [[0, 30], [60, 0], [30, 30], [30, 30], [30, 0]]
        )
    }

    func testFiveWindowsActiveLast() {
        XCTAssertEqual(
            pairs(NiriAccordionGeometry.insets(count: 5, activeIndex: 4, padding: 30, span: 800)),
            [[0, 30], [30, 30], [30, 30], [0, 60], [30, 0]]
        )
    }

    func testOutOfRangeActiveIndexIsClamped() {
        XCTAssertEqual(
            NiriAccordionGeometry.insets(count: 3, activeIndex: 9, padding: 30, span: 800),
            NiriAccordionGeometry.insets(count: 3, activeIndex: 2, padding: 30, span: 800)
        )
    }

    func testZeroPaddingGivesNoInset() {
        XCTAssertEqual(
            pairs(NiriAccordionGeometry.insets(count: 3, activeIndex: 1, padding: 0, span: 800)),
            [[0, 0], [0, 0], [0, 0]]
        )
    }

    func testNegativePaddingIsTreatedAsZero() {
        XCTAssertEqual(
            pairs(NiriAccordionGeometry.insets(count: 2, activeIndex: 0, padding: -5, span: 800)),
            [[0, 0], [0, 0]]
        )
    }

    func testPaddingClampsSoEveryWindowKeepsRenderableSpan() {
        let span: CGFloat = 41
        let insets = NiriAccordionGeometry.insets(count: 5, activeIndex: 2, padding: 30, span: span)
        for inset in insets {
            XCTAssertGreaterThanOrEqual(
                span - inset.leading - inset.trailing,
                NiriAxisSolver.minimumRenderableSpan
            )
        }
        XCTAssertEqual(insets[2].leading, 20)
    }

    func testApplyHorizontalMovesX() {
        let rect = CGRect(x: 100, y: 50, width: 600, height: 400)
        let result = NiriAccordionGeometry.apply(
            NiriAccordionInset(leading: 30, trailing: 60), to: rect, axis: .horizontal
        )
        XCTAssertEqual(result, CGRect(x: 130, y: 50, width: 510, height: 400))
    }

    func testApplyVerticalMovesY() {
        let rect = CGRect(x: 100, y: 50, width: 600, height: 400)
        let result = NiriAccordionGeometry.apply(
            NiriAccordionInset(leading: 30, trailing: 60), to: rect, axis: .vertical
        )
        XCTAssertEqual(result, CGRect(x: 100, y: 80, width: 600, height: 310))
    }
}
