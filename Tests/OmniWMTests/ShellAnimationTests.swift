// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellAnimationTests: XCTestCase {
    func testAnimateEncodesItsPreset() throws {
        let source = """
        function render(ctx)
            return ui.row{ ui.box{ animate = "bouncy" }, ui.box{ animate = "ease" }, ui.box{ animate = "wobbly" }, ui.box{},
                ui.box{ animate = 0.15, hoverAnimate = 0.1, hoverMaterial = "regular" }, ui.box{ animate = 9 },
                ui.box{ animate = -1 } }
        end
        """
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        defer { _ = omni_vm_destroy(vm) }
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_vm_load(vm, "=motion", source, source.utf8.count, 100_000_000, &error, error.count),
            OMNI_OK
        )
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        var stats = omni_render_stats()
        XCTAssertEqual(omni_instance_render(instance, OMNI_VIEW_BAR, 8_000_000, &stats, &error, error.count), OMNI_OK)
        var size = 0
        let bytes = try XCTUnwrap(omni_instance_output(instance, OMNI_VIEW_BAR, &size))
        let nodes = (1 ... 7).map { index in
            UnsafeRawPointer(bytes + MemoryLayout<omni_wire_header>.stride + index * MemoryLayout<omni_wire_node>
                .stride)
                .loadUnaligned(as: omni_wire_node.self)
        }
        XCTAssertEqual(
            nodes.map { ShellMotion(wire: $0.motion) },
            [.bouncy, .ease, nil, nil, .ease(seconds: 0.15), .ease(seconds: 2.51), nil]
        )
        XCTAssertEqual(ShellMotion(wire: nodes[4].hover_motion), .ease(seconds: 0.1))
        XCTAssertNil(ShellMotion(wire: nodes[0].hover_motion))
        XCTAssertEqual(nodes[4].hover_material, 3)
        XCTAssertEqual(nodes[0].hover_material, 0)
    }

    func testPresetsBuildTheirTimingCurves() {
        let ease = ShellAnimation(motion: .ease, speed: 2).make("opacity")
        XCTAssertFalse(ease is CASpringAnimation)
        XCTAssertEqual(ease.duration, 0.1, accuracy: 0.0001)
        let bouncy = ShellAnimation(motion: .bouncy, speed: 1).make("bounds")
        let smooth = ShellAnimation(motion: .smooth, speed: 1).make("bounds")
        XCTAssertTrue(bouncy is CASpringAnimation)
        XCTAssertEqual(bouncy.duration, (bouncy as? CASpringAnimation)?.settlingDuration ?? 0, accuracy: 0.0001)
        XCTAssertTrue(smooth is CASpringAnimation)
        XCTAssertEqual((smooth as? CASpringAnimation)?.bounce ?? -1, 0, accuracy: 0.001)
    }

    func testHoverPaintsTheHoverMaterialFillScaleAndOpacity() {
        let base = Paint(fill: Color(packed: 0x0000_00FF, role: 0), opacity: 0.5)
        let plain = ShellWidgetSurface.hovered(base, by: Content())
        XCTAssertEqual(plain.material, 0)
        XCTAssertEqual(plain.opacity, 0.5)
        let hovered = ShellWidgetSurface.hovered(
            base,
            by: Content(hoverScale: 1.05, hoverOpacity: 1, hoverMaterial: 3)
        )
        XCTAssertEqual(hovered.material, 3)
        XCTAssertEqual(hovered.scale, 1.05)
        XCTAssertEqual(hovered.opacity, 1)
        XCTAssertEqual(hovered.fill, base.fill)
        XCTAssertTrue(Content(hoverMaterial: 3).hasHoverEffect)
    }

    func testHoverTransitionsUseTheirOwnTimingAndFallBackToAnimate() throws {
        let both = "function render(ctx) return ui.box{w=10,h=10,animate=0.15,hoverAnimate=0.1} end"
        let cases: [(String, Bool, ShellMotion?)] = [
            (both, true, .ease(seconds: 0.1)), (both, false, .ease(seconds: 0.15)),
            ("function render(ctx) return ui.box{w=10,h=10,animate='bouncy'} end", true, .bouncy),
            ("function render(ctx) return ui.box{w=10,h=10} end", true, nil)
        ]
        for (source, hover, expected) in cases {
            let widget = try ShellRenderedWidget(name: "hover-motion", source: source)
            widget.render(ShellBarData())
            let handle = widget.surface.layout.core.rootHandle
            XCTAssertNotEqual(handle, .none)
            XCTAssertEqual(widget.surface.animation(for: handle, hover: hover)?.motion, expected)
        }
    }

    func testScaledElementsGrowAroundTheirCentreAndCarryAShadow() throws {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        let shadow = CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 0.5)
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .image, after: -1),
            .frame(slot: 0, rect: CGRect(x: 10, y: 0, width: 20, height: 20), animation: nil),
            .paint(
                slot: 0,
                ShellLayerPaint(
                    fill: nil,
                    border: nil,
                    borderWidth: 0,
                    radius: 0,
                    opacity: 1,
                    scale: 1.1,
                    shadow: shadow,
                    shadowRadius: 4
                ),
                animation: nil
            )
        ], animated: false)
        let state = ShellLayerScene.engineQueue.sync {
            let layer = container.sublayers?.first
            return (layer?.frame, layer?.shadowColor, layer?.shadowRadius, layer?.shadowOpacity)
        }
        let frame = try XCTUnwrap(state.0)
        XCTAssertEqual(frame.midX, 20, accuracy: 0.001)
        XCTAssertEqual(frame.width, 22, accuracy: 0.001)
        XCTAssertEqual(state.1, shadow)
        XCTAssertEqual(state.2, 4)
        XCTAssertEqual(state.3, 1)
    }

    func testABorderWidthWithoutABorderColorDrawsNoBorder() {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .image, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 20), animation: nil),
            .paint(
                slot: 0,
                ShellLayerPaint(
                    fill: nil,
                    border: nil,
                    borderWidth: 1,
                    radius: 4,
                    opacity: 1,
                    scale: 1,
                    shadow: nil,
                    shadowRadius: 0
                ),
                animation: nil
            )
        ], animated: false)
        let border = ShellLayerScene.engineQueue.sync { container.sublayers?.first?.borderColor }
        XCTAssertEqual(border?.alpha, 0)
    }

    private func paint(
        rotation: CGFloat = 0,
        quarter: Bool = false,
        opacity: Float = 1,
        loop: ShellLoop? = nil
    ) -> ShellLayerPaint {
        ShellLayerPaint(
            fill: nil,
            border: nil,
            borderWidth: 0,
            radius: 0,
            opacity: opacity,
            scale: 1,
            shadow: nil,
            shadowRadius: 0,
            rotation: rotation,
            quarter: quarter,
            loop: loop
        )
    }

    func testQuarterTurnsKeepTheirContentUprightInsideTheTurnedBox() throws {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .image, after: -1),
            .paint(slot: 0, paint(rotation: .pi / 2, quarter: true), animation: nil),
            .frame(slot: 0, rect: CGRect(x: 10, y: 0, width: 20, height: 60), animation: nil)
        ], animated: false)
        let (bounds, frame) = ShellLayerScene.engineQueue.sync {
            (container.sublayers?.first?.bounds.size, container.sublayers?.first?.frame)
        }
        XCTAssertEqual(bounds, CGSize(width: 60, height: 20))
        let turned = try XCTUnwrap(frame)
        XCTAssertEqual(turned.minX, 10, accuracy: 0.001)
        XCTAssertEqual(turned.minY, 0, accuracy: 0.001)
        XCTAssertEqual(turned.width, 20, accuracy: 0.001)
        XCTAssertEqual(turned.height, 60, accuracy: 0.001)
    }

    func testLoopsKeepRunningThroughRepaintsUntilTheyChange() throws {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        let spin = try XCTUnwrap(ShellLoop("rotate 0 360 20;dx -4 4 5"))
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .image, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 40, height: 40), animation: nil)
        ], animated: false)
        let state = try ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            defer { CATransaction.commit() }
            let layer = try XCTUnwrap(scene.layers[0])
            scene.applyLoop(0, spin, to: layer)
            let rotate = layer.animation(forKey: "loop.rotate") as? CAKeyframeAnimation
            let drift = layer.animation(forKey: "loop.dx") as? CABasicAnimation
            layer.removeAnimation(forKey: "loop.dx")
            scene.applyLoop(0, spin, to: layer)
            let kept = layer.animation(forKey: "loop.dx") == nil
            scene.applyLoop(0, ShellLoop("dx 0 8 5"), to: layer)
            let changed = (layer.animation(forKey: "loop.dx") != nil, layer.animation(forKey: "loop.rotate") == nil)
            scene.applyLoop(0, nil, to: layer)
            return (rotate, drift, kept, changed, layer.animationKeys() ?? [])
        }
        let rotate = try XCTUnwrap(state.0)
        XCTAssertTrue(rotate.isAdditive)
        XCTAssertEqual(rotate.repeatCount, .infinity)
        XCTAssertEqual(rotate.duration, 20)
        XCTAssertEqual(rotate.values?.count, 73)
        let half = try XCTUnwrap(rotate.values?[36] as? NSValue).caTransform3DValue
        XCTAssertEqual(CGPoint.zero.applying(CATransform3DGetAffineTransform(half)).x, 40, accuracy: 0.001)
        let drift = try XCTUnwrap(state.1)
        XCTAssertEqual(drift.keyPath, "position.x")
        XCTAssertEqual(drift.fromValue as? CGFloat, -4)
        XCTAssertTrue(state.2)
        XCTAssertTrue(state.3.0)
        XCTAssertTrue(state.3.1)
        XCTAssertEqual(state.4, [])
        XCTAssertNil(ShellLoop("spin 0 1 2"))
        XCTAssertNil(ShellLoop("dx 0 1 0"))
    }
}
