// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleCenteredResizeTests: XCTestCase {
    func testCenteredResizeCrossesAnIntermediateMinimumClampAndReversesOnBothAxes() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation)
            let originalBranch = fixture.extent / 2
            let originalInner = 7 * originalBranch / 16
            let originalTarget = originalInner / 4
            try fixture.assertLayout(
                left: originalBranch, target: originalTarget,
                near: originalInner - originalTarget, far: 9 * originalBranch / 16
            )
            XCTAssertTrue(fixture.begin())
            let breakpoint = originalBranch / 8
            XCTAssertTrue(fixture.update(halfGrowth: breakpoint))
            try fixture.assertLayout(
                left: originalBranch - breakpoint,
                target: originalTarget + 2 * breakpoint,
                near: 9 * originalBranch / 16 - originalTarget - 2 * breakpoint,
                far: 9 * originalBranch / 16
            )
            let halfGrowth = 3 * originalBranch / 16
            XCTAssertTrue(fixture.update(halfGrowth: halfGrowth))
            try fixture.assertLayout(
                left: originalBranch - halfGrowth, target: 31 * originalBranch / 64,
                near: 7 * originalBranch / 64, far: 19 * originalBranch / 32
            )
            XCTAssertEqual(fixture.outer.splitRatio, 2 * (originalBranch - halfGrowth) / fixture.extent)
            XCTAssertEqual(fixture.intermediate.splitRatio, 1)
            XCTAssertEqual(fixture.inner.splitRatio, 2 * 31 / CGFloat(38))
            XCTAssertTrue(fixture.update(halfGrowth: 0))
            XCTAssertEqual(fixture.outer.splitRatio, 1)
            XCTAssertEqual(fixture.intermediate.splitRatio, 1)
            XCTAssertEqual(fixture.inner.splitRatio, 0.5)
            try fixture.assertLayout(
                left: originalBranch, target: originalTarget,
                near: originalInner - originalTarget, far: 9 * originalBranch / 16
            )
            XCTAssertTrue(fixture.engine.interactiveResizeEnd())
            XCTAssertNil(fixture.engine.interactiveResize)
        }
    }
}

private extension DwindleCenteredResizeTests {
    struct CornerFixture {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let screen = CGRect(x: 160, y: 96, width: 2048, height: 1536)
        let left = WindowToken(pid: 1, windowId: 1)
        let bottom = WindowToken(pid: 1, windowId: 2)
        let target = WindowToken(pid: 1, windowId: 3)
        let right = WindowToken(pid: 1, windowId: 4)
        let top = WindowToken(pid: 1, windowId: 5)
        let fixedHorizontal: Bool

        init(fixedHorizontal: Bool) {
            self.fixedHorizontal = fixedHorizontal
            if !fixedHorizontal {
                engine.addWindow(token: left, to: workspace, activeWindowFrame: nil)
                engine.setPreselection(.right, in: workspace)
            }
            engine.addWindow(token: bottom, to: workspace, activeWindowFrame: nil)
            engine.setPreselection(.up, in: workspace)
            engine.addWindow(token: target, to: workspace, activeWindowFrame: nil)
            engine.setPreselection(.right, in: workspace)
            engine.addWindow(token: right, to: workspace, activeWindowFrame: nil)
            engine.setSelectedNode(engine.findNode(for: target, in: workspace), in: workspace)
            engine.setPreselection(.up, in: workspace)
            engine.addWindow(token: top, to: workspace, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspace, screen: screen)
        }

