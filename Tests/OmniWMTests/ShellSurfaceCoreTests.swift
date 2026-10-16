// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

final class ShellSurfaceCoreTests: XCTestCase {
    private func apply(_ tree: [TreeNode], to core: inout SurfaceCore, patches: inout PatchBuffer) {
        patches.removeAll()
        let measure: MeasureText = { _, text, _, _, _, width, height in
            width.pointee = Float(text) * 10
            height.pointee = 12
        }
        tree.withUnsafeBufferPointer { core.apply($0, measure: measure, context: nil, into: &patches) }
    }

    private func row(keys: [UInt64], text: UInt32 = 1, reserve: UInt32 = 0) -> [TreeNode] {
        var nodes = [TreeNode(kind: .group, subtreeEnd: Int32(keys.count + 1), key: 99)]
        for (index, key) in keys.enumerated() {
            nodes.append(TreeNode(
                kind: .label,
                subtreeEnd: Int32(index + 2),
                key: key,
                content: Content(text: text, reserve: reserve)
            ))
        }
        return nodes
    }

    private func counts(_ patches: borrowing PatchBuffer) -> (inserts: Int, removes: Int, moves: Int, frames: Int) {
        var result = (inserts: 0, removes: 0, moves: 0, frames: 0)
        for index in 0 ..< patches.count {
            switch patches.op(at: index) {
            case .insert: result.inserts += 1
            case .remove: result.removes += 1
            case .move: result.moves += 1
            case .setFrame: result.frames += 1
            default: break
            }
        }
        return result
    }

