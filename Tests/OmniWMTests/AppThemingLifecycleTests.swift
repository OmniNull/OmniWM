// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

final class AppThemingLifecycleTests: XCTestCase {
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
    private func makeController(
        systemIsDark: @escaping @MainActor () -> Bool = { true }
    ) -> WMController {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: sandbox.root.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: sandbox.root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        controller.appThemeEngine = sandbox.engine(fake)
        controller.makeAppThemeService = { settings, engine, reloadsEnabledApps in
            AppThemeService(
                settings: settings,
                engine: engine,
                reloadsEnabledApps: reloadsEnabledApps,
                systemIsDark: systemIsDark,
                perform: { $0() },
                deliver: { MainActor.assumeIsolated($0) }
            )
        }
        return controller
    }

    @MainActor
    func testTheServiceExistsOnlyWhileAnAppIsOn() {
        let controller = makeController()
        XCTAssertNil(controller.appThemeService)
        controller.settings.appTheming.values.kitty.enabled = true
        let service = controller.appThemeService
        XCTAssertNotNil(service)
        controller.settings.appTheming.values.herdr.enabled = true
        XCTAssertTrue(controller.appThemeService === service)
        controller.settings.appTheming.values.kitty.enabled = false
        XCTAssertTrue(controller.appThemeService === service)
        controller.settings.appTheming.values.herdr.enabled = false
        XCTAssertNil(controller.appThemeService)
    }

    @MainActor
    func testWithEveryAppOffTheShellAndPaletteHooksCreateNothing() {
        let controller = makeController()
        controller.appThemeShellIsOff(theme: { .native })
        controller.appThemeShellIsOff(theme: { .native }, refresh: true)
        controller.appThemePaletteDidChange(.native)
        controller.workspaceBarManager.prepareShell(for: [], settings: controller.settings)
        XCTAssertNil(controller.appThemeService)
        XCTAssertNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
    }

    @MainActor
    func testAnAppTurnedOnIsWrittenAndReloadedRightAway() throws {
        let controller = makeController()
        controller.settings.appTheming.values.kitty.enabled = true
        XCTAssertNotNil(sandbox.read(".config/kitty/dark-theme.auto.conf"))
        let service = try XCTUnwrap(controller.appThemeService)
        XCTAssertEqual(service.results["kitty"]?.outcome, .updated)
        XCTAssertFalse(service.isRunning)
        XCTAssertNotNil(service.results["kitty"]?.reload)
    }

    @MainActor
    func testTurningOnAReviewedFileTakesItOverWithABackup() throws {
        try sandbox.write("[keys]\nprefix = \"x\"\n", to: ".config/herdr/config.toml")
        let controller = makeController()
        let preview = controller.appThemePreview
        let changes = try preview.changes(for: preview.target(for: .herdr), onlyExisting: true)
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(controller.appThemeService)
        controller.turnOnAppTheme(.herdr, approving: changes)
        let service = try XCTUnwrap(controller.appThemeService)
        XCTAssertEqual(service.results["herdr"]?.outcome, .updated)
        let backup = try XCTUnwrap(service.lastBackup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "[keys]\nprefix = \"x\"\n")
        XCTAssertTrue(try XCTUnwrap(sandbox.read(".config/herdr/config.toml")).contains("[theme.custom]"))
    }

    @MainActor
    func testTheServiceFollowsTheAppearanceOnlyWhileItExists() throws {
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let controller = makeController(systemIsDark: AppThemeService.liveSystemIsDark)
        controller.settings.appTheming.values.kitty.enabled = true
        let service = try XCTUnwrap(controller.appThemeService)
        XCTAssertFalse(service.isDark)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(service.isDark)
        controller.settings.appTheming.values.kitty.enabled = false
        XCTAssertNil(controller.appThemeService)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        XCTAssertTrue(service.isDark)
    }

    @MainActor
    func testBarColorChangesRefreshTheCachedPaletteWithTheShellOff() throws {
        let controller = makeController()
        controller.settings.workspaceBar.enabled = false
        controller.settings.island.enabled = false
        controller.workspaceBarManager.setup(controller: controller, settings: controller.settings)
        controller.workspaceBarManager.commandPaletteConfigCache = ShellConfig()
        controller.settings.appTheming.values.kitty.enabled = true
        let service = try XCTUnwrap(controller.appThemeService)
        let before = try XCTUnwrap(service.palette)
        let accent = SettingsColor(red: 0, green: 0, blue: 0, alpha: 1)
        let foreground = SettingsColor(red: 1, green: 1, blue: 1, alpha: 1)
        controller.settings.workspaceBar.accentColor = accent
        controller.settings.workspaceBar.textColor = foreground
        controller.workspaceBarManager.refreshShellBarColors(controller.settings)
        let after = try XCTUnwrap(service.palette)
        XCTAssertNotEqual(after, before)
        for scheme in [after.light, after.dark] {
            XCTAssertEqual(scheme.roles[.accent], .black)
            XCTAssertEqual(scheme.roles[.foreground], .white)
        }
        XCTAssertNil(controller.workspaceBarManager.shellHost)
    }

    @MainActor
    func testBarColorChangesPublishOnceForNativeAndCustomThemes() throws {
        let host = ShellWidgetHost(
            configDirectory: sandbox.root,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: sandbox.root.appendingPathComponent("resources")),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        let accent = SettingsColor(red: 0, green: 0, blue: 0, alpha: 1)
        let foreground = SettingsColor(red: 1, green: 1, blue: 1, alpha: 1)
        var delivered: [ShellTheme] = []
        host.onPaletteChange = { delivered.append($0) }
        for name in ["native", "custom"] {
            host.started = false
            host.setBarColors(accent: nil, foreground: nil)
            delivered = []
            host.config.themeName = name
            host.started = true
            host.setBarColors(accent: accent, foreground: foreground)
            host.setBarColors(accent: accent, foreground: foreground)
            XCTAssertEqual(delivered.count, 1)
            let palette = AppThemePalette(theme: try XCTUnwrap(delivered.first))
            for scheme in [palette.light, palette.dark] {
                XCTAssertEqual(scheme.roles[.accent], .black)
                XCTAssertEqual(scheme.roles[.foreground], .white)
            }
        }
        host.started = false
    }
}
