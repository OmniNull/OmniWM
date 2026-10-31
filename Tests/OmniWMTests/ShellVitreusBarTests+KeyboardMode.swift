// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

private let unit = 1.35
private let modes: [KeyboardModeKind] = [.paused, .prefix, .window]

private struct ModePieces {
    let pill: CGRect
    let search: CGRect
    let logo: CGRect
    let controls: CGRect

    var all: [CGRect] {
        [pill, search, logo, controls]
    }
}

@MainActor
extension ShellVitreusBarTests {
    private func modeProbe(_ shell: URL) throws -> ShellRenderedWidget {
        let names = ([KeyboardModeKind.normal] + modes).map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        let size = VitreusFixture.monitor().frame.size
        let probe = try VitreusFixture.probe(shell, """
        local units = require("../lib/vitreus/units")
        local keyboardMode = require("../lib/keyboard-mode")
        function render(ctx)
            local bu = units.of({ size = { w = \(size.width), h = \(size.height) } }).bu
            local items = {}
            for _, mode in { \(names) } do
                for _, spec in { { "wide", false, 20 }, { "narrow", true, 12 } } do
                    local key, style = mode .. "-" .. spec[1], { keyboardMode = mode, vertical = spec[2] }
                    local chip = keyboardMode.chip(style, spec[3] * bu)
                    if chip then
                        chip.key = key
                        items[#items + 1] = chip
                    end
                    items[#items + 1] = ui.text{
                        key = key .. "-width", text = tostring(keyboardMode.width(ctx, style, spec[3] * bu)),
                    }
                end
            end
            return ui.column(items)
        end
        """)
        probe.render(ShellBarData())
        return probe
    }

    private func modeWidth(_ probe: ShellRenderedWidget, _ key: String) throws -> Double {
        let content = probe.surface.layout.core.content(of: try VitreusFixture.element(probe, key: key + "-width"))
        return try XCTUnwrap(Double(probe.text.string(content.text)), key)
    }

    private func modeStrings(_ widget: ShellRenderedWidget, _ key: String) throws -> [String] {
        let layout = widget.surface.layout
        let chip = try VitreusFixture.element(widget, key: key)
        let children = layout.core.elements { _ in true }.filter { layout.core.parent(of: $0) == chip }
        let texts = { (kind: ElementKind) in
            children.filter { layout.core.kind(of: $0) == kind }
                .map { widget.text.string(layout.core.content(of: $0).text) }
        }
        return [widget.text.string(layout.core.content(of: chip).help)] + texts(.symbol) + texts(.label)
    }

