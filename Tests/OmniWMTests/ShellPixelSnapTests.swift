// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellPixelSnapTests: XCTestCase {
    private func workspaceBar() -> ShellBarData {
        var bar = ShellBarData()
        bar.style.height = 30
        bar.style.inactive = 0.6
        bar.workspaces = (1 ... 7).map { index in
            let window = ShellBarWindow(id: "ow_\(index)", title: "App", focused: false, hidden: false)
            let item = ShellBarItem(
                id: "ow_\(index)", bundle: "com.apple.finder", name: "Finder", focused: index == 4, count: 1,
                hidden: 0, windows: [window]
            )
            return ShellBarWorkspace(id: "\(index)", name: "\(index)", focused: index == 4, windows: [item])
        }
        return bar
    }

    private func offGridContent(_ widget: ShellRenderedWidget, scale: CGFloat) throws -> [String] {
        let root = try XCTUnwrap(widget.surface.view.layer)
        func onGrid(_ value: CGFloat) -> Bool {
            abs(value * scale - (value * scale).rounded()) < 0.001
        }
        return widget.layers().filter { $0 !== root && $0.contents != nil }.compactMap { layer in
            let frame = layer.convert(layer.bounds, to: root)
            return [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(onGrid) ? nil : "\(frame)"
        }
    }

    func testWorkspaceTextAndIconsLandOnWholePixelsAtOneX() throws {
        let widget = try ShellRenderedWidget(source: ShellRenderedWidget.bundledSource("workspaces"), scale: 1)
        widget.render(workspaceBar())
        XCTAssertGreaterThanOrEqual(widget.layers().filter { $0.contents != nil }.count, 14)
        XCTAssertEqual(try offGridContent(widget, scale: 1), [])
    }

    func testTextUnderARotatedGroupKeepsItsSize() throws {
        func labelSize(rotate: Int) throws -> CGSize {
            let widget = try ShellRenderedWidget(name: "rotated", source: """
            function render(ctx)
                return ui.box{ w = 40, h = 40, rotate = \(rotate), ui.text{ text = "7" } }
            end
            """, scale: 1)
            widget.render(ShellBarData())
            return try XCTUnwrap(widget.layers().first { $0.contents != nil }).bounds.size
        }
        XCTAssertEqual(try labelSize(rotate: 45), try labelSize(rotate: 0))
    }

    func testTextReturnsToItsLayoutFrameWhenItsGroupStartsRotating() throws {
        let widget = try ShellRenderedWidget(name: "turning", source: """
        function render(ctx)
            return ui.box{ w = 40, h = 40, rotate = ctx.data.turn or 0, ui.text{ text = "7" } }
        end
        """, scale: 1)
        func label() throws -> CALayer {
            try XCTUnwrap(widget.layers().first { $0.contents != nil })
        }
        widget.render(ShellBarData())
        XCTAssertEqual(try label().position.y, 13)
        widget.set("turn") { $0.number(45) }
        widget.render(ShellBarData())
        XCTAssertEqual(try label().position.y, 12.5)
    }

    func testPixelAlignmentKeepsEqualSizesAndHairlines() {
        let first = ShellLayerScene.pixelAligned(CGRect(x: 33.875, y: 4.5625, width: 16.875, height: 16.875), scale: 1)
        let second = ShellLayerScene.pixelAligned(CGRect(x: 100.5, y: 4.5625, width: 16.875, height: 16.875), scale: 1)
        XCTAssertEqual(first, CGRect(x: 34, y: 5, width: 17, height: 17))
        XCTAssertEqual(second.size, first.size)
        XCTAssertEqual(
            ShellLayerScene.pixelAligned(CGRect(x: 0, y: 0, width: 0.3, height: 0), scale: 1).size,
            CGSize(width: 1, height: 0)
        )
    }
}