        func assertLayout(dx: CGFloat, dy: CGFloat) throws {
            let frames = engine.calculateLayout(for: workspace, screen: screen)
            let leftWidth = fixedHorizontal ? 0 : screen.width / 2 - dx
            let rightWidth = fixedHorizontal ? screen.width / 2 : screen.width / 4 - dx
            let targetWidth = screen.width - leftWidth - rightWidth
            let bottomHeight = screen.height / 2 - dy
            let targetHeight = screen.height / 4 + 2 * dy
            let topHeight = screen.height / 4 - dy
            var rectangles = [
                (bottom, CGRect(
                    x: screen.minX + leftWidth,
                    y: screen.minY,
                    width: screen.width - leftWidth,
                    height: bottomHeight
                )),
                (target, CGRect(
                    x: screen.minX + leftWidth,
                    y: screen.minY + bottomHeight,
                    width: targetWidth,
                    height: targetHeight
                )),
                (right, CGRect(
                    x: screen.maxX - rightWidth,
                    y: screen.minY + bottomHeight,
                    width: rightWidth,
                    height: screen.height - bottomHeight
                )),
                (top, CGRect(
                    x: screen.minX + leftWidth,
                    y: screen.maxY - topHeight,
                    width: targetWidth,
                    height: topHeight
                ))
            ]
            if !fixedHorizontal {
                rectangles.append((
                    left,
                    CGRect(x: screen.minX, y: screen.minY, width: leftWidth, height: screen.height)
                ))
            }
            XCTAssertEqual(frames.count, rectangles.count)
            for (token, raw) in rectangles {
                XCTAssertEqual(try XCTUnwrap(frames[token]), DwindleGapCalculator.applyGaps(
                    nodeRect: raw, tilingArea: screen, settings: engine.settings
                ))
            }
        }
    }
}

