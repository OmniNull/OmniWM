// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

final class AppThemingSettingsTests: XCTestCase {
    func testNothingIsOnByDefault() {
        let defaults = SettingsExport.defaults().appTheming
        XCTAssertFalse(defaults.anyEnabled)
        XCTAssertTrue(defaults.custom.isEmpty)
        XCTAssertTrue(defaults.targets(configHome: URL(fileURLWithPath: "/Users/x/.config")).isEmpty)
    }

    func testSettingsRoundTripThroughTOML() throws {
        var settings = SettingsExport.defaults()
        settings.appTheming.ghostty.enabled = true
        settings.appTheming.herdr = .init(enabled: true, reloadSavedMachines: false)
        settings.appTheming.custom = [
            .init(
                id: "A1",
                name: "Alacritty",
                template: "~/.config/omniwm/app-themes/alacritty.toml",
                darkTemplate: "~/.config/omniwm/app-themes/alacritty-dark.toml",
                output: "~/.config/alacritty/omniwm.toml",
                reload: .kitty
            )
        ]
        let data = try SettingsTOMLCodec.encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("[appTheming.ghostty]"), text)
        XCTAssertTrue(text.contains("[[appTheming.custom]]"), text)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).appTheming, settings.appTheming)
    }

    func testTerminalColorsSettingRoundTripsAndDefaultsToPalette() throws {
        XCTAssertEqual(SettingsExport.defaults().appTheming.terminalColors, .palette)
        var settings = SettingsExport.defaults()
        settings.appTheming.terminalColors = .standard
        let data = try SettingsTOMLCodec.encode(settings)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("terminalColors = \"standard\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).appTheming.terminalColors, .standard)
        let text = String(decoding: data, as: UTF8.self)
        let missing = text.replacingOccurrences(of: "terminalColors = \"standard\"\n", with: "")
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(missing.utf8)).appTheming.terminalColors, .palette)
        let unknown = text.replacingOccurrences(of: "terminalColors = \"standard\"", with: "terminalColors = \"sepia\"")
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(unknown.utf8)).appTheming.terminalColors, .palette)
    }

    func testMissingSectionAndKeysDecodeToSafeDefaults() throws {
        let encoded = try SettingsTOMLCodec.encode(SettingsExport.defaults())
        let lines = String(decoding: encoded, as: UTF8.self).components(separatedBy: "\n")
        var inSection = false
        let legacy = lines.filter { line in
            if line.hasPrefix("[") { inSection = line.hasPrefix("[appTheming") || line.hasPrefix("[[appTheming") }
            return !inSection
        }.joined(separator: "\n")
        XCTAssertFalse(legacy.contains("appTheming"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(legacy.utf8)).appTheming, SettingsExport.AppTheming())
        let partial = legacy + "\n[appTheming.kitty]\nenabled = true\n\n[[appTheming.custom]]\nname = \"Foot\"\n"
        let decoded = try SettingsTOMLCodec.decode(Data(partial.utf8)).appTheming
        XCTAssertTrue(decoded.kitty.enabled)
        XCTAssertFalse(decoded.ghostty.enabled)
        XCTAssertTrue(decoded.herdr.reloadSavedMachines)
        XCTAssertEqual(decoded.custom.first?.name, "Foot")
        XCTAssertEqual(decoded.custom.first?.enabled, false)
        XCTAssertEqual(decoded.custom.first?.reload, AppThemeCustomReload.none)
    }

    @MainActor
    func testSettingsOwnerSavesAndAppliesValues() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        var changes = 0
        settings.appTheming.onValuesChange = { changes += 1 }
        settings.appTheming.values.kitty.enabled = true
        settings.appTheming.values.kitty.enabled = true
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(settings.toExport().appTheming.kitty.enabled)
        var export = settings.toExport()
        export.appTheming.kitty.enabled = false
        settings.applyExport(export)
        XCTAssertFalse(settings.appTheming.values.kitty.enabled)
    }

    func testBuiltInTargetsUseTheConfigHome() {
        var settings = SettingsExport.AppTheming()
        for app in AppThemeBuiltIn.allCases { settings.setEnabled(app, true) }
        let home = URL(fileURLWithPath: "/Users/x/.config")
        let paths = settings.targets(configHome: home).flatMap(\.outputs).map(\.path)
        XCTAssertEqual(paths, [
            "/Users/x/.config/ghostty/themes/omniwm-light", "/Users/x/.config/ghostty/themes/omniwm-dark",
            "/Users/x/.config/kitty/light-theme.auto.conf", "/Users/x/.config/kitty/dark-theme.auto.conf",
            "/Users/x/.config/herdr/config.toml", "/Users/x/.config/nvim/lua/omniwm.lua",
            "/Users/x/.config/nvim/colors/omniwm.lua"
        ])
    }
}

