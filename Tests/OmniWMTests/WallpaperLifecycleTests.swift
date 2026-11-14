// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WallpaperLifecycleTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperLifecycle-\(UUID().uuidString)")
        _ = try WallpaperFixtures.makeFolder(directory, "Pictures/Wallpapers", files: ["a.jpg"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController() -> WMController {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.workspaceBar.enabled = false
        settings.island.enabled = false
        let controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: directory.appendingPathComponent("clipboard"),
            diagnosticsDirectory: directory.appendingPathComponent("diagnostics"),
            ownedWindowRegistry: OwnedWindowRegistry()
        )
        controller.workspaceBarManager.setup(controller: controller, settings: settings)
        return controller
    }

    private func follow(_ controller: WMController, desktop: FakeWallpaperDesktop) {
        let home = directory.path
        let make: @MainActor (SettingsStore) -> WallpaperManager = { settings in
            WallpaperManager(
                settings: settings.wallpaper, desktop: desktop,
                environment: WallpaperFixtures.environment(state: WallpaperStateBox(), home: home)
            )
        }
        controller.settings.onWallpaperSettingsChanged = { [weak controller] in
            controller?.applyWallpaperSettings(make: make)
        }
        controller.applyWallpaperSettings(make: make)
    }

    func testTheManagerExistsOnlyWhileManagementIsOn() {
        let controller = makeController()
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        follow(controller, desktop: desktop)
        XCTAssertNil(controller.wallpaperManager)
        controller.workspaceBarManager.prepareShell(for: [], settings: controller.settings)
        controller.workspaceBarManager.performWallpaperCommand(.next(.all))
        XCTAssertNil(controller.wallpaperManager, "the shell and widget commands create nothing while it is off")
        XCTAssertEqual(desktop.reads, 0)

        controller.settings.wallpaper.enabled = true
        let manager = controller.wallpaperManager
        XCTAssertEqual(manager?.running, true)
        controller.settings.wallpaper.rotationMinutes = SettingsExport.Wallpaper.rotationPresets[0]
        XCTAssertTrue(controller.wallpaperManager === manager)

        controller.settings.wallpaper.enabled = false
        XCTAssertNil(controller.wallpaperManager)
        XCTAssertEqual(manager?.running, false)
        XCTAssertNil(desktop.onChange, "turning it off removes the desktop observer")
    }

    func testAWidgetRotationCommandWhileManagementIsOffWritesNoSettings() throws {
        let controller = makeController()
        let before = try XCTUnwrap(String(
            data: SettingsTOMLCodec.encode(controller.settings.toExport()),
            encoding: .utf8
        ))
        controller.workspaceBarManager.performWallpaperCommand(
            .rotation(minutes: SettingsExport.Wallpaper.rotationPresets[0])
        )
        XCTAssertEqual(controller.settings.wallpaper.rotationMinutes, 0)
        let after = try XCTUnwrap(String(
            data: SettingsTOMLCodec.encode(controller.settings.toExport()),
            encoding: .utf8
        ))
        XCTAssertEqual(after, before, "settings.toml stays as it was")
        XCTAssertFalse(after.contains("[wallpaper]"))
    }

    func testAWidgetReadingWallpaperDataWhileManagementIsOffSeesItOffAndStartsNothing() {
        let feed = ShellDataFeed { _ in }
        feed.start()
        defer { feed.stop() }
        feed.setDemand(ShellDataKey.wallpaper.bit | ShellDataKey.wallpaperPreviews.bit, cadence: .init())
        XCTAssertEqual(feed.current.wallpaper, ShellWallpaper())
        XCTAssertEqual(feed.current.wallpaper?.enabled, false)
        XCTAssertEqual(feed.current.wallpaperPreviews, ShellWallpaperPreviews())
        XCTAssertNil(feed.wallpaper)
    }

    func testTheWriterAndTheManagerShareOneObserverForEachDesktopEvent() {
        let events = ShellWallpaperEvents.shared
        let subscribers = events.subscribers
        let desktop = LiveWallpaperDesktop(screens: { [] }, store: { nil }, location: { _ in nil })
        var desktopEvents = 0
        desktop.onChange = { desktopEvents += 1 }
        let writer = ShellWallpaperPaletteWriter(
            destination: directory.appendingPathComponent("themes/wallpaper.toml"), scheme: .tonalSpot,
            source: { { .capture(aerial: false) } }, read: { _ in nil }, image: { _ in nil },
            perform: { _ in }, deliver: { _ in }
        ) { _ in }
        writer.start()
        XCTAssertEqual(events.subscribers, subscribers + 2)
        XCTAssertTrue(events.isObserving)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(desktopEvents, 1, "one Space switch reaches the manager once")

        writer.stop()
        desktop.onChange = nil
        XCTAssertEqual(events.subscribers, subscribers)
        XCTAssertEqual(events.isObserving, subscribers > 0)
    }

    func testANewerColorChoiceDiscardsTheOlderOneStillOnItsWay() async {
        let controller = makeController()
        var finished: [String] = []
        let older = controller.workspaceBarManager.selectWallpaperScheme(.vibrant) { _ in finished.append("older") }
        let newer = controller.workspaceBarManager.useStylePalette { _ in finished.append("newer") }
        await older.value
        await newer.value
        XCTAssertEqual(finished, ["newer"], "only the newest choice applies and reports")
    }
}
