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
}