    func testKeyedReorderMovesInsteadOfRecreating() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply(row(keys: [1, 2, 3]), to: &core, patches: &patches)
        apply(row(keys: [3, 1, 2]), to: &core, patches: &patches)
        let result = counts(patches)
        XCTAssertEqual(result.inserts, 0)
        XCTAssertEqual(result.removes, 0)
        XCTAssertEqual(result.moves, 1)
        XCTAssertEqual(core.liveCount, 4)
    }

    func testRemovedChildIsRemoved() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply(row(keys: [1, 2, 3]), to: &core, patches: &patches)
        apply(row(keys: [1, 3]), to: &core, patches: &patches)
        XCTAssertEqual(counts(patches).removes, 1)
        XCTAssertEqual(core.liveCount, 3)
    }

    func testOverlayChildrenFollowTheirAlignment() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 3, layout: LayoutStyle(axis: .overlay, width: 20, height: 20)),
            TreeNode(kind: .box, subtreeEnd: 2, layout: LayoutStyle(width: 10, height: 10)),
            TreeNode(kind: .box, subtreeEnd: 3, layout: LayoutStyle(width: 6, height: 6, align: 6))
        ], to: &core, patches: &patches)
        let centered = core.hitTest(x: 10, y: 10) { _ in true }
        XCTAssertEqual(core.absoluteFrame(of: centered), Rect(x: 5, y: 5, width: 10, height: 10))
        let corner = core.hitTest(x: 18, y: 2) { _ in true }
        XCTAssertEqual(core.absoluteFrame(of: corner), Rect(x: 14, y: 0, width: 6, height: 6))
    }

    func testElementsMatchingFindsEveryMatchingNode() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 4),
            TreeNode(kind: .box, subtreeEnd: 3, content: Content(target: 1)),
            TreeNode(kind: .box, subtreeEnd: 3, content: Content(target: 2)),
            TreeNode(kind: .box, subtreeEnd: 4)
        ], to: &core, patches: &patches)
        let found = core.elements { $0.target != 0 }.map { core.content(of: $0).target }
        XCTAssertEqual(Set(found), [1, 2])
    }

    func testOverlayOnlyConstrainsTheScrollingAxisOfScrollableChildren() {
        for axis in [Axis.row, .column] {
            for scrolls in [false, true] {
                var core = SurfaceCore(capacity: 16)
                var patches = PatchBuffer(capacity: 64)
                apply([
                    TreeNode(kind: .group, subtreeEnd: 4, layout: LayoutStyle(axis: .overlay, width: 100, height: 80)),
                    TreeNode(kind: .shader, subtreeEnd: 2),
                    TreeNode(
                        kind: .group, subtreeEnd: 4,
                        layout: LayoutStyle(axis: axis), content: Content(target: 1, scrolls: scrolls)
                    ),
                    TreeNode(kind: .box, subtreeEnd: 4, layout: LayoutStyle(width: 200, height: 160))
                ], to: &core, patches: &patches)
                let child = core.elements { $0.target == 1 }.first
                let frame = child.map { core.absoluteFrame(of: $0) }
                XCTAssertEqual(frame?.width, scrolls && axis == .row ? 100 : 200)
                XCTAssertEqual(frame?.height, scrolls && axis == .column ? 80 : 160)
                XCTAssertEqual(shaderFrame(core), Rect(x: 0, y: 0, width: 100, height: 80))
            }
        }
    }

    private func shaderFrame(_ core: borrowing SurfaceCore) -> Rect? {
        core.elements { _ in true }.first { core.kind(of: $0) == .shader }.map { core.absoluteFrame(of: $0) }
    }

    func testAShaderWithoutASizeFillsItsStackWithoutSizingIt() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 3, layout: LayoutStyle(axis: .overlay)),
            TreeNode(kind: .shader, subtreeEnd: 2, layout: LayoutStyle(dx: -2)),
            TreeNode(kind: .box, subtreeEnd: 3, layout: LayoutStyle(width: 10, height: 8))
        ], to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame.width, 10)
        XCTAssertEqual(core.rootFrame.height, 8)
        XCTAssertEqual(shaderFrame(core), Rect(x: -2, y: 0, width: 10, height: 8))

        apply([
            TreeNode(kind: .group, subtreeEnd: 3, layout: LayoutStyle(axis: .overlay)),
            TreeNode(kind: .shader, subtreeEnd: 2, layout: LayoutStyle(width: 4, align: 1)),
            TreeNode(kind: .box, subtreeEnd: 3, layout: LayoutStyle(width: 30, height: 20))
        ], to: &core, patches: &patches)
        XCTAssertEqual(shaderFrame(core), Rect(x: 0, y: 0, width: 4, height: 20))

        apply([
            TreeNode(kind: .group, subtreeEnd: 3),
            TreeNode(kind: .shader, subtreeEnd: 2),
            TreeNode(kind: .box, subtreeEnd: 3, layout: LayoutStyle(width: 10, height: 30))
        ], to: &core, patches: &patches)
        XCTAssertEqual(shaderFrame(core), Rect(x: 0, y: 7, width: 16, height: 16))
    }

    func testRootBleedStretchesFillShadersPastTheRoot() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 3, layout: LayoutStyle(axis: .overlay)),
            TreeNode(kind: .shader, subtreeEnd: 2),
            TreeNode(kind: .box, subtreeEnd: 3, layout: LayoutStyle(width: 20, height: 10))
        ], to: &core, patches: &patches)
        core.setRootBleed(Insets(left: 2, top: 6, right: 3), into: &patches)
        XCTAssertEqual(shaderFrame(core), Rect(x: -2, y: -6, width: 25, height: 16))
        XCTAssertEqual(core.rootFrame, Rect(x: 0, y: 0, width: 20, height: 10))
        XCTAssertTrue(core.covers(x: 5, y: -3) { _ in true })
        XCTAssertFalse(core.covers(x: 5, y: -7) { _ in true })
        core.setRootBleed(Insets(), into: &patches)
        XCTAssertEqual(shaderFrame(core), Rect(x: 0, y: 0, width: 20, height: 10))
    }

    func testOverlayOffsetsMoveAChildWithoutResizingTheStack() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 3, layout: LayoutStyle(axis: .overlay)),
            TreeNode(kind: .box, subtreeEnd: 2, layout: LayoutStyle(width: 10, height: 10)),
            TreeNode(kind: .box, subtreeEnd: 3, layout: LayoutStyle(width: 4, height: 4, align: 6, dx: 2, dy: -3))
        ], to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame.width, 10)
        XCTAssertEqual(core.rootFrame.height, 10)
        let badge = core.elements { _ in true }.first { core.layoutFrame(of: $0).width == 4 }
        XCTAssertEqual(badge.map { core.absoluteFrame(of: $0) }, Rect(x: 8, y: -3, width: 4, height: 4))
    }

    func testHitTestFindsDeepestMatchingElement() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        let box = LayoutStyle(width: 20, height: 10)
        apply([
            TreeNode(kind: .group, subtreeEnd: 4, content: Content(action: 1)),
            TreeNode(kind: .box, subtreeEnd: 3, layout: box, content: Content(action: 2)),
            TreeNode(kind: .label, subtreeEnd: 3, content: Content(text: 1)),
            TreeNode(kind: .box, subtreeEnd: 4, layout: box)
        ], to: &core, patches: &patches)
        let inner = core.hitTest(x: 5, y: 5) { $0.action != 0 }
        XCTAssertEqual(core.content(of: inner).action, 2)
        let outer = core.hitTest(x: 25, y: 5) { $0.action != 0 }
        XCTAssertEqual(core.content(of: outer).action, 1)
        XCTAssertEqual(core.hitTest(x: 45, y: 5) { $0.action != 0 }, .none)
        XCTAssertTrue(core.contains(inner))
        apply([TreeNode(kind: .group, subtreeEnd: 1)], to: &core, patches: &patches)
        XCTAssertFalse(core.contains(inner))
    }

    func testHitPathCollectsEveryMatchingElementUnderThePoint() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        let box = LayoutStyle(width: 20, height: 10)
        apply([
            TreeNode(kind: .group, subtreeEnd: 4, content: Content(hoverScale: 1.1)),
            TreeNode(kind: .box, subtreeEnd: 3, layout: box, content: Content(hover: Color(packed: 0xFF00_00FF))),
            TreeNode(kind: .label, subtreeEnd: 3, content: Content(text: 1, hoverOpacity: 0.5)),
            TreeNode(kind: .box, subtreeEnd: 4, layout: box)
        ], to: &core, patches: &patches)
        let path = core.hitPath(x: 5, y: 5) { $0.hasHoverEffect }
        XCTAssertEqual(path.count, 3)
        XCTAssertEqual(core.content(of: path[0]).hoverScale, 1.1)
        XCTAssertEqual(core.content(of: path[2]).hoverOpacity, 0.5)
        XCTAssertEqual(core.hitPath(x: 25, y: 5) { $0.hasHoverEffect }.count, 1)
        XCTAssertTrue(core.hitPath(x: 45, y: 5) { $0.hasHoverEffect }.isEmpty)
    }

    func testScrollContainersOffsetTheirChildrenWithinTheirExtent() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        let item = LayoutStyle(width: 20, height: 30)
        apply([
            TreeNode(
                kind: .group,
                subtreeEnd: 4,
                layout: LayoutStyle(axis: .column, height: 50),
                content: Content(scrolls: true)
            ),
            TreeNode(kind: .box, subtreeEnd: 2, layout: item, content: Content(action: 1)),
            TreeNode(kind: .box, subtreeEnd: 3, layout: item, content: Content(action: 2)),
            TreeNode(kind: .box, subtreeEnd: 4, layout: item, content: Content(action: 3))
        ], to: &core, patches: &patches)
        let container = core.hitTest(x: 5, y: 5) { $0.scrolls }
        XCTAssertEqual(core.content(of: core.hitTest(x: 5, y: 45) { $0.action != 0 }).action, 2)

        XCTAssertEqual(core.scroll(container, by: 100), 40)
        XCTAssertNil(core.scroll(container, by: 10))
        let second = core.hitTest(x: 5, y: 5) { $0.action != 0 }
        XCTAssertEqual(core.content(of: second).action, 2)
        XCTAssertEqual(core.absoluteFrame(of: second).y, -10)
        XCTAssertEqual(core.content(of: core.hitTest(x: 5, y: 45) { $0.action != 0 }).action, 3)
        XCTAssertEqual(core.scroll(container, by: -100), 0)
    }

    func testARootLimitShrinksScrollingChildrenAndKeepsTheirContentReachable() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        let item = LayoutStyle(width: 20, height: 30)
        apply([
            TreeNode(kind: .group, subtreeEnd: 5, layout: LayoutStyle(axis: .column)),
            TreeNode(kind: .box, subtreeEnd: 2, layout: LayoutStyle(width: 20, height: 10)),
            TreeNode(kind: .group, subtreeEnd: 5, layout: LayoutStyle(axis: .column), content: Content(scrolls: true)),
            TreeNode(kind: .box, subtreeEnd: 4, layout: item, content: Content(action: 1)),
            TreeNode(kind: .box, subtreeEnd: 5, layout: item, content: Content(action: 2))
        ], to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame.height, 70)

        core.setRootLimit(Size2(width: .infinity, height: 40), into: &patches)
        XCTAssertEqual(core.rootFrame.height, 40)
        XCTAssertEqual(core.rootSize.height, 70)
        let list = core.hitTest(x: 5, y: 15) { $0.scrolls }
        XCTAssertEqual(core.layoutFrame(of: list).height, 30)
        XCTAssertEqual(core.scroll(list, by: 100), 30)
        XCTAssertEqual(core.content(of: core.hitTest(x: 5, y: 15) { $0.action != 0 }).action, 2)

        core.setRootLimit(Size2(width: .infinity, height: .infinity), into: &patches)
        XCTAssertEqual(core.rootFrame.height, 70)
        XCTAssertEqual(core.layoutFrame(of: list).height, 60)
        XCTAssertNil(core.scroll(list, by: 10))
    }

    func testFirstDescendantSearchesOnlyInsideItsElement() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 6, layout: LayoutStyle(axis: .row)),
            TreeNode(kind: .group, subtreeEnd: 4, layout: LayoutStyle(axis: .row), content: Content(target: 1)),
            TreeNode(kind: .group, subtreeEnd: 3, layout: LayoutStyle(width: 5, height: 5)),
            TreeNode(kind: .box, subtreeEnd: 4, layout: LayoutStyle(width: 5, height: 5), content: Content(target: 2)),
            TreeNode(kind: .box, subtreeEnd: 5, layout: LayoutStyle(width: 5, height: 5), content: Content(target: 1)),
            TreeNode(kind: .box, subtreeEnd: 6, layout: LayoutStyle(width: 5, height: 5), content: Content(target: 3))
        ], to: &core, patches: &patches)
        let element = core.hitTest(x: 1, y: 1) { $0.target == 1 }
        XCTAssertEqual(core.content(of: core.firstDescendant(of: element) { $0.target == 2 }).target, 2)
        XCTAssertEqual(core.firstDescendant(of: element) { $0.target == 1 }, .none)
        XCTAssertEqual(core.firstDescendant(of: element) { $0.target == 3 }, .none)
        XCTAssertEqual(core.content(of: core.firstDescendant(of: core.rootHandle) { $0.target == 3 }).target, 3)
    }

    func testReturningToDefaultsClearsPaintAndText() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        let painted = Paint(fill: Color(packed: 0xFF00_00FF))
        apply([
            TreeNode(kind: .group, subtreeEnd: 3),
            TreeNode(kind: .box, subtreeEnd: 2, paint: painted),
            TreeNode(kind: .label, subtreeEnd: 3, content: Content(text: 1))
        ], to: &core, patches: &patches)
        apply([
            TreeNode(kind: .group, subtreeEnd: 3),
            TreeNode(kind: .box, subtreeEnd: 2),
            TreeNode(kind: .label, subtreeEnd: 3)
        ], to: &core, patches: &patches)
        var clearedPaint = false
        var clearedText = false
        for index in 0 ..< patches.count {
            switch patches.op(at: index) {
            case let .setPaint(_, paint): clearedPaint = paint == .none
            case let .setText(_, text, _, _, _, _): clearedText = text == 0
            default: break
            }
        }
        XCTAssertTrue(clearedPaint)
        XCTAssertTrue(clearedText)
    }

    func testReservedTextKeepsItsWidth() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply(row(keys: [1], text: 2, reserve: 5), to: &core, patches: &patches)
        let width = core.rootFrame.width
        apply(row(keys: [1], text: 3, reserve: 5), to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame.width, width)
        XCTAssertEqual(counts(patches).frames, 0)
        apply(row(keys: [1], text: 4), to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame.width, 40)
    }
}
