// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import TOML
import XCTest

@MainActor
final class ShellThemeTests: XCTestCase {
    private func render(_ source: String) throws -> (status: omni_status, nodes: [omni_wire_node]) {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        defer { _ = omni_vm_destroy(vm) }
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(omni_vm_load(vm, "=theme", source, source.utf8.count, 100_000_000, &error, error.count), OMNI_OK)
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        var stats = omni_render_stats()
        let status = omni_instance_render(instance, OMNI_VIEW_BAR, 8_000_000, &stats, &error, error.count)
        var size = 0
        guard status == OMNI_OK, let bytes = omni_instance_output(instance, OMNI_VIEW_BAR, &size) else {
            return (status, [])
        }
        let header = UnsafeRawPointer(bytes).loadUnaligned(as: omni_wire_header.self)
        let nodes = (0 ..< Int(header.node_count)).map { index in
            UnsafeRawPointer(bytes + MemoryLayout<omni_wire_header>.stride + index * MemoryLayout<omni_wire_node>
                .stride)
                .loadUnaligned(as: omni_wire_node.self)
        }
        return (status, nodes)
    }

    func testColorsAcceptRolesAndHexStrings() throws {
        let result = try render("""
        function render(ctx)
            return ui.box{ fill = "accent/0.5", border = "#FF000080", color = "foreground", hover = "#00FF00" }
        end
        """)
        XCTAssertEqual(result.status, OMNI_OK)
        let node = try XCTUnwrap(result.nodes.first)
        XCTAssertEqual(node.fill_role, UInt16(ShellRole.accent.rawValue + 1) | (128 << 8))
        XCTAssertEqual(node.stroke, 0xFF00_0080)
        XCTAssertEqual(node.stroke_role, 0)
        XCTAssertEqual(node.color_role, UInt16(ShellRole.foreground.rawValue + 1) | (255 << 8))
        XCTAssertEqual(node.hover, 0x00FF_00FF)
        for invalid in ["nope", "accent/", "accent/2", "accent/0.5junk", "#12345"] {
            let source = "function render(ctx) return ui.box{ fill = \"\(invalid)\" } end"
            XCTAssertEqual(try render(source).status, OMNI_ERR_RUNTIME, invalid)
        }
    }

