// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import TOML
import XCTest

@MainActor
extension ShellVitreusDeskTests {
    private static let stock: [(name: String, color: UInt32)] = [
        ("ink", 0xF5F7F5), ("faint", 0xC2C7CC), ("mint", 0x9ED6BD), ("mintlo", 0x6CBC9C), ("minthi", 0xDCF8EC),
        ("onmint", 0x10161A), ("tint", 0x1B2127), ("panel", 0x161A1F), ("deep", 0x0B0E11), ("off", 0x3A4048),
        ("alert", 0xEF4444)
    ]

    private static let slide = ShellMotion.spring(response: 0.424, bounce: 0.19)
    private static let glance = ShellMotion.ease(seconds: 0.14)

    private func vitreusRoles() throws -> [String: String] {
        let names = Self.stock.map { "\"\($0.name)\"" }.joined(separator: ", ")
        let widget = try VitreusFixture.probe(shell(), """
        local palette = require("../lib/vitreus/palette")
        function render(ctx)
            local rows = {}
            for _, name in { \(names) } do
                rows[#rows + 1] = ui.text{ text = name .. "=" .. palette.roles[name] }
            end
            return ui.column(rows)
        end
        """)
        widget.render(ShellBarData())
        var roles: [String: String] = [:]
        for line in widget.strings() {
            let parts = line.split(separator: "=").map(String.init)
            if parts.count == 2 { roles[parts[0]] = parts[1] }
        }
        XCTAssertEqual(roles.count, Self.stock.count)
        return roles
    }

