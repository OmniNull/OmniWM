// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellPathTrackSceneTests: XCTestCase {
    private final class Clock {
        var time = CACurrentMediaTime()
    }

    func testRetiringARevealSubtreeClosesItsPencilContourOnTheSameNativeClock() throws {
        let widget = try ShellRenderedWidget(name: "path-track-closing", source: """
        function render(ctx)
            if ctx.data.seconds==1 then return ui.stack{key='root',w=256,h=100} end
            return ui.stack{key='root',w=256,h=100,
                ui.stack{key='panel',w=256,h=100,reveal={response=.3,bounce=.2},
                    ui.glass{key='body',w=256,h=100,backdrop=false,fill='#FFFFFFFF',shadow='#00000000',
                        ui.shape{key='pill',w=40,h=20,dx=60,dy=20,align='topLeading',radius=6,
                            morph={stops={{at=0,scale=0},{at=1}}}}},
                    ui.path{key='outline',w=256,h=100,decorative=true,border='#FFFFFFFF',borderWidth=1,fill=0,
                        d='M 66 20 Q 60 20 60 26 L 60 34 Q 60 40 66 40 L 94 40 Q 100 40 100 34 L 100 26 Q 100 20 94 20 Z',
                        morph={track='pill'}}}}
        end
        """)
        let clock = Clock()
        widget.surface.clock = { clock.time }
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(x: 0, y: 0, width: 256, height: 100)
            root.speed = 0
            root.timeOffset = clock.time
            return try ShellOffscreenRenderer(root: root, width: 256, height: 100)
        }
        defer { withExtendedLifetime(renderer) {} }
        widget.resources.motion.userAnimationsEnabled = true
        widget.set("seconds") { $0.number(0) }
        widget.render(ShellBarData())
        let panel = try element(widget, "panel")
        let shape = try element(widget, "pill")
        let outline = try element(widget, "outline")
        let scene = widget.surface.scene
        let opening = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(scene.shapeTracks.entries[shape.slot])
        }
        let path = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.layers[outline.slot] as? CAShapeLayer) }
        let native = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(scene.glassBodies[opening.body]?.lockstepLayers(shape.slot).first)
        }
        clock.time += 0.12
        let expected = opening.shape(at: clock.time)
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        try ShellLayerScene.engineQueue.sync {
            XCTAssertNil(scene.layers[panel.slot])
            XCTAssertEqual(scene.presence.retained.count, 1)
            XCTAssertNotNil(path.superlayer)
            try Self.assertClosing(path, native: native, expected: expected)
        }
    }

    private nonisolated static func assertClosing(
        _ path: CAShapeLayer, native: CALayer, expected: ShellGlassShape
    ) throws {
        let closing = try XCTUnwrap(path.animation(forKey: ShellLayerScene.pathTrackKey) as? CAKeyframeAnimation)
        let fill = try XCTUnwrap(native.animation(forKey: "omni.glass.position") as? CAKeyframeAnimation)
        XCTAssertEqual(closing.beginTime, fill.beginTime, accuracy: 1e-9)
        XCTAssertEqual(closing.duration, fill.duration, accuracy: 1e-9)
        XCTAssertEqual(closing.keyTimes, fill.keyTimes)
        XCTAssertFalse(closing.isRemovedOnCompletion)
        XCTAssertEqual(closing.fillMode, .forwards)
        let paths = try XCTUnwrap(closing.values as? [CGPath])
        let first = try XCTUnwrap(paths.first).boundingBoxOfPath
        XCTAssertEqual(first.width, expected.rect.width, accuracy: 1e-9)
        XCTAssertEqual(first.height, expected.rect.height, accuracy: 1e-9)
        XCTAssertEqual(paths.last?.boundingBoxOfPath.width, 0)
        XCTAssertEqual(paths.last?.boundingBoxOfPath.height, 0)
    }

    private func element(_ widget: ShellRenderedWidget, _ key: String) throws -> ElementHandle {
        let hash = key.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
            & ~(UInt64(3) << 62)
        return try XCTUnwrap(widget.surface.layout.core.elements { _ in true }.first {
            widget.surface.layout.core.key(of: $0) == hash
        })
    }
}
