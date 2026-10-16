// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellIslandPanelTests: XCTestCase {
    func testEnvelopeUsesDisplayTopAndNotchCoordinates() {
        let display = monitor(notch: 500 ... 700, height: 32, scale: 2)
        let geometry = ShellIslandGeometry(monitor: display, size: CGSize(width: 600, height: 300))
        XCTAssertEqual(geometry.frame, CGRect(x: 300, y: 500, width: 600, height: 300))
        XCTAssertEqual(geometry.notch, CGRect(x: 200, y: 0, width: 200, height: 32))
        XCTAssertEqual(
            geometry.screenRect(CGRect(x: 200, y: 10, width: 80, height: 20)),
            CGRect(x: 500, y: 770, width: 80, height: 20)
        )
        let data = ShellIslandData(monitor: display, geometry: geometry, visible: true, fullscreen: false)
        XCTAssertEqual(data.size, geometry.frame.size)
        XCTAssertEqual(data.notch, geometry.notch)
        XCTAssertEqual(data.menuBar, 32)
        XCTAssertEqual(data.scale, 2)
    }

    func testEnvelopeFitsExternalDisplayWithoutInventingNotch() {
        let display = monitor()
        let geometry = ShellIslandGeometry(monitor: display, size: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(geometry.frame, display.frame)
        XCTAssertNil(geometry.notch)
    }

    func testPanelDoesNotConstrainEnvelopeBelowMenuBar() {
        let panel = ShellIslandPanel(content: NSView())
        defer { panel.close() }
        let frame = CGRect(x: 300, y: 500, width: 600, height: 300)
        XCTAssertEqual(panel.constrainFrameRect(frame, to: nil), frame)
        XCTAssertTrue(panel.setEnvelope(frame))
        XCTAssertFalse(panel.setEnvelope(frame))
        XCTAssertEqual(panel.frame, frame)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isVisible)
    }

    func testContentChangesPreserveEnvelopeAndRegistration() throws {
        let widget = try ShellRenderedWidget(name: "island", source: """
        function render(ctx)
            return ui.box{ w = ctx.data.vars.width or 50, h = 30, fill = "accent" }
        end
        """)
        widget.set("vars") { $0.map(0) }
        let scene = SurfaceScene()
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator(scene: scene))
        let island = ShellIsland(
            surface: widget.surface,
            monitor: monitor(),
            size: CGSize(width: 600, height: 300),
            registry: registry
        )
        defer { island.close() }
        let frame = island.panel.frame
        XCTAssertEqual(widget.surface.layout.core.rootLimit.width, 600)
        XCTAssertEqual(widget.surface.layout.core.rootLimit.height, 300)
        for width in [50, 400, 100] {
            widget.set("vars") { writer in
                writer.map(1)
                writer.key("width")
                writer.number(Double(width))
            }
            widget.render(ShellBarData())
            island.layoutSurface()
            XCTAssertEqual(island.panel.frame, frame)
            XCTAssertEqual(
                island.regions,
                [CGRect(x: frame.minX, y: frame.maxY - 30, width: CGFloat(width), height: 30)]
            )
            XCTAssertEqual(scene.runtimeSnapshot().byKind[.shellIsland], 1)
            XCTAssertFalse(island.panel.isVisible)
        }
        island.update(monitor: monitor(), size: frame.size, visible: false, level: .mainMenu)
        XCTAssertEqual(island.panel.frame, frame)
        XCTAssertTrue(registry.visibleSurfaceIDs(kind: .shellIsland).isEmpty)
        island.close()
        XCTAssertEqual(scene.runtimeSnapshot().total, 0)
    }

    private func monitor(
        notch: ClosedRange<CGFloat>? = nil,
        height: CGFloat = 0,
        scale: CGFloat = 1
    ) -> Monitor {
        Monitor(
            id: .init(displayId: 43),
            displayId: 43,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 768),
            hasNotch: notch != nil,
            notchRange: notch,
            notchHeight: height,
            backingScale: scale,
            name: "Island test"
        )
    }
}
