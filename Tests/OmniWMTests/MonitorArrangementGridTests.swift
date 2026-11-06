// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MonitorArrangementGridTests: XCTestCase {
    func testNearestCellRoundTripsCellFrameCenters() {
        let canvas = CGSize(width: 400, height: 300)
        let spacing: CGFloat = 8
        let fit = MonitorArrangementGeometry.gridFit(columns: 3, rows: 2, in: canvas, padding: 12, spacing: spacing)
        for column in 0 ..< 3 {
            for row in 0 ..< 2 {
                let frame = MonitorArrangementGeometry.cellFrame(column: column, row: row, fit: fit, spacing: spacing)
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let nearest = MonitorArrangementGeometry.nearestCell(toPoint: center, fit: fit, spacing: spacing)
                XCTAssertEqual(nearest.column, column)
                XCTAssertEqual(nearest.row, row)
            }
        }
    }

    func testGridFitProducesSquareCellsWithinCanvas() {
        let canvas = CGSize(width: 400, height: 300)
        let fit = MonitorArrangementGeometry.gridFit(columns: 2, rows: 2, in: canvas, padding: 10, spacing: 6)
        XCTAssertEqual(fit.cellSize.width, fit.cellSize.height)
        XCTAssertGreaterThan(fit.cellSize.width, 0)
        let last = MonitorArrangementGeometry.cellFrame(column: 1, row: 1, fit: fit, spacing: 6)
        XCTAssertLessThanOrEqual(last.maxX, canvas.width - 10 + 0.001)
        XCTAssertLessThanOrEqual(last.maxY, canvas.height - 10 + 0.001)
    }

    func testNearestCellHandlesDegenerateFit() {
        let fit = MonitorArrangementGeometry.gridFit(columns: 1, rows: 1, in: .zero, padding: 0, spacing: 0)
        let nearest = MonitorArrangementGeometry.nearestCell(toPoint: .zero, fit: fit, spacing: 0)
        XCTAssertEqual(nearest.column, 0)
        XCTAssertEqual(nearest.row, 0)
    }
}