    private static func theme(_ text: String, name: String) throws -> ShellTheme {
        var problems: [String] = []
        let theme = try ShellTheme(
            toml: TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8)), name: name, problems: &problems
        )
        XCTAssertEqual(problems, [], name)
        return theme
    }

    private static func color(_ role: String?, in theme: ShellTheme) throws -> ShellRGBA {
        let role = try XCTUnwrap(role)
        return try ShellRGBA(XCTUnwrap(ShellThemeColor(role, theme: theme), role).color(dark: true).cgColor)
    }

    private static func hex(_ color: ShellRGBA) -> UInt32 {
        [color.red, color.green, color.blue].reduce(0) { $0 << 8 | UInt32(($1 * 255).rounded()) }
    }

    private static func tone(_ color: ShellRGBA) -> Double {
        let luminance = color.luminance
        return luminance > 216 / 24389 ? 116 * cbrt(luminance) - 16 : luminance * 24389 / 27
    }

    private static func assertMotion(
        _ motion: ShellMotion?, _ expected: ShellMotion, _ label: String, line: UInt = #line
    ) {
        switch (motion, expected) {
        case let (.spring(response, bounce)?, .spring(target, spring)):
            XCTAssertEqual(response, target, accuracy: 0.0001, label, line: line)
            XCTAssertEqual(bounce, spring, accuracy: 0.0001, label, line: line)
        case let (.ease(seconds)?, .ease(target)):
            XCTAssertEqual(seconds, target, accuracy: 0.0001, label, line: line)
        default:
            XCTFail("\(label): \(String(describing: motion)) is not \(expected)", line: line)
        }
    }

    func testTheVitreusThemeResolvesEveryRoleToTheStockVitreusPalette() throws {
        let roles = try vitreusRoles()
        let url = try XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("themes/vitreus.toml")
        let theme = try Self.theme(String(contentsOf: url, encoding: .utf8), name: "vitreus")
        for (name, stock) in Self.stock where name != "mintlo" {
            XCTAssertEqual(Self.hex(try Self.color(roles[name], in: theme)), stock, name)
        }
        XCTAssertEqual(roles["mintlo"], roles["mint"])
    }

    func testWallpaperColorsGiveTheVitreusRolesIrisGlassAndItsLegibilityFloors() throws {
        let roles = try vitreusRoles()
        let written = Set(ShellMaterialPalette.roles.keys)
        for (name, role) in roles {
            XCTAssertTrue(written.contains(try XCTUnwrap(ShellRole(name: role), role)), "\(name) = \(role)")
        }
        let reference = ShellWallpaperPalette.pixels(of: ShellWallpaperPaletteTests.image([(0x3F4768, 1)]))
        let measured = ShellRGBA(red: 63.0 / 255, green: 71.0 / 255, blue: 104.0 / 255)
        let white = ShellRGBA(red: 1, green: 1, blue: 1)
        var tints: Set<UInt32> = []
        for wallpaper in ShellWallpaperPaletteTests.wallpapers + [(name: "reference", pixels: reference)] {
            for scheme in ShellWallpaperScheme.allCases {
                let label = "\(wallpaper.name) \(scheme)"
                let theme = try Self.theme(
                    ShellWallpaperPalette.theme(pixels: wallpaper.pixels, scheme: scheme), name: label
                )
                func color(_ name: String) throws -> ShellRGBA {
                    try Self.color(roles[name], in: theme)
                }
                let tint = try color("tint")
                let glass = try color("panel").mixed(with: white, 0.12)
                for (name, floor) in [("ink", 4.5), ("faint", 4.5), ("mint", 4.5), ("minthi", 4.5), ("alert", 3)] {
                    XCTAssertGreaterThanOrEqual(try color(name).contrast(glass), floor, "\(label) \(name)")
                }
                XCTAssertGreaterThanOrEqual(try color("onmint").contrast(color("mint")), 4.5, label)
                XCTAssertEqual(Self.tone(tint), 30.5, accuracy: 1.5, label)
                XCTAssertLessThan(try color("panel").luminance, tint.luminance, label)
                XCTAssertLessThan(try color("deep").luminance, tint.luminance, label)
                guard scheme == .tonalSpot else { continue }
                XCTAssertGreaterThan(try color("minthi").luminance, try color("mint").luminance, label)
                tints.insert(Self.hex(tint))
                if wallpaper.name == "reference" {
                    let distance = [
                        tint.red - measured.red, tint.green - measured.green, tint.blue - measured.blue
                    ].reduce(0) { $0 + $1 * $1 }.squareRoot() * 255
                    XCTAssertLessThan(distance, 20, label)
                }
            }
        }
        XCTAssertEqual(tints.count, 4)
    }

    func testTheDeskGlassCarriesTheVitreusIslandDeskBody() throws {
        let widget = try VitreusFixture.desk(shell())
        let layout = widget.surface.layout
        let glass = try VitreusFixture.element(widget, key: "desk-glass")
        let paint = layout.core.paint(of: glass)
        for (color, role, alpha) in [(paint.fill, ShellRole.secondaryContainer, 0.36), (paint.shadow, .shadow, 0.24)] {
            XCTAssertEqual(color.role & 0xFF, UInt16(role.rawValue + 1), "\(role)")
            XCTAssertEqual(Double(color.role >> 8) / 255, alpha, accuracy: 0.003, "\(role)")
        }
        XCTAssertEqual(paint.shadowRadius, 20)
        let recipe = try XCTUnwrap(ShellGlassRecipe(widget.text.string(layout.core.content(of: glass).text)))
        XCTAssertEqual(recipe.shadowOffset, CGPoint(x: 0, y: 7))
        XCTAssertEqual(recipe.rim, 0.1, accuracy: 1e-6)
        XCTAssertFalse(recipe.flat)
        XCTAssertEqual(recipe.light, CGPoint(x: -1, y: 0))
    }

    func testTabAndChipLabelsCrossFadeOnTheSlideSpringAndHoverInPleamarsZoneTime() throws {
        let widget = try VitreusFixture.desk(shell())
        let surface = widget.surface
        let layout = surface.layout
        let (border, ink) = (UInt16(ShellRole.border.rawValue + 1), UInt16(ShellRole.foreground.rawValue + 1))
        func check(_ name: String, chosen: Bool) throws {
            let zone = try VitreusFixture.element(widget, key: name)
            let label = try XCTUnwrap(
                layout.core.elements { $0.text != 0 }.first { layout.core.parent(of: $0) == zone }, name
            )
            Self.assertMotion(surface.animation(for: zone)?.motion, Self.slide, name)
            Self.assertMotion(
                ShellWidgetSurface.motion(of: layout.core.content(of: zone), hover: true), Self.glance, name
            )
            Self.assertMotion(surface.animation(for: label)?.motion, Self.slide, name)
            XCTAssertEqual(layout.core.content(of: label).color.role & 0xFF, chosen ? border : ink, name)
            XCTAssertEqual(Double(layout.core.paint(of: label).opacity), chosen ? 1 : 0.92, accuracy: 0.001, name)
            XCTAssertEqual(
                Double(layout.core.paint(of: zone).opacity), chosen ? 1 : 0.62 / 0.92, accuracy: 0.001, name
            )
        }
        for (name, chosen) in [("tab-focus", true), ("tab-pad", false), ("chip-30", true), ("chip-15", false)] {
            try check(name, chosen: chosen)
        }
        try VitreusFixture.click(widget, key: "tab-pad")
        try check("tab-pad", chosen: true)
        try check("tab-focus", chosen: false)
    }

    func testResetTurnsItsArrowOnHoverBoundariesAndSquishesUnderThePress() throws {
        let widget = try VitreusFixture.desk(shell())
        let surface = widget.surface
        let layout = surface.layout
        let du = Self.envelope(width: 1920, height: 1080).du
        func reset() throws -> (handle: ElementHandle, content: Content) {
            let handle = try VitreusFixture.element(widget, key: "reset")
            return (handle, layout.core.content(of: handle))
        }
        func turn() throws -> Double {
            try Double(layout.core.paint(of: VitreusFixture.element(widget, key: "reset-arc")).rotate)
        }
        let idle = try reset()
        XCTAssertEqual(idle.content.action, 0)
        let button = try VitreusFixture.frame(widget, key: "reset")
        let arc = try VitreusFixture.frame(widget, key: "reset-arc")
        XCTAssertEqual(arc.midX, button.midX - 18 * du, accuracy: 0.01)
        XCTAssertEqual(arc.midY, button.midY + du, accuracy: 0.01)
        let spin = try VitreusFixture.element(widget, key: "reset-arc")
        Self.assertMotion(surface.animation(for: spin)?.motion, Self.glance, "arc")
        Self.assertMotion(ShellWidgetSurface.motion(of: idle.content, hover: true), Self.glance, "hover")
        XCTAssertEqual(try turn(), 0)
        for (phase, angle) in [(ShellEvent.Phase.began, 90.0), (.ended, 0)] {
            var event = ShellEvent()
            event.phase = phase
            widget.invoke(try reset().content.hoverAction, event: event)
            VitreusFixture.show(widget)
            XCTAssertEqual(try turn(), angle)
        }
        try VitreusFixture.click(widget, key: "start")
        XCTAssertTrue(widget.strings().contains("FOCUSING"))
        let busy = try reset()
        XCTAssertNotEqual(busy.content.action, 0)
        for state in [idle, busy] {
            XCTAssertEqual(state.content.pressScale, 0.92, accuracy: 1e-6)
            Self.assertMotion(
                surface.animation(for: state.handle, press: true)?.motion,
                .spring(response: 0.363, bounce: 0.65),
                "press"
            )
        }
    }

    func testTheOpenerChipsStartAndResetShowThePointingHandWhereVitreusDoes() throws {
        let previous = NSCursor.current
        defer { previous.set() }
        let shell = try shell()
        let bar = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell)
        )
        bar.render(VitreusFixture.bar())
        let opener = try VitreusFixture.element(bar, key: "desk-opener")
        XCTAssertEqual(bar.surface.layout.core.content(of: opener).cursor, .pointer)
        let widget = try VitreusFixture.desk(shell)
        let layout = widget.surface.layout
        func cursor(_ name: String) throws -> ElementCursor {
            try layout.core.content(of: VitreusFixture.element(widget, key: name)).cursor
        }
        for name in ["chip-15", "chip-30", "chip-45", "chip-60", "start", "reset"] {
            XCTAssertEqual(try cursor(name), .pointer, name)
        }
        let start = try VitreusFixture.frame(widget, key: "start")
        widget.surface.hover(at: CGPoint(x: start.midX, y: start.midY))
        XCTAssertTrue(widget.surface.view.cursorState.current === NSCursor.pointingHand)
        try VitreusFixture.click(widget, key: "start")
        XCTAssertTrue(widget.strings().contains("FOCUSING"))
        for name in ["chip-15", "chip-60"] {
            XCTAssertEqual(try cursor(name), ElementCursor.none, name)
        }
        XCTAssertEqual(try cursor("start"), .pointer)
        XCTAssertEqual(try cursor("reset"), .pointer)
    }
}
