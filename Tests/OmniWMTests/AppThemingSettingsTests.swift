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

    func testCustomHerdrReloadsFollowTheSavedMachinesSetting() {
        var settings = SettingsExport.AppTheming()
        settings.custom = [.init(name: "herdr", template: "~/t.conf", output: "~/.config/x/y.conf", reload: .herdr)]
        let configHome = URL(fileURLWithPath: "/Users/x/.config")
        settings.herdr.reloadSavedMachines = false
        XCTAssertEqual(settings.targets(configHome: configHome).first?.reload, .herdr(savedMachines: false))
        settings.herdr.reloadSavedMachines = true
        XCTAssertEqual(settings.targets(configHome: configHome).first?.reload, .herdr(savedMachines: true))
    }

    func testThePageBuildsCustomHerdrTargetsFromTheSavedMachinesSetting() throws {
        var values = SettingsExport.AppTheming()
        let custom = SettingsExport.AppTheming.Custom(
            name: "herdr", template: "~/t.conf", output: "~/.config/x/y.conf", reload: .herdr
        )
        values.custom = [custom]
        let sandbox = try AppThemeSandbox()
        defer { sandbox.remove() }
        for machines in [false, true] {
            values.herdr.reloadSavedMachines = machines
            let preview = AppThemePreview(
                engine: sandbox.engine(AppThemeFakeEnvironment()),
                values: values,
                dark: true
            ) { nil }
            XCTAssertEqual(preview.target(for: custom).reload, .herdr(savedMachines: machines))
        }
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
    func testPaletteChangeAppliesRightAwayAndKeepsTheLatestPalette() throws {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let dark = AppThemeTestFlag(true)
        let service = sandbox.service(settings, fake) { dark.value }
        service.paletteDidChange(theme(background: .black))
        service.paletteDidChange(theme(background: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)))
        XCTAssertTrue(sandbox.read(".config/kitty/dark-theme.auto.conf")?.contains("background #1a334d") == true)
        XCTAssertEqual(service.results["kitty"]?.outcome, .updated)
        dark.value = false
        service.appearanceDidChange()
        XCTAssertFalse(service.isDark)
    }

    @MainActor
    func testARunGoesThroughTheWorkerAndComesBackThroughTheMainThreadHop() throws {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let worker = AppThemeHeldWork()
        let hops = AppThemeHeldHops()
        let service = sandbox.service(settings, fake, perform: worker.perform, deliver: hops.deliver) { true }
        service.paletteDidChange(theme(background: .black))
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(worker.count, 1)
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        worker.release()
        XCTAssertNotNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        XCTAssertTrue(service.isRunning)
        XCTAssertNil(service.results["kitty"])
        XCTAssertEqual(hops.count, 1)
        hops.release()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.results["kitty"]?.outcome, .updated)
    }

    @MainActor
    func testWithEveryAppOffNoPaletteIsBuilt() {
        let settings = AppThemingSettings()
        let service = sandbox.service(settings, fake) { true }
        let asked = AppThemeTestCounter()
        service.useThemeWhileShellIsOff {
            asked.value += 1
            return .native
        }
        service.applyNow()
        service.settingsDidChange()
        service.appearanceDidChange()
        XCTAssertEqual(asked.value, 0)
        XCTAssertFalse(service.isRunning)
    }

    @MainActor
    func testAnAppTurnedOffAfterItsRunWasQueuedIsNotWritten() {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        settings.values.herdr = .init(enabled: true, reloadSavedMachines: false)
        let worker = AppThemeHeldWork()
        let service = sandbox.service(settings, fake, perform: worker.perform) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        settings.values.kitty.enabled = false
        worker.release()
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        XCTAssertNil(service.results["kitty"])
        XCTAssertNotNil(sandbox.read(".config/herdr/config.toml"))
        XCTAssertFalse(fake.signals.contains { $0.pid == AppThemeFakeEnvironment.kittyPID })
    }

    @MainActor
    func testAStoppedServiceDropsItsQueuedRun() {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let worker = AppThemeHeldWork()
        let service = sandbox.service(settings, fake, perform: worker.perform) { true }
        service.paletteDidChange(theme(background: .black))
        service.stop()
        worker.release()
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        XCTAssertNil(service.results["kitty"])
        XCTAssertTrue(fake.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.store.stateURL.path))
    }

    @MainActor
    func testStoredResultsArriveFromTheWorkersRunNotFromTheMainThread() {
        var stored = SettingsExport.AppTheming()
        stored.herdr = .init(enabled: true, reloadSavedMachines: false)
        _ = sandbox.engine(fake).run(AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            appearanceChanged: false,
            targets: stored.targets(configHome: sandbox.policy.configHome)
        ))
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let worker = AppThemeHeldWork()
        let service = sandbox.service(settings, fake, perform: worker.perform) { true }
        XCTAssertTrue(service.results.isEmpty)
        service.paletteDidChange(theme(background: .black))
        XCTAssertTrue(service.results.isEmpty)
        worker.release()
        XCTAssertEqual(service.results["herdr"]?.outcome, .updated)
        XCTAssertEqual(service.results["kitty"]?.outcome, .updated)
    }

    @MainActor
    func testAQueuedRunSkipsATemplateWhoseOutputChangedSince() throws {
        try sandbox.write("{{mode}}\n", to: "templates/mode.conf")
        let settings = AppThemingSettings()
        let custom = SettingsExport.AppTheming.Custom(
            name: "Mode",
            template: sandbox.path("templates/mode.conf").path,
            output: "~/.config/mode/old.conf"
        )
        settings.values.custom = [custom]
        let worker = AppThemeHeldWork()
        let service = sandbox.service(settings, fake, perform: worker.perform) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        settings.values.custom[0].output = "~/.config/mode/new.conf"
        worker.release()
        XCTAssertNil(sandbox.read(".config/mode/old.conf"))
        worker.release()
        XCTAssertEqual(sandbox.read(".config/mode/new.conf"), "dark\n")
        XCTAssertNil(sandbox.read(".config/mode/old.conf"))
    }

    @MainActor
    func testDisabledAppsAreNeverWritten() {
        let service = sandbox.service(AppThemingSettings(), fake) { true }
        service.paletteDidChange(theme(background: .black))
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
    }

    @MainActor
    func testTurningOnAnAppWithAnExistingFileBacksItUpFirst() throws {
        try sandbox.write("[keys]\nprefix = \"x\"\n", to: ".config/herdr/config.toml")
        let settings = AppThemingSettings()
        let service = sandbox.service(settings, fake) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        let changes = try service.changes(for: service.target(for: .herdr), onlyExisting: true)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.diff.filter { $0.kind == .removed }, [])
        XCTAssertTrue(changes.first?.diff.contains { $0.kind == .added && $0.text == "[theme.custom]" } == true)
        service.confirm(changes, enabling: .herdr)
        XCTAssertTrue(settings.values.herdr.enabled)
        XCTAssertEqual(service.results["herdr"]?.outcome, .updated)
        let backup = try XCTUnwrap(service.lastBackup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "[keys]\nprefix = \"x\"\n")
    }

    @MainActor
    func testTakingOverAFileThatChangedSinceTheReviewIsRefused() throws {
        try sandbox.write("include mine.conf\n", to: ".config/kitty/dark-theme.auto.conf")
        let settings = AppThemingSettings()
        let service = sandbox.service(settings, fake) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        let stale = try service.changes(for: service.target(for: .kitty), onlyExisting: true)
        try sandbox.write("include newer.conf\n", to: ".config/kitty/dark-theme.auto.conf")
        service.confirm(stale, enabling: .kitty)
        XCTAssertEqual(sandbox.read(".config/kitty/dark-theme.auto.conf"), "include newer.conf\n")
        XCTAssertEqual(service.results["kitty"]?.outcome, .conflict)
        XCTAssertNil(service.lastBackup)
        let reviewed = try service.changes(for: service.target(for: .kitty), onlyExisting: true)
        service.confirm(reviewed)
        XCTAssertEqual(service.results["kitty"]?.outcome, .updated)
        let backup = try XCTUnwrap(service.lastBackup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "include newer.conf\n")
    }

    @MainActor
    func testAReviewedFileThatChangedSinceIsReviewedAgain() throws {
        try sandbox.write("include mine.conf\n", to: ".config/kitty/dark-theme.auto.conf")
        let settings = AppThemingSettings()
        let service = sandbox.service(settings, fake) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        let stale = try service.changes(for: service.target(for: .kitty), onlyExisting: true)
        try sandbox.write("include newer.conf\n", to: ".config/kitty/dark-theme.auto.conf")
        service.confirm(stale, enabling: .kitty)
        XCTAssertEqual(service.reviewAgain, "kitty")
        service.reviewShown()
        XCTAssertNil(service.reviewAgain)
        service.applyNow()
        XCTAssertNil(service.reviewAgain)
    }

    @MainActor
    private func ghosttyService() -> AppThemeService {
        let settings = AppThemingSettings()
        settings.values.ghostty.enabled = true
        let service = sandbox.service(settings, fake) { true }
        service.paletteDidChange(theme(background: .black))
        return service
    }

    @MainActor
    func testAnUnreadableGhosttyConfigIsReportedNotSkipped() throws {
        try sandbox.write("theme = light:omniwm-light,dark:omniwm-dark\n", to: ".config/ghostty/config")
        let support = "Library/Application Support/com.mitchellh.ghostty/config"
        try sandbox.write("theme = catppuccin\n", to: support)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: sandbox.path(support).path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sandbox.path(support).path)
        }
        let service = ghosttyService()
        XCTAssertEqual(service.ghosttySelectionStatus(), .unreadable("~/\(support)"))
        XCTAssertThrowsError(try service.ghosttySelectionChanges())
    }

    @MainActor
    func testGhosttySelectionBacksUpTheExactBytesItReplaces() throws {
        let url = sandbox.path(".config/ghostty/config")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("font-size = 14\r\ntheme = catppuccin\n".utf8)
        try original.write(to: url)
        let service = ghosttyService()
        let changes = try service.ghosttySelectionChanges()
        XCTAssertEqual(changes.map(\.url), [url])
        service.applyGhosttySelection(changes)
        XCTAssertEqual(service.ghosttySelectionStatus(), .selected)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(service.lastBackup)), original)
        let mode = try FileManager.default
            .attributesOfItem(atPath: XCTUnwrap(service.lastBackup).path)[.posixPermissions]
        XCTAssertEqual(mode as? Int, 0o600)
    }

    @MainActor
    func testGhosttySelectionEditShowsTheLineAndBacksUp() throws {
        try sandbox.write("font-size = 14\ntheme = catppuccin\n", to: ".config/ghostty/config")
        let service = ghosttyService()
        XCTAssertEqual(service.ghosttySelectionStatus(), .notSelected)
        let changes = try service.ghosttySelectionChanges()
        XCTAssertEqual(changes.map(\.display), ["~/.config/ghostty/config"])
        XCTAssertEqual(changes.first?.after, """
        font-size = 14
        # theme = catppuccin

        \(AppThemeGhosttySelection.marker)
        \(AppThemeBuiltIn.ghosttyThemeLine)

        """)
        service.applyGhosttySelection(changes)
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), changes.first?.after)
        XCTAssertEqual(service.ghosttySelectionStatus(), .selected)
        XCTAssertTrue(try service.ghosttySelectionChanges().isEmpty)
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
        let service = ghosttyService()
        XCTAssertEqual(service.ghosttySelectionStatus(), .overridden("~/\(support)"))
        let changes = try service.ghosttySelectionChanges()
        XCTAssertEqual(changes.map(\.display), ["~/\(support)"])
        XCTAssertEqual(
            changes.first?.after,
            "font-size = 13\n# theme = dark:omniwm-wallpaper-dark,light:omniwm-wallpaper-light\n"
        )
        service.applyGhosttySelection(changes)
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
        ).map(\.url.path)
        XCTAssertEqual(files, [
            sandbox.path(".config/ghostty/config.ghostty").path,
            sandbox.path(".config/ghostty/config").path,
            sandbox.path("\(supportFolder)/config.ghostty").path,
            sandbox.path("\(supportFolder)/extra.conf").path
        ])
        let service = ghosttyService()
        XCTAssertEqual(service.ghosttySelectionStatus(), .notSelected)
        let changes = try service.ghosttySelectionChanges()
        XCTAssertEqual(changes.count, 4)
        service.applyGhosttySelection(changes)
        XCTAssertEqual(service.ghosttySelectionStatus(), .selected)
        let active = files.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .flatMap { $0.components(separatedBy: "\n") }
            .filter(AppThemeGhosttySelection.isThemeLine)
        XCTAssertEqual(active, [AppThemeBuiltIn.ghosttyThemeLine])
    }

    @MainActor
    func testALinkedGhosttyConfigGetsOneEditForItsFile() throws {
        let support = "Library/Application Support/com.mitchellh.ghostty/config"
        try sandbox.write("font-size = 13\ntheme = catppuccin\n", to: support)
        try FileManager.default.createDirectory(
            at: sandbox.path(".config/ghostty"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: sandbox.path(".config/ghostty/config"),
            withDestinationURL: sandbox.path(support)
        )
        let service = ghosttyService()
        let changes = try service.ghosttySelectionChanges()
        XCTAssertEqual(changes.map(\.url.path), [sandbox.path(support).path])
        service.applyGhosttySelection(changes)
        XCTAssertNil(service.reviewAgain)
        XCTAssertEqual(service.ghosttySelectionStatus(), .selected)
        XCTAssertTrue(try XCTUnwrap(sandbox.read(support)).contains(AppThemeBuiltIn.ghosttyThemeLine))
    }

    @MainActor
    func testGhosttySelectionRefusesWhenAnyFileChangedSinceTheReview() throws {
        let support = "Library/Application Support/com.mitchellh.ghostty/config.ghostty"
        try sandbox.write("theme = a\n", to: ".config/ghostty/config")
        try sandbox.write("theme = b\n", to: support)
        let service = ghosttyService()
        let changes = try service.ghosttySelectionChanges()
        XCTAssertEqual(changes.count, 2)
        try sandbox.write("theme = c\n", to: support)
        service.applyGhosttySelection(changes)
        XCTAssertEqual(service.reviewAgain, AppThemeService.ghosttySelectionReview)
        XCTAssertEqual(sandbox.read(".config/ghostty/config"), "theme = a\n")
        XCTAssertEqual(sandbox.read(support), "theme = c\n")
    }

    @MainActor
    func testGhosttySelectionEditReloadsGhosttyOnceWhenThemesAreUnchanged() throws {
        fake.runGhostty()
        try sandbox.write("theme = catppuccin\n", to: ".config/ghostty/config")
        let settings = AppThemingSettings()
        settings.values.ghostty.enabled = true
        let service = sandbox.service(settings, fake) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        let reloads = { self.fake.signals.count }
        XCTAssertEqual(reloads(), 1)
        let changes = try service.ghosttySelectionChanges()
        XCTAssertEqual(changes.count, 1)
        service.applyGhosttySelection(changes)
        XCTAssertEqual(service.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(reloads(), 2)
        service.applyNow()
        XCTAssertEqual(reloads(), 2)
    }

    @MainActor
    func testGhosttySelectionEditAlsoReloadsTheQuakeTerminal() throws {
        try sandbox.write("theme = catppuccin\n", to: ".config/ghostty/config")
        let settings = AppThemingSettings()
        settings.values.ghostty.enabled = true
        let service = sandbox.service(settings, fake) { true }
        var quakeReloads = 0
        service.onGhosttyThemesChanged = { quakeReloads += 1 }
        service.paletteDidChange(theme(background: .black))
        XCTAssertEqual(quakeReloads, 1)
        let changes = try service.ghosttySelectionChanges()
        service.applyGhosttySelection(changes)
        XCTAssertEqual(service.results["ghostty"]?.outcome, .unchanged)
        XCTAssertEqual(quakeReloads, 2)
        service.applyNow()
        XCTAssertEqual(quakeReloads, 2)
    }

    @MainActor
    func testTurningAnAppOnReloadsItEvenWhenItsFilesAlreadyMatch() throws {
        let configHome = sandbox.policy.configHome
        var enabled = SettingsExport.AppTheming()
        enabled.kitty.enabled = true
        let settings = AppThemingSettings()
        let service = sandbox.service(settings, fake) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        service.paletteDidChange(theme(background: .black))
        let palette = try XCTUnwrap(service.palette)
        _ = sandbox.engine(fake).run(AppThemeJob(
            palette: palette, dark: true, appearanceChanged: false, targets: enabled.targets(configHome: configHome)
        ))
        let kills = { self.fake.signals.filter { $0.signal == SIGUSR1 }.count }
        XCTAssertEqual(kills(), 1)
        settings.values.kitty.enabled = true
        XCTAssertEqual(service.results["kitty"]?.outcome, .unchanged)
        XCTAssertEqual(kills(), 2)
        service.applyNow()
        XCTAssertEqual(kills(), 2)
    }

    @MainActor
    func testChangingTerminalColorsRedrawsThePreviewAndRewritesApps() throws {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let service = sandbox.service(settings, fake) { true }
        settings.onValuesChange = { service.settingsDidChange() }
        var wallpaper = ShellTheme.native
        for (role, hex) in [(ShellRole.accent, "#4FD8EB"), (.background, "#0E1415"), (.foreground, "#DDE4E5")] {
            wallpaper.dark[role.rawValue] = NSColor(shellHex: hex)!
            wallpaper.light[role.rawValue] = NSColor(shellHex: hex)!
        }
        service.paletteDidChange(wallpaper)
        let followed = try XCTUnwrap(service.palette).dark.ansi
        let before = sandbox.read(".config/kitty/dark-theme.auto.conf")
        settings.values.terminalColors = .standard
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
    func testDarkEffectiveAppearanceWritesDarkColors() throws {
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let settings = AppThemingSettings()
        settings.values.herdr = .init(enabled: true, reloadSavedMachines: false)
        let service = sandbox.service(settings, fake, systemIsDark: AppThemeService.liveSystemIsDark)
        XCTAssertTrue(service.isDark)
        service.paletteDidChange(theme(background: .black))
        let herdr = try XCTUnwrap(sandbox.read(".config/herdr/config.toml"))
        XCTAssertTrue(herdr.contains("from its dark palette"), herdr)
    }

    @MainActor
    func testEveryPaletteRunReadsTheAppearanceFresh() throws {
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let settings = AppThemingSettings()
        settings.values.herdr = .init(enabled: true, reloadSavedMachines: false)
        let service = sandbox.service(settings, fake, systemIsDark: AppThemeService.liveSystemIsDark)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        service.paletteDidChange(theme(background: .black))
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("from its dark palette"))
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        service.paletteDidChange(theme(background: .darkGray))
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("from its light palette"))
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        service.paletteDidChange(theme(background: .black))
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("from its dark palette"))
    }

    @MainActor
    func testAnAppearanceChangeIsAppliedAsItHappens() throws {
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let settings = AppThemingSettings()
        settings.values.herdr = .init(enabled: true, reloadSavedMachines: false)
        let service = sandbox.service(settings, fake, systemIsDark: AppThemeService.liveSystemIsDark)
        service.start()
        defer { service.stop() }
        service.paletteDidChange(theme(background: .black))
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("from its light palette"))
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(service.isDark)
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("from its dark palette"))
    }

    @MainActor
    func testAStoppedServiceNoLongerFollowsTheAppearance() {
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let service = sandbox.service(settings, fake, systemIsDark: AppThemeService.liveSystemIsDark)
        service.start()
        service.stop()
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        XCTAssertFalse(service.isDark)
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
    }

    @MainActor
    func testWithTheShellOffTheRealThemeIsUsed() throws {
        let settings = AppThemingSettings()
        settings.values.kitty.enabled = true
        let service = sandbox.service(settings, fake) { true }
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
