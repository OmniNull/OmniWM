// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class ShellLakeMotionTests: XCTestCase {
    private func digits(options: String = "{size=20,width=14,height=25}") throws -> ShellRenderedWidget {
        let directory = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake/lib/lake")
        let modules = try ["motion", "digits"].map { name in
            ShellWidgetSource.Module(
                path: "lib/lake/\(name).luau",
                source: try String(contentsOf: directory.appendingPathComponent("\(name).luau"), encoding: .utf8)
            )
        }
        return try ShellRenderedWidget(name: "digits", source: """
        local digits = require("../lib/lake/digits")
        function render(ctx) return digits.render(ctx.data.title, \(options)) end
        """, modules: modules, chunk: "@widgets/digits-test/init.luau")
    }

    func testDigitStripUpdatesOnlyRetainedOffsetsAcrossRollover() throws {
        let widget = try digits()
        widget.set("title") { $0.string("19") }
        widget.render(ShellBarData())
        let surface = widget.surface
        let strips = surface.layout.core.elements { $0.motionCurve == 255 }.sorted {
            surface.layout.core.absoluteFrame(of: $0).x < surface.layout.core.absoluteFrame(of: $1).x
        }
        XCTAssertEqual(strips.count, 2)
        XCTAssertEqual(surface.size, CGSize(width: 28, height: 25))
        XCTAssertEqual(widget.tree().count, 47)
        XCTAssertEqual(widget.tree().filter { $0.kind == .label }.count, 20)
        XCTAssertEqual(strips.map { surface.layout.core.layoutFrame(of: $0).y }, [-25, -225])
        widget.set("title") { $0.string("20") }
        widget.render(ShellBarData())
        XCTAssertTrue(strips.allSatisfy { surface.layout.core.contains($0) })
        XCTAssertEqual(strips.map { surface.layout.core.layoutFrame(of: $0).y }, [-50, 0])
        XCTAssertFalse((0 ..< surface.layout.patches.count).contains { index in
            switch surface.layout.patches.op(at: index) {
            case .insert,
                 .remove,
                 .setText: true
            default: false
            }
        })
        let scene = surface.scene
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.masks.count }, 2)
    }

    func testDigitPrototypePreservesUnicodeAndBoundsItsRetainedTree() throws {
        let widget = try digits()
        widget.set("title") { $0.string("12:34\u{202f}PM") }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains(":"))
        XCTAssertTrue(widget.strings().contains("\u{202f}"))
        XCTAssertTrue(widget.strings().contains("P"))
        XCTAssertTrue(widget.strings().contains("M"))
        widget.set("title") { $0.string(String(repeating: "9", count: 16)) }
        widget.render(ShellBarData())
        XCTAssertEqual(widget.tree().count, 369)
        let long = String(repeating: "9", count: 17)
        widget.set("title") { $0.string(long) }
        widget.render(ShellBarData())
        XCTAssertEqual(widget.tree().count, 1)
        XCTAssertEqual(widget.strings(), [long])
    }

    func testDigitMotionCanBeDisabledUsingThePublicAnimationProperty() throws {
        let widget = try digits(options: "{size=20,width=14,height=25,animate='none'}")
        widget.set("title") { $0.string("09") }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.tree().allSatisfy { $0.content.motion == 0 })
        XCTAssertEqual(widget.surface.size, CGSize(width: 28, height: 25))
    }
}
