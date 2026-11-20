// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleEdgeExpansionTests: XCTestCase {
    func testEveryEdgeExpandsToNeighborMinimumAndRestoresAcrossTheNormalRatioLimit() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for first in [false, true] {
                for divisor: CGFloat in [64, 4] {
                    let fixture = try Fixture(orientation: orientation, targetFirst: first, minimumDivisor: divisor)
                    try fixture.assertTwoLeafLayout(ratio: 1)
                    XCTAssertTrue(fixture.toggle())
                    XCTAssertEqual(fixture.root.splitRatio, fixture.endpoint)
                    try fixture.assertTwoLeafLayout(ratio: fixture.endpoint)
                    XCTAssertTrue(fixture.toggle())
                    XCTAssertEqual(fixture.root.splitRatio, 1)
                    XCTAssertNil(fixture.root.edgeExpansion)
                    try fixture.assertTwoLeafLayout(ratio: 1)
                }
            }
        }
    }

    func testNativeResizeUsesItsExpandedOriginForInwardMotionAndExactReturn() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for first in [false, true] {
                for centeredSingle in [false, true] {
                    let fixture = try Fixture(orientation: orientation, targetFirst: first)
                    var edges = fixture.edge
                    if centeredSingle {
                        fixture.insert(
                            Fixture.extra,
                            beside: fixture.target,
                            direction: fixture.horizontal ? .down : .left
                        )
                        fixture.insert(
                            Fixture.other,
                            beside: fixture.target,
                            direction: fixture.horizontal ? .up : .right
                        )
                        edges.formUnion(fixture.horizontal ? [.top, .bottom] : [.left, .right])
                    }
                    _ = fixture.layout()
                    XCTAssertTrue(fixture.toggle())
                    _ = fixture.layout()
                    XCTAssertTrue(fixture.begin(edges: edges, allowsCentered: centeredSingle))
                    let inward = (first ? -fixture.extent : fixture.extent) / 128
                    XCTAssertTrue(fixture.update(delta: inward))
                    XCTAssertEqual(fixture.root.splitRatio, fixture.endpoint + 2 * inward / fixture.extent)
                    XCTAssertTrue(fixture.update(delta: 0))
                    XCTAssertEqual(fixture.root.splitRatio, fixture.endpoint)
                    XCTAssertTrue(fixture.engine.interactiveResizeEnd())
                    XCTAssertNil(fixture.engine.interactiveResize)
                    XCTAssertTrue(fixture.toggle())
                    XCTAssertEqual(fixture.root.splitRatio, 1)
                }
            }
        }
    }

    func testKeyboardResizeStartsFreshExpansionWithoutRestoringAnObsoleteRatio() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for first in [false, true] {
                for focused in [false, true] {
                    let fixture = try Fixture(orientation: orientation, targetFirst: first)
                    fixture.engine.setSelectedNode(
                        fixture.engine.findNode(for: fixture.target, in: fixture.workspace),
                        in: fixture.workspace
                    )
                    XCTAssertTrue(fixture.toggle())
                    _ = fixture.layout()
                    XCTAssertTrue(fixture.resizeCommand(by: -1 / 64, focused: focused))
                    let inwardRatio = fixture.endpoint + (first ? -1 : 1) / 64
                    XCTAssertEqual(fixture.root.splitRatio, inwardRatio)
                    XCTAssertFalse(fixture.resizeCommand(by: 1 / 64, focused: focused))
                    XCTAssertEqual(fixture.root.splitRatio, inwardRatio)
                    XCTAssertTrue(fixture.toggle())
                    XCTAssertEqual(fixture.root.splitRatio, fixture.endpoint)
                    XCTAssertTrue(fixture.toggle())
                    XCTAssertEqual(fixture.root.splitRatio, inwardRatio)
                    try fixture.assertTwoLeafLayout(ratio: inwardRatio)
                }
            }
        }
    }

    func testCenteredPairReturnsToItsExpandedBoundaryWithoutRatchet() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation, targetFirst: false)
            fixture.insert(Fixture.extra, beside: fixture.target, direction: fixture.forward)
            let branch = fixture.extent / 2
            let minimum = branch / 64
            fixture.setMinimum(Fixture.extra, contentExtent: minimum - fixture.engine.settings.innerGap / 2)
            _ = fixture.layout()
            let inner = try XCTUnwrap(fixture.engine.findNode(for: fixture.target, in: fixture.workspace)?.parent)
            XCTAssertTrue(fixture.engine.toggleEdgeExpansion(
                for: fixture.target,
                edge: fixture.forwardEdge,
                in: fixture.workspace
            ))
            _ = fixture.layout()
            let expanded = 2 * (branch - minimum) / branch
            XCTAssertEqual(inner.splitRatio, expanded)
            XCTAssertTrue(fixture.begin(edges: fixture.pairedEdges, allowsCentered: true))
            let halfGrowth = -fixture.extent / 256
            XCTAssertTrue(fixture.update(delta: -halfGrowth))
            XCTAssertEqual(fixture.root.splitRatio, 2 * (1 - (branch + halfGrowth) / fixture.extent))
            XCTAssertEqual(inner.splitRatio, 2 * (branch - minimum + 2 * halfGrowth) / (branch + halfGrowth))
            XCTAssertTrue(fixture.update(delta: 0))
            XCTAssertEqual(fixture.root.splitRatio, 1)
            XCTAssertEqual(inner.splitRatio, expanded)
            XCTAssertTrue(fixture.engine.interactiveResizeEnd())
            XCTAssertTrue(fixture.engine.toggleEdgeExpansion(
                for: fixture.target,
                edge: fixture.forwardEdge,
                in: fixture.workspace
            ))
            XCTAssertEqual(inner.splitRatio, 1)
        }
    }

    func testNestedExpansionChangesOnlyTheControllingSplitAndProjectsItsChildrenNormally() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation)
            fixture.insert(Fixture.extra, beside: fixture.target, direction: fixture.backward)
            _ = fixture.layout()
            let inner = try XCTUnwrap(fixture.engine.findNode(for: fixture.target, in: fixture.workspace)?.parent)
            XCTAssertTrue(fixture.toggle())
            XCTAssertEqual(fixture.root.splitRatio, fixture.endpoint)
            XCTAssertEqual(inner.splitRatio, 1)
            let outerFrames = fixture.split(fixture.screen, ratio: fixture.endpoint)
            let innerFrames = fixture.split(outerFrames.0, ratio: 1)
            try fixture.assertFrames([
                (Fixture.extra, innerFrames.0),
                (fixture.target, innerFrames.1),
                (fixture.neighbor, outerFrames.1)
            ])
            XCTAssertTrue(fixture.toggle())
            XCTAssertEqual(fixture.root.splitRatio, 1)
            XCTAssertEqual(inner.splitRatio, 1)
            let originalOuter = fixture.split(fixture.screen, ratio: 1)
            let originalInner = fixture.split(originalOuter.0, ratio: 1)
            try fixture.assertFrames([
                (Fixture.extra, originalInner.0),
                (fixture.target, originalInner.1),
                (fixture.neighbor, originalOuter.1)
            ])
        }
    }

    func testCollapsedBranchesAndInactiveGroupMinimumUseProjectedGeometry() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for grouped in [false, true] {
                let fixture = try Fixture(orientation: orientation)
                if grouped {
                    fixture.insert(
                        Fixture.extra,
                        beside: fixture.neighbor,
                        direction: fixture.horizontal ? .up : .right
                    )
                    XCTAssertTrue(fixture.engine.groupWindow(
                        Fixture.extra,
                        into: fixture.neighbor,
                        in: fixture.workspace
                    ))
                    fixture.setMinimum(fixture.neighbor, contentExtent: 1)
                    let rail = fixture.horizontal ? fixture.engine.tabRailWidth : 0
                    fixture.setMinimum(
                        Fixture.extra,
                        contentExtent: fixture.minimum - fixture.engine.settings.innerGap / 2 - rail
                    )
                    let tile = try XCTUnwrap(fixture.engine.findNode(for: fixture.neighbor, in: fixture.workspace)?
                        .tile)
                    XCTAssertTrue(tile.activate(fixture.neighbor))
                } else {
                    fixture.insert(Fixture.extra, beside: fixture.target, direction: fixture.horizontal ? .up : .right)
                    fixture.engine.setExcludedTokens([Fixture.extra], in: fixture.workspace)
                }
                _ = fixture.layout()
                XCTAssertTrue(fixture.toggle())
                XCTAssertEqual(fixture.root.splitRatio, fixture.endpoint)
                try fixture.assertTwoLeafLayout(ratio: fixture.endpoint, groupedNeighbor: grouped)
                XCTAssertTrue(fixture.toggle())
                XCTAssertEqual(fixture.root.splitRatio, 1)
                try fixture.assertTwoLeafLayout(ratio: 1, groupedNeighbor: grouped)
            }
        }
    }

    func testChangedLeafIdentityCannotRestoreTheOldExpansion() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation)
            XCTAssertTrue(fixture.toggle())
            fixture.insert(Fixture.extra, beside: fixture.target, direction: fixture.horizontal ? .up : .right)
            _ = fixture.layout()
            XCTAssertFalse(fixture.toggle())
            XCTAssertEqual(fixture.root.splitRatio, fixture.endpoint)
            XCTAssertNil(fixture.root.edgeExpansion)
        }
    }

    func testRestoreRespectsNewMinimumsAndRefusedActionsDoNotStoreExpansion() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation)
            XCTAssertFalse(fixture.engine.toggleEdgeExpansion(
                for: fixture.target,
                edge: fixture.oppositeEdge,
                in: fixture.workspace
            ))
            XCTAssertFalse(fixture.engine.toggleEdgeExpansion(
                for: fixture.target,
                edge: [.left, .top],
                in: fixture.workspace
            ))
            XCTAssertNil(fixture.root.edgeExpansion)
            XCTAssertTrue(fixture.toggle())
            let newMinimum = 3 * fixture.extent / 4
            fixture.setMinimum(fixture.target, contentExtent: newMinimum - fixture.engine.settings.innerGap / 2)
            _ = fixture.layout()
            XCTAssertTrue(fixture.toggle())
            XCTAssertEqual(fixture.root.splitRatio, 2 * newMinimum / fixture.extent)
            XCTAssertNil(fixture.root.edgeExpansion)
            try fixture.assertTwoLeafLayout(ratio: 2 * newMinimum / fixture.extent)
            fixture.root.kind = .split(orientation: orientation, ratio: fixture.endpoint)
            _ = fixture.layout()
            XCTAssertFalse(fixture.toggle())
            XCTAssertNil(fixture.root.edgeExpansion)
            fixture.engine.setExcludedTokens([fixture.target], in: fixture.workspace)
            XCTAssertFalse(fixture.toggle())
            XCTAssertNil(fixture.root.edgeExpansion)
        }
    }
}

