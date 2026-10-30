// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import TOML
import XCTest

final class ShellDefaultsTests: XCTestCase {
    private var root: URL!

    private var source: URL {
        root.appendingPathComponent("bundle", isDirectory: true)
    }

    private var installed: URL {
        root.appendingPathComponent("shell/default", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try write("v1", to: "widgets/clock/init.luau", in: source)
        try write("a = 1", to: "themes/dusk.toml", in: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFirstSyncInstallsTheBundleAndRepeatedSyncsWriteNothing() throws {
        XCTAssertEqual(sync(), [])
        XCTAssertEqual(try read("widgets/clock/init.luau"), "v1")
        XCTAssertEqual(try read("themes/dusk.toml"), "a = 1")
        let manifest = installed.appendingPathComponent(".manifest.json")
        let fingerprint = try XCTUnwrap(SettingsFileAccess.currentFingerprint(at: manifest))

        XCTAssertEqual(sync(), [])
        XCTAssertEqual(SettingsFileAccess.currentFingerprint(at: manifest), fingerprint)
    }

    func testUpgradesReplaceUneditedFilesAndBackUpEditedOnesOnlyWhenTheyChange() throws {
        _ = sync()
        try write("a = 2", to: "themes/dusk.toml", in: installed)
        try write("v2", to: "widgets/clock/init.luau", in: source)

        XCTAssertEqual(sync(), [])
        XCTAssertEqual(try read("widgets/clock/init.luau"), "v2")
        XCTAssertEqual(try read("themes/dusk.toml"), "a = 2")

        try write("a = 3", to: "themes/dusk.toml", in: source)
        let backups = sync()
        XCTAssertEqual(backups.map(\.lastPathComponent), ["dusk.toml.edited-2026-10-08"])
        XCTAssertEqual(try read("themes/dusk.toml"), "a = 3")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8), "a = 2")
        XCTAssertEqual(sync(), [])
    }

    func testFilesOmniWMDidNotWriteAreBackedUpBeforeTheFirstSync() throws {
        try write("mine", to: "widgets/clock/init.luau", in: installed)
        try write("earlier", to: "widgets/clock/init.luau.edited-2026-10-08", in: installed)

        let backups = sync()
        XCTAssertEqual(backups.map(\.lastPathComponent), ["init.luau.edited-2026-10-08-2"])
        XCTAssertEqual(try read("widgets/clock/init.luau"), "v1")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8), "mine")
    }

    func testFilesDroppedFromTheBundleAreRemovedUnlessEdited() throws {
        try write("old", to: "widgets/old/init.luau", in: source)
        try write("kept", to: "widgets/kept/init.luau", in: source)
        _ = sync()
        try write("mine", to: "widgets/kept/init.luau", in: installed)
        try FileManager.default.removeItem(at: source.appendingPathComponent("widgets/old"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("widgets/kept"))

        XCTAssertEqual(sync(), [])
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: installed.appendingPathComponent("widgets/old/init.luau").path))
        XCTAssertEqual(try read("widgets/kept/init.luau"), "mine")
    }

    func testRepositoryStylesInstallExplicitlyBesideTheManagedDefault() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let name = try XCTUnwrap(ShellStyleFixture.names().first)
        let source = try ShellStyleFixture.source(name)
        XCTAssertEqual(sync(), [])
        XCTAssertEqual(ShellProfiles.names(in: shell), [ShellDefaults.profile])
        let target = try ShellStyleFixture.install(name, into: shell)
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("shell.toml")),
            try Data(contentsOf: source.appendingPathComponent("shell.toml"))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".manifest.json").path))
        XCTAssertEqual(ShellProfiles.names(in: shell), [ShellDefaults.profile, name])
        XCTAssertThrowsError(try ShellStyleFixture.install(name, into: shell))
        XCTAssertEqual(try read("widgets/clock/init.luau"), "v1")
    }

    func testTheRepositoryStylesLoadAsCleanProfiles() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let names = try ShellStyleFixture.names()
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(ShellProfiles.names(in: shell), [ShellDefaults.profile] + names)
        let defaultTheme = ShellConfig.resolve(shellDirectory: shell).themeName
        for style in names {
            try write("profile = \"\(style)\"\n", to: "shell.toml", in: shell)
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], style)
            let source = try ShellStyleFixture.source(style).appendingPathComponent("shell.toml")
            let declared = try TOMLDecoder().decode([String: TOMLNode].self, from: Data(contentsOf: source))
            if case let .string(theme)? = declared["theme"] {
                XCTAssertEqual(config.themeName, theme, style)
            } else {
                XCTAssertEqual(config.themeName, defaultTheme, style)
            }
            guard case let .table(bar)? = declared["workspaceBar"],
                  case let .integer(height)? = bar["height"],
                  case let .boolean(fullWidth)? = bar["fullWidth"],
                  case let .string(position)? = bar["position"]
            else { return XCTFail("Missing bar declaration for \(style)") }
            XCTAssertEqual(config.barOverride?.settings.height, Double(height), style)
            XCTAssertEqual(config.barOverride?.settings.fullWidth, fullWidth, style)
            XCTAssertEqual(config.barOverride?.settings.position?.rawValue, position, style)
            let celestial = style == "celestial"
            let dashboard = config.drawers.first { $0.id == "dashboard" }
            XCTAssertEqual(dashboard?.widgets, celestial ? ["dashboard"] : nil, style)
            if let dashboard {
                XCTAssertEqual(dashboard.edge, .top)
                XCTAssertTrue(dashboard.hover)
                XCTAssertTrue(dashboard.closesOnLeave)
                XCTAssertFalse(dashboard.chrome)
            }
            for widget in config.leading + config.center + config.trailing {
                XCTAssertNotNil(config.widget(widget), "\(style) \(widget)")
            }
        }
    }

    func testTheInstalledVitreusProfileKeepsItsIslandAndComponents() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        try ShellStyleFixture.install("vitreus", into: shell)
        try write("profile = \"vitreus\"\n", to: "shell.toml", in: shell)
        var problems: [String] = []
        let vitreus = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(vitreus.themeName, "vitreus")
        let island = try XCTUnwrap(vitreus.island)
        XCTAssertEqual(island.root, "vitreus")
        XCTAssertEqual(island.sizing, .display)
        XCTAssertEqual(island.displays, .all)
        XCTAssertEqual(island.components.map(\.id), ["pad", "focus"])
        XCTAssertEqual(island.components.map(\.widget), ["desk-pad", "desk-focus"])
        XCTAssertEqual(vitreus.leading + vitreus.center + vitreus.trailing, [])
        XCTAssertEqual(vitreus.barOverride?.settings.transparentBackground, true)
        XCTAssertEqual(vitreus.barOverride?.settings.reserveLayoutSpace, false)
    }

    func testVitreusThemeKeepsTheStockVitreusPaletteInBothAppearances() throws {
        let url = try XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("themes/vitreus.toml")
        let toml = try TOMLDecoder().decode([String: TOMLNode].self, from: Data(contentsOf: url))
        guard case let .table(light)? = toml["light"], case let .table(dark)? = toml["dark"] else {
            return XCTFail("vitreus needs [light] and [dark]")
        }
        XCTAssertEqual(light, dark)
        let stock = [
            "background": "#1B2127", "surface": "#161A1F", "foreground": "#F5F7F5", "secondaryForeground": "#C2C7CC",
            "accent": "#9ED6BD", "accentForeground": "#10161A", "shadow": "#0B0E11", "border": "#3A4048",
            "error": "#EF4444"
        ]
        for (role, hex) in stock {
            XCTAssertEqual(light[role], .string(hex), role)
        }
    }

    func testInstalledProfilesStartWithTheSharedAppleAndAppMenus() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ShellProfiles.names(in: shell) {
            _ = try ShellProfiles.select(profile, in: shell)
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], profile)
            let layout = ShellBarLayout(config: config, shellDirectory: shell)
            XCTAssertFalse(layout.widgets.contains { $0.name == "focus-ribbon" }, profile)
            if profile == "vitreus" {
                XCTAssertEqual(config.leading + config.center + config.trailing, [], profile)
                continue
            }
            XCTAssertEqual(Array(config.leading.prefix(3)), ["apple-menu", "app-menu", "omniwm"], profile)
            for name in ["apple-menu", "app-menu"] {
                XCTAssertEqual(config.widget(name), shell.appendingPathComponent("default/widgets/\(name)/init.luau"))
                XCTAssertEqual(config.leading.filter { $0 == name }.count, 1, profile)
                XCTAssertFalse(config.center.contains(name), profile)
                XCTAssertFalse(config.trailing.contains(name), profile)
            }
        }
    }

    func testScratchpadIconCountComesFromTheResolvedProfileAndIsClamped() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        XCTAssertEqual(ShellConfig.resolve(shellDirectory: shell).scratchpadIcons, 3)
        XCTAssertTrue(try ShellProfiles.select("nocturne", in: shell))
        XCTAssertEqual(ShellConfig.resolve(shellDirectory: shell).scratchpadIcons, 2)
        let selected = try String(contentsOf: shell.appendingPathComponent("shell.toml"), encoding: .utf8)
        for (value, expected) in [("9", 6), ("-1", 0), ("4", 4), ("inf", 6), ("2.7", 2)] {
            try Data((selected + "\n[profiles.nocturne.widgets.scratchpads]\nshownWindows = \(value)\n").utf8)
                .write(to: shell.appendingPathComponent("shell.toml"))
            XCTAssertEqual(ShellConfig.resolve(shellDirectory: shell).scratchpadIcons, expected, value)
        }
    }

    func testDefaultInstallsNativeMaterialBarAndTheSharedEffectsGallery() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(config.profile, "default")
        XCTAssertEqual(config.themeName, "native")
        XCTAssertEqual(config.theme, .native)
        XCTAssertEqual(config.leading, ["apple-menu", "app-menu", "omniwm", "workspaces", "scratchpads"])
        XCTAssertEqual(config.center, ["active-window"])
        XCTAssertEqual(
            config.trailing,
            ["media", "notifications", "volume", "wifi", "battery-details", "control-center", "system-stats", "clock"]
        )
        XCTAssertEqual(config.hiddenBarWidget, "hidden-bar")
        XCTAssertEqual(config.systemStatsWidget, "system-stats")
        XCTAssertEqual(config.barOverride?.systemStatsButton, true)
        let island = try XCTUnwrap(config.island)
        XCTAssertEqual(island.root, "focus-ribbon")
        XCTAssertEqual(island.displays, .all)
        XCTAssertEqual(island.width, 620)
        XCTAssertEqual(island.height, 200)
        XCTAssertEqual(island.fullscreen, .hide)
        XCTAssertTrue(island.components.isEmpty)
        let bar = try XCTUnwrap(config.barOverride?.settings)
        XCTAssertEqual(bar.position, .overlappingMenuBar)
        XCTAssertEqual(bar.height, 32)
        XCTAssertEqual(bar.fullWidth, true)
        XCTAssertEqual(bar.reserveLayoutSpace, true)
        XCTAssertEqual(bar.transparentBackground, false)
        XCTAssertEqual(bar.backgroundOpacity, 0)
        XCTAssertEqual(bar.solidBlackBackground, false)
        XCTAssertEqual(bar.showItemBackgrounds, false)
        XCTAssertEqual(bar.showAccentHighlights, true)
        XCTAssertNil(config.widgetSettings["workspaces"])
        let defaults = shell.appendingPathComponent("default/widgets", isDirectory: true)
        let widgets = try FileManager.default.contentsOfDirectory(atPath: defaults.path).sorted()
        let expectedWidgets = [
            "effects-lab",
            "focus-ribbon",
            "apple-menu",
            "app-menu",
            "notifications",
            "workspaces",
            "scratchpads",
            "omniwm",
            "hidden-bar",
            "hidden-bar-menu",
            "system-stats",
            "volume",
            "media",
            "clock",
            "calendar",
            "weather",
            "active-window",
            "battery",
            "battery-details",
            "wifi",
            "bluetooth",
            "input-source",
            "launcher",
            "privacy",
            "world-clock",
            "stats",
            "control-center"
        ]
        XCTAssertEqual(widgets, expectedWidgets.sorted())
        for widget in expectedWidgets {
            XCTAssertEqual(config.widget(widget), defaults.appendingPathComponent("\(widget)/init.luau"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: shell.appendingPathComponent("system").path))
    }

    func testLakeInstallsPopulatedBarLanesAndReservedMaterialPlacement() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        try write("profile = \"lake\"\n", to: "shell.toml", in: shell)
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        XCTAssertFalse(config.leading.isEmpty)
        XCTAssertFalse(config.center.isEmpty)
        XCTAssertFalse(config.trailing.isEmpty)
        for widget in config.leading + config.center + config.trailing {
            XCTAssertNotNil(config.widget(widget), widget)
        }
        let bar = try XCTUnwrap(config.barOverride?.settings)
        XCTAssertEqual(bar.position, .overlappingMenuBar)
        XCTAssertEqual(bar.height, 32)
        XCTAssertEqual(bar.reserveLayoutSpace, true)
        XCTAssertEqual(bar.transparentBackground, false)
        XCTAssertEqual(bar.backgroundOpacity, 0.1)
        XCTAssertEqual(bar.showItemBackgrounds, true)
        XCTAssertEqual(bar.showAccentHighlights, true)
        XCTAssertEqual(bar.solidBlackBackground, false)
        XCTAssertEqual(bar.showLabels, true)
        XCTAssertEqual(bar.xOffset, 0)
        XCTAssertEqual(bar.yOffset, 0)
        XCTAssertEqual(
            config.widget("workspaces"),
            shell.appendingPathComponent("default/widgets/workspaces/init.luau")
        )
        let workspaces = try XCTUnwrap(config.widgetSettings["workspaces"])
        XCTAssertEqual(try ShellServiceValue.decode(workspaces).fields?["indicator"]?.string, "underline")
        XCTAssertEqual(config.island?.components.count, 6)
    }

    func testStylesWithoutAnIslandInheritTheFocusRibbonOnEveryDisplay() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let monitors = [true, false].enumerated().map { index, hasNotch in
            let displayID = CGDirectDisplayID(91001 + index)
            let frame = CGRect(x: index * 1600, y: 0, width: 1600, height: 1000)
            return Monitor(
                id: .init(displayId: displayID),
                displayId: displayID,
                frame: frame,
                visibleFrame: frame,
                hasNotch: hasNotch,
                name: hasNotch ? "Notched" : "Flat",
                isMain: !hasNotch
            )
        }
        for profile in ["matrix", "sakura", "wayline", "nocturne", "celestial"] {
            XCTAssertTrue(try ShellProfiles.select(profile, in: shell), profile)
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], profile)
            let island = try XCTUnwrap(config.island, profile)
            XCTAssertEqual(island.root, "focus-ribbon", profile)
            XCTAssertEqual(island.displays, .all, profile)
            XCTAssertEqual(monitors.filter { island.includes($0) }.map(\.id), monitors.map(\.id), profile)
        }

        XCTAssertTrue(try ShellProfiles.select("lake", in: shell))
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        let island = try XCTUnwrap(config.island)
        XCTAssertEqual(island.root, "lake")
        XCTAssertEqual(island.displays, .all)
        XCTAssertEqual(monitors.filter { island.includes($0) }.map(\.id), monitors.map(\.id))
    }

    func testBundledProviderRetainsExecutablePermissionsAfterInstallAndUpdate() throws {
        let path = "widgets/provider/provider.pl"
        try write("#!/usr/bin/perl\nprint 1;\n", to: path, in: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: source.appendingPathComponent(path).path
        )
        XCTAssertEqual(sync(), [])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.appendingPathComponent(path).path))
        XCTAssertFalse(FileManager.default
            .isExecutableFile(atPath: installed.appendingPathComponent("widgets/clock/init.luau").path))
        try write("#!/usr/bin/perl\nprint 2;\n", to: path, in: source)
        XCTAssertEqual(sync(), [])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.appendingPathComponent(path).path))
        XCTAssertEqual(try read(path), "#!/usr/bin/perl\nprint 2;\n")
    }

    func testDefaultSyncLeavesAnUnmanagedStyleAlone() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let name = try XCTUnwrap(ShellStyleFixture.names().first)
        let target = try ShellStyleFixture.install(name, into: shell)
        let file = target.appendingPathComponent("shell.toml")
        let contents = "mine"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(sync(), [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".manifest.json").path))
    }

    func testDefaultSyncLeavesFormerlyManagedStylesAndTheirFilesAlone() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let files = [
            "shell.toml": "theme = 'native'", "lib/style.luau": "return {}",
            "widgets/extra/init.luau": "mine", ".manifest.json": "{}"
        ]
        let style = shell.appendingPathComponent("system", isDirectory: true)
        for (path, contents) in files { try write(contents, to: path, in: style) }
        for version in ["v1", "v2"] {
            try write(version, to: "widgets/clock/init.luau", in: source)
            XCTAssertEqual(sync(), [])
            XCTAssertEqual(try read("widgets/clock/init.luau"), version)
            for (path, contents) in files {
                XCTAssertEqual(try String(contentsOf: style.appendingPathComponent(path), encoding: .utf8), contents)
            }
            XCTAssertEqual(ShellProfiles.names(in: shell), [ShellDefaults.profile, style.lastPathComponent])
        }
    }

    func testDefaultSyncLeavesInstalledStylesThroughASymlinkedShellPath() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let name = try XCTUnwrap(ShellStyleFixture.names().first)
        let style = try ShellStyleFixture.install(name, into: shell)
        let manifest = ".manifest.json"
        try write("{}", to: manifest, in: style)
        let link = root.appendingPathComponent("linked-shell")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let linkedShell = link.appendingPathComponent("shell", isDirectory: true)
        let original = try Data(contentsOf: style.appendingPathComponent("shell.toml"))
        XCTAssertEqual(ShellDefaults.sync(into: linkedShell, from: source), [])
        XCTAssertEqual(try Data(contentsOf: style.appendingPathComponent("shell.toml")), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: style.appendingPathComponent(manifest).path))
        XCTAssertEqual(ShellProfiles.names(in: linkedShell), [ShellDefaults.profile, name])
    }

    private func sync() -> [URL] {
        ShellDefaults.sync(
            into: root.appendingPathComponent("shell", isDirectory: true),
            from: source,
            day: "2026-10-08"
        )
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: installed.appendingPathComponent(path), encoding: .utf8)
    }

    private func write(_ contents: String, to path: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}