extension DwindleCenteredResizeTests {
    func testThreeLeafResizeKeepsItsCenterWithEitherOuterBoundary() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for mirrored in [false, true] {
                let fixture = try Fixture(orientation: orientation, nested: false, mirrored: mirrored)
                try fixture.assertLinearLayout(halfGrowth: 0)
                XCTAssertTrue(fixture.begin())
                for halfGrowth in [fixture.extent / 16, -fixture.extent / 32, 0] {
                    XCTAssertTrue(fixture.update(halfGrowth: halfGrowth))
                    try fixture.assertUnconstrainedLinearLayout(halfGrowth: halfGrowth)
                }
                try fixture.assertLinearLayout(halfGrowth: 0)
                XCTAssertEqual(fixture.outer.splitRatio, 1)
                XCTAssertEqual(fixture.inner.splitRatio, 1)
                XCTAssertTrue(fixture.engine.interactiveResizeEnd())
            }
        }
    }

    func testAsymmetricNeighborMinimumStopsBothBoundariesTogetherAndReverses() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for mirrored in [false, true] {
                let fixture = try Fixture(orientation: orientation, nested: false, mirrored: mirrored)
                let limit = fixture.extent / 32
                let halfGap = fixture.engine.settings.innerGap / 2
                fixture.setMinimum(fixture.left, extent: fixture.initialLeft - limit - halfGap)
                fixture.setMinimum(fixture.near, extent: fixture.initialNear - 2 * limit - halfGap)
                _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
                XCTAssertTrue(fixture.begin())
                XCTAssertTrue(fixture.update(halfGrowth: 4 * limit))
                try fixture.assertLinearLayout(halfGrowth: limit)
                XCTAssertFalse(fixture.update(halfGrowth: 4 * limit))
                XCTAssertTrue(fixture.update(halfGrowth: 0))
                try fixture.assertLinearLayout(halfGrowth: 0)
                XCTAssertEqual(fixture.outer.splitRatio, 1)
                XCTAssertEqual(fixture.inner.splitRatio, 1)
                XCTAssertTrue(fixture.engine.interactiveResizeEnd())
            }
        }
    }

    func testCenteredCornerMovesBothAxesButKeepsAFixedOuterAxisStationary() throws {
        for fixedHorizontal in [false, true] {
            let fixture = CornerFixture(fixedHorizontal: fixedHorizontal)
            XCTAssertTrue(fixture.engine.interactiveResizeBegin(
                token: fixture.target, edges: .all, startLocation: fixture.screen.center,
                in: fixture.workspace, innerGap: fixture.engine.settings.innerGap, allowsCentered: true
            ))
            let dx = fixture.screen.width / 32
            let dy = fixture.screen.height / 32
            XCTAssertTrue(fixture.engine.interactiveResizeUpdate(currentLocation: CGPoint(
                x: fixture.screen.midX - dx, y: fixture.screen.midY - dy
            )))
            try fixture.assertLayout(dx: fixedHorizontal ? 0 : dx, dy: dy)
            XCTAssertTrue(fixture.engine.interactiveResizeUpdate(currentLocation: fixture.screen.center))
            try fixture.assertLayout(dx: 0, dy: 0)
            XCTAssertTrue(fixture.engine.interactiveResizeEnd())
        }
    }

    func testExcludedIntermediateBranchDoesNotConstrainCenteredProjection() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation)
            fixture.engine.setExcludedTokens([fixture.far], in: fixture.workspace)
            _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
            let branch = fixture.extent / 2
            XCTAssertTrue(fixture.begin())
            let halfGrowth = branch / 8
            XCTAssertTrue(fixture.update(halfGrowth: halfGrowth))
            try fixture.assertLayout(
                left: branch - halfGrowth, target: branch / 4 + 2 * halfGrowth,
                near: 3 * branch / 4 - halfGrowth
            )
            XCTAssertEqual(fixture.intermediate.splitRatio, 1)
            XCTAssertTrue(fixture.update(halfGrowth: 0))
            try fixture.assertLayout(left: branch, target: branch / 4, near: 3 * branch / 4)
            XCTAssertEqual(fixture.inner.splitRatio, 0.5)
            XCTAssertTrue(fixture.engine.interactiveResizeEnd())
        }
    }

    func testGroupedNeighborIncludesInactiveMinimumAndRailInCenteredLimit() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation, nested: false)
            fixture.select(fixture.near, direction: fixture.horizontal ? .up : .right)
            fixture.engine.addWindow(token: fixture.far, to: fixture.workspace, activeWindowFrame: nil)
            XCTAssertTrue(fixture.engine.groupWindow(fixture.far, into: fixture.near, in: fixture.workspace))
            let limit = fixture.extent / 32
            let rail = fixture.horizontal ? fixture.engine.tabRailWidth : 0
            fixture.setMinimum(
                fixture.far, extent: fixture.initialNear - limit - fixture.engine.settings.innerGap / 2 - rail
            )
            let tile = try XCTUnwrap(fixture.engine.findNode(for: fixture.near, in: fixture.workspace)?.tile)
            XCTAssertTrue(tile.activate(fixture.near))
            _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
            XCTAssertTrue(fixture.begin())
            XCTAssertTrue(fixture.update(halfGrowth: 4 * limit))
            try fixture.assertLinearLayout(halfGrowth: limit, grouped: fixture.near)
            XCTAssertEqual(tile.activeToken, fixture.near)
            XCTAssertTrue(fixture.update(halfGrowth: 0))
            try fixture.assertLinearLayout(halfGrowth: 0, grouped: fixture.near)
            XCTAssertTrue(fixture.engine.interactiveResizeEnd())
        }
    }

    func testChangedControllingChildIdentityWritesNeitherCapturedRatio() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for mirrored in [false, true] {
                let fixture = try Fixture(orientation: orientation, nested: false, mirrored: mirrored)
                XCTAssertTrue(fixture.begin())
                fixture.select(fixture.target, direction: fixture.horizontal ? .right : .up)
                fixture.engine.addWindow(token: fixture.far, to: fixture.workspace, activeWindowFrame: nil)
                _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
                XCTAssertFalse(fixture.update(halfGrowth: fixture.extent / 16))
                XCTAssertEqual(fixture.outer.splitRatio, 1)
                XCTAssertEqual(fixture.inner.splitRatio, 1)
                XCTAssertEqual(
                    fixture.engine.findNode(for: fixture.target, in: fixture.workspace)?.parent?.splitRatio,
                    1
                )
                XCTAssertFalse(fixture.engine.interactiveResizeEnd())
            }
        }
    }
}