private extension DwindleEdgeExpansionTests {
    struct Fixture {
        static let extra = WindowToken(pid: 1, windowId: 3)
        static let other = WindowToken(pid: 1, windowId: 4)
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let screen = CGRect(x: 160, y: 96, width: 2048, height: 1536)
        let target = WindowToken(pid: 1, windowId: 1)
        let neighbor = WindowToken(pid: 1, windowId: 2)
        let orientation: DwindleOrientation
        let targetFirst: Bool
        let minimumDivisor: CGFloat
        let root: DwindleNode

        var horizontal: Bool {
            orientation == .horizontal
        }

        var extent: CGFloat {
            horizontal ? screen.width : screen.height
        }

        var minimum: CGFloat {
            extent / minimumDivisor
        }

        var forward: Direction {
            horizontal ? .right : .up
        }

        var backward: Direction {
            horizontal ? .left : .down
        }

        var forwardEdge: ResizeEdge {
            horizontal ? .right : .top
        }

        var backwardEdge: ResizeEdge {
            horizontal ? .left : .bottom
        }

        var edge: ResizeEdge {
            targetFirst ? forwardEdge : backwardEdge
        }

        var oppositeEdge: ResizeEdge {
            targetFirst ? backwardEdge : forwardEdge
        }

        var pairedEdges: ResizeEdge {
            horizontal ? [.left, .right] : [.bottom, .top]
        }

