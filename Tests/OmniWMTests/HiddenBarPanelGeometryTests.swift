// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarPanelGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testCentersUnderAnchor() {
        let frame = PopupAttachment(anchor: CGPoint(x: 720, y: 900))
            .frame(size: CGSize(width: 200, height: 60), visibleFrame: screen)
        XCTAssertEqual(frame.midX, 720, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 896, accuracy: 0.5)
    }

    func testClampsRightEdge() {
        let frame = PopupAttachment(anchor: CGPoint(x: 1435, y: 900))
            .frame(size: CGSize(width: 200, height: 60), visibleFrame: screen)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - 8 + 0.5)
    }

    func testClampsLeftEdge() {
        let frame = PopupAttachment(anchor: CGPoint(x: 5, y: 900))
            .frame(size: CGSize(width: 200, height: 60), visibleFrame: screen)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + 8 - 0.5)
    }

    func testNarrowScreenPinsToMinX() {
        let narrow = CGRect(x: 100, y: 0, width: 150, height: 900)
        let frame = PopupAttachment(anchor: CGPoint(x: 175, y: 900))
            .frame(size: CGSize(width: 200, height: 60), visibleFrame: narrow)
        XCTAssertEqual(frame.minX, narrow.minX + 8, accuracy: 0.5)
    }

    func testBarSizeEmptyIsCompact() {
        let size = HiddenBarPanelController.barSize(
            itemWidths: [],
            rowHeight: 24,
            maxContentWidth: 600,
            spacing: 8,
            padding: 8
        )
        XCTAssertEqual(size, CGSize(width: 140, height: 40))
    }

    func testBarSizeSingleRowWhenItemsFit() {
        let size = HiddenBarPanelController.barSize(
            itemWidths: [30, 30, 30],
            rowHeight: 24,
            maxContentWidth: 600,
            spacing: 8,
            padding: 8
        )
        XCTAssertEqual(size, CGSize(width: 30 * 3 + 8 * 2 + 16, height: 24 + 16))
    }

    func testBarSizeWrapsWhenExceedingMaxWidth() {
        let size = HiddenBarPanelController.barSize(
            itemWidths: [30, 30, 30],
            rowHeight: 24,
            maxContentWidth: 70,
            spacing: 8,
            padding: 8
        )
        XCTAssertEqual(size.height, 24 * 2 + 8 + 16)
        XCTAssertEqual(size.width, 30 + 8 + 30 + 16)
    }

    func testRowRangesGreedyBoundaries() {
        let ranges = HiddenBarPanelController.rowRanges(
            itemWidths: [30, 30, 30],
            maxContentWidth: 70,
            spacing: 8
        )
        XCTAssertEqual(ranges, [0 ..< 2, 2 ..< 3])
    }

    func testRowRangesOversizeItemGetsOwnRow() {
        let ranges = HiddenBarPanelController.rowRanges(
            itemWidths: [200, 30],
            maxContentWidth: 100,
            spacing: 8
        )
        XCTAssertEqual(ranges, [0 ..< 1, 1 ..< 2])
    }

    func testGlyphDisplayWidthScalesDownTallGlyphs() {
        let width = HiddenBarPanelController.glyphDisplayWidth(
            for: CGSize(width: 40, height: 40),
            rowHeight: 24
        )
        XCTAssertEqual(width, 24)
    }

    func testGlyphDisplayWidthGuaranteesMinimumTarget() {
        let width = HiddenBarPanelController.glyphDisplayWidth(
            for: CGSize(width: 16, height: 16),
            rowHeight: 24
        )
        XCTAssertEqual(width, 24)
    }
}
