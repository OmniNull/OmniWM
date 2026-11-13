// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppThemeTemplateTests: XCTestCase {
    private let palette = AppThemeFixtures.palette

    func testRendersEveryFormatForTheRequestedVariant() throws {
        let template = """
        bg={{colors.background.default.hex}} fg={{ colors.foreground.dark.hex }}
        stripped={{colors.accent.light.hex_stripped}} rgb={{colors.red.default.rgb}}
        rgba={{colors.scrim.default.rgba}} parts={{colors.blue.dark.red}},{{colors.blue.dark.green}},{{colors.blue.dark.blue}}
        alpha={{colors.scrim.default.alpha}} mode={{mode}}
        """
        let rendered = try AppThemeTemplate.render(template, palette: palette, dark: false)
        XCTAssertEqual(rendered, """
        bg=#eff1f5 fg=#cdd6f4
        stripped=8839ef rgb=rgb(210, 15, 57)
        rgba=rgba(17, 17, 27, 0.4) parts=137,180,250
        alpha=0.4 mode=light
        """)
    }

    func testDefaultVariantFollowsTheRenderedMode() throws {
        let template = "{{colors.background.default.hex}} {{mode}}"
        XCTAssertEqual(try AppThemeTemplate.render(template, palette: palette, dark: true), "#11111b dark")
        XCTAssertEqual(try AppThemeTemplate.render(template, palette: palette, dark: false), "#eff1f5 light")
    }

    func testANSIPlaceholdersMatchTheDerivedTerminalColors() throws {
        let rendered = try AppThemeTemplate.render(
            (0 ..< AppThemeANSI.colorCount).map { "{{colors.ansi\($0).dark.hex}}" }.joined(separator: " "),
            palette: palette,
            dark: false
        )
        XCTAssertEqual(rendered, palette.dark.ansi.map(\.hex).joined(separator: " "))
    }

    func testEscapedBracesStayLiteral() throws {
        let rendered = try AppThemeTemplate.render(
            "a \\{{colors.background.default.hex}} b {{colors.background.default.hex}}",
            palette: palette,
            dark: true
        )
        XCTAssertEqual(rendered, "a {{colors.background.default.hex}} b #11111b")
    }

    func testUnknownPlaceholdersAreErrorsWithTheirLine() {
        for (template, name) in [
            ("ok\n{{colors.nope.default.hex}}", "colors.nope.default.hex"),
            ("ok\n{{colors.accent.sepia.hex}}", "colors.accent.sepia.hex"),
            ("ok\n{{colors.accent.default.cmyk}}", "colors.accent.default.cmyk"),
            (
                "ok\n{{colors.ansi\(AppThemeANSI.colorCount).default.hex}}",
                "colors.ansi\(AppThemeANSI.colorCount).default.hex"
            ),
            ("ok\n{{colors.ansi01.default.hex}}", "colors.ansi01.default.hex"),
            ("ok\n{{env.HOME}}", "env.HOME")
        ] {
            XCTAssertThrowsError(try AppThemeTemplate.render(template, palette: palette, dark: true)) { error in
                XCTAssertEqual(error as? AppThemeTemplateError, .unknownPlaceholder(name, line: 2))
            }
        }
    }

    func testUnclosedPlaceholderIsAnError() {
        XCTAssertThrowsError(try AppThemeTemplate.render("a\nb {{colors.accent\n}}", palette: palette, dark: true)) {
            XCTAssertEqual($0 as? AppThemeTemplateError, .unterminatedPlaceholder(line: 2))
        }
    }

    func testOversizedTemplateIsRefused() {
        let template = String(repeating: "x", count: AppThemeTemplate.maximumBytes + 1)
        XCTAssertThrowsError(try AppThemeTemplate.render(template, palette: palette, dark: true)) {
            XCTAssertEqual($0 as? AppThemeTemplateError, .tooLarge(bytes: AppThemeTemplate.maximumBytes + 1))
        }
    }

    func testShellSyntaxInATemplateIsOnlyText() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-template-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let hostile = "$(touch \(marker.path)) `touch \(marker.path)` ; touch \(marker.path) && echo pwned"
        XCTAssertEqual(try AppThemeTemplate.render(hostile, palette: palette, dark: true), hostile)
        XCTAssertThrowsError(try AppThemeTemplate.render("{{$(touch \(marker.path))}}", palette: palette, dark: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBuiltInTemplatesRenderInBothModes() throws {
        for app in AppThemeBuiltIn.allCases {
            for dark in [false, true] {
                let rendered = try AppThemeTemplate.render(app.template, palette: palette, dark: dark)
                XCTAssertFalse(rendered.contains("{{"), "\(app) left a placeholder")
                XCTAssertTrue(rendered.contains(palette.scheme(dark: dark).ansi[1].hex), "\(app) misses its red")
            }
        }
        let ghostty = try AppThemeTemplate.render(AppThemeBuiltIn.ghostty.template, palette: palette, dark: true)
        XCTAssertTrue(ghostty.contains("background = #11111b\n"))
        XCTAssertTrue(ghostty.contains("palette = 15=\(palette.dark.ansi[15].hex)\n"))
        let kitty = try AppThemeTemplate.render(AppThemeBuiltIn.kitty.template, palette: palette, dark: false)
        XCTAssertTrue(kitty.contains("background #eff1f5\n"))
        XCTAssertTrue(kitty.contains("color4 \(palette.light.ansi[4].hex)\n"))
    }

    func testHerdrTemplateKeepsItsPanelsTransparent() throws {
        let herdr = try AppThemeTemplate.render(AppThemeBuiltIn.herdr.template, palette: palette, dark: true)
        for key in ["panel_bg", "surface0", "surface1", "surface_dim"] {
            XCTAssertTrue(herdr.contains("\(key) = \"reset\"\n"), key)
        }
        XCTAssertFalse(herdr.contains("sidebar_bg"))
        XCTAssertTrue(herdr.hasPrefix("[theme.custom]\n"))
    }
}
