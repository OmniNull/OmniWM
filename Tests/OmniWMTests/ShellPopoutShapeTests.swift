// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class ShellPopoutShapeTests: XCTestCase {
    func testABridgeJoinsThePopoutToItsBarItem() {
        let anchor = ShellAnchor(
            frame: CGRect(x: 100, y: 975, width: 20, height: 20),
            level: .statusBar,
            container: CGRect(x: 0, y: 970, width: 1000, height: 30)
        )
        let content = CGRect(x: 60, y: 766, width: 100, height: 200)
        let bridged = ShellPopoutGeometry.make(content: content, anchor: anchor, bridge: true)
        XCTAssertEqual(bridged.source, CGRect(x: 100, y: 970, width: 20, height: 30))
        XCTAssertEqual(bridged.panel, CGRect(x: 60, y: 766, width: 100, height: 234))
        XCTAssertEqual(bridged.bleed, Insets(top: 34))
        XCTAssertEqual(bridged.contentInPanel, CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(
            bridged.stage(anchor: anchor.frame),
            ShellShaderStage(anchor: CGPoint(x: 50, y: -19), content: CGRect(x: 0, y: 0, width: 100, height: 200))
        )
        XCTAssertEqual(bridged.surfacePoint(CGPoint(x: 70, y: 956)), CGPoint(x: 10, y: 10))

        let plain = ShellPopoutGeometry.make(content: content, anchor: anchor, bridge: false)
        XCTAssertEqual(plain.panel, content)
        XCTAssertNil(plain.source)
        XCTAssertEqual(plain.bleed, Insets())
        XCTAssertEqual(plain.stage(anchor: anchor.frame).anchor, CGPoint(x: 50, y: -19))

        let side = ShellAnchor(
            frame: CGRect(x: 2, y: 500, width: 20, height: 20),
            level: .statusBar,
            container: CGRect(x: 0, y: 0, width: 24, height: 1000)
        )
        let sideways = ShellPopoutGeometry.make(
            content: CGRect(x: 28, y: 400, width: 100, height: 200),
            anchor: side,
            bridge: true
        )
        XCTAssertEqual(sideways.source, CGRect(x: 0, y: 500, width: 24, height: 20))
        XCTAssertEqual(sideways.bleed, Insets(left: 28))

        let headless = ShellAnchor(frame: CGRect(x: 0, y: 0, width: 1, height: 1), level: .statusBar)
        XCTAssertNil(ShellPopoutGeometry.make(content: content, anchor: headless, bridge: true).source)
    }

    func testOnlyDrawnOrInteractiveElementsCatchThePointer() throws {
        let widget = try ShellRenderedWidget(name: "shape", source: """
        function render(ctx)
            return ui.box{ w = 0, h = 0 }
        end
        function popout(ctx)
            local children = {
                ui.box{ w = 40, h = 10, fill = "accent" },
                ui.box{ w = 40, h = 10 },
                ui.box{ w = 40, h = 10, onClick = "focus left" },
            }
            local column = ui.column(children)
            if ctx.data.vars.shader then
                return ui.stack{ material = "clear", bridge = true, ui.shader{ source = "glow.metal" }, column }
            end
            return ui.stack{ material = "clear", column }
        end
        """)
        widget.set("vars") { $0.map(0) }
        widget.layoutPopout()
        let surface = widget.surface
        XCTAssertTrue(surface.chrome.clear)
        XCTAssertFalse(surface.bridges)
        XCTAssertTrue(surface.containsShape(at: CGPoint(x: 5, y: 5)))
        XCTAssertFalse(surface.containsShape(at: CGPoint(x: 5, y: 15)))
        XCTAssertTrue(surface.containsShape(at: CGPoint(x: 5, y: 25)))
        XCTAssertFalse(surface.containsShape(at: CGPoint(x: 45, y: 5)))

        widget.set("vars") { writer in
            writer.map(1)
            writer.key("shader")
            writer.string("1")
        }
        widget.layoutPopout()
        XCTAssertTrue(surface.bridges)
        XCTAssertTrue(surface.containsShape(at: CGPoint(x: 5, y: 15)))
        surface.setRootBleed(Insets(top: 8))
        ShellLayerScene.engineQueue.sync {}
        XCTAssertTrue(widget.layers().contains { $0.frame == CGRect(x: 0, y: -8, width: 40, height: 38) })
        XCTAssertFalse(surface.containsShape(at: CGPoint(x: 5, y: -4)))
    }
}
