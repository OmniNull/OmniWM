// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleResizeDirectionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 800)
    private let step: CGFloat = 0.1

    /// root = H( V( H(bottomLeft, bottomRight), top ), right )
    private struct Fixture {
        let engine: DwindleLayoutEngine
        let ws: WorkspaceDescriptor.ID
        let bottomLeft: WindowToken
        let bottomRight: WindowToken
        let top: WindowToken
        let right: WindowToken

        var root: DwindleNode? { engine.root(for: ws) }
        var leftColumn: DwindleNode? { engine.findNode(for: top, in: ws)?.parent }
        var bottomRow: DwindleNode? { engine.findNode(for: bottomLeft, in: ws)?.parent }

        func select(_ token: WindowToken) {
            engine.setSelectedNode(engine.findNode(for: token, in: ws), in: ws)
        }

        func ratios() -> [CGFloat?] {
            [root?.splitRatio, leftColumn?.splitRatio, bottomRow?.splitRatio]
        }
    }

    private func makeFixture(file: StaticString = #filePath, line: UInt = #line) -> Fixture {
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()
        let bottomLeft = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        let top = WindowToken(pid: 3, windowId: 3)
        let bottomRight = WindowToken(pid: 4, windowId: 4)
        let fixture = Fixture(
            engine: engine, ws: ws, bottomLeft: bottomLeft, bottomRight: bottomRight, top: top, right: right
        )

        _ = engine.addWindow(token: bottomLeft, to: ws, activeWindowFrame: nil)
        for (token, direction) in [(right, Direction.right), (top, .up), (bottomRight, .right)] {
            fixture.select(bottomLeft)
            XCTAssertTrue(engine.setPreselection(direction, in: ws), file: file, line: line)
            _ = engine.addWindow(token: token, to: ws, activeWindowFrame: nil)
        }
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertEqual(fixture.root?.splitOrientation, .horizontal, file: file, line: line)
        XCTAssertTrue(fixture.leftColumn?.isFirstChild(of: fixture.root!) ?? false, file: file, line: line)
        XCTAssertEqual(fixture.leftColumn?.splitOrientation, .vertical, file: file, line: line)
        XCTAssertTrue(fixture.bottomRow?.isFirstChild(of: fixture.leftColumn!) ?? false, file: file, line: line)
        XCTAssertEqual(fixture.bottomRow?.splitOrientation, .horizontal, file: file, line: line)
        XCTAssertTrue(
            engine.findNode(for: bottomRight, in: ws)?.isFirstChild(of: fixture.bottomRow!) == false,
            file: file,
            line: line
        )
        XCTAssertEqual(fixture.ratios(), [1.0, 1.0, 1.0], file: file, line: line)
        return fixture
    }

    func testMovesRightBorderOwnedByAncestorSplit() {
        let cases: [(Direction, CGFloat)] = [(.right, 1.1), (.left, 0.9)]
        for (direction, expectedRoot) in cases {
            let fixture = makeFixture()
            fixture.select(fixture.bottomRight)
            XCTAssertTrue(fixture.engine.resizeSelected(toward: direction, by: step, in: fixture.ws), "\(direction)")
            XCTAssertEqual(fixture.ratios(), [expectedRoot, 1.0, 1.0], "\(direction)")
        }
    }

    func testMovesNearestRightBorderWhenItBelongsToParent() {
        let cases: [(Direction, CGFloat)] = [(.right, 1.1), (.left, 0.9)]
        for (direction, expectedRow) in cases {
            let fixture = makeFixture()
            fixture.select(fixture.bottomLeft)
            XCTAssertTrue(fixture.engine.resizeSelected(toward: direction, by: step, in: fixture.ws), "\(direction)")
            XCTAssertEqual(fixture.ratios(), [1.0, 1.0, expectedRow], "\(direction)")
        }
    }

    func testFallsBackToLeftBorderWithoutRightNeighbour() {
        let cases: [(Direction, CGFloat)] = [(.right, 1.1), (.left, 0.9)]
        for (direction, expectedRoot) in cases {
            let fixture = makeFixture()
            fixture.select(fixture.right)
            XCTAssertTrue(fixture.engine.resizeSelected(toward: direction, by: step, in: fixture.ws), "\(direction)")
            XCTAssertEqual(fixture.ratios(), [expectedRoot, 1.0, 1.0], "\(direction)")
        }
    }

    func testVerticalMovesBottomBorderThenFallsBackToTopBorder() {
        let cases: [(Direction, CGFloat)] = [(.up, 1.1), (.down, 0.9)]
        for (direction, expectedColumn) in cases {
            let fixture = makeFixture()
            fixture.select(fixture.top)
            XCTAssertTrue(fixture.engine.resizeSelected(toward: direction, by: step, in: fixture.ws), "\(direction)")
            XCTAssertEqual(fixture.ratios(), [1.0, expectedColumn, 1.0], "top \(direction)")

            let fallback = makeFixture()
            fallback.select(fallback.bottomRight)
            XCTAssertTrue(fallback.engine.resizeSelected(toward: direction, by: step, in: fallback.ws), "\(direction)")
            XCTAssertEqual(fallback.ratios(), [1.0, expectedColumn, 1.0], "bottom \(direction)")
        }
    }

    func testNoSplitOnAxisReturnsFalse() {
        let fixture = makeFixture()
        fixture.select(fixture.right)
        XCTAssertFalse(fixture.engine.resizeSelected(toward: .up, by: step, in: fixture.ws))
        XCTAssertEqual(fixture.ratios(), [1.0, 1.0, 1.0])
    }

    func testStopsAtRatioLimit() {
        let fixture = makeFixture()
        fixture.select(fixture.bottomRight)
        var changed = true
        for _ in 0 ..< 100 where changed {
            changed = fixture.engine.resizeSelected(toward: .right, by: step, in: fixture.ws)
        }
        XCTAssertFalse(fixture.engine.resizeSelected(toward: .right, by: step, in: fixture.ws))
        XCTAssertTrue(fixture.engine.resizeSelected(toward: .left, by: step, in: fixture.ws))
    }
}
