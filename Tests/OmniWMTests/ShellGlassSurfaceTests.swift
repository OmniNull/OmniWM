// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellGlassSurfaceTests: XCTestCase {
    func testShapeOnlyChangesUseLiveParentMotion() throws {
        let widget = try ShellRenderedWidget(name: "glass-motion", source: """
        function render(ctx) return ui.box{w=1,h=1} end
        function popout(ctx)
            local step = ctx.data.seconds
            local animation = nil
            if step ~= 2 then animation = 'spring' end
            return ui.stack{w=120,h=100,ui.glass{key='body',animate=animation,
                ui.shape{key='card',w=40+step*5,h=50,radius=step+4}}}
        end
        """, resources: ShellResources(motion: MotionPolicy(animationsEnabled: true)))
        widget.set("seconds") { $0.number(1) }
        widget.layoutPopout()
        let shape = try XCTUnwrap(widget.surface.layout.core.elements { _ in true }.first {
            widget.surface.layout.core.kind(of: $0) == .shape
        })
        XCTAssertEqual(widget.surface.layout.core.content(of: shape).motion, 0)
        for step in [2, 3] {
            widget.set("seconds") { $0.number(Double(step)) }
            widget.layoutPopout()
            let commands = widget.surface.commands(text: widget.text)
            var frameFound = false
            var shapeFound = false
            for command in commands {
                switch command {
                case let .frame(slot, _, animation) where slot == shape.slot:
                    frameFound = true
                    XCTAssertEqual(animation?.motion.isSpring == true, step == 3)
                case let .glass(slot, _, animation) where slot == shape.slot:
                    shapeFound = true
                    XCTAssertEqual(animation?.motion.isSpring == true, step == 3)
                default:
                    break
                }
            }
            XCTAssertTrue(frameFound)
            XCTAssertTrue(shapeFound)
            ShellLayerScene.engineQueue.sync {
                XCTAssertNil(widget.surface.scene.layers[shape.slot]?.animation(forKey: "position.x"))
                XCTAssertNil(widget.surface.scene.layers[shape.slot]?.animation(forKey: "bounds.size.width"))
            }
        }
    }

    func testAnimatedInsertionDoesNotSpringCanvasFromZero() throws {
        let widget = try ShellRenderedWidget(name: "glass-insert", source: """
        function render(ctx) return ui.box{w=1,h=1} end
        function popout(ctx)
            return ui.stack{w=96,h=96,ctx.data.seconds > 0 and
                ui.glass{key='body',animate='spring',ui.shape{w=80,h=80,radius=12}} or ui.box{w=1,h=1}}
        end
        """, resources: ShellResources(motion: MotionPolicy(animationsEnabled: true)))
        widget.set("seconds") { $0.number(0) }
        widget.layoutPopout()
        let renderer = try ShellLayerScene.engineQueue.sync {
            widget.surface.scene.container.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
            let renderer = try ShellOffscreenRenderer(root: widget.surface.scene.container, width: 96, height: 96)
            _ = try renderer.render(paused: CACurrentMediaTime())
            return renderer
        }
        widget.set("seconds") { $0.number(1) }
        widget.layoutPopout()
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(widget.surface.scene.glassBodies.values.first)
            guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
            let targets = [body.layer] + (body.layer.sublayers ?? []) + (body.layer.sublayers ?? []).compactMap(\.mask)
            for target in targets {
                for channel in ShellGlassBody.Channel.geometry {
                    XCTAssertNil(target.animation(forKey: channel.key))
                }
            }
            _ = try renderer.render()
            XCTAssertEqual(body.layer.bounds.size, CGSize(width: 96, height: 96))
            for mask in targets.compactMap(\.mask) {
                XCTAssertEqual((mask.presentation() ?? mask).bounds.size, CGSize(width: 96, height: 96))
            }
        }
    }

    func testVisibleGlassCapturesPaddingWithoutBecomingAnElementTarget() throws {
        let widget = try ShellRenderedWidget(name: "glass-hit", source: """
        function render(ctx) return ui.box{w=1,h=1} end
        function popout(ctx)
            return ui.stack{material='clear',w=120,h=100,
                ui.glass{ui.shape{w=100,h=80,radius=20}}}
        end
        """)
        widget.layoutPopout()
        widget.surface.view.frame = CGRect(origin: .zero, size: widget.surface.size)
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 60, y: 12)))
        XCTAssertFalse(widget.surface.containsShape(at: CGPoint(x: 11, y: 11)))
        XCTAssertTrue(widget.surface.islandRegions().contains { $0.contains(CGPoint(x: 60, y: 12)) })
        var path: [ElementHandle] = []
        widget.surface.layout.core.hitPath(
            x: 60,
            y: 50,
            matching: { _ in true },
            clip: { _, _, _ in true },
            into: &path
        )
        XCTAssertEqual(path, [widget.surface.layout.core.rootHandle])
        XCTAssertNil(widget.surface.command(at: CGPoint(x: 60, y: 50)))
    }

    func testGlassAllowsParentActions() throws {
        let widget = try ShellRenderedWidget(name: "glass-parent", source: """
        function render(ctx) return ui.box{w=1,h=1} end
        function popout(ctx)
            return ui.stack{material='clear',w=120,h=100,onClick='focus left',
                ui.glass{ui.shape{w=100,h=80,radius=20}}}
        end
        """)
        widget.layoutPopout()
        XCTAssertEqual(widget.surface.command(at: CGPoint(x: 60, y: 50)), "focus left")
    }

    func testFrameHoleAndEllipseCornersStayTransparentToPointerCoverage() throws {
        let widget = try ShellRenderedWidget(name: "glass-ring", source: """
        function render(ctx) return ui.box{w=1,h=1} end
        function popout(ctx)
            return ui.stack{material='clear',w=120,h=100,
                ui.glass{ui.shape{shape='frame',radius=24,thickness=8}},
                ui.glass{ui.shape{shape='ellipse',w=20,h=10,dx=40}}}
        end
        """)
        widget.layoutPopout()
        widget.surface.view.frame = CGRect(origin: .zero, size: widget.surface.size)
        XCTAssertFalse(widget.surface.containsShape(at: CGPoint(x: 60, y: 50)))
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 3, y: 50)))
        XCTAssertFalse(widget.surface.containsShape(at: CGPoint(x: 1, y: 1)))
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 12, y: 12)))
        let regions = widget.surface.islandRegions()
        XCTAssertFalse(regions.contains { $0.contains(CGPoint(x: 60, y: 50)) })
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 3, y: 50)) })
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 12, y: 12)) })
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 100, y: 50)))
        XCTAssertFalse(widget.surface.containsShape(at: CGPoint(x: 91, y: 46)))
    }

    func testResetDropsGlassCoverageHandlesBeforeRebuilding() throws {
        let widget = try ShellRenderedWidget(name: "glass-reset", source: """
        function render(ctx) return ui.box{w=1,h=1} end
        function popout(ctx) return ui.stack{material='clear',w=96,h=96,ui.glass{ui.shape{radius=12}}} end
        """)
        widget.layoutPopout()
        for _ in 0 ..< 2 {
            XCTAssertEqual(widget.surface.glassShapeHandles.count, 1)
            widget.surface.reset(text: widget.text)
            XCTAssertTrue(widget.surface.glassShapeHandles.isEmpty)
            widget.layoutPopout()
            XCTAssertEqual(widget.surface.glassShapeHandles.count, 1)
            XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 48, y: 48)))
        }
    }
}