    @discardableResult
    private func assertModeChip(
        _ widget: ShellRenderedWidget, _ probe: ShellRenderedWidget, _ key: String, _ label: String
    ) throws -> Double {
        let width = try modeWidth(probe, key)
        XCTAssertEqual(try VitreusFixture.frame(probe, key: key).width, width, accuracy: 0.001, label)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "bar-omniwm-mode").width, width, accuracy: 0.001, label)
        XCTAssertEqual(try modeStrings(widget, "bar-omniwm-mode"), try modeStrings(probe, key), label)
        return width
    }

    private func modeGlyph(_ widget: ShellRenderedWidget) throws -> CGRect {
        let layout = widget.surface.layout
        let icon = try VitreusFixture.element(widget, key: "bar-omniwm-icon")
        let glyph = try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.parent(of: $0) == icon })
        return CGRect(layout.core.absoluteFrame(of: glyph))
    }

    private func modePieces(_ widget: ShellRenderedWidget, pill: String) throws -> ModePieces {
        try ModePieces(
            pill: VitreusFixture.frame(widget, key: pill), search: VitreusFixture.frame(widget, key: "bar-search"),
            logo: VitreusFixture.frame(widget, key: "bar-omniwm"),
            controls: VitreusFixture.frame(widget, key: "bar-controls")
        )
    }

    private func modeZone(_ widget: ShellRenderedWidget) throws -> [String] {
        let content = widget.surface.layout.core.content(of: try VitreusFixture.element(widget, key: "bar-omniwm"))
        return [content.action, content.secondaryAction, content.help].map(widget.text.string)
    }

    private func assertModeZone(
        _ widget: ShellRenderedWidget, _ zone: [String], at point: CGPoint, _ label: String
    ) throws {
        XCTAssertEqual(try modeZone(widget), zone, label)
        XCTAssertEqual(widget.surface.command(at: point), zone.first, label)
    }

    private func assertModeOff(
        _ widget: ShellRenderedWidget, _ bar: ShellBarData, _ base: ModePieces, pill: String, _ label: String
    ) throws {
        var bar = bar
        bar.style.keyboardMode = KeyboardModeKind.normal.rawValue
        VitreusFixture.show(widget, bar: bar)
        XCTAssertFalse(Self.has(widget, "bar-omniwm-mode"), label)
        for (rect, target) in zip(try modePieces(widget, pill: pill).all, base.all) {
            Self.assertRect(rect, target, label)
        }
    }

    func testTheKeyboardModeChipFollowsTheLogoAndWidensItsPieceOnHorizontalBars() throws {
        let shell = try shell()
        let probe = try modeProbe(shell)
        XCTAssertEqual(try ["normal-wide", "normal-narrow"].map { try modeWidth(probe, $0) }, [0, 0])
        XCTAssertFalse(Self.has(probe, "normal-wide") || Self.has(probe, "normal-narrow"))
        let layouts = [("island", false), ("island", true), ("ftop", false), ("fbottom", false), ("seg", false)]
        for (layout, fullWidth) in layouts {
            var bar = VitreusFixture.bar()
            bar.style.fullWidth = fullWidth
            let widget = try island(shell, settings: ["layout": .string(layout)], bar: bar)
            let pill = layout == "seg" ? "bar-hover-right" : "bar-hover"
            let base = try modePieces(widget, pill: pill)
            let zone = try modeZone(widget)
            let natural = layout == "seg" || layout == "island" && !fullWidth
            XCTAssertFalse(Self.has(widget, "bar-omniwm-mode"), layout)
            for mode in modes {
                let label = "\(layout) fullWidth=\(fullWidth) \(mode.rawValue)"
                bar.style.keyboardMode = mode.rawValue
                VitreusFixture.show(widget, bar: bar)
                let grow = try 4 * unit + assertModeChip(widget, probe, mode.rawValue + "-wide", label)
                let pieces = try modePieces(widget, pill: pill)
                let badge = try VitreusFixture.frame(widget, key: "bar-omniwm-mode")
                let glyph = try modeGlyph(widget)
                XCTAssertEqual(badge.height, 20 * unit, accuracy: 0.001, label)
                XCTAssertEqual(badge.minX - glyph.maxX, 4 * unit, accuracy: 0.001, label)
                XCTAssertEqual(badge.midY, glyph.midY, accuracy: 0.001, label)
                XCTAssertLessThanOrEqual(badge.maxX, pieces.controls.minX, label)
                let span = pieces.controls.midX - pieces.search.midX
                XCTAssertEqual(span, base.controls.midX - base.search.midX + grow, accuracy: 0.001, label)
                XCTAssertEqual(pieces.pill.width, base.pill.width + (natural ? grow : 0), accuracy: 0.001, label)
                if !natural { Self.assertRect(pieces.pill, base.pill, label) }
                XCTAssertEqual(pieces.logo.size, base.logo.size, label)
                try assertModeZone(widget, zone, at: CGPoint(x: pieces.logo.midX, y: pieces.logo.midY), label)
            }
            try assertModeOff(widget, bar, base, pill: pill, layout)
        }
    }

    func testVerticalStripsBadgeTheLogoCornerAndKeepEveryLevel() throws {
        let shell = try shell()
        let probe = try modeProbe(shell)
        for layout in ["left", "right"] {
            var bar = VitreusFixture.bar()
            let widget = try island(shell, settings: ["layout": .string(layout)], bar: bar)
            let base = try modePieces(widget, pill: "bar-hover")
            let zone = try modeZone(widget)
            XCTAssertFalse(Self.has(widget, "bar-omniwm-mode"), layout)
            for mode in modes {
                let label = "\(layout) \(mode.rawValue)"
                bar.style.keyboardMode = mode.rawValue
                VitreusFixture.show(widget, bar: bar)
                try assertModeChip(widget, probe, mode.rawValue + "-narrow", label)
                for (rect, target) in zip(try modePieces(widget, pill: "bar-hover").all, base.all) {
                    Self.assertRect(rect, target, label)
                }
                let badge = try VitreusFixture.frame(widget, key: "bar-omniwm-mode")
                let glyph = try modeGlyph(widget)
                XCTAssertEqual(badge.height, 12 * unit, accuracy: 0.001, label)
                XCTAssertEqual(badge.midX, glyph.maxX, accuracy: 0.001, label)
                XCTAssertEqual(badge.midY, glyph.maxY, accuracy: 0.001, label)
                XCTAssertTrue(base.logo.contains(badge), label)
                XCTAssertLessThanOrEqual(badge.maxY, base.controls.minY, label)
                try assertModeZone(widget, zone, at: CGPoint(x: badge.midX, y: badge.midY), label)
            }
            try assertModeOff(widget, bar, base, pill: "bar-hover", layout)
        }
    }
}
