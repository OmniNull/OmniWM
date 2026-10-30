// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import TOML
import XCTest

@MainActor
final class ShellVitreusDeskTests: XCTestCase {
    private struct Screen {
        let width: Double
        let height: Double
        let top: Double
    }

    private static let sizes = [
        Screen(width: 1920, height: 1080, top: 32), Screen(width: 1440, height: 900, top: 32),
        Screen(width: 1280, height: 720, top: 32), Screen(width: 2560, height: 1440, top: 32),
        Screen(width: 1920, height: 1080, top: 300)
    ]

    func shell() throws -> URL {
        let shell = try VitreusFixture.shell()
        let folder = shell.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return shell
    }

    private func probe(_ main: String) throws -> [String] {
        let widget = try VitreusFixture.probe(shell(), main)
        widget.render(ShellBarData())
        return widget.strings()
    }

    private static func expectedDesk(_ size: Screen) -> [Double] {
        let scale = min(max(size.height / 1350, 0.55), 1)
        let du = 1.5525 * scale
        let width = 353 * du
        let height = 460 * du
        return [
            scale, du, size.width - 7.5 * du - width, max(size.top, size.height / 2 - height / 2), width, height, 35.1,
            2, 2, width - 4, height - 4, 26 * du - 2, 6.5 * du, 340 * du, 460 * du
        ]
    }

    func testUnitsPlaceTheIslandDeskOnTheRightEdgeAtEveryDisplaySize() throws {
        let sizes = Self.sizes.map { "{ \($0.width), \($0.height), \($0.top) }" }.joined(separator: ", ")
        let text = try probe("""
        local units = require("../lib/vitreus/units")
        function render(ctx)
            local lines = {}
            for _, size in { \(sizes) } do
                local g = units.desk({ size = { w = size[1], h = size[2] },
                    usableRect = { x = 0, y = size[3], w = size[1], h = size[2] - size[3] } })
                local e = g.envelope
                lines[#lines + 1] = table.concat({ g.k.rs, g.k.du, e.x, e.y, e.w, e.h, g.bodyRadius, g.clip.x, g.clip.y,
                    g.clip.w, g.clip.h, g.clip.radius, g.content.x, g.content.w, g.content.h }, " ")
            end
            return ui.text{ text = table.concat(lines, ";") }
        end
        """)
        let rows = try XCTUnwrap(text.first).split(separator: ";").map {
            $0.split(separator: " ").compactMap { Double($0) }
        }
        XCTAssertEqual(rows.count, Self.sizes.count)
        for (row, size) in zip(rows, Self.sizes) {
            let expected = Self.expectedDesk(size)
            XCTAssertEqual(row.count, expected.count)
            for (value, target) in zip(row, expected) {
                XCTAssertEqual(value, target, accuracy: 0.01, "\(size)")
            }
        }
        let reference = rows[0]
        for (index, value) in [(0, 0.8), (1, 1.242), (2, 1472.26), (3, 254.34), (4, 438.43), (5, 571.32), (11, 30.29)] {
            XCTAssertEqual(reference[index], value, accuracy: 0.01)
        }
        XCTAssertEqual(rows[2][0], 0.55, accuracy: 0.0001)
        XCTAssertEqual(rows[3][0], 1, accuracy: 0.0001)
        XCTAssertEqual(rows[4][3], 300, accuracy: 0.0001)
    }

    func testPaletteAlphaClampsToColorsTheThemeResolves() throws {
        let strings = try probe("""
        local palette = require("../lib/vitreus/palette")
        function render(ctx)
            return ui.column{
                ui.text{ text = palette.alpha("ink", 1.3) }, ui.text{ text = palette.alpha("mint", -0.1) },
                ui.text{ text = palette.alpha("tint", 0.36) }, ui.text{ text = palette.alpha("alert", 0 / 0) },
            }
        end
        """)
        XCTAssertEqual(strings, ["foreground/1.000", "accent/0.000", "secondaryContainer/0.360", "error/0.000"])
        let url = try ShellStyleFixture.source("vitreus").appendingPathComponent("themes/vitreus.toml")
        var problems: [String] = []
        let theme = try ShellTheme(
            toml: TOMLDecoder().decode([String: TOMLNode].self, from: Data(contentsOf: url)),
            name: "vitreus", problems: &problems
        )
        XCTAssertEqual(problems, [])
        for text in strings {
            XCTAssertNotNil(ShellThemeColor(text, theme: theme), text)
        }
        let tint = try XCTUnwrap(
            ShellThemeColor("secondaryContainer/0.360", theme: theme)?.dark.usingColorSpace(.sRGB)
        )
        XCTAssertEqual(tint.alphaComponent, 0.36, accuracy: 0.001)
        XCTAssertEqual(tint.redComponent, 0x1B / 255, accuracy: 0.002)
    }

