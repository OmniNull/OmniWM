// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    func testBundledStylesInstallAsProfilesBesideTheDefault() throws {
        let styles = root.appendingPathComponent("styles", isDirectory: true)
        try write("theme = \"dusk\"", to: "dusk/shell.toml", in: styles)
        try write("s1", to: "dusk/widgets/clock/init.luau", in: styles)
        try write("x", to: "widgets/clock/init.luau", in: styles)
        try write("y", to: "default/shell.toml", in: styles)
        let shell = root.appendingPathComponent("shell", isDirectory: true)

        XCTAssertEqual(sync(styles: styles), [])
        let dusk = shell.appendingPathComponent("dusk", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: dusk.appendingPathComponent("widgets/clock/init.luau"), encoding: .utf8),
            "s1"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: dusk.appendingPathComponent(".manifest.json").path))
        XCTAssertEqual(ShellProfiles.names(in: shell), ["default", "dusk"])
        XCTAssertEqual(try read("widgets/clock/init.luau"), "v1")

        try write("mine", to: "dusk/widgets/clock/init.luau", in: shell)
        try write("s2", to: "dusk/widgets/clock/init.luau", in: styles)
        XCTAssertEqual(sync(styles: styles).map(\.lastPathComponent), ["init.luau.edited-2026-10-08"])
        XCTAssertEqual(
            try String(contentsOf: dusk.appendingPathComponent("widgets/clock/init.luau"), encoding: .utf8),
            "s2"
        )
    }

    func testTheBundledStylesLoadAsCleanProfiles() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        XCTAssertEqual(
            ShellProfiles.names(in: shell),
            ["default", "celestial", "lake", "matrix", "nocturne", "sakura", "system", "wayline"]
        )
        for style in ["celestial", "nocturne", "wayline"] {
            try write("profile = \"\(style)\"\n", to: "shell.toml", in: shell)
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], style)
            XCTAssertEqual(config.themeName, style)
            let celestial = style == "celestial"
            XCTAssertEqual(config.barOverride?.settings.height, celestial ? 60 : 40, style)
            XCTAssertEqual(config.barOverride?.settings.fullWidth, celestial ? true : nil, style)
            XCTAssertEqual(config.barOverride?.settings.position, celestial ? .left : nil, style)
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

    func testBundledProfilesStartWithTheSharedAppleAndAppMenus() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        for profile in ShellProfiles.names(in: shell) {
            _ = try ShellProfiles.select(profile, in: shell)
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], profile)
            XCTAssertEqual(Array(config.leading.prefix(3)), ["apple-menu", "app-menu", "omniwm"], profile)
            for name in ["apple-menu", "app-menu"] {
                XCTAssertEqual(config.widget(name), shell.appendingPathComponent("default/widgets/\(name)/init.luau"))
                XCTAssertEqual(config.leading.filter { $0 == name }.count, 1, profile)
                XCTAssertFalse(config.center.contains(name), profile)
                XCTAssertFalse(config.trailing.contains(name), profile)
            }
        }
        try write("profile = \"system\"\nprofiles.system.leading = [\"workspaces\"]\n", to: "shell.toml", in: shell)
        XCTAssertEqual(ShellConfig.resolve(shellDirectory: shell).leading, ["workspaces"])
        try ShellBarLayout.reset(shellDirectory: shell)
        XCTAssertEqual(
            Array(ShellConfig.resolve(shellDirectory: shell).leading.prefix(3)),
            ["apple-menu", "app-menu", "omniwm"]
        )
    }

    func testSystemInstallsNativeMaterialBarAndInheritsTheSharedEffectsGallery() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        try write("profile = \"system\"\n", to: "shell.toml", in: shell)
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(config.themeName, "native")
        XCTAssertEqual(config.theme, .native)
        XCTAssertEqual(config.leading, ["apple-menu", "app-menu", "omniwm", "workspaces", "scratchpads"])
        XCTAssertEqual(config.center, ["active-window"])
        XCTAssertEqual(config.trailing, ["privacy", "wifi", "battery-details", "control-center", "clock"])
        XCTAssertEqual(config.hiddenBarWidget, "hidden-bar")
        XCTAssertEqual(config.systemStatsWidget, "system-stats")
        let island = try XCTUnwrap(config.island)
        XCTAssertEqual(island.root, "focus-ribbon")
        XCTAssertEqual(island.displays, .all)
        XCTAssertEqual(island.width, 620)
        XCTAssertEqual(island.height, 200)
        XCTAssertEqual(island.fullscreen, .hide)
        XCTAssertTrue(island.components.isEmpty)
        let bar = try XCTUnwrap(config.barOverride?.settings)
        XCTAssertEqual(bar.position, .belowMenuBar)
        XCTAssertEqual(bar.height, 32)
        XCTAssertEqual(bar.fullWidth, true)
        XCTAssertEqual(bar.reserveLayoutSpace, true)
        XCTAssertEqual(bar.transparentBackground, false)
        XCTAssertEqual(bar.backgroundOpacity, 0)
        XCTAssertEqual(bar.solidBlackBackground, false)
        XCTAssertEqual(bar.showItemBackgrounds, false)
        XCTAssertEqual(bar.showAccentHighlights, true)
        let workspaces = try XCTUnwrap(config.widgetSettings["workspaces"])
        XCTAssertEqual(try ShellServiceValue.decode(workspaces).fields?["compact"]?.boolean, true)
        let defaults = shell.appendingPathComponent("default/widgets", isDirectory: true)
        let system = shell.appendingPathComponent("system/widgets", isDirectory: true)
        let widgets = try FileManager.default.contentsOfDirectory(atPath: defaults.path).sorted()
        let systemWidgets = try FileManager.default.contentsOfDirectory(atPath: system.path).sorted()
        let sharedWidgets = ["effects-lab", "apple-menu", "app-menu"]
        let styledWidgets = widgets.filter { !sharedWidgets.contains($0) }
        XCTAssertEqual(systemWidgets, (styledWidgets + ["focus-ribbon"]).sorted())
        XCTAssertEqual(config.widget("focus-ribbon"), system.appendingPathComponent("focus-ribbon/init.luau"))
        for widget in sharedWidgets {
            XCTAssertTrue(widgets.contains(widget))
            XCTAssertEqual(config.widget(widget), defaults.appendingPathComponent("\(widget)/init.luau"))
        }
        for widget in styledWidgets {
            XCTAssertEqual(config.widget(widget), system.appendingPathComponent("\(widget)/init.luau"))
        }
    }

    func testLakeInstallsPopulatedBarLanesAndReservedOpaquePlacement() throws {
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
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
        XCTAssertEqual(bar.position, .belowMenuBar)
        XCTAssertEqual(bar.height, 32)
        XCTAssertEqual(bar.reserveLayoutSpace, true)
        XCTAssertEqual(bar.transparentBackground, false)
        XCTAssertEqual(bar.backgroundOpacity, 1)
        XCTAssertEqual(bar.solidBlackBackground, true)
        XCTAssertEqual(
            config.widget("workspaces"),
            shell.appendingPathComponent("default/widgets/workspaces/init.luau")
        )
        let workspaces = try XCTUnwrap(config.widgetSettings["workspaces"])
        XCTAssertEqual(try ShellServiceValue.decode(workspaces).fields?["indicator"]?.string, "underline")
        XCTAssertEqual(config.island?.components.count, 6)
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

    func testAFolderTheUserMadeUnderAStyleNameIsLeftAlone() throws {
        let styles = root.appendingPathComponent("styles", isDirectory: true)
        try write("s1", to: "dusk/widgets/clock/init.luau", in: styles)
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        try write("mine", to: "dusk/shell.toml", in: shell)

        XCTAssertEqual(sync(styles: styles), [])
        let dusk = shell.appendingPathComponent("dusk", isDirectory: true)
        XCTAssertEqual(try String(contentsOf: dusk.appendingPathComponent("shell.toml"), encoding: .utf8), "mine")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dusk.appendingPathComponent("widgets").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dusk.appendingPathComponent(".manifest.json").path))
    }

    private func sync(styles: URL? = nil) -> [URL] {
        ShellDefaults.sync(
            into: root.appendingPathComponent("shell", isDirectory: true),
            from: source,
            styles: styles,
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
        let config = ShellConfig.resolve(shellDirectory: root)
        XCTAssertEqual(config.profile, "default")
        XCTAssertEqual(config.leading, ["menu"])
        XCTAssertEqual(config.trailing, ["clock"])
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

        try write("profiles.default.leading = [", to: "shell.toml")
        problems = []
        XCTAssertNil(ShellConfig.load(shellDirectory: root, problems: &problems))
        problems = []
        XCTAssertEqual(ShellConfig.resolve(shellDirectory: root, problems: &problems).profile, "default")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems.first?.hasPrefix("\(root.lastPathComponent)/shell.toml: ") == true)

        let bundled = try String(contentsOf: XCTUnwrap(ShellDefaults.bundledFile("shell.toml")), encoding: .utf8)
        try write(bundled, to: "default/shell.toml")
        let bundledThemes = try FileManager.default.contentsOfDirectory(
            atPath: XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("themes").path
        )
        XCTAssertEqual(bundledThemes.count, 14)
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
            "tokyo-night", "wayline"
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
        for folder in ["widgets", "themes", "shaders", ".git", "default", "noctalia", "Aqua"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try write("x", to: "notes.txt")
        XCTAssertEqual(ShellProfiles.names(in: root), ["default", "Aqua", "noctalia"])
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

        XCTAssertTrue(try ShellProfiles.setValue(
            red,
            at: ["profiles", "default", "workspaceBar", "accentColor"],
            in: root
        ))
        XCTAssertTrue(try ShellProfiles.setValue(
            red,
            at: ["profiles", "default", "workspaceBar", "textColor"],
            in: root
        ))
        settings.profileOverride = try XCTUnwrap(ShellConfig.load(shellDirectory: root)?.barOverride)
        XCTAssertEqual(settings.resolved(for: monitor).accentColor, red)
        XCTAssertEqual(settings.resolved(for: monitor).textColor, red)
        XCTAssertTrue(try ShellProfiles.reset(["profiles", "default", "workspaceBar"], in: root))
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
        XCTAssertTrue(try ShellProfiles.setValue([custom], at: ["profiles", "look", "monitorBarOverrides"], in: root))
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
        XCTAssertTrue(try ShellProfiles.reset(["profiles", "look", "monitorBarOverrides"], in: root))
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

    func testABrokenLayerKeepsThePreviousConfig() throws {
        try write("leading = [", to: "default/shell.toml")
        XCTAssertNil(ShellConfig.load(shellDirectory: root))
    }

    private func write(_ contents: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