    func testPaletteResolvesRolesForTheAppearance() throws {
        let palette = ShellPalette()
        var theme = ShellTheme.native
        theme.light[ShellRole.accent.rawValue] = try XCTUnwrap(NSColor(shellHex: "#0000FF"))
        theme.dark[ShellRole.accent.rawValue] = try XCTUnwrap(NSColor(shellHex: "#FF0000"))
        let accent = Color(packed: 0, role: UInt16(ShellRole.accent.rawValue + 1) | (128 << 8))

        palette.refresh(theme: theme, appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)))
        let dark = try XCTUnwrap(palette.color(accent))
        XCTAssertEqual(dark.components?[0] ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(dark.alpha, 128.0 / 255, accuracy: 0.001)

        palette.refresh(theme: theme, appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        XCTAssertEqual(palette.color(accent)?.components?[2] ?? 0, 1, accuracy: 0.001)
        XCTAssertNil(palette.color(.clear))
    }

    func testSystemColorsAreRolesThatShadersCanRead() throws {
        let result = try render("""
        function render(ctx)
            return ui.box{ fill = "cyan", border = "purple/0.5", color = "gray" }
        end
        """)
        XCTAssertEqual(result.status, OMNI_OK)
        let node = try XCTUnwrap(result.nodes.first)
        XCTAssertEqual(node.fill_role, UInt16(ShellRole.cyan.rawValue + 1) | (255 << 8))
        XCTAssertEqual(node.stroke_role, UInt16(ShellRole.purple.rawValue + 1) | (128 << 8))
        XCTAssertEqual(node.color_role, UInt16(ShellRole.gray.rawValue + 1) | (255 << 8))
        XCTAssertEqual(ShellTheme.native.light.count, ShellRole.allCases.count)
        XCTAssertEqual(ShellTheme.native.dark.count, ShellRole.allCases.count)

        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let palette = ShellPalette(theme: .native, appearance: dark)
        var expected: CGColor?
        dark.performAsCurrentDrawingAppearance {
            expected = NSColor.systemCyan.cgColor
        }
        XCTAssertEqual(
            palette.color(Color(packed: 0, role: UInt16(ShellRole.cyan.rawValue + 1) | (255 << 8))),
            expected
        )

        let prelude = ShellShaderLibrary.wrap("", name: "test")
        XCTAssertTrue(prelude.contains("constant int omni_badge = 15;"))
        XCTAssertTrue(prelude.contains("constant int omni_cyan = \(ShellRole.cyan.rawValue);"))
        XCTAssertTrue(prelude.contains("constant int omni_gray = \(ShellRole.gray.rawValue);"))
        XCTAssertTrue(prelude.contains("float4 colors[40];"))
        XCTAssertTrue(prelude.contains("constant int omni_tertiaryContainerForeground = 37;"))
        XCTAssertGreaterThanOrEqual(ShellShaderInput.Colors.count, ShellRole.allCases.count)
    }

    func testRoundedTextUsesRoundedMonospacedDigits() {
        let font = ShellTextStyle.font(for: 5 | (1500 << OMNI_STYLE_SIZE_SHIFT)) as NSFont
        XCTAssertEqual(font.pointSize, 15)
        XCTAssertTrue(font.fontName.contains("Rounded"), font.fontName)
        let width = { (text: String) in NSAttributedString(string: text, attributes: [.font: font]).size().width }
        XCTAssertEqual(width("1111"), width("0000"), accuracy: 0.01)
        XCTAssertFalse((ShellTextStyle.font(for: 2) as NSFont).fontName.contains("Rounded"))
    }

    func testConfigLoadsTheSelectedThemeAndKeepsTheRestWhenItIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let themes = root.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try Data("profiles.default.theme = \"ocean\"\nprofiles.default.leading = [\"clock\"]\n".utf8)
            .write(to: root.appendingPathComponent("shell.toml"))
        let fallback = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(fallback.themeName, "native")
        XCTAssertEqual(fallback.theme, ShellTheme.native)
        XCTAssertEqual(fallback.leading, ["clock"])

        try Data("[light]\naccent = \"#112233\"\n".utf8).write(to: themes.appendingPathComponent("ocean.toml"))
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.themeName, "ocean")
        XCTAssertEqual(config.theme.light[ShellRole.accent.rawValue], NSColor(shellHex: "#112233"))
        XCTAssertEqual(config.theme.dark, ShellTheme.native.dark)
    }

    func testEveryThemeGetsReadableContainersAndAccents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(
            at: XCTUnwrap(ShellDefaults.bundledFile("themes")),
            includingPropertiesForKeys: nil
        ).map { $0.deletingPathExtension().lastPathComponent }.sorted()
        XCTAssertEqual(names.count, 14)
        var themes = [("native", ShellTheme.native)]
        for name in names {
            try Data("profiles.default.theme = \"\(name)\"\n".utf8).write(to: root.appendingPathComponent("shell.toml"))
            themes.append((name, try XCTUnwrap(ShellConfig.load(shellDirectory: root), name).theme))
        }
        let wallpaper = root.appendingPathComponent("themes/\(ShellWallpaperPalette.themeName).toml")
        for image in ShellWallpaperPaletteTests.wallpapers {
            for scheme in ShellWallpaperScheme.allCases {
                let text = ShellWallpaperPalette.theme(pixels: image.pixels, scheme: scheme)
                _ = try ShellWallpaperPalette.write(text, to: wallpaper)
                try Data("profiles.default.theme = \"wallpaper\"\n".utf8)
                    .write(to: root.appendingPathComponent("shell.toml"))
                let label = "wallpaper \(image.name) \(scheme)"
                themes.append((label, try XCTUnwrap(ShellConfig.load(shellDirectory: root), label).theme))
            }
        }
        let families: [(accent: ShellRole, container: ShellRole, text: ShellRole)] = [
            (.accent, .accentContainer, .accentContainerForeground),
            (.secondaryAccent, .secondaryContainer, .secondaryContainerForeground),
            (.tertiaryAccent, .tertiaryContainer, .tertiaryContainerForeground)
        ]
        for (name, theme) in themes {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let palette = ShellPalette(theme: theme, appearance: try XCTUnwrap(NSAppearance(named: appearanceName)))
                func role(_ role: ShellRole) throws -> ShellRGBA {
                    try ShellRGBA(XCTUnwrap(palette.color(Color(
                        packed: 0,
                        role: UInt16(role.rawValue + 1) | (255 << 8)
                    ))))
                }
                let label = "\(name) \(appearanceName.rawValue)"
                let grounds = try [ShellRole.background, .surface, .elevatedSurface, .highestSurface].map(role)
                XCTAssertGreaterThanOrEqual(try role(.foreground).contrast(role(.highestSurface)), 4.5, label)
                for family in families {
                    XCTAssertGreaterThanOrEqual(
                        try role(family.text).contrast(role(family.container)),
                        4.5,
                        "\(label) \(family.text)"
                    )
                    if family.accent != .accent {
                        for ground in grounds {
                            XCTAssertGreaterThanOrEqual(
                                try role(family.accent).contrast(ground),
                                3,
                                "\(label) \(family.accent)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testThemesKeepTheContainerRolesTheySet() throws {
        var problems: [String] = []
        let toml = try TOMLDecoder().decode([String: TOMLNode].self, from: Data("""
        [dark]
        tertiaryAccent = "#123456"
        """.utf8))
        let theme = ShellTheme(toml: toml, name: "test", problems: &problems)
        XCTAssertEqual(problems, [])
        XCTAssertFalse(theme.derivedDark.contains(.tertiaryAccent))
        XCTAssertTrue(theme.derivedDark.contains(.secondaryAccent))
        XCTAssertTrue(theme.derivedLight.contains(.tertiaryAccent))
        let light = ShellPalette(theme: theme, appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        let lightTertiary = try XCTUnwrap(light.color(Color(
            packed: 0,
            role: UInt16(ShellRole.tertiaryAccent.rawValue + 1) | (255 << 8)
        )))
        XCTAssertEqual(ShellRGBA(lightTertiary).alpha, 1)
        let palette = ShellPalette(theme: theme, appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)))
        let tertiary = try XCTUnwrap(palette.color(Color(
            packed: 0,
            role: UInt16(ShellRole.tertiaryAccent.rawValue + 1) | (255 << 8)
        )))
        let kept = ShellRGBA(tertiary)
        for (value, expected) in [(kept.red, 0x12), (kept.green, 0x34), (kept.blue, 0x56)] {
            XCTAssertEqual(value, Double(expected) / 255, accuracy: 0.0001)
        }
        let derived = try XCTUnwrap(ShellThemeColor("secondaryAccent", theme: theme)).color(dark: true)
        let painted = try XCTUnwrap(palette.color(Color(
            packed: 0,
            role: UInt16(ShellRole.secondaryAccent.rawValue + 1) | (255 << 8)
        )))
        XCTAssertEqual(ShellRGBA(derived.cgColor).red, ShellRGBA(painted).red, accuracy: 0.002)
    }

    func testBundledThemesLoadUnlessAUserThemeSharesTheirName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let themes = root.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        for name in ["wayline", "nocturne", "monolith", "celestial"] {
            try Data("profiles.default.theme = \"\(name)\"\n".utf8).write(to: root.appendingPathComponent("shell.toml"))
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root), name)
            XCTAssertNotEqual(
                config.theme.dark[ShellRole.accent.rawValue],
                ShellTheme.native.dark[ShellRole.accent.rawValue]
            )
            XCTAssertNotEqual(
                config.theme.light[ShellRole.background.rawValue],
                ShellTheme.native.light[ShellRole.background.rawValue]
            )
        }
        try Data("profiles.default.theme = \"nocturne\"\n".utf8).write(to: root.appendingPathComponent("shell.toml"))
        XCTAssertEqual(
            try XCTUnwrap(ShellConfig.load(shellDirectory: root)).theme.dark[ShellRole.accent.rawValue],
            NSColor(shellHex: "#FFF59B")
        )
        try Data("[dark]\naccent = \"#112233\"\n".utf8).write(to: themes.appendingPathComponent("nocturne.toml"))
        let override = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(override.theme.dark[ShellRole.accent.rawValue], NSColor(shellHex: "#112233"))
        XCTAssertEqual(override.theme.light, ShellTheme.native.light)
    }

    func testLanesOrderListedWidgetsAndDefaultToTrailing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("profiles.default.leading = [\"menu\"]\nprofiles.default.trailing = [\"clock\", \"wm\"]\n".utf8)
            .write(to: root.appendingPathComponent("shell.toml"))
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.lane(of: "menu").lane, .leading)
        XCTAssertEqual(config.lane(of: "wm").rank, 1)
        XCTAssertEqual(config.lane(of: "other").lane, .trailing)
        XCTAssertEqual(config.lane(of: "other").rank, 2)
    }

    func testSlicesShowTheirIslandsWidgetsByLaneInEveryOrientation() {
        let widget = { (id: String, lane: ShellLane, island: WorkspaceBarIslandSlice) in
            WorkspaceBarShellWidget(id: id, size: CGSize(width: 10, height: 10), lane: lane, island: island)
        }
        for orientation in [WorkspaceBarOrientation.horizontal, .vertical] {
            let snapshot = WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(items: [], scratchpads: []),
                backgroundOpacity: 0.6,
                barHeight: 24,
                orientation: orientation,
                shellWidgets: [
                    widget("menu", .leading, .all),
                    widget("clock", .trailing, .all),
                    widget("menu", .leading, .active),
                    widget("spaces", .leading, .active),
                    widget("spaces", .leading, .secondary),
                    widget("clock", .trailing, .secondary)
                ]
            )
            let ids = { (slice: WorkspaceBarIslandSlice, lane: ShellLane) in
                slice.shellWidgets(in: snapshot, lane: lane).map(\.id)
            }
            XCTAssertEqual(ids(.all, .leading), ["menu"])
            XCTAssertEqual(ids(.all, .trailing), ["clock"])
            XCTAssertEqual(ids(.active, .leading), ["menu", "spaces"])
            XCTAssertEqual(ids(.active, .trailing), [])
            XCTAssertEqual(ids(.secondary, .leading), ["spaces"])
            XCTAssertEqual(ids(.secondary, .trailing), ["clock"])
        }
    }
}