        var endpoint: CGFloat {
            2 * (targetFirst ? extent - minimum : minimum) / extent
        }

        init(orientation: DwindleOrientation, targetFirst: Bool = true, minimumDivisor: CGFloat = 64) throws {
            self.orientation = orientation
            self.targetFirst = targetFirst
            self.minimumDivisor = minimumDivisor
            engine.addWindow(token: target, to: workspace, activeWindowFrame: nil)
            let horizontal = orientation == .horizontal
            engine.setPreselection(
                targetFirst ? (horizontal ? .right : .up) : (horizontal ? .left : .down),
                in: workspace
            )
            engine.addWindow(token: neighbor, to: workspace, activeWindowFrame: nil)
            root = try XCTUnwrap(engine.root(for: workspace))
            setMinimum(neighbor, contentExtent: minimum - engine.settings.innerGap / 2)
            _ = layout()
        }

        func toggle() -> Bool {
            engine.toggleEdgeExpansion(for: target, edge: edge, in: workspace)
        }

        func layout() -> [WindowToken: CGRect] {
            engine.calculateLayout(for: workspace, screen: screen)
        }

        func setMinimum(_ token: WindowToken, contentExtent: CGFloat) {
            engine.updateWindowConstraints(for: token, constraints: WindowSizeConstraints(
                minSize: CGSize(width: horizontal ? contentExtent : 1, height: horizontal ? 1 : contentExtent),
                maxSize: .zero, isFixed: false
            ))
        }