    func testRingPathsOpenFromTwelveOClockWithRoundCaps() throws {
        let strings = try probe("""
        local kit = require("../lib/vitreus/kit")
        function render(ctx)
            local full, even = kit.ringPath(170, 188, 70, 16, 1)
            return ui.column{
                ui.text{ text = kit.ringPath(170, 188, 70, 16, 0.25) }, ui.text{ text = full .. "|" .. tostring(even) },
                ui.text{ text = kit.ringPath(170, 188, 70, 16, 0) },
            }
        end
        """)
        let quarter = strings[0].split(separator: " ").map(String.init)
        XCTAssertEqual(quarter.count { $0 == "A" }, 4)
        func number(_ index: Int) throws -> Double {
            try XCTUnwrap(Double(quarter[index]))
        }
        XCTAssertEqual(quarter[0], "M")
        for (index, value) in [
            (1, 170.0), (2, 110), (4, 78), (9, 248), (10, 188), (12, 8), (17, 232), (18, 188), (20, 62), (25, 170), (
                26,
                126
            )
        ] {
            XCTAssertEqual(try number(index), value, accuracy: 0.001, "\(index)")
        }
        XCTAssertEqual((try number(9) + number(17)) / 2, 170 + 70, accuracy: 0.001)
        let full = strings[1].split(separator: "|")
        XCTAssertEqual(full.last, "true")
        XCTAssertEqual(full.first?.split(separator: " ").count { $0 == "M" }, 2)
        let empty = strings[2].split(separator: " ").map(String.init)
        XCTAssertEqual(try XCTUnwrap(Double(empty[9])), 170 + 78 * sin(0.002 * 2 * .pi), accuracy: 0.001)
    }

    func testTheDeskShowsOnlyWorkingPagesWithFocusSelectedByDefault() throws {
        let widget = try VitreusFixture.desk(shell())
        let layout = widget.surface.layout
        let tabs = VitreusFixture.labels(widget).filter { ["Pad", "Focus"].contains($0.text) }
            .sorted { $0.frame.minX < $1.frame.minX }.map(\.text)
        XCTAssertEqual(tabs, ["Pad", "Focus"])
        XCTAssertTrue(widget.strings().contains("READY"))
        XCTAssertTrue(widget.strings().contains("30:00"))
        let hidden = ["Shelf", "Clip", "Term", "Ask", "Draw", "Silence alerts", "Keep awake"]
        XCTAssertTrue(widget.strings().allSatisfy { !hidden.contains($0) })
        let keys = [VitreusFixture.key("tab-pad"), VitreusFixture.key("tab-focus")]
        let zones = layout.core.elements { $0.action != 0 }.filter { keys.contains(layout.core.key(of: $0)) }
        XCTAssertEqual(zones.count, tabs.count)
    }

    func testDisabledAndFailedPagesLoseTheirTabsButFailuresStayVisible() throws {
        let shell = try shell()
        let focus = try VitreusFixture.desk(shell, components: [
            ShellComponentInstance(id: "pad", widget: "desk-pad", enabled: false),
            ShellComponentInstance(id: "focus", widget: "desk-focus")
        ])
        XCTAssertEqual(
            VitreusFixture.labels(focus).filter { ["Pad", "Focus"].contains($0.text) }.map(\.text),
            ["Focus"]
        )
        let empty = try VitreusFixture.desk(shell, components: [])
        XCTAssertTrue(empty.strings().contains("No pages to show"))
        let layout = empty.surface.layout
        XCTAssertFalse(layout.core.elements { _ in true }.contains {
            layout.core.key(of: $0) == VitreusFixture.key("tab-focus")
        })

        let source = try VitreusFixture.source(shell)
        let failed = try ShellRenderedWidget(source: ShellWidgetSource(
            chunk: source.chunk, main: source.main,
            modules: source.modules.map {
                $0.path.hasSuffix("widgets/desk-pad/component.luau")
                    ? .init(path: $0.path, source: "error('pad exploded')") : $0
            },
            isIslandRoot: true, moduleLimit: source.moduleLimit, components: source.components,
            componentDescriptors: source.componentDescriptors, fontFolders: source.fontFolders
        ))
        VitreusFixture.open(failed)
        let lines = failed.strings()
        XCTAssertFalse(lines.contains("Pad"))
        XCTAssertTrue(lines.contains("Focus"))
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("Pad could not load: ") && $0.contains("pad exploded") },
            "\(lines)"
        )
    }

    func testDeskTextUsesTheShippedSpaceGroteskFace() throws {
        let shell = try shell()
        let folders = try VitreusFixture.source(shell).fontFolders
        let shipped = try XCTUnwrap(folders.flatMap(ShellFontLibrary.files(in:)).first)
        XCTAssertEqual(
            shipped.resolvingSymlinksInPath(),
            shell.appendingPathComponent("vitreus/fonts/SpaceGrotesk[wght].ttf").resolvingSymlinksInPath()
        )
        let faces = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(shipped as CFURL) as? [CTFontDescriptor])
        XCTAssertEqual(
            Set(faces.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }),
            ["Space Grotesk"]
        )
        let id = try XCTUnwrap(ShellFontLibrary.shared.fonts(in: folders).ids["Space Grotesk"])
        let widget = try VitreusFixture.desk(shell)
        let labels = VitreusFixture.labels(widget)
        XCTAssertGreaterThan(labels.count, 10)
        for label in labels {
            XCTAssertEqual((label.style & OMNI_STYLE_FONT_MASK) >> OMNI_STYLE_FONT_SHIFT, UInt32(id), label.text)
            XCTAssertEqual(ShellFontLibrary.shared.family(of: label.style), "Space Grotesk", label.text)
        }
    }
}
