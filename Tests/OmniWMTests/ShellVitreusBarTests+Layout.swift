// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
extension ShellVitreusBarTests {
    private func logoGlyph(_ widget: ShellRenderedWidget) throws -> CGRect {
        let layout = widget.surface.layout
        let icon = try VitreusFixture.element(widget, key: "bar-omniwm-icon")
        let glyph = try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.parent(of: $0) == icon })
        return CGRect(layout.core.absoluteFrame(of: glyph))
    }

    private func layoutMark(_ widget: ShellRenderedWidget) throws -> (frame: CGRect, strings: [String]) {
        let mark = try VitreusFixture.element(widget, key: "bar-omniwm-layout")
        let content = widget.surface.layout.core.content(of: mark)
        return try (
            VitreusFixture.frame(widget, key: "bar-omniwm-layout"),
            [content.text, content.help].map(widget.text.string)
        )
    }

    private func markGeometry(_ shell: URL) throws -> (size: CGFloat, gap: CGFloat) {
        let screen = VitreusFixture.monitor().frame.size
        let probe = try VitreusFixture.probe(shell, """
        local units = require("../lib/vitreus/units")
        local buttons = require("../lib/vitreus/bar/buttons")
        function render(ctx)
            local bu = units.of({ size = { w = \(screen.width), h = \(screen.height) } }).bu
            return ui.column{
                ui.text{ key = "mark-size", text = tostring(buttons.mark.size * bu) },
                ui.text{ key = "mark-gap", text = tostring(buttons.mark.gap * bu) },
            }
        end
        """)
        probe.render(ShellBarData())
        func value(_ key: String) throws -> CGFloat {
            let content = probe.surface.layout.core.content(of: try VitreusFixture.element(probe, key: key))
            return try CGFloat(XCTUnwrap(Double(probe.text.string(content.text)), key))
        }
        return try (value("mark-size"), value("mark-gap"))
    }

    private func layoutPieces(_ widget: ShellRenderedWidget, pill: String) throws -> [CGRect] {
        try [pill, "bar-search", "bar-controls"].map { try VitreusFixture.frame(widget, key: $0) }
    }

    func testTheLayoutMarkSitsBesideTheLogoInsideTheOmniWMButton() throws {
        let shell = try shell()
        let geometry = try markGeometry(shell)
        let extent = geometry.size + geometry.gap
        let layouts = [
            ("island", false), ("island", true), ("ftop", false), ("fbottom", false), ("seg", false),
            ("left", false), ("right", false)
        ]
        for (name, fullWidth) in layouts {
            let vertical = name == "left" || name == "right"
            let pill = name == "seg" ? "bar-hover-right" : "bar-hover"
            var bar = VitreusFixture.bar()
            bar.style.fullWidth = fullWidth
            let widget = try island(shell, settings: ["layout": .string(name)], bar: bar)
            let unmarked = try layoutPieces(widget, pill: pill)
            let unmarkedButton = try VitreusFixture.frame(widget, key: "bar-omniwm")
            for mode in [KeyboardModeKind.normal, .paused] {
                bar.style.keyboardMode = mode.rawValue
                bar.layout = nil
                VitreusFixture.show(widget, bar: bar)
                let base = try layoutPieces(widget, pill: pill)
                let baseButton = try VitreusFixture.frame(widget, key: "bar-omniwm")
                let baseGlyph = try logoGlyph(widget)
                let chipGap = try mode == .paused
                    ? VitreusFixture.frame(widget, key: "bar-omniwm-mode").minX - baseGlyph.maxX : 0
                for layout in [ActiveLayoutKind.niri, .dwindle] {
                    let label = "\(name) fullWidth=\(fullWidth) \(mode.rawValue) \(layout.rawValue)"
                    bar.layout = layout
                    VitreusFixture.show(widget, bar: bar)
                    let mark = try layoutMark(widget)
                    let glyph = try logoGlyph(widget)
                    let button = try VitreusFixture.frame(widget, key: "bar-omniwm")
                    let pieces = try layoutPieces(widget, pill: pill)
                    let rounding = CGFloat.floatRounding(operations: 8, at: max(button.maxX, button.maxY))
                    XCTAssertEqual(
                        mark.strings,
                        [StatusBarController.layoutSymbolName(layout), StatusBarController.layoutDisplayName(layout)],
                        label
                    )
                    XCTAssertTrue(button.contains(mark.frame), label)
                    XCTAssertEqual(mark.frame.width, geometry.size, accuracy: rounding, label)
                    XCTAssertEqual(mark.frame.height, geometry.size, accuracy: rounding, label)
                    XCTAssertEqual(mark.frame.minX - glyph.maxX, geometry.gap, accuracy: rounding, label)
                    XCTAssertEqual(mark.frame.midY, glyph.midY, accuracy: rounding, label)
                    XCTAssertEqual(glyph.size, baseGlyph.size, label)
                    XCTAssertEqual(
                        widget.surface.command(at: CGPoint(x: mark.frame.midX, y: mark.frame.midY)),
                        "shell menu",
                        label
                    )
                    if vertical {
                        XCTAssertEqual((glyph.minX + mark.frame.maxX) / 2, baseGlyph.midX, accuracy: rounding, label)
                        Self.assertRect(button, baseButton, label)
                        for (rect, target) in zip(pieces, base) {
                            Self.assertRect(rect, target, label)
                        }
                    } else {
                        XCTAssertEqual(button.width, baseButton.width + extent, accuracy: rounding, label)
                        XCTAssertEqual(
                            pieces[2].midX - pieces[1].midX,
                            base[2].midX - base[1].midX + extent,
                            accuracy: rounding,
                            label
                        )
                    }
                    guard mode == .paused else {
                        XCTAssertFalse(Self.has(widget, "bar-omniwm-mode"), label)
                        continue
                    }
                    let chip = try VitreusFixture.frame(widget, key: "bar-omniwm-mode")
                    if vertical {
                        XCTAssertEqual(chip.midX, glyph.maxX, accuracy: rounding, label)
                    } else {
                        XCTAssertEqual(chip.minX - mark.frame.maxX, chipGap, accuracy: rounding, label)
                    }
                }
            }
            bar.layout = nil
            bar.style.keyboardMode = KeyboardModeKind.normal.rawValue
            VitreusFixture.show(widget, bar: bar)
            XCTAssertFalse(Self.has(widget, "bar-omniwm-layout"), name)
            Self.assertRect(try VitreusFixture.frame(widget, key: "bar-omniwm"), unmarkedButton, name)
            for (rect, target) in zip(try layoutPieces(widget, pill: pill), unmarked) {
                Self.assertRect(rect, target, name)
            }
        }
    }
}