final class ShellProfileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testABrokenShellTomlFallsBackToTheLayersBelowIt() throws {
        try write("leading = [\"menu\"]\ntrailing = [\"clock\"]\n", to: "default/shell.toml")
        try write("leading = [", to: "shell.toml")

        XCTAssertNil(ShellConfig.load(shellDirectory: root))
        var problems: [String] = []
        let config = ShellConfig.resolve(shellDirectory: root, problems: &problems)
        XCTAssertEqual(config.profile, "default")
        XCTAssertEqual(config.leading, ["menu"])
        XCTAssertEqual(config.trailing, ["clock"])
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems.first?.hasPrefix("\(root.lastPathComponent)/shell.toml: ") == true)

        try write("", to: "shell.toml")
        try write("leading = [", to: "default/shell.toml")
        XCTAssertNil(ShellConfig.load(shellDirectory: root))
    }

    func testTheShellFolderLayersOverTheProfileWhichLayersOverTheDefault() throws {
        try write("profile = \"look\"\nprofiles.look.trailing = [\"clock\"]\n", to: "shell.toml")
        try write("""
        hiddenBarWidget = "drawer"
        leading = ["menu"]
        [weather]
        city = "Oslo"
        """, to: "default/shell.toml")
        try write("leading = [\"spaces\"]\n[weather]\nunits = \"fahrenheit\"\n", to: "look/shell.toml")

        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.profile, "look")
        XCTAssertEqual(config.directories, [
            root,
            root.appendingPathComponent("look", isDirectory: true),
            root.appendingPathComponent("default", isDirectory: true)
        ])
        XCTAssertEqual(config.leading, ["spaces"])
        XCTAssertEqual(config.trailing, ["clock"])
        XCTAssertEqual(config.hiddenBarWidget, "drawer")
        XCTAssertEqual(
            config.weather,
            ShellWeatherLocation(place: .city("Oslo"), fahrenheit: true, refresh: .seconds(15 * 60))
        )
    }

    func testFilesResolveFromTheShellFolderThenTheProfileThenTheDefault() throws {
        try write("profile = \"look\"\n", to: "shell.toml")
        try write("theme = \"dusk\"\n", to: "look/shell.toml")
        try write("[light]\naccent = \"#FF0000\"\n", to: "default/themes/dusk.toml")
        for layer in ["default", "look"] {
            try write("return nil", to: "\(layer)/widgets/clock/init.luau")
        }
        try write("return nil", to: "default/widgets/battery/init.luau")

        var config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.themeName, "dusk")
        XCTAssertEqual(config.widget("clock"), root.appendingPathComponent("look/widgets/clock/init.luau"))
        XCTAssertEqual(config.widget("battery"), root.appendingPathComponent("default/widgets/battery/init.luau"))
        XCTAssertNil(config.widget("../default/widgets/battery"))
        XCTAssertNil(config.widget("volume"))

        try write("return nil", to: "widgets/clock/init.luau")
        config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.widget("clock"), root.appendingPathComponent("widgets/clock/init.luau"))
    }

    @MainActor
    func testProfilesOverrideHiddenBarSettings() throws {
        try write("[hiddenBar]\nenabled = false\nhiddenBundleIDs = [\"a\"]\n", to: "default/shell.toml")
        try write("[profiles.default.hiddenBar]\nrehideIntervalSeconds = 99\n", to: "shell.toml")

        let override = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.hiddenBarOverride)
        XCTAssertEqual(
            override,
            HiddenBarProfileOverride(profile: "default", enabled: false, rehideIntervalSeconds: 30)
        )
        XCTAssertEqual(override.overriddenKeys, ["enabled", "rehideIntervalSeconds"])

        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.hiddenBar.enabled = true
        settings.hiddenBar.rehideIntervalSeconds = 8
        XCTAssertTrue(settings.effectiveHiddenBarEnabled)
        settings.hiddenBar.profileOverride = override
        XCTAssertFalse(settings.effectiveHiddenBarEnabled)
        XCTAssertEqual(settings.hiddenBar.resolvedRehideIntervalSeconds, 30)
        XCTAssertEqual(settings.hiddenBar.rehideIntervalSeconds, 8)

        try write("[hiddenBar]\n", to: "default/shell.toml")
        try write("[profiles.default.hiddenBar]\nhiddenBundleIDs = []\n", to: "shell.toml")
        XCTAssertNil(try XCTUnwrap(ShellConfig.load(shellDirectory: root)).hiddenBarOverride)
    }

    @MainActor
    func testProfilesOverrideWorkspaceBarSettingsAboveMonitorOverrides() throws {
        try write("""
        [workspaceBar]
        height = 30
        position = "bottom"
        showLabels = false
        inactiveIconOpacity = 4
        excludedBundleIDs = ["com.apple.Safari"]
        notchMode = "nowhere"
        """, to: "default/shell.toml")
        try write("[profiles.default.workspaceBar]\nheight = 36\n", to: "shell.toml")

        let override = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(
            override.overriddenKeys,
            ["accentColor", "height", "inactiveIconOpacity", "position", "showLabels", "textColor"]
        )
        XCTAssertEqual(override.settings.height, 36)
        XCTAssertEqual(override.settings.inactiveIconOpacity, 1)
        XCTAssertEqual(override.settings.position, .bottom)
        XCTAssertNil(override.settings.notchMode)

        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            hasNotch: false,
            name: "Side"
        )
        let settings = WorkspaceBarSettings()
        settings.showFloatingWindows = false
        settings.update(
            MonitorBarSettings(monitorName: "Side", monitorDisplayId: 7, showFloatingWindows: true, height: 22),
            for: monitor
        )
        XCTAssertEqual(settings.resolved(for: monitor).height, 22)

        settings.profileOverride = override
        let resolved = settings.resolved(for: monitor)
        XCTAssertEqual(resolved.height, 36)
        XCTAssertEqual(resolved.position, .bottom)
        XCTAssertFalse(resolved.showLabels)
        XCTAssertTrue(resolved.showFloatingWindows)
    }

    @MainActor
    func testProfilesOverrideGlobalWorkspaceBarSettings() throws {
        try write("""
        [profiles.default.workspaceBar]
        hoverPreviewsEnabled = false
        systemStatsButton = false
        hideInNativeFullscreen = false
        notificationBadges = "dot"
        notificationBadgeRefreshIntervalSeconds = 0
        autoHideRevealDelayMilliseconds = 250
        autoHideHideDelayMilliseconds = 5000
        revealModifier = "option"
        revealHoldMilliseconds = 300
        excludedBundleIDs = ["com.apple.Safari"]
        """, to: "shell.toml")
        var problems: [String] = []
        let override = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)?.barOverride)
        XCTAssertEqual(override.overriddenKeys, [
            "accentColor", "autoHideHideDelayMilliseconds", "autoHideRevealDelayMilliseconds", "hideInNativeFullscreen",
            "hoverPreviewsEnabled", "notificationBadgeRefreshIntervalSeconds", "notificationBadges",
            "revealHoldMilliseconds", "revealModifier", "systemStatsButton", "textColor"
        ])
        XCTAssertEqual(override.notificationBadgeRefreshIntervalSeconds, 1)
        XCTAssertEqual(override.autoHideHideDelayMilliseconds, 1000)
        XCTAssertEqual(
            problems,
            ["[workspaceBar] excludedBundleIDs is not a bar setting a shell profile or theme can override"]
        )

        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            hasNotch: false,
            name: "Side"
        )
        let settings = WorkspaceBarSettings()
        settings.profileOverride = override
        XCTAssertFalse(settings.resolvedHoverPreviewsEnabled)
        XCTAssertFalse(settings.resolvedHideInNativeFullscreen)
        XCTAssertEqual(settings.resolvedNotificationBadges, .dot)
        XCTAssertEqual(settings.resolvedNotificationBadgeRefreshIntervalSeconds, 1)
        XCTAssertEqual(settings.resolvedAutoHideRevealDelayMilliseconds, 250)
        XCTAssertEqual(settings.resolvedAutoHideHideDelayMilliseconds, 1000)
        XCTAssertEqual(settings.resolvedRevealModifier, .option)
        XCTAssertEqual(settings.resolvedRevealHoldMilliseconds, 300)
        XCTAssertFalse(settings.resolved(for: monitor).systemStatsButton)
        XCTAssertEqual(settings.revealModifier, WorkspaceBarSettings().revealModifier)
        XCTAssertEqual(settings.export().hoverPreviewsEnabled, settings.hoverPreviewsEnabled)
        XCTAssertTrue(settings.hoverPreviewsEnabled)

        settings.profileOverride = nil
        XCTAssertEqual(settings.resolvedRevealModifier, settings.revealModifier)
        XCTAssertEqual(settings.resolvedNotificationBadges, settings.notificationBadges)
        XCTAssertEqual(settings.resolved(for: monitor).systemStatsButton, settings.systemStatsButton)
    }

    func testThemesSetWorkspaceBarSettingsBelowShellToml() throws {
        try write("""
        [dark]
        accent = "#FF0000"

        [workspaceBar]
        height = 40
        backgroundOpacity = 0.5
        solidBlackBackground = true
        """, to: "themes/look.toml")
        try write(
            "profiles.default.theme = \"look\"\n\n[profiles.default.workspaceBar]\nheight = 32\n",
            to: "shell.toml"
        )

        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        let override = try XCTUnwrap(config.barOverride)
        XCTAssertEqual(config.themeName, "look")
        XCTAssertEqual(
            override.overriddenKeys,
            ["accentColor", "backgroundOpacity", "height", "solidBlackBackground", "textColor"]
        )
        XCTAssertEqual(override.settings.height, 32)
        XCTAssertEqual(override.settings.backgroundOpacity, 0.5)
        XCTAssertEqual(override.settings.solidBlackBackground, true)

        try write("profiles.default.theme = \"native\"\n", to: "shell.toml")
        XCTAssertTrue(try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride).usesThemeColors)
    }

    @MainActor
    func testThemesAndProfilesPaintTheBarWithPaletteRoles() throws {
        try write("""
        [dark]
        surface = "#102030"
        border = "#405060"

        [workspaceBar]
        barFill = "surface/0.5"
        barBorder = "nowhere"
        """, to: "themes/look.toml")
        try write(
            "profiles.default.theme = \"look\"\n\n[profiles.default.workspaceBar]\ntransparentBackground = true\n",
            to: "shell.toml"
        )
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        let override = try XCTUnwrap(config.barOverride)
        XCTAssertEqual(override.overriddenKeys, ["accentColor", "barFill", "textColor", "transparentBackground"])
        XCTAssertEqual(
            problems,
            ["[workspaceBar] barBorder must be a palette role such as \"surface\" or \"surface/0.8\""]
        )
        let fill = try XCTUnwrap(override.barFill).dark.usingColorSpace(.sRGB)
        XCTAssertEqual(fill?.blueComponent ?? 0, 0x30 / 255, accuracy: 0.001)
        XCTAssertEqual(fill?.alphaComponent ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(ShellThemeColor("surface/2", theme: config.theme))

        try write(
            "profiles.default.theme = \"look\"\n\n[profiles.default.workspaceBar]\nbarBorder = \"border\"\n",
            to: "shell.toml"
        )
        let bordered = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(bordered.barBorder, ShellThemeColor("border", theme: config.theme))
        XCTAssertEqual(bordered.barFill, override.barFill)

        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            hasNotch: false,
            name: "Side"
        )
        let settings = WorkspaceBarSettings()
        settings.profileOverride = override
        let resolved = settings.resolved(for: monitor)
        XCTAssertEqual(resolved.barFill, override.barFill)
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 0,
            transparentBackground: resolved.transparentBackground,
            barHeight: 24,
            barFill: resolved.barFill,
            barBorder: resolved.barBorder
        )
        XCTAssertEqual(snapshot.backgroundStyle, .transparent)
        XCTAssertEqual(snapshot.replacingShellWidgets([]).backgroundStyle, snapshot.backgroundStyle)

        settings.profileOverride = nil
        XCTAssertNil(settings.resolved(for: monitor).barFill)
    }

    func testTheConfigReportsItsProblems() throws {
        try write("""
        profiles.default.leading = ["clock", 3]
        profiles.default.trailling = ["clock"]
        profiles.default.theme = "look"

        [weather]
        city = "Toronto"
        unit = "celsius"

        [profiles.default.drawer.controls]
        widgets = ["volume"]
        edges = "left"
        """, to: "shell.toml")
        try write("""
        [light]
        accent = "orange"

        [bar]
        height = 30
        """, to: "themes/look.toml")
        var problems: [String] = []
        XCTAssertNotNil(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(problems, [
            "shell.toml has unknown key trailling",
            "shell.toml: leading must contain widget names",
            "shell.toml: [weather] has unknown key unit",
            "shell.toml: [drawer.controls] has unknown key edges",
            "Theme look has unknown key bar",
            "Theme look: [light] accent must be a role name set to \"#RRGGBB\" or \"#RRGGBBAA\""
        ])

        let bundled = try String(contentsOf: XCTUnwrap(ShellDefaults.bundledFile("shell.toml")), encoding: .utf8)
        try write(bundled, to: "default/shell.toml")
        let bundledThemes = try FileManager.default.contentsOfDirectory(
            atPath: XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("themes").path
        )
        XCTAssertEqual(bundledThemes.count, 15)
        for theme in bundledThemes.map({ String($0.dropLast(5)) }) {
            try write("profiles.default.theme = \"\(theme)\"\n", to: "shell.toml")
            problems = []
            XCTAssertEqual(ShellConfig.load(shellDirectory: root, problems: &problems)?.themeName, theme)
            XCTAssertEqual(problems, [], theme)
        }
    }

    func testBundledPalettesSetEveryRoleReadably() throws {
        let themes = try XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("themes")
        let names = [
            "catppuccin", "celestial", "dracula", "everforest", "gruvbox", "kanagawa", "nocturne", "nord", "rose-pine",
            "tokyo-night", "vitreus", "wayline"
        ]
        for name in names {
            let toml = try TOMLDecoder().decode(
                [String: TOMLNode].self,
                from: Data(contentsOf: themes.appendingPathComponent("\(name).toml"))
            )
            for appearance in ["light", "dark"] {
                guard case let .table(entries)? = toml[appearance]
                else { return XCTFail("\(name) has no [\(appearance)]") }
                let derived = Set(ShellTheme.derivedRoles.map { "\($0)" })
                XCTAssertEqual(
                    Set(entries.keys).subtracting(derived),
                    Set(ShellRole.allCases.map { "\($0)" }).subtracting(derived),
                    "\(name) \(appearance)"
                )
                let color = { (role: ShellRole) -> NSColor in
                    guard case let .string(text)? = entries["\(role)"], let color = NSColor(shellHex: text) else {
                        return .clear
                    }
                    return color
                }
                let label = "\(name) \(appearance)"
                for ground in [ShellRole.background, .surface] {
                    XCTAssertGreaterThanOrEqual(Self.contrast(color(.foreground), color(ground)), 4.5, label)
                }
                XCTAssertGreaterThanOrEqual(Self.contrast(color(.accentForeground), color(.accent)), 4.5, label)
                XCTAssertGreaterThanOrEqual(Self.contrast(.white, color(.badge)), 3, label)
                let tinted = ShellRole.allCases
                    .filter { (ShellRole.red.rawValue ... ShellRole.gray.rawValue).contains($0.rawValue) }
                    + [.accent, .success, .warning, .error, .mutedForeground]
                for role in tinted {
                    for ground in [ShellRole.background, .surface, .elevatedSurface] {
                        XCTAssertGreaterThanOrEqual(
                            Self.contrast(color(role), color(ground)),
                            3,
                            "\(label) \(role) on \(ground)"
                        )
                    }
                }
            }
        }
    }

    private static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let luminance = { (color: NSColor) -> Double in
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (high, low) = (max(luminance(lhs), luminance(rhs)), min(luminance(lhs), luminance(rhs)))
        return (high + 0.05) / (low + 0.05)
    }

    func testProfilesAreTheShellFoldersOtherThanItsOwnContent() throws {
        for folder in ["widgets", "themes", "shaders", "fonts", ".git", "default", "noctalia", "Aqua"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try write("x", to: "notes.txt")
        XCTAssertEqual(ShellProfiles.names(in: root), ["default", "Aqua", "noctalia"])
    }

    func testProfileDiscoveryFollowsDirectorySymlinksAndKeepsTheirNames() throws {
        let names = try makeSymlinkedProfiles()
        let target = root.appendingPathComponent(".profiles/look", isDirectory: true)
        for name in ["widgets", "themes", "shaders", "lib", "default", ".hidden"] {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(name),
                withDestinationURL: target
            )
        }

        XCTAssertEqual(ShellProfiles.names(in: root), ["default"] + names)

        let linkedShell = root.appendingPathComponent(".linked-shell", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedShell, withDestinationURL: root)
        XCTAssertEqual(ShellProfiles.names(in: linkedShell), ["default"] + names)
    }

    func testSelectingSymlinkedProfilesLoadsTheirSettingsAndWidgets() throws {
        for name in try makeSymlinkedProfiles() {
            XCTAssertTrue(try ShellProfiles.select(name, in: root), name)
            assertTOMLEqual(try String(contentsOf: root.appendingPathComponent("shell.toml"), encoding: .utf8), """
            profile = "\(name)"
            """)

            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
            XCTAssertEqual(problems, [], name)
            XCTAssertEqual(config.profile, name)
            XCTAssertEqual(config.trailing, ["linked-clock"])
            let widget = try XCTUnwrap(config.widget("linked-clock"))
            XCTAssertEqual(widget, root.appendingPathComponent("\(name)/widgets/linked-clock/init.luau"))
            XCTAssertEqual(try String(contentsOf: widget, encoding: .utf8), "return 'linked profile'")
            XCTAssertFalse(try ShellProfiles.select(name, in: root), name)
        }
    }

    func testNonDirectoryProfileSymlinksAreRejected() throws {
        try write("x", to: "notes.txt")
        let destinations = [
            "file-link": "notes.txt",
            "dangling": "missing",
            "cycle-a": "cycle-b",
            "cycle-b": "cycle-a"
        ]
        for (name, destination) in destinations {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(name).path,
                withDestinationPath: destination
            )
        }

        XCTAssertEqual(ShellProfiles.names(in: root), ["default"])
        for name in destinations.keys {
            XCTAssertThrowsError(try ShellProfiles.select(name, in: root)) { error in
                XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("shell.toml").path))
    }

    private func makeSymlinkedProfiles() throws -> [String] {
        try write("trailing = [\"linked-clock\"]\n", to: ".profiles/look/shell.toml")
        try write("return 'linked profile'", to: ".profiles/look/widgets/linked-clock/init.luau")
        let links = [
            ("absolute", root.appendingPathComponent(".profiles/look").path),
            ("relative", ".profiles/look"),
            ("chained", "relative")
        ]
        for (name, destination) in links {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(name).path,
                withDestinationPath: destination
            )
        }
        return links.map(\.0).sorted()
    }

    private func assertTOMLEqual(
        _ actual: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let decoder = TOMLDecoder()
            let actualValue = try decoder.decode([String: TOMLNode].self, from: Data(actual.utf8))
            let expectedValue = try decoder.decode([String: TOMLNode].self, from: Data(expected.utf8))
            XCTAssertEqual(actualValue, expectedValue, file: file, line: line)
        } catch {
            XCTFail(error.localizedDescription, file: file, line: line)
        }
    }

    func testSelectingAProfileEditsOnlyTheProfileLine() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("look"),
            withIntermediateDirectories: true
        )
        let config = root.appendingPathComponent("shell.toml")
        let read = { try String(contentsOf: config, encoding: .utf8) }

        XCTAssertFalse(try ShellProfiles.select("default", in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertTrue(try ShellProfiles.select("look", in: root))
        assertTOMLEqual(try read(), "profile = \"look\"\n")
        XCTAssertEqual(ShellConfig.load(shellDirectory: root)?.profile, "look")

        try write("trailing = [\"clock\"]\n  profile   = \"look\"\n[weather]\nprofile = \"keep\"\n", to: "shell.toml")
        XCTAssertTrue(try ShellProfiles.select("default", in: root))
        assertTOMLEqual(try read(), "trailing = [\"clock\"]\nprofile = \"default\"\n[weather]\nprofile = \"keep\"\n")
        XCTAssertFalse(try ShellProfiles.select("default", in: root))
        XCTAssertThrowsError(try ShellProfiles.select("gone", in: root))

        try write("[weather]\nprofile = \"keep\"", to: "shell.toml")
        XCTAssertTrue(try ShellProfiles.select("look", in: root))
        assertTOMLEqual(try read(), "profile = \"look\"\n[weather]\nprofile = \"keep\"\n")
    }

    @MainActor
    func testYourSettingsForAProfileWinOverItsOwnAndStayWithThatProfile() throws {
        try write("theme = \"dusk\"\n\n[workspaceBar]\nheight = 34\nshowLabels = true\n", to: "look/shell.toml")
        try write("[dark]\naccent = \"#0000FF\"\n", to: "look/themes/dusk.toml")
        try write("""
        profile = "look"

        [profiles.look.workspaceBar]
        height = 40

        [profiles.default.workspaceBar]
        height = 22
        """, to: "shell.toml")
        let look = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(look.settings.height, 40)
        XCTAssertEqual(look.settings.showLabels, true)
        XCTAssertTrue(look.usesThemeColors)

        try write(
            "[profiles.look.workspaceBar]\nheight = 40\n\n[profiles.default.workspaceBar]\nheight = 22\n",
            to: "shell.toml"
        )
        let plain = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(plain.settings.height, 22)
        XCTAssertNil(plain.settings.showLabels)
        XCTAssertTrue(plain.usesThemeColors)
    }

    @MainActor
    func testProfileColorsOverrideNamedThemesAndResetToThePalette() throws {
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            hasNotch: false,
            name: "Side"
        )
        let settings = WorkspaceBarSettings()
        let red = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        settings.accentColor = red
        settings.textColor = red
        try write("profiles.default.theme = \"nocturne\"\n", to: "shell.toml")
        settings.profileOverride = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertNil(settings.resolved(for: monitor).accentColor)
        XCTAssertNil(settings.resolved(for: monitor).textColor)

        XCTAssertTrue(try ShellProfiles.setNodes([
            (["profiles", "default", "workspaceBar", "accentColor"], try ShellTOMLText.node(red))
        ], in: root))
        XCTAssertTrue(try ShellProfiles.setNodes([
            (["profiles", "default", "workspaceBar", "textColor"], try ShellTOMLText.node(red))
        ], in: root))
        settings.profileOverride = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(settings.resolved(for: monitor).accentColor, red)
        XCTAssertEqual(settings.resolved(for: monitor).textColor, red)
        XCTAssertTrue(try ShellProfiles.setNodes([(["profiles", "default", "workspaceBar"], nil)], in: root))
        settings.profileOverride = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertNil(settings.resolved(for: monitor).accentColor)
        XCTAssertNil(settings.resolved(for: monitor).textColor)
        XCTAssertEqual(ShellConfig.resolve(shellDirectory: root).themeName, "nocturne")
        settings.profileOverride = nil
        XCTAssertEqual(settings.resolved(for: monitor).accentColor, red)
    }

    @MainActor
    func testProfileMonitorOverridesWinOnlyForTheirDisplayAndProfile() throws {
        let monitor = Monitor(
            id: .init(displayId: 7), displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600), hasNotch: false, name: "Main"
        )
        try write("[workspaceBar]\nposition = \"left\"\nheight = 60\n", to: "look/shell.toml")
        try write("profile = \"look\"\n[profiles.look.workspaceBar]\nheight = 80\n", to: "shell.toml")
        let custom = MonitorBarSettings(monitorName: monitor.name, monitorDisplayId: 7, position: .bottom, height: 100)
        XCTAssertTrue(try ShellProfiles.setNodes([
            (["profiles", "look", "monitorBarOverrides"], try ShellTOMLText.node([custom]))
        ], in: root))
        let settings = WorkspaceBarSettings()
        settings.height = 24
        settings.update(MonitorBarSettings(monitorName: monitor.name, position: .right, height: 32), for: monitor)
        settings.profileOverride = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(settings.resolved(for: monitor).position, .bottom)
        XCTAssertEqual(settings.resolved(for: monitor).height, 100)
        XCTAssertEqual(settings.resolved(for: monitor, includingProfileMonitor: false).position, .left)
        XCTAssertEqual(settings.resolved(for: monitor, includingProfileMonitor: false).height, 80)
        settings.enabled = false
        XCTAssertFalse(settings.resolved(for: monitor).enabled)
        XCTAssertTrue(try ShellProfiles.select("default", in: root))
        settings.profileOverride = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(settings.resolved(for: monitor).position, .right)
        XCTAssertEqual(settings.resolved(for: monitor).height, 32)
        XCTAssertTrue(try ShellProfiles.select("look", in: root))
        XCTAssertTrue(try ShellProfiles.setNodes([(["profiles", "look", "monitorBarOverrides"], nil)], in: root))
        settings.profileOverride = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(settings.resolved(for: monitor).position, .left)
        XCTAssertEqual(settings.resolved(for: monitor).height, 80)
    }

    func testEachProfileKeepsItsOwnThemeChoice() throws {
        try write("[dark]\naccent = \"#FF0000\"\n", to: "themes/ember.toml")
        try write("theme = \"dusk\"\n", to: "look/shell.toml")
        try write("[dark]\naccent = \"#0000FF\"\n", to: "look/themes/dusk.toml")
        try write("x", to: "themes/notes.txt")
        let config = root.appendingPathComponent("shell.toml")
        let read = { try String(contentsOf: config, encoding: .utf8) }
        let bundled = try FileManager.default.contentsOfDirectory(
            atPath: XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("themes").path
        ).map { String($0.dropLast(5)) }

        let names = ShellProfiles.themes(of: ShellConfig.resolve(shellDirectory: root))
        XCTAssertEqual(names.first, "native")
        XCTAssertEqual(Set(names), Set(["native", ShellWallpaperPalette.themeName, "ember"] + bundled))
        XCTAssertFalse(try ShellProfiles.selectTheme("native", in: root))
        XCTAssertThrowsError(try ShellProfiles.selectTheme("dusk", in: root))
        XCTAssertThrowsError(try ShellProfiles.selectTheme("notes", in: root))
        XCTAssertTrue(try ShellProfiles.selectTheme("ember", in: root))
        assertTOMLEqual(try read(), "profiles.default.theme = \"ember\"\n")
        XCTAssertEqual(ShellConfig.load(shellDirectory: root)?.themeName, "ember")

        XCTAssertTrue(try ShellProfiles.select("look", in: root))
        assertTOMLEqual(try read(), "profile = \"look\"\nprofiles.default.theme = \"ember\"\n")
        let look = ShellConfig.resolve(shellDirectory: root)
        XCTAssertEqual(look.themeName, "dusk")
        XCTAssertTrue(ShellProfiles.themes(of: look).contains("dusk"))
        XCTAssertFalse(try ShellProfiles.selectTheme("dusk", in: root))
        XCTAssertTrue(try ShellProfiles.selectTheme("ember", in: root))
        XCTAssertEqual(ShellConfig.load(shellDirectory: root)?.themeName, "ember")
        XCTAssertTrue(try ShellProfiles.selectTheme("dusk", in: root))
        assertTOMLEqual(try read(), "profile = \"look\"\nprofiles.default.theme = \"ember\"\n")

        XCTAssertTrue(try ShellProfiles.select(ShellDefaults.profile, in: root))
        XCTAssertEqual(ShellConfig.load(shellDirectory: root)?.themeName, "ember")
    }

    func testEjectingCopiesInheritedWidgetsIntoTheSelectedProfile() throws {
        try write("profile = \"look\"\n", to: "shell.toml")
        try write("", to: "look/shell.toml")
        try write("return 'look'", to: "default/widgets/clock/init.luau")
        try write("return 2", to: "default/widgets/clock/helper.luau")
        var config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.profile, "look")
        XCTAssertEqual(config.widget("clock"), root.appendingPathComponent("default/widgets/clock/init.luau"))

        let clock = try XCTUnwrap(ShellProfiles.eject("clock", config: config, shellDirectory: root))
        XCTAssertEqual(clock, root.appendingPathComponent("look/widgets/clock", isDirectory: true))
        XCTAssertEqual(try String(contentsOf: clock.appendingPathComponent("helper.luau"), encoding: .utf8), "return 2")
        config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertNil(try ShellProfiles.eject("clock", config: config, shellDirectory: root))

        let battery = try XCTUnwrap(ShellProfiles.eject("battery", config: config, shellDirectory: root))
        XCTAssertEqual(
            try Data(contentsOf: battery.appendingPathComponent("init.luau")),
            try Data(contentsOf: XCTUnwrap(ShellConfig.bundledWidget("battery")))
        )
        XCTAssertThrowsError(try ShellProfiles.eject("missing", config: config, shellDirectory: root))
    }

    func testCreatingAWidgetKeepsItInTheSelectedProfile() throws {
        try write("profile = \"look\"\n", to: "shell.toml")
        try write("", to: "look/shell.toml")
        XCTAssertTrue(try ShellProfiles.create("mine", in: root))
        XCTAssertFalse(try ShellProfiles.create("mine", in: root))
        XCTAssertEqual(
            ShellConfig.resolve(shellDirectory: root).widget("mine"),
            root.appendingPathComponent("look/widgets/mine/init.luau")
        )
        XCTAssertTrue(try ShellProfiles.select("default", in: root))
        XCTAssertNil(ShellConfig.resolve(shellDirectory: root).widget("mine"))
    }

    func testTheHiddenBarWidgetIsNamedInShellToml() throws {
        try write("profiles.default.hiddenBarWidget = \"drawer\"\n", to: "shell.toml")
        XCTAssertEqual(ShellConfig.load(shellDirectory: root)?.hiddenBarWidget, "drawer")
        try write("profiles.default.hiddenBarWidget = \"../drawer\"\n", to: "shell.toml")
        XCTAssertNil(ShellConfig.load(shellDirectory: root)?.hiddenBarWidget)
    }

    func testAMissingProfileFallsBackToTheDefault() throws {
        try write("profile = \"gone\"\n", to: "shell.toml")
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.profile, ShellDefaults.profile)
        XCTAssertEqual(config.directories, [root, root.appendingPathComponent("default", isDirectory: true)])
    }

    private func write(_ contents: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
