// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellShapeHitTests: XCTestCase {
    func testClicksFollowAPathsOutline() throws {
        let widget = try ShellRenderedWidget(name: "shape", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.stack{ material = "clear",
                ui.path{ d = "M0 0 L20 0 L0 20 Z", w = 20, h = 20, fill = "accent", onClick = "focus left" } }
        end
        """)
        widget.layoutPopout()
        XCTAssertEqual(widget.surface.command(at: CGPoint(x: 4, y: 4)), "focus left")
        XCTAssertNil(widget.surface.command(at: CGPoint(x: 16, y: 16)))
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 4, y: 4)))
        XCTAssertFalse(widget.surface.containsShape(at: CGPoint(x: 16, y: 16)))
    }

    func testStrokedPathsTakeClicksOnTheirStroke() throws {
        let widget = try ShellRenderedWidget(name: "shape", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.stack{ material = "clear",
                ui.path{ d = "M2 12 H22", w = 24, h = 24, border = "accent", borderWidth = 4, onClick = "focus up" } }
        end
        """)
        widget.layoutPopout()
        XCTAssertEqual(widget.surface.command(at: CGPoint(x: 12, y: 13)), "focus up")
        XCTAssertNil(widget.surface.command(at: CGPoint(x: 12, y: 20)))
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 12, y: 11)))
    }

    func testAPathResizesWhenOnlyItsViewBoxChanges() throws {
        let widget = try ShellRenderedWidget(name: "shape", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            local side = ctx.data.seconds
            return ui.row{ ui.path{ d = "M0 0 L1 0 L1 1 Z", viewBox = { 0, 0, side, side } } }
        end
        """)
        widget.set("seconds") { $0.number(20) }
        widget.layoutPopout()
        XCTAssertEqual(widget.surface.size, CGSize(width: 20, height: 20))
        widget.set("seconds") { $0.number(32) }
        widget.layoutPopout()
        XCTAssertEqual(widget.surface.size, CGSize(width: 32, height: 32))
    }

    func testAMaskedStackCatchesClicksOnlyInsideItsMask() throws {
        let widget = try ShellRenderedWidget(name: "shape", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.stack{ material = "clear",
                ui.stack{ w = 40, h = 20, fill = "accent", onClick = "focus right",
                    ui.path{ d = "M0 0 L10 0 L0 10 Z", viewBox = { 0, 0, 10, 10 }, mask = true },
                    ui.box{ w = 40, h = 20, fill = "foreground", onClick = "focus down" } } }
        end
        """)
        widget.layoutPopout()
        XCTAssertEqual(widget.surface.command(at: CGPoint(x: 4, y: 4)), "focus down")
        XCTAssertNil(widget.surface.command(at: CGPoint(x: 36, y: 16)))
        XCTAssertFalse(widget.surface.hasAction(at: CGPoint(x: 36, y: 16)))
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 4, y: 4)))
        XCTAssertFalse(widget.surface.containsShape(at: CGPoint(x: 36, y: 16)))
    }

    func testAMaskInsideAScrolledContainerFollowsTheScroll() throws {
        let widget = try ShellRenderedWidget(name: "shape", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.stack{ material = "clear",
                ui.column{ w = 40, h = 30, scroll = true, fill = "accent", onClick = "focus right",
                    ui.box{ w = 40, h = 20 },
                    ui.path{ d = "M0 0 L10 0 L10 10 L0 10 Z", viewBox = { 0, 0, 10, 10 }, w = 40, h = 20, mask = true } } }
        end
        """)
        widget.layoutPopout()
        XCTAssertNil(widget.surface.command(at: CGPoint(x: 5, y: 15)))
        XCTAssertEqual(widget.surface.command(at: CGPoint(x: 5, y: 25)), "focus right")
        XCTAssertTrue(widget.surface.scroll(
            at: CGPoint(x: 5, y: 25),
            event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: 10)
        ))
        XCTAssertEqual(widget.surface.command(at: CGPoint(x: 5, y: 15)), "focus right")
        XCTAssertNil(widget.surface.command(at: CGPoint(x: 5, y: 5)))
    }

    func testArrowKeysMoveBetweenLinesOfDifferentLengths() throws {
        let widget = try ShellRenderedWidget(name: "keys", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            local function item(index) return ui.box{ w = 20, h = 20, onClick = "focus " .. index } end
            return ui.column{ gap = 4,
                ui.row{ gap = 4, item(1), item(2), item(3) },
                ui.row{ gap = 4, item(4), item(5) } }
        end
        """)
        widget.surface.focusAxis = .horizontal
        widget.layoutPopout()
        let keys: [(code: Int, expected: String)] = [
            (kVK_RightArrow, "focus 2"), (kVK_RightArrow, "focus 3"), (kVK_DownArrow, "focus 5"),
            (kVK_UpArrow, "focus 2"), (kVK_UpArrow, "focus 5"), (kVK_LeftArrow, "focus 4"), (kVK_Tab, "focus 5")
        ]
        for key in keys {
            XCTAssertTrue(widget.surface.handleKey(UInt16(key.code), shift: false))
            XCTAssertTrue(widget.surface.handleKey(UInt16(kVK_Return), shift: false))
            XCTAssertEqual(widget.clicks.last?.action, key.expected, "\(key.code)")
        }
    }

    func testClearPopoutsLetClicksThroughAShadersTransparentPixels() async throws {
        executionTimeAllowance = 60
        guard ShellShaderGPU.device != nil else { throw MissingTestPrerequisite("Metal is not available") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        float4 shade(float2 uv, constant OmniShader& shader) {
            return float4(1, 1, 1, uv.x < 0.5 ? 1 : 0);
        }
        """.utf8).write(to: directory.appendingPathComponent("half.metal"))
        let widget = try ShellRenderedWidget(name: "shape", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.stack{ material = "clear", w = 40, h = 20, ui.shader{ source = "half.metal" } }
        end
        """, directories: [directory])
        let program = widget.resources.shaders.program(source: "half.metal", directories: [directory])
        await waitForShaders(in: widget.resources.shaders) { !program.isCompiling }
        XCTAssertNotNil(program.pipeline, program.failure ?? "")
        let (shapeChanges, shapeChanged) = boundedChanges()
        var shapes = 0
        widget.surface.onShapeChange = {
            shapes += 1
            shapeChanged.yield()
        }
        widget.layoutPopout()
        let scene = widget.surface.scene
        let slot = try XCTUnwrap(widget.surface.shaders.keys.first)
        await waitForFrames(in: scene) {
            ShellLayerScene.engineQueue.sync { scene.shaders?.alpha(slot, at: .zero) != nil }
        }

        let clear = CGPoint(x: 30, y: 10)
        XCTAssertTrue(widget.surface.containsShape(at: clear))
        await shapeChanges.wait { !widget.surface.containsShape(at: clear) }
        XCTAssertFalse(widget.surface.containsShape(at: clear))
        XCTAssertGreaterThan(shapes, 0)
        let drawn = CGPoint(x: 10, y: 10)
        let shapesBeforeDrawn = shapes
        _ = widget.surface.containsShape(at: drawn)
        await shapeChanges.wait { shapes > shapesBeforeDrawn }
        XCTAssertTrue(widget.surface.containsShape(at: drawn))
    }
}
