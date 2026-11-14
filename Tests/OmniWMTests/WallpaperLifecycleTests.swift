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
        let workspace = NotificationCenter()
        let screens = NotificationCenter()
        let events = ShellWallpaperEvents(store: directory, workspace: workspace, screens: screens)
        let desktop = LiveWallpaperDesktop(screens: { [] }, store: { nil }, location: { _ in nil }, events: events)
        let writer = Owner()
        var desktopEvents = 0
        var writerEvents = 0
        desktop.onChange = { desktopEvents += 1 }
        events.subscribe(writer) { writerEvents += 1 }
        XCTAssertEqual(events.subscribers, 2)
        XCTAssertTrue(events.isObserving)

        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        screens.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(desktopEvents, 2, "each Space or screen change reaches the manager once")
        XCTAssertEqual(writerEvents, 2, "and the writer once, through the same observer")

        events.unsubscribe(writer)
        desktop.onChange = nil
        XCTAssertFalse(events.isObserving, "the observer goes away with its last subscriber")
    }

    func testThePaletteWriterSubscribesToTheSharedObserverOnlyWhileStarted() {
        let shared = ShellWallpaperEvents.shared
        let subscribers = shared.subscribers
        let writer = ShellWallpaperPaletteWriter(
            destination: directory.appendingPathComponent("themes/wallpaper.toml"), scheme: .tonalSpot,
            source: { { .capture(aerial: false) } }, read: { _ in nil }, image: { _ in nil },
            perform: { _ in }, deliver: { _ in }
        ) { _ in }
        writer.start()
        XCTAssertEqual(shared.subscribers, subscribers + 1)
        writer.stop()
        XCTAssertEqual(shared.subscribers, subscribers)
    }

    func testAColorFailureWhileManagementIsOffIsShownWithTheShellsProblems() {
        let controller = makeController()
        let host = ShellWidgetHost(
            configDirectory: directory,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("resources")),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        controller.workspaceBarManager.shellHost = host
        let problem = "The wallpaper colors can’t be written: the disk is full"
        controller.workspaceBarManager.reportWallpaperProblem(problem)
        XCTAssertTrue(host.configProblems.contains(problem), "\(host.configProblems)")
        controller.workspaceBarManager.shellHost = nil
    }

    private final class Owner {}

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