final class AppThemeServiceTests: XCTestCase {
    private var sandbox: AppThemeSandbox!
    private var fake: AppThemeFakeEnvironment!

    override func setUpWithError() throws {
        sandbox = try AppThemeSandbox()
        fake = AppThemeFakeEnvironment()
    }

    override func tearDown() {
        sandbox.remove()
    }

    @MainActor
    private func theme(background: NSColor) -> ShellTheme {
        var theme = ShellTheme.native
        theme.dark[ShellRole.background.rawValue] = background
        theme.light[ShellRole.background.rawValue] = background
        return theme
    }

    @MainActor
    private func waitForRun(_ service: AppThemeService, _ body: () -> Void) async {
        let finished = expectation(description: "run finished")
        finished.assertForOverFulfill = false
        service.onRunFinished = { if !service.isRunning { finished.fulfill() } }
        body()
        await fulfillment(of: [finished], timeout: 10)
    }

    @MainActor
    func testPaletteChangeAppliesRightAwayAndKeepsTheLatestPalette() async throws {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let dark = AppThemeTestFlag(true)
        let service = AppThemeService(settings: settings, engine: sandbox.engine(fake)) { dark.value }
        await waitForRun(service) {
            service.paletteDidChange(theme(background: .black))
            service.paletteDidChange(theme(background: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)))
        }
        XCTAssertTrue(sandbox.read(".config/kitty/dark-theme.auto.conf")?.contains("background #1a334d") == true)
        XCTAssertEqual(service.results["kitty"]?.outcome, .updated)
        dark.value = false
        await waitForRun(service) { service.appearanceDidChange() }
        XCTAssertFalse(service.isDark)
    }

    @MainActor
    func testDisabledAppsAreNeverWritten() {
        let service = AppThemeService(settings: AppThemingSettings(), engine: sandbox.engine(fake)) { true }
        service.paletteDidChange(theme(background: .black))
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
    }

    @MainActor
    func testTurningOnAnAppWithAnExistingFileBacksItUpFirst() async throws {
        try sandbox.write("[keys]\nprefix = \"x\"\n", to: ".config/herdr/config.toml")
        let settings = AppThemingSettings()
        let service = AppThemeService(settings: settings, engine: sandbox.engine(fake)) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        let changes = try service.changes(for: service.target(for: .herdr), onlyExisting: true)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.diff.filter { $0.kind == .removed }, [])
        XCTAssertTrue(changes.first?.diff.contains { $0.kind == .added && $0.text == "[theme.custom]" } == true)
        await waitForRun(service) { try? service.confirm(changes, enabling: .herdr) }
        XCTAssertTrue(settings.values.herdr.enabled)
        XCTAssertEqual(service.results["herdr"]?.outcome, .updated)
        let backup = try XCTUnwrap(service.lastBackup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "[keys]\nprefix = \"x\"\n")
    }

    @MainActor
    func testGhosttySelectionEditShowsTheLineAndBacksUp() throws {
        try sandbox.write("font-size = 14\ntheme = catppuccin\n", to: ".config/ghostty/config")
        let service = AppThemeService(settings: AppThemingSettings(), engine: sandbox.engine(fake)) { true }
        XCTAssertEqual(service.ghosttySelectionStatus(), .notSelected)
        let changes = service.ghosttySelectionChanges()
        XCTAssertEqual(changes.map(\.display), ["~/.config/ghostty/config"])
        XCTAssertEqual(changes.first?.after, """
        font-size = 14
        # theme = catppuccin

        \(AppThemeGhosttySelection.marker)
        \(AppThemeBuiltIn.ghosttyThemeLine)

        """)
        try service.applyGhosttySelection(changes)
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), changes.first?.after)
        XCTAssertEqual(service.ghosttySelectionStatus(), .selected)
        XCTAssertTrue(service.ghosttySelectionChanges().isEmpty)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(service.lastBackup), encoding: .utf8), changes.first?.before)
    }

    @MainActor
    func testALaterApplicationSupportConfigThatOverridesTheSelectionIsReportedAndFixed() throws {
        let support = "Library/Application Support/com.mitchellh.ghostty/config.ghostty"
        try sandbox.write("\(AppThemeBuiltIn.ghosttyThemeLine)\n", to: ".config/ghostty/config")
        try sandbox.write(
            "font-size = 13\ntheme = dark:omniwm-wallpaper-dark,light:omniwm-wallpaper-light\n",
            to: support
        )
        let service = AppThemeService(settings: AppThemingSettings(), engine: sandbox.engine(fake)) { true }
        XCTAssertEqual(service.ghosttySelectionStatus(), .overridden("~/\(support)"))
        let changes = service.ghosttySelectionChanges()
        XCTAssertEqual(changes.map(\.display), ["~/\(support)"])
        XCTAssertEqual(
            changes.first?.after,
            "font-size = 13\n# theme = dark:omniwm-wallpaper-dark,light:omniwm-wallpaper-light\n"
        )
        try service.applyGhosttySelection(changes)
        XCTAssertEqual(service.ghosttySelectionStatus(), .selected)
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), "\(AppThemeBuiltIn.ghosttyThemeLine)\n")
        let backup = try XCTUnwrap(service.lastBackup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), changes.first?.before)
    }

    @MainActor
    func testSelectionFollowsEveryFileGhosttyLoadsInOrder() throws {
        let supportFolder = "Library/Application Support/com.mitchellh.ghostty"
        try sandbox.write("theme = a\n", to: ".config/ghostty/config.ghostty")
        try sandbox.write("theme = b\nconfig-file = ?missing.conf\n", to: ".config/ghostty/config")
        try sandbox.write("theme = c\nconfig-file = extra.conf\n", to: "\(supportFolder)/config.ghostty")
        try sandbox.write("theme = d\nconfig-file = ?config.ghostty\n", to: "\(supportFolder)/extra.conf")
        let files = AppThemeGhosttySelection.loadedFiles(
            configHome: sandbox.policy.configHome,
            home: sandbox.home
        ).map(\.path)
        XCTAssertEqual(files, [
            sandbox.path(".config/ghostty/config.ghostty").path,
            sandbox.path(".config/ghostty/config").path,
            sandbox.path("\(supportFolder)/config.ghostty").path,
            sandbox.path("\(supportFolder)/extra.conf").path
        ])
        let service = AppThemeService(settings: AppThemingSettings(), engine: sandbox.engine(fake)) { true }
        XCTAssertEqual(service.ghosttySelectionStatus(), .notSelected)
        let changes = service.ghosttySelectionChanges()
        XCTAssertEqual(changes.count, 4)
        try service.applyGhosttySelection(changes)
        XCTAssertEqual(service.ghosttySelectionStatus(), .selected)
        let active = files.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .flatMap { $0.components(separatedBy: "\n") }
            .filter(AppThemeGhosttySelection.isThemeLine)
        XCTAssertEqual(active, [AppThemeBuiltIn.ghosttyThemeLine])
    }

    @MainActor
    func testGhosttySelectionRefusesWhenAnyFileChangedSinceTheReview() throws {
        let support = "Library/Application Support/com.mitchellh.ghostty/config.ghostty"
        try sandbox.write("theme = a\n", to: ".config/ghostty/config")
        try sandbox.write("theme = b\n", to: support)
        let service = AppThemeService(settings: AppThemingSettings(), engine: sandbox.engine(fake)) { true }
        let changes = service.ghosttySelectionChanges()
        XCTAssertEqual(changes.count, 2)
        try sandbox.write("theme = c\n", to: support)
        XCTAssertThrowsError(try service.applyGhosttySelection(changes))
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), "theme = a\n")
        XCTAssertEqual(sandbox.read(support), "theme = c\n")
    }

    @MainActor
    func testGhosttySelectionEditReloadsGhosttyOnceWhenThemesAreUnchanged() async throws {
        fake.runningApps = [AppThemeReloader.ghosttyBundleIdentifier]
        try sandbox.write("theme = catppuccin\n", to: ".config/ghostty/config")
        let settings = AppThemingSettings()
        settings.values.ghostty.enabled = true
        let service = AppThemeService(settings: settings, engine: sandbox.engine(fake)) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        await waitForRun(service) { service.paletteDidChange(theme(background: .black)) }
        let reloads = { self.fake.calls.filter { $0.executable == "/usr/bin/osascript" }.count }
        XCTAssertEqual(reloads(), 1)
        let changes = service.ghosttySelectionChanges()
        XCTAssertEqual(changes.count, 1)
        await waitForRun(service) { try? service.applyGhosttySelection(changes) }
        XCTAssertEqual(service.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(reloads(), 2)
        await waitForRun(service) { service.applyNow() }
        XCTAssertEqual(reloads(), 2)
    }

    @MainActor
    func testTurningAnAppOnReloadsItEvenWhenItsFilesAlreadyMatch() async throws {
        let configHome = sandbox.policy.configHome
        var enabled = SettingsExport.AppTheming()
        enabled.kitty.enabled = true
        let settings = AppThemingSettings()
        let service = AppThemeService(settings: settings, engine: sandbox.engine(fake)) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        let palette = try XCTUnwrap(service.palette)
        _ = sandbox.engine(fake).run(AppThemeJob(
            palette: palette, dark: true, appearanceChanged: false, targets: enabled.targets(configHome: configHome)
        ))
        let kills = { self.fake.calls.filter { $0.executable == "/usr/bin/pkill" }.count }
        XCTAssertEqual(kills(), 1)
        await waitForRun(service) { settings.values.kitty.enabled = true }
        XCTAssertEqual(service.results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(kills(), 2)
        await waitForRun(service) { service.applyNow() }
        XCTAssertEqual(kills(), 2)
    }

    @MainActor
    func testChangingTerminalColorsRedrawsThePreviewAndRewritesApps() async throws {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let service = AppThemeService(settings: settings, engine: sandbox.engine(fake)) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        var wallpaper = ShellTheme.native
        for (role, hex) in [(ShellRole.accent, "#4FD8EB"), (.background, "#0E1415"), (.foreground, "#DDE4E5")] {
            wallpaper.dark[role.rawValue] = NSColor(shellHex: hex)!
            wallpaper.light[role.rawValue] = NSColor(shellHex: hex)!
        }
        await waitForRun(service) { service.paletteDidChange(wallpaper) }
        let followed = try XCTUnwrap(service.palette).dark.ansi
        let before = sandbox.read(".config/kitty/dark-theme.auto.conf")
        await waitForRun(service) { settings.values.terminalColors = .standard }
        let standard = try XCTUnwrap(service.palette).dark.ansi
        XCTAssertNotEqual(followed, standard)
        XCTAssertEqual(standard, AppThemePalette(theme: wallpaper, terminalColors: .standard).dark.ansi)
        XCTAssertNotEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), before)
        XCTAssertTrue(sandbox.read(".config/kitty/dark-theme.auto.conf")?.contains("color4 \(standard[4].hex)") == true)
    }

    @MainActor
    func testLiveAppearanceComesFromTheEffectiveAppearance() {
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(AppThemeService.liveSystemIsDark())
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        XCTAssertFalse(AppThemeService.liveSystemIsDark())
    }

    @MainActor
    func testDarkEffectiveAppearanceWritesDarkColors() async throws {
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let settings = AppThemingSettings()
        settings.values.herdr = .init(enabled: true, reloadSavedMachines: false)
        let service = AppThemeService(settings: settings, engine: sandbox.engine(fake))
        XCTAssertTrue(service.isDark)
        await waitForRun(service) { service.paletteDidChange(theme(background: .black)) }
        let herdr = try XCTUnwrap(sandbox.read(".config/herdr/config.toml"))
        XCTAssertTrue(herdr.contains("from its dark palette"), herdr)
    }

    @MainActor
    func testEveryPaletteRunReadsTheAppearanceFresh() async throws {
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let settings = AppThemingSettings()
        settings.values.herdr = .init(enabled: true, reloadSavedMachines: false)
        let service = AppThemeService(settings: settings, engine: sandbox.engine(fake))
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        await waitForRun(service) { service.paletteDidChange(theme(background: .black)) }
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("from its dark palette"))
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        await waitForRun(service) { service.paletteDidChange(theme(background: .darkGray)) }
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("from its light palette"))
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        await waitForRun(service) { service.paletteDidChange(theme(background: .black)) }
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("from its dark palette"))
    }

    @MainActor
    func testAThemeChangeNotificationReReadsTheAppearanceOnTheNextTurn() async throws {
        let reads = AppThemeTestCounter()
        let service = AppThemeService(settings: AppThemingSettings(), engine: sandbox.engine(fake)) {
            reads.value += 1
            return reads.value >= 3
        }
        XCTAssertFalse(service.isDark)
        service.appearanceNotificationReceived()
        XCTAssertFalse(service.isDark)
        for _ in 0 ..< 20 where !service.isDark {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(service.isDark)
        XCTAssertGreaterThanOrEqual(reads.value, 3)
    }

    @MainActor
    func testWithTheShellOffTheRealThemeIsUsed() throws {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let service = AppThemeService(settings: settings, engine: sandbox.engine(fake)) { true }
        let catppuccin = theme(background: NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x1B / 255, alpha: 1))
        var asked = 0
        service.useThemeWhileShellIsOff {
            asked += 1
            return catppuccin
        }
        XCTAssertEqual(service.palette, AppThemePalette(theme: catppuccin))
        XCTAssertNotEqual(service.palette, AppThemePalette(theme: .native))
        service.useThemeWhileShellIsOff { .native }
        XCTAssertEqual(service.palette, AppThemePalette(theme: catppuccin))
        service.useThemeWhileShellIsOff({ .native }, refresh: true)
        XCTAssertEqual(service.palette, AppThemePalette(theme: .native))
        XCTAssertEqual(asked, 1)
    }

    @MainActor
    func testWorkspaceBarManagerOffersTheConfiguredThemeWhenTheShellIsOff() throws {
        let directory = sandbox.root.appendingPathComponent("omniwm-config", isDirectory: true)
        let shell = directory.appendingPathComponent("shell", isDirectory: true)
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        try Data("profiles.default.theme = \"catppuccin\"\n".utf8).write(to: shell.appendingPathComponent("shell.toml"))
        let manager = WorkspaceBarManager(
            configDirectory: directory,
            motionPolicy: MotionPolicy(animationsEnabled: false)
        )
        XCTAssertNil(manager.shellHost)
        let palette = AppThemePalette(theme: manager.appThemeFallbackTheme())
        XCTAssertEqual(palette.dark.roles[.background], AppThemeColor(hex: "#11111B"))
        XCTAssertEqual(palette.light.roles[.background], AppThemeColor(hex: "#EFF1F5"))
    }

    @MainActor
    func testDiffShowsOnlyTheChangedLinesWithContext() {
        let before = (1 ... 10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "line 6\n", with: "line six\n")
        let diff = AppThemeDiff.lines(before: before, after: after)
        XCTAssertEqual(diff.map(\.kind), [.gap, .context, .context, .removed, .added, .context, .context, .gap])
        XCTAssertEqual(
            diff.filter { $0.kind != .gap }.map(\.text),
            ["line 4", "line 5", "line 6", "line six", "line 7", "line 8"]
        )
    }
}