private extension DwindleCenteredResizeTests {
    struct Fixture {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let screen = CGRect(x: 160, y: 96, width: 2048, height: 1536)
        let left = WindowToken(pid: 1, windowId: 1)
        let target = WindowToken(pid: 1, windowId: 2)
        let near = WindowToken(pid: 1, windowId: 3)
        let far = WindowToken(pid: 1, windowId: 4)
        let orientation: DwindleOrientation
        let mirrored: Bool
        let outer: DwindleNode
        let intermediate: DwindleNode
        let inner: DwindleNode

        var horizontal: Bool {
            orientation == .horizontal
        }

        var extent: CGFloat {
            horizontal ? screen.width : screen.height
        }

        var start: CGPoint {
            screen.center
        }

        var pairedEdges: ResizeEdge {
            horizontal ? [.left, .right] : [.bottom, .top]
        }

        var initialLeft: CGFloat {
            extent / (mirrored ? 4 : 2)
        }

        var initialNear: CGFloat {
            extent / (mirrored ? 2 : 4)
        }

        init(orientation: DwindleOrientation, nested: Bool = true, mirrored: Bool = false) throws {
            self.orientation = orientation
            self.mirrored = mirrored
            let forward: Direction = orientation == .horizontal ? .right : .up
            engine.addWindow(token: left, to: workspace, activeWindowFrame: nil)
            engine.setPreselection(forward, in: workspace)
            engine.addWindow(token: mirrored ? near : target, to: workspace, activeWindowFrame: nil)
            if nested {
                engine.setPreselection(forward, in: workspace)
                engine.addWindow(token: far, to: workspace, activeWindowFrame: nil)
            }
            engine.setSelectedNode(engine.findNode(for: mirrored ? left : target, in: workspace), in: workspace)
            engine.setPreselection(forward, in: workspace)
            engine.addWindow(token: mirrored ? target : near, to: workspace, activeWindowFrame: nil)
            outer = try XCTUnwrap(engine.root(for: workspace))
            inner = try XCTUnwrap(engine.findNode(for: target, in: workspace)?.parent)
            intermediate = try XCTUnwrap(inner.parent)
            inner.kind = .split(orientation: orientation, ratio: nested ? 0.5 : 1)
            if nested {
                let axisExtent = orientation == .horizontal ? screen.width : screen.height
                let farMinimum = 9 * (axisExtent / 2) / 16 - engine.settings.innerGap / 2
                engine.updateWindowConstraints(for: far, constraints: WindowSizeConstraints(
                    minSize: CGSize(
                        width: orientation == .horizontal ? farMinimum : 1,
                        height: orientation == .vertical ? farMinimum : 1
                    ),
                    maxSize: .zero, isFixed: false
                ))
            }
            _ = engine.calculateLayout(for: workspace, screen: screen)
        }

        func begin(edges: ResizeEdge? = nil) -> Bool {
            engine.interactiveResizeBegin(
                token: target, edges: edges ?? pairedEdges, startLocation: start,
                in: workspace, innerGap: engine.settings.innerGap,
                edgePolicy: .exact, allowsCentered: true
            )
        }

        func update(halfGrowth: CGFloat) -> Bool {
            engine.interactiveResizeUpdate(currentLocation: CGPoint(
                x: start.x - (horizontal ? halfGrowth : 0),
                y: start.y - (horizontal ? 0 : halfGrowth)
            ))
        }

