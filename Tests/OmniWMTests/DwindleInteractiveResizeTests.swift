// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleInteractiveResizeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let start = CGPoint(x: 100, y: 100)

    private func makeEngine() -> (DwindleLayoutEngine, WorkspaceDescriptor.ID) {
        (DwindleLayoutEngine(), WorkspaceDescriptor.ID())
    }

    func testAxisEdgesGrowControllingSplit() {
        let cases: [(
            label: String,
            vertical: Bool,
            edges: ResizeEdge,
            delta: CGPoint,
            orientation: DwindleOrientation
        )] = [
            ("horizontal right", false, [.right], CGPoint(x: 100, y: 0), .horizontal),
            ("vertical top", true, [.top], CGPoint(x: 0, y: 80), .vertical)
        ]
        for row in cases {
            let (engine, ws) = makeEngine()
            let first = WindowToken(pid: 1, windowId: 1)
            let second = WindowToken(pid: 2, windowId: 2)
            _ = engine.addWindow(token: first, to: ws, activeWindowFrame: nil)
            if row.vertical {
                engine.setPreselection(.up, in: ws)
            }
            _ = engine.addWindow(token: second, to: ws, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: ws, screen: screen)
            XCTAssertEqual(engine.root(for: ws)?.splitOrientation, row.orientation, row.label)

            XCTAssertTrue(
                engine.interactiveResizeBegin(
                    token: first, edges: row.edges, startLocation: start,
                    in: ws, innerGap: engine.settings.innerGap
                ),
                row.label
            )
            XCTAssertTrue(
                engine.interactiveResizeUpdate(
                    currentLocation: CGPoint(x: start.x + row.delta.x, y: start.y + row.delta.y)
                ),
                row.label
            )
            XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.2, row.label)
        }
    }

    func testHorizontalRatioClampsAtMax() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 5000, y: start.y)))

        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.9)
    }

    func testCornerDragResizesBothAxes() {
        let (engine, ws) = makeEngine()
        let leaf1 = WindowToken(pid: 1, windowId: 1)
        let other = WindowToken(pid: 2, windowId: 2)
        let leaf3 = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: leaf1, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: other, to: ws, activeWindowFrame: nil)
        engine.setSelectedNode(engine.findNode(for: leaf1, in: ws), in: ws)
        engine.setPreselection(.up, in: ws)
        _ = engine.addWindow(token: leaf3, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        let verticalSplit = engine.findNode(for: leaf1, in: ws)?.parent
        let horizontalSplit = engine.root(for: ws)
        XCTAssertEqual(verticalSplit?.splitOrientation, .vertical)
        XCTAssertEqual(horizontalSplit?.splitOrientation, .horizontal)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: leaf1,
                edges: [.right, .top],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y + 80))
        )

        XCTAssertEqual(horizontalSplit?.splitRatio ?? 0, 1.2)
        XCTAssertEqual(verticalSplit?.splitRatio ?? 0, 1.2)
    }

    func testEdgeAtScreenBoundaryIsNotResizable() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertFalse(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.left],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertNil(engine.interactiveResize)
    }

    func testEndWithoutMovementReportsNoChange() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertFalse(engine.interactiveResizeEnd())
        XCTAssertNil(engine.interactiveResize)
    }

    func testWindowRemovedMidGestureAborts() {
        let (engine, ws) = makeEngine()
        let left = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: left, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: left,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )
        engine.removeWindow(token: left, from: ws)

        XCTAssertFalse(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y)))
        XCTAssertNil(engine.interactiveResize)
    }

    func testTopologyChangeSkipsAxisOnIdentityMismatch() {
        let (engine, ws) = makeEngine()
        let outer = WindowToken(pid: 3, windowId: 3)
        let leaf1 = WindowToken(pid: 1, windowId: 1)
        let leaf2 = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: outer, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: leaf1, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: leaf2, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)

        let innerSplit = engine.findNode(for: leaf1, in: ws)?.parent
        XCTAssertEqual(innerSplit?.splitOrientation, .horizontal)
        XCTAssertNotEqual(innerSplit?.id, engine.root(for: ws)?.id)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: leaf1,
                edges: [.right],
                startLocation: start,
                in: ws,
                innerGap: engine.settings.innerGap
            )
        )

        engine.removeWindow(token: outer, from: ws)
        let collapsedRoot = engine.root(for: ws)
        XCTAssertEqual(collapsedRoot?.splitOrientation, .horizontal)
        XCTAssertEqual(engine.findNode(for: leaf1, in: ws)?.isFirstChild(of: collapsedRoot!), true)

        XCTAssertFalse(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y)))
        XCTAssertEqual(collapsedRoot?.splitRatio ?? 0, 1.0)
        XCTAssertNotNil(engine.findNode(for: leaf1, in: ws))
    }

    func testNearestMovableFallsBackAtEachScreenEdge() {
        for vertical in [false, true] {
            let (engine, workspace) = makeEngine()
            let first = WindowToken(pid: 1, windowId: 1)
            let second = WindowToken(pid: 2, windowId: 2)
            _ = engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
            if vertical { engine.setPreselection(.up, in: workspace) }
            _ = engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspace, screen: screen)
            let firstEdge: ResizeEdge = vertical ? .top : .right
            let secondEdge: ResizeEdge = vertical ? .bottom : .left
            for (token, requested, effective) in [(first, secondEdge, firstEdge), (second, firstEdge, secondEdge)] {
                XCTAssertFalse(engine.interactiveResizeBegin(
                    token: token, edges: requested, startLocation: start, in: workspace,
                    innerGap: engine.settings.innerGap
                ))
                XCTAssertTrue(engine.interactiveResizeBegin(
                    token: token, edges: requested, startLocation: start, in: workspace,
                    innerGap: engine.settings.innerGap, edgePolicy: .nearestMovable
                ))
                XCTAssertEqual(engine.interactiveResize?.edges, effective)
                let originalRatio = engine.root(for: workspace)?.splitRatio ?? 0
                let location = CGPoint(x: start.x + (vertical ? 0 : 100), y: start.y + (vertical ? 80 : 0))
                XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: location))
                XCTAssertEqual(engine.root(for: workspace)?.splitRatio ?? 0, originalRatio + 0.2)
                XCTAssertTrue(engine.interactiveResizeEnd())
            }
        }
    }

    func testNearestMovableFallsBackOnBothAxesAtCorner() {
        let (engine, workspace) = makeEngine()
        let target = WindowToken(pid: 1, windowId: 1)
        let right = WindowToken(pid: 2, windowId: 2)
        let top = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: target, to: workspace, activeWindowFrame: nil)
        _ = engine.addWindow(token: right, to: workspace, activeWindowFrame: nil)
        engine.setSelectedNode(engine.findNode(for: target, in: workspace), in: workspace)
        engine.setPreselection(.up, in: workspace)
        _ = engine.addWindow(token: top, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.interactiveResizeBegin(
            token: target, edges: [.left, .bottom], startLocation: start, in: workspace,
            innerGap: engine.settings.innerGap, edgePolicy: .nearestMovable
        ))
        XCTAssertEqual(engine.interactiveResize?.edges, [.right, .top])
        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x + 100, y: start.y + 80)))
        XCTAssertEqual(engine.root(for: workspace)?.splitRatio ?? 0, 1.2)
        XCTAssertEqual(engine.findNode(for: target, in: workspace)?.parent?.splitRatio ?? 0, 1.2)
    }

    func testNearestMovableKeepsRequestedEdgeWhenItCanMove() {
        let (engine, workspace) = makeEngine()
        let target = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: target, to: workspace, activeWindowFrame: nil)
        _ = engine.addWindow(token: WindowToken(pid: 2, windowId: 2), to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.interactiveResizeBegin(
            token: target, edges: [.right], startLocation: start, in: workspace,
            innerGap: engine.settings.innerGap, edgePolicy: .nearestMovable
        ))
        XCTAssertEqual(engine.interactiveResize?.edges, [.right])
        XCTAssertNil(engine.interactiveResize?.vertical)
    }

    func testNearestMovableRejectsWindowWithoutControllingSplits() {
        let (engine, workspace) = makeEngine()
        let target = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: target, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertFalse(engine.interactiveResizeBegin(
            token: target, edges: [.left, .bottom], startLocation: start, in: workspace,
            innerGap: engine.settings.innerGap, edgePolicy: .nearestMovable
        ))
        XCTAssertNil(engine.interactiveResize)
    }

    func testExactPolicyPreservesRequestedCornerWithoutAddingUnavailableAxis() {
        let (engine, workspace) = makeEngine()
        let target = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: target, to: workspace, activeWindowFrame: nil)
        _ = engine.addWindow(token: WindowToken(pid: 2, windowId: 2), to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.interactiveResizeBegin(
            token: target, edges: [.right, .top], startLocation: start, in: workspace,
            innerGap: engine.settings.innerGap
        ))
        XCTAssertEqual(engine.interactiveResize?.edges, [.right, .top])
        XCTAssertNotNil(engine.interactiveResize?.horizontal)
        XCTAssertNil(engine.interactiveResize?.vertical)
        XCTAssertFalse(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: start.x, y: start.y + 80)))
        XCTAssertEqual(engine.root(for: workspace)?.splitRatio ?? 0, 1.0)
    }
}