        func insert(_ token: WindowToken, beside existing: WindowToken, direction: Direction) {
            engine.setSelectedNode(engine.findNode(for: existing, in: workspace), in: workspace)
            engine.setPreselection(direction, in: workspace)
            engine.addWindow(token: token, to: workspace, activeWindowFrame: nil)
        }

        func begin(edges: ResizeEdge, allowsCentered: Bool) -> Bool {
            engine.interactiveResizeBegin(
                token: target, edges: edges, startLocation: screen.center, in: workspace,
                innerGap: engine.settings.innerGap, allowsCentered: allowsCentered
            )
        }

        func update(delta: CGFloat) -> Bool {
            engine.interactiveResizeUpdate(currentLocation: CGPoint(
                x: screen.midX + (horizontal ? delta : 0), y: screen.midY + (horizontal ? 0 : delta)
            ))
        }

        func resizeCommand(by delta: CGFloat, focused: Bool) -> Bool {
            focused ? engine.resizeFocusedWindow(by: delta, in: workspace)
                : engine.resizeSelected(by: delta, orientation: orientation, in: workspace)
        }

        func split(_ frame: CGRect, ratio: CGFloat) -> (CGRect, CGRect) {
            engine.splitRect(frame, orientation: orientation, ratio: ratio, minimums: (first: .zero, second: .zero))
        }

        func assertTwoLeafLayout(ratio: CGFloat, groupedNeighbor: Bool = false) throws {
            let raw = split(screen, ratio: ratio)
            try assertFrames(
                [(target, targetFirst ? raw.0 : raw.1), (neighbor, targetFirst ? raw.1 : raw.0)],
                grouped: groupedNeighbor ? neighbor : nil
            )
        }

        func assertFrames(_ expected: [(WindowToken, CGRect)], grouped: WindowToken? = nil) throws {
            let frames = layout()
            XCTAssertEqual(frames.count, expected.count)
            for (token, raw) in expected {
                var content = DwindleGapCalculator.applyGaps(
                    nodeRect: raw,
                    tilingArea: screen,
                    settings: engine.settings
                )
                if token == grouped {
                    content.origin.x += engine.tabRailWidth
                    content.size.width -= engine.tabRailWidth
                }
                XCTAssertEqual(try XCTUnwrap(frames[token]), content)
            }
        }
    }
}