        func assertLayout(
            left leftExtent: CGFloat, target targetExtent: CGFloat,
            near nearExtent: CGFloat, far farExtent: CGFloat? = nil, grouped: WindowToken? = nil,
            file: StaticString = #filePath, line: UInt = #line
        ) throws {
            let frames = engine.calculateLayout(for: workspace, screen: screen)
            var offset: CGFloat = 0
            var spans = [(left, leftExtent), (target, targetExtent), (near, nearExtent)]
            if let farExtent { spans.append((far, farExtent)) }
            XCTAssertEqual(frames.count, spans.count, file: file, line: line)
            for (token, length) in spans {
                let raw = CGRect(
                    x: screen.minX + (horizontal ? offset : 0),
                    y: screen.minY + (horizontal ? 0 : offset),
                    width: horizontal ? length : screen.width,
                    height: horizontal ? screen.height : length
                )
                var expected = DwindleGapCalculator.applyGaps(
                    nodeRect: raw, tilingArea: screen, settings: engine.settings
                )
                if grouped == token {
                    expected.origin.x += engine.tabRailWidth
                    expected.size.width -= engine.tabRailWidth
                }
                XCTAssertEqual(try XCTUnwrap(frames[token], file: file, line: line), expected, file: file, line: line)
                offset += length
            }
            XCTAssertEqual(offset, extent, file: file, line: line)
        }

        func select(_ token: WindowToken, direction: Direction) {
            engine.setSelectedNode(engine.findNode(for: token, in: workspace), in: workspace)
            engine.setPreselection(direction, in: workspace)
        }

        func setMinimum(_ token: WindowToken, extent: CGFloat) {
            engine.updateWindowConstraints(for: token, constraints: WindowSizeConstraints(
                minSize: CGSize(width: horizontal ? extent : 1, height: horizontal ? 1 : extent),
                maxSize: .zero, isFixed: false
            ))
        }

        func assertLinearLayout(halfGrowth: CGFloat, grouped: WindowToken? = nil) throws {
            try assertLayout(
                left: initialLeft - halfGrowth, target: extent / 4 + 2 * halfGrowth,
                near: initialNear - halfGrowth, grouped: grouped
            )
        }

        func assertUnconstrainedLinearLayout(halfGrowth: CGFloat) throws {
            let branchExtent = extent / 2 + halfGrowth
            let targetExtent = extent / 4 + 2 * halfGrowth
            let branchFraction = branchExtent / extent
            let targetFraction = targetExtent / branchExtent
            let outerRatio = 2 * (mirrored ? branchFraction : 1 - branchFraction)
            let innerRatio = 2 * (mirrored ? 1 - targetFraction : targetFraction)
            let outerFrames = engine.splitRect(
                screen, orientation: orientation, ratio: outerRatio,
                minimums: (first: .zero, second: .zero)
            )
            let innerFrames = engine.splitRect(
                mirrored ? outerFrames.0 : outerFrames.1, orientation: orientation, ratio: innerRatio,
                minimums: (first: .zero, second: .zero)
            )
            let rawFrames = mirrored
                ? [(left, innerFrames.0), (target, innerFrames.1), (near, outerFrames.1)]
                : [(left, outerFrames.0), (target, innerFrames.0), (near, innerFrames.1)]
            let frames = engine.calculateLayout(for: workspace, screen: screen)
            XCTAssertEqual(frames.count, rawFrames.count)
            XCTAssertEqual(outer.splitRatio, outerRatio)
            XCTAssertEqual(inner.splitRatio, innerRatio)
            for (token, raw) in rawFrames {
                XCTAssertEqual(try XCTUnwrap(frames[token]), DwindleGapCalculator.applyGaps(
                    nodeRect: raw, tilingArea: screen, settings: engine.settings
                ))
            }
            XCTAssertEqual(try XCTUnwrap(frames[target]).center, CGPoint(
                x: horizontal ? screen.minX + initialLeft + extent / 8 : screen.midX,
                y: horizontal ? screen.midY : screen.minY + initialLeft + extent / 8
            ))
        }
    }
}
