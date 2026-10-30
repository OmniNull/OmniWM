// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore
import XCTest

final class ShellManipulationQueryTests: XCTestCase {
    private func apply(_ tree: [TreeNode], to core: inout SurfaceCore, patches: inout PatchBuffer) {
        patches.removeAll()
        let measure: MeasureText = { _, _, _, _, _, width, height in
            width.pointee = 0
            height.pointee = 0
        }
        tree.withUnsafeBufferPointer { core.apply($0, measure: measure, context: nil, into: &patches) }
    }

    func testPresentedTargetUsesSignedCoordinatesAndWinsSiblingHitOrder() throws {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 4, layout: LayoutStyle(axis: .overlay, width: 300, height: 200)),
            TreeNode(
                kind: .box,
                subtreeEnd: 2,
                key: 1,
                layout: LayoutStyle(width: 80, height: 60, align: 5, dx: 50, dy: 20),
                content: Content(action: 1)
            ),
            TreeNode(
                kind: .box,
                subtreeEnd: 3,
                key: 2,
                layout: LayoutStyle(width: 80, height: 60, align: 5, dx: 50, dy: 20),
                content: Content(action: 2)
            ),
            TreeNode(kind: .box, subtreeEnd: 4, key: 3, layout: LayoutStyle(width: 300, height: 200, align: 5))
        ], to: &core, patches: &patches)
        let first = try XCTUnwrap(core.elements { $0.action == 1 }.first)
        let second = try XCTUnwrap(core.elements { $0.action == 2 }.first)
        XCTAssertEqual(core.hitTest(x: 60, y: 30) { $0.action != 0 }, second)
        let moved = SurfacePresentation(targets: [first: .init(
            frame: Rect(x: 30, y: 60, width: 80, height: 60),
            scale: 1,
            visible: true
        )])
        XCTAssertEqual(core.hitTest(x: 40, y: 70, presentation: moved) { $0.action != 0 }, first)
        XCTAssertEqual(core.hitTest(x: 60, y: 70, presentation: moved) { $0.action != 0 }, first)
        XCTAssertEqual(core.hitPath(x: 60, y: 70, presentation: moved, matching: { $0.action != 0 }), [first])
        XCTAssertTrue(core.covers(x: 40, y: 70, presentation: moved) { $0 == first })
        XCTAssertFalse(core.covers(x: 60, y: 30, presentation: moved) { $0 == first })
        XCTAssertEqual(core.absoluteFrame(of: first), Rect(x: 50, y: 20, width: 80, height: 60))
    }

    func testResizePresentationClipsAllQueryKindsAtTheSameTargetBoundary() throws {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 4, layout: LayoutStyle(axis: .overlay, width: 300, height: 200)),
            TreeNode(
                kind: .group,
                subtreeEnd: 4,
                key: 1,
                layout: LayoutStyle(axis: .overlay, width: 100, height: 80, align: 5, dx: 50, dy: 20)
            ),
            TreeNode(
                kind: .box,
                subtreeEnd: 3,
                layout: LayoutStyle(width: 100, height: 80, align: 5),
                content: Content(action: 1)
            ),
            TreeNode(
                kind: .box,
                subtreeEnd: 4,
                layout: LayoutStyle(width: 20, height: 20, align: 5, dx: 75, dy: 10),
                content: Content(action: 2)
            )
        ], to: &core, patches: &patches)
        let child = try XCTUnwrap(core.elements { $0.action == 1 }.first)
        let target = core.parent(of: child)
        let resized = SurfacePresentation(targets: [target: .init(
            frame: Rect(x: 50, y: 20, width: 60, height: 40),
            scale: 1,
            visible: true
        )])
        XCTAssertNotEqual(core.hitTest(x: 130, y: 35) { $0.action != 0 }, .none)
        XCTAssertEqual(core.hitTest(x: 130, y: 35, presentation: resized) { $0.action != 0 }, .none)
        XCTAssertTrue(core.hitPath(x: 130, y: 35, presentation: resized, matching: { $0.action != 0 }).isEmpty)
        XCTAssertFalse(core.covers(x: 130, y: 35, presentation: resized) { core.content(of: $0).action != 0 })
        XCTAssertTrue(core.covers(x: 80, y: 35, presentation: resized) { core.content(of: $0).action != 0 })
    }

    func testScaledPresentationDividesLocalCoordinatesOnEnteringTheTarget() throws {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 4, layout: LayoutStyle(axis: .overlay, width: 400, height: 400)),
            TreeNode(
                kind: .group,
                subtreeEnd: 3,
                key: 1,
                layout: LayoutStyle(axis: .overlay, width: 200, height: 200, align: 5, dx: 100, dy: 100)
            ),
            TreeNode(
                kind: .box,
                subtreeEnd: 3,
                layout: LayoutStyle(width: 20, height: 20, align: 5, dx: 100, dy: 100),
                content: Content(action: 1)
            ),
            TreeNode(
                kind: .box,
                subtreeEnd: 4,
                key: 2,
                layout: LayoutStyle(width: 400, height: 400, align: 5),
                content: Content(action: 2)
            )
        ], to: &core, patches: &patches)
        let child = try XCTUnwrap(core.elements { $0.action == 1 }.first)
        let cover = try XCTUnwrap(core.elements { $0.action == 2 }.first)
        let target = core.parent(of: child)
        let scaled = SurfacePresentation(targets: [
            target: .init(frame: Rect(x: 100, y: 100, width: 100, height: 100), scale: 0.5, visible: true)
        ])
        XCTAssertEqual(core.hitTest(x: 150, y: 150) { $0.action != 0 }, cover)
        XCTAssertEqual(core.hitTest(x: 150, y: 150, presentation: scaled) { $0.action != 0 }, child)
        XCTAssertEqual(core.hitTest(x: 159, y: 159, presentation: scaled) { $0.action != 0 }, child)
        XCTAssertEqual(core.hitTest(x: 161, y: 155, presentation: scaled) { $0.action != 0 }, cover)
        XCTAssertEqual(core.hitTest(x: 205, y: 205, presentation: scaled) { $0.action != 0 }, cover)
        XCTAssertEqual(core.hitPath(x: 150, y: 150, presentation: scaled, matching: { $0.action == 1 }), [child])
        XCTAssertTrue(core.hitPath(x: 205, y: 205, presentation: scaled, matching: { $0.action == 1 }).isEmpty)
        XCTAssertTrue(core.covers(x: 150, y: 150, presentation: scaled) { $0 == child })
        XCTAssertFalse(core.covers(x: 205, y: 205, presentation: scaled) { $0 == child })
        XCTAssertFalse(core.covers(x: 161, y: 155, presentation: scaled) { $0 == child })
    }

    func testDecorativeSubtreesStayInspectableButDoNotOccludeInteractiveSiblings() throws {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        var decorative = Content()
        decorative.decorative = true
        apply([
            TreeNode(kind: .group, subtreeEnd: 5, layout: LayoutStyle(axis: .overlay, width: 300, height: 200)),
            TreeNode(
                kind: .box,
                subtreeEnd: 2,
                key: 1,
                layout: LayoutStyle(width: 80, height: 60, align: 5),
                content: Content(action: 1)
            ),
            TreeNode(
                kind: .group,
                subtreeEnd: 5,
                layout: LayoutStyle(axis: .overlay, width: 300, height: 200),
                content: decorative
            ),
            TreeNode(kind: .shader, subtreeEnd: 4, layout: LayoutStyle(width: 300, height: 200), content: decorative),
            TreeNode(kind: .box, subtreeEnd: 5, layout: LayoutStyle(width: 300, height: 200), content: decorative)
        ], to: &core, patches: &patches)
        let interactive = try XCTUnwrap(core.elements { $0.action == 1 }.first)
        XCTAssertEqual(core.elements { $0.decorative }.count, 3)
        XCTAssertNotEqual(core.firstDescendant(of: core.rootHandle) { $0.decorative }, .none)
        XCTAssertEqual(core.hitTest(x: 10, y: 10) { $0.action != 0 }, interactive)
        XCTAssertEqual(core.hitPath(x: 10, y: 10, matching: { $0.action != 0 }), [interactive])
        XCTAssertFalse(core.covers(x: 200, y: 100) { core.content(of: $0).decorative })
        XCTAssertFalse(core.covers(x: 200, y: 100) { core.content(of: $0).action != 0 })
    }
}
