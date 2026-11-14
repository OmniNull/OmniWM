// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import TOML
import XCTest

@MainActor
final class BorderPaletteColorTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BorderPalette-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
    }

    private func theme(_ stripes: [(UInt32, Int)]) throws -> ShellTheme {
        let image = ShellBundledWidgetTests.wallpaperGradient(
            64, 36, stripes.map { color, _ in
                CGColor(
                    srgbRed: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
                    blue: CGFloat(color & 0xFF) / 255, alpha: 1
                )
            }
        )
        let text = ShellWallpaperPalette.theme(pixels: ShellWallpaperPalette.pixels(of: image), scheme: .tonalSpot)
        var problems: [String] = []
        let theme = ShellTheme(
            toml: try TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8)),
            name: ShellWallpaperPalette.themeName,
            problems: &problems
        )
        XCTAssertEqual(problems, [])
        return theme
    }

    private func color(_ theme: ShellTheme, _ role: ShellRole, dark: Bool) throws -> SettingsColor {
        try XCTUnwrap(SettingsColor(nsColor: theme.resolvedColor(role, dark: dark)))
    }

    func testFollowingThePaletteIsOffByDefaultAndRoundTrips() throws {
        let defaults = SettingsExport.defaults()
        XCTAssertEqual(defaults.borders.colorSource ?? .fixed, .fixed)
        let text = try XCTUnwrap(String(data: SettingsTOMLCodec.encode(defaults), encoding: .utf8))
        XCTAssertFalse(text.contains("colorSource"), "existing settings files do not change")

        var export = defaults
        export.borders.colorSource = .palette
        let data = try SettingsTOMLCodec.encode(export)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        guard case let .table(borders)? = tree["borders"] else { return XCTFail("no [borders] table") }
        XCTAssertEqual(borders["colorSource"], .string("palette"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)

        let settings = store()
        XCTAssertEqual(settings.borders.colorSource, .fixed)
        settings.applyExport(export)
        XCTAssertEqual(settings.borders.colorSource, .palette)
        XCTAssertEqual(settings.toExport().borders.colorSource, .palette)
    }

    func testThePaletteAccentColorsTheBorderInLightAndDarkWithGradientAndGlow() throws {
        let palette = try theme([(0x1E88E5, 5), (0xFF7043, 3)])
        let settings = store()
        settings.borders.enabled = true
        settings.borders.colorSource = .palette
        settings.borders.gradient = BorderGradient(
            enabled: true, start: .init(red: 1, green: 0, blue: 0, alpha: 1),
            end: .init(red: 0, green: 1, blue: 0, alpha: 1), direction: .topLeftToBottomRight
        )
        settings.borders.glow = BorderGlow(
            enabled: true,
            radius: 8,
            opacity: 0.6,
            color: .init(red: 0, green: 0, blue: 1, alpha: 1)
        )
        for dark in [false, true] {
            let config = BorderConfig.from(settings: settings, isDark: dark, palette: palette)
            XCTAssertEqual(config.color, try color(palette, .accent, dark: dark))
            XCTAssertEqual(config.gradient?.start, try color(palette, .accent, dark: dark))
            XCTAssertEqual(config.gradient?.end, try color(palette, .tertiaryAccent, dark: dark))
            XCTAssertEqual(config.glow?.color, try color(palette, .accent, dark: dark))
        }
        XCTAssertNotEqual(
            BorderConfig.from(settings: settings, isDark: false, palette: palette).color,
            BorderConfig.from(settings: settings, isDark: true, palette: palette).color
        )
        let fallback = BorderConfig.from(settings: settings, isDark: false, palette: nil)
        XCTAssertEqual(fallback.color, settings.borders.color, "without a palette the fixed color is used")
        settings.borders.colorSource = .fixed
        let fixed = BorderConfig.from(settings: settings, isDark: false, palette: palette)
        XCTAssertEqual(fixed.color, settings.borders.color)
        XCTAssertEqual(fixed.gradient?.start, settings.borders.gradient?.start)
    }

    func testWithFollowWallpaperColorsOffAPaletteChangeLeavesTheBorderAlone() throws {
        let settings = store()
        let controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: directory.appendingPathComponent("clipboard"),
            diagnosticsDirectory: directory.appendingPathComponent("diagnostics"),
            ownedWindowRegistry: OwnedWindowRegistry()
        )
        controller.workspaceBarManager.setup(controller: controller, settings: settings)
        settings.borders.enabled = true
        let host = ShellWidgetHost(
            configDirectory: directory,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("resources")),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        controller.workspaceBarManager.shellHost = host
        controller.workspaceBarManager.observeShellPalette(host)
        _ = controller.resolvedBorderConfig()
        let cached = try XCTUnwrap(controller.cachedBorderConfig)
        var next = host.config
        next.theme = try theme([(0x2E7D32, 6), (0xC5E1A5, 1)])
        host.started = true
        host.applyConfig(next)
        XCTAssertEqual(
            controller.cachedBorderConfig?.revision, cached.revision,
            "with the option off a palette change neither stores a palette nor touches the border"
        )
        XCTAssertNotNil(controller.cachedBorderConfig)
        XCTAssertEqual(controller.resolvedBorderConfig().color, settings.borders.color)
        host.started = false
    }

    func testEveryInputOfTheShellPaletteReachesTheBorder() throws {
        let settings = store()
        let controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: directory.appendingPathComponent("clipboard"),
            diagnosticsDirectory: directory.appendingPathComponent("diagnostics"),
            ownedWindowRegistry: OwnedWindowRegistry()
        )
        controller.workspaceBarManager.setup(controller: controller, settings: settings)
        settings.borders.enabled = true
        settings.borders.colorSource = .palette
        let host = ShellWidgetHost(
            configDirectory: directory,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("resources")),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        controller.workspaceBarManager.shellHost = host
        controller.workspaceBarManager.observeShellPalette(host)
        let dark = controller.borderUsesDarkAppearance
        let accent = SettingsColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        func expected(_ config: ShellConfig) throws -> SettingsColor {
            try color(
                ShellWidgetHost.paletteTheme(config: config, accent: accent, foreground: nil),
                .accent,
                dark: dark
            )
        }
        for name in ["native", "custom"] {
            host.started = false
            host.setBarColors(accent: nil, foreground: nil)
            host.config.themeName = name
            host.started = true
            host.setBarColors(accent: accent, foreground: nil)
            XCTAssertEqual(
                controller.resolvedBorderConfig().color, try expected(host.config),
                "a bar color edited under the \(name) theme reaches the border"
            )
        }

        var next = host.config
        next.theme = try theme([(0x2E7D32, 6), (0xC5E1A5, 1)])
        host.applyConfig(next)
        XCTAssertEqual(controller.resolvedBorderConfig().color, try expected(host.config), "a theme change reaches it")

        controller.workspaceBarManager.stopShellHost()
        XCTAssertEqual(
            controller.resolvedBorderConfig().color, settings.borders.color, "with the shell off it is fixed again"
        )
        host.started = false
    }
}
