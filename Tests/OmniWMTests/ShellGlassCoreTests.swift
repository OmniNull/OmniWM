// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

final class ShellGlassCoreTests: XCTestCase {
    private func apply(_ tree: [TreeNode], to core: inout SurfaceCore, patches: inout PatchBuffer) {
        patches.removeAll()
        let measure: MeasureText = { _, _, _, _, _, width, height in
            width.pointee = 0
            height.pointee = 0
        }
        tree.withUnsafeBufferPointer { core.apply($0, measure: measure, context: nil, into: &patches) }
    }

    private func glassPatches(_ patches: borrowing PatchBuffer) -> Int {
        var count = 0
        for index in 0 ..< patches.count {
            if case .setGlass = patches.op(at: index) { count += 1 }
        }
        return count
    }

    private func body(width: Float, height: Float) -> [TreeNode] {
        [
            TreeNode(kind: .glass, subtreeEnd: 3),
            TreeNode(kind: .shape, subtreeEnd: 2, layout: LayoutStyle(width: width, height: height)),
            TreeNode(kind: .shape, subtreeEnd: 3, content: Content(target: 1))
        ]
    }

    func testGlassOverlaysShapesAndFillingShapeDoesNotDetermineBodySize() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply(body(width: 80, height: 40), to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame, Rect(x: 0, y: 0, width: 80, height: 40))
        let filling = core.firstDescendant(of: core.rootHandle) { $0.target == 1 }
        XCTAssertEqual(core.layoutFrame(of: filling), Rect(x: 0, y: 0, width: 80, height: 40))
        apply(body(width: 120, height: 60), to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame, Rect(x: 0, y: 0, width: 120, height: 60))
        XCTAssertEqual(core.layoutFrame(of: filling), Rect(x: 0, y: 0, width: 120, height: 60))
    }

    func testInitiallyFillingShapeCanInvalidateItsBodyAfterBecomingExplicit() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply(body(width: -1, height: -1), to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame, .zero)
        apply(body(width: 90, height: 55), to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame, Rect(x: 0, y: 0, width: 90, height: 55))
    }

    func testAutoGlassFillsOverlayWithoutInflatingItsMeasurement() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        apply([
            TreeNode(kind: .group, subtreeEnd: 4, layout: LayoutStyle(axis: .overlay)),
            TreeNode(kind: .glass, subtreeEnd: 3, content: Content(target: 1)),
            TreeNode(kind: .shape, subtreeEnd: 3, layout: LayoutStyle(width: 300, height: 200)),
            TreeNode(kind: .box, subtreeEnd: 4, layout: LayoutStyle(width: 100, height: 80))
        ], to: &core, patches: &patches)
        XCTAssertEqual(core.rootFrame, Rect(x: 0, y: 0, width: 100, height: 80))
        let glass = core.firstDescendant(of: core.rootHandle) { $0.target == 1 }
        XCTAssertEqual(core.layoutFrame(of: glass), Rect(x: 0, y: 0, width: 100, height: 80))
    }

    func testGlassRecipeAndShapePaintUpdatesUseDedicatedPatches() {
        var core = SurfaceCore(capacity: 16)
        var patches = PatchBuffer(capacity: 64)
        var tree = [
            TreeNode(kind: .glass, subtreeEnd: 2, content: Content(text: 1)),
            TreeNode(kind: .shape, subtreeEnd: 2, layout: LayoutStyle(width: 80, height: 40))
        ]
        apply(tree, to: &core, patches: &patches)
        XCTAssertEqual(glassPatches(patches), 2)
        apply(tree, to: &core, patches: &patches)
        XCTAssertEqual(patches.count, 0)

        tree[0].content.text = 2
        apply(tree, to: &core, patches: &patches)
        XCTAssertEqual(glassPatches(patches), 1)
        tree[1].content.glassShape = 2
        apply(tree, to: &core, patches: &patches)
        XCTAssertEqual(glassPatches(patches), 1)
        tree[1].content.params.x = 8
        apply(tree, to: &core, patches: &patches)
        XCTAssertEqual(glassPatches(patches), 1)
        tree[1].paint.cornerRadius = 26
        apply(tree, to: &core, patches: &patches)
        XCTAssertEqual(glassPatches(patches), 1)
        tree[0].paint = Paint(fill: Color(packed: 0xFF00_0040), shadowRadius: 6, blurRadius: 6, saturation: 1)
        apply(tree, to: &core, patches: &patches)
        XCTAssertEqual(glassPatches(patches), 1)
        for index in 0 ..< patches.count {
            switch patches.op(at: index) {
            case .setPaint,
                 .setText:
                XCTFail("Glass paint and recipe must not draw generic content")
            default:
                break
            }
        }
    }

    func testGlassAndShapeWireKindsPreserveVariantAndDecorativeFlag() {
        for kind in [ElementKind.glass, .shape] {
            var header = omni_wire_header()
            header.magic = OMNI_WIRE_MAGIC
            header.node_count = 1
            var wire = omni_wire_node()
            wire.kind = kind.rawValue
            wire.subtree_end = 1
            wire.width = 120
            wire.height = 80
            wire.text = 7
            wire.behavior_flags = UInt32(OMNI_NODE_BEHAVIOR_DECORATIVE) | 4
            wire.params.0 = 8
            var bytes = withUnsafeBytes(of: header) { Array($0) }
            bytes += withUnsafeBytes(of: wire) { Array($0) }
            let nodes = UnsafeMutablePointer<TreeNode>.allocate(capacity: 1)
            nodes.initialize(to: TreeNode(kind: .group, subtreeEnd: 1))
            defer {
                nodes.deinitialize(count: 1)
                nodes.deallocate()
            }
            let count = bytes.withUnsafeBytes { buffer in
                ShellWireDecoder.decode(buffer.baseAddress!, length: buffer.count, into: nodes, capacity: 1)
            }
            XCTAssertEqual(count, 1)
            XCTAssertEqual(nodes.pointee.kind, kind)
            XCTAssertEqual(nodes.pointee.content.text, 7)
            XCTAssertEqual(nodes.pointee.content.glassShape, 2)
            XCTAssertEqual(nodes.pointee.content.params.x, 8)
            XCTAssertTrue(nodes.pointee.content.decorative)
            XCTAssertFalse(nodes.pointee.content.acceptsPointer)
            XCTAssertEqual(nodes.pointee.layout.width, 120)
            XCTAssertEqual(nodes.pointee.layout.height, 80)
            if kind == .glass { XCTAssertEqual(nodes.pointee.layout.axis, .overlay) }
        }
    }
}
