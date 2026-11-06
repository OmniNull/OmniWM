// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

@MainActor
final class ShellBlurTests: XCTestCase {
    func testBlurDefaultsAndExplicitZeroPassThroughToNativeFilters() throws {
        ShellWidgetSurface.reducesTransparencyOverride = false
        defer { ShellWidgetSurface.reducesTransparencyOverride = nil }
        let widget = try ShellRenderedWidget(name: "blur", source: """
        function render(ctx)
            return ui.stack{ w = 100, h = 80, material = 'regular',
                blurRadius = ctx.state.radius, saturation = ctx.state.saturation,
                fill = '#ff000040', onClick = function(next)
                    next.state.radius = 0; next.state.saturation = 0
                end }
        end
        """)
        widget.render(ShellBarData())
        let node = try XCTUnwrap(widget.tree().first)
        XCTAssertEqual(node.paint.blurRadius, -1)
        XCTAssertEqual(node.paint.saturation, 1.8)
        let scene = widget.surface.scene
        let values = {
            ShellLayerScene.engineQueue.sync { () -> [CGFloat] in
                guard let entry = scene.backdrops.values.first,
                      let filters = entry.backdrop.filters as? [NSObject] else { return [] }
                return [
                    filters[0].value(forKey: "inputRadius") as? CGFloat ?? -1,
                    filters[1].value(forKey: "inputAmount") as? CGFloat ?? -1
                ]
            }
        }
        XCTAssertEqual(values(), [20, CGFloat(Float(1.8))])
        widget.invoke(node.content.action)
        widget.render(ShellBarData())
        XCTAssertEqual(widget.tree().first?.paint.blurRadius, 0)
        XCTAssertEqual(widget.tree().first?.paint.saturation, 0)
        XCTAssertEqual(values(), [0, 0])
        ShellLayerScene.engineQueue.sync {
            XCTAssertNotNil(scene.backdrops.values.first?.tint.backgroundColor)
        }
    }

    func testFillOnlyRepaintKeepsBackdropFilters() throws {
        ShellWidgetSurface.reducesTransparencyOverride = false
        defer { ShellWidgetSurface.reducesTransparencyOverride = nil }
        let widget = try ShellRenderedWidget(name: "blurfill", source: """
        function render(ctx)
            return ui.stack{ w = 100, h = 80, material = 'regular',
                fill = ctx.state.on and '#00ff0040' or '#ff000040',
                onClick = function(next) next.state.on = true end }
        end
        """)
        widget.render(ShellBarData())
        let node = try XCTUnwrap(widget.tree().first)
        let scene = widget.surface.scene
        let state = {
            ShellLayerScene.engineQueue.sync { () -> ([NSObject], CGColor?) in
                let entry = scene.backdrops.values.first
                return (entry?.backdrop.filters as? [NSObject] ?? [], entry?.tint.backgroundColor)
            }
        }
        let (before, beforeTint) = state()
        XCTAssertEqual(before.count, 2)
        widget.invoke(node.content.action)
        widget.render(ShellBarData())
        let (after, afterTint) = state()
        XCTAssertNotEqual(beforeTint, afterTint)
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(zip(before, after).allSatisfy { $0 === $1 })
    }

    func testInvalidBlurAndTextureDeclarationsAreRejected() throws {
        for properties in [
            "blurRadius = -1",
            "blurRadius = 65",
            "saturation = 4",
            "saturation = 0/0",
            "texture = {}",
            "texture = 'sample.png'"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return ui.box{\(properties)} end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, properties)
        }
    }
}
