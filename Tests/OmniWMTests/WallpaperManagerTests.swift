// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WallpaperManagerTests: XCTestCase {
    private var root: URL!
    private var state = WallpaperRuntimeState()
    private var clock: ManualWallpaperClock!
    private var sampled: [WallpaperSampleKey] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try WallpaperFixtures.makeFolder(root, "Pictures/Wallpapers", files: ["a.jpg", "b.png", "c.heic", "d.webp"])
        state = WallpaperRuntimeState()
        clock = ManualWallpaperClock()
        sampled = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager(
        _ desktop: FakeWallpaperDesktop,
        palette: FakeWallpaperPalette? = nil,
        configure: (WallpaperSettings) -> Void = { _ in }
    ) -> WallpaperManager {
        let settings = WallpaperSettings()
        settings.enabled = true
        configure(settings)
        var environment = WallpaperEnvironment()
        environment.home = root.path
        environment.seed = 7
        environment.now = { [clock] in clock!.now }
        environment.schedule = { [clock] due, action in clock!.schedule(due, action) }
        environment.sample = { key in
            [UInt32(truncatingIfNeeded: key.file.path.utf8.count + key.width + key.height)]
        }
        environment.preview = { _ in nil }
        let manager = WallpaperManager(
            settings: settings, desktop: desktop, environment: environment,
            loadState: { [unowned self] in state },
            saveState: { [unowned self] in state = $0 }
        )
        palette?.desktop = desktop
        manager.palette = palette
        manager.settingsDidChange()
        return manager
    }

    private var defaultFolder: String {
        root.appendingPathComponent("Pictures/Wallpapers").path
    }

    func testAMacBookAloneWithANotchGetsTheDefaultFolderAndThePaletteFollowsIt() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.macBook])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries[0].folder.path, defaultFolder)
        XCTAssertEqual(manager.entries[0].files, ["a.jpg", "b.png", "c.heic", "d.webp"])
        let value = manager.shellValue().displays[0]
        XCTAssertTrue(value.notch)
        XCTAssertTrue(value.builtin)
        XCTAssertEqual(value.width, 1512)
        XCTAssertEqual(value.folder, "~/Pictures/Wallpapers")

        await manager.next(.all)

        XCTAssertEqual(desktop.events.count, 2)
        XCTAssertTrue(desktop.events[0].hasPrefix("palette "), "the palette is published before the wallpaper is set")
        XCTAssertTrue(desktop.events[1].hasPrefix("set \(WallpaperFixtures.macBook.key) "))
        XCTAssertNotNil(desktop.screens[0].current)
    }

    func testAMacBookWithAnExternalShowsTwoDisplaysAndThePaletteFollowsTheMainOne() async {
        let desktop = FakeWallpaperDesktop([
            WallpaperFixtures.studio,
            WallpaperFixtures.secondary(WallpaperFixtures.macBook)
        ])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        XCTAssertEqual(manager.entries.map(\.display.name), ["Studio Display", "Built-in Retina Display"])

        await manager.next(.all)
        XCTAssertEqual(palette.published.count, 1)
        XCTAssertEqual(manager.pin?.url, desktop.screens[0].current, "the palette follows the main display")
        XCTAssertEqual(manager.pin?.key.width, 2560)

        palette.published = []
        await manager.next(.display(WallpaperFixtures.macBook.monitorId))
        XCTAssertTrue(palette.published.isEmpty, "a change on a secondary display leaves the palette alone")
    }

    func testClamshellWithOnlyTheExternalDisplayStillWorks() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)
        XCTAssertEqual(palette.published.count, 1)
        XCTAssertEqual(desktop.events.filter { $0.hasPrefix("set") }.count, 1)
    }

    func testIdenticalMonitorsKeepTheirOwnFoldersAndShuffleHistoryByUUID() async throws {
        let left = try WallpaperFixtures.makeFolder(root, "left", files: ["l1.jpg", "l2.jpg"])
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.twinLeft, WallpaperFixtures.twinRight])
        let manager = makeManager(desktop) { settings in
            settings.setFolder(left.path, for: WallpaperFixtures.twinLeft.monitor)
        }
        XCTAssertEqual(manager.entries[0].folder.path, left.path)
        XCTAssertEqual(manager.entries[1].folder.path, defaultFolder)

        await manager.next(.all)
        XCTAssertEqual(
            Set(state.shuffle.displays.keys),
            [WallpaperFixtures.twinLeft.uuid!, WallpaperFixtures.twinRight.uuid!]
        )
        XCTAssertTrue(desktop.screens[0].current!.path.hasPrefix(left.path))
        XCTAssertTrue(desktop.screens[1].current!.path.hasPrefix(defaultFolder))

        desktop.screens.reverse()
        manager.refresh()
        XCTAssertEqual(manager.entries[0].display.uuid, WallpaperFixtures.twinRight.uuid)
        XCTAssertEqual(
            manager.entries[0].folder.path,
            defaultFolder,
            "reordering identical monitors keeps each one's folder"
        )
        XCTAssertEqual(manager.entries[1].folder.path, left.path)
    }

    func testAMissingDisplayIsNeverReplacedByAnotherWithTheSameName() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.twinLeft, WallpaperFixtures.twinRight])
        _ = makeManager(desktop)
        let gone = WallpaperFixtures.twinRight
        desktop.screens.removeAll { $0.uuid == gone.uuid }
        XCTAssertThrowsError(try desktop.setWallpaper(
            URL(fileURLWithPath: defaultFolder + "/a.jpg"), on: gone, placement: .fill
        ))
        XCTAssertNil(desktop.screens[0].current, "the surviving twin keeps its wallpaper")
    }

    func testUnplugMidRotationSetsTheRemainingDisplayAndKeepsTheOtherHistory() async {
        let desktop = FakeWallpaperDesktop([
            WallpaperFixtures.studio,
            WallpaperFixtures.secondary(WallpaperFixtures.macBook)
        ])
        let manager = makeManager(desktop)
        await manager.next(.all)
        let history = state.shuffle.displays[WallpaperFixtures.macBook.key]
        XCTAssertNotNil(history)
        let due = try? XCTUnwrap(manager.nextChange)

        desktop.unplug(WallpaperFixtures.macBook.key)
        desktop.events = []
        clock.advance(to: due ?? clock.now)
        for _ in 0 ..< 5 { await Task.yield() }
        await manager.next(.display(WallpaperFixtures.studio.monitorId))

        XCTAssertFalse(desktop.events.contains { $0.contains("Built-in") || $0.hasPrefix("missing") })
        XCTAssertEqual(state.shuffle.displays[WallpaperFixtures.macBook.key], history)
        XCTAssertNil(manager.problem)
    }

    func testAnEmptyFolderIsReportedAndOtherDisplaysStillChange() async throws {
        let empty = try WallpaperFixtures.makeFolder(root, "empty", files: ["notes.txt", ".hidden.jpg"])
        try FileManager.default.createDirectory(
            at: empty.appendingPathComponent("folder.jpg"), withIntermediateDirectories: true
        )
        let desktop = FakeWallpaperDesktop([
            WallpaperFixtures.studio,
            WallpaperFixtures.secondary(WallpaperFixtures.macBook)
        ])
        let manager = makeManager(desktop) { settings in
            settings.setFolder(empty.path, for: WallpaperFixtures.macBook.monitor)
        }
        XCTAssertEqual(manager.entries[1].files, [], "text files, hidden files and folders are not wallpapers")
        await manager.next(.all)
        XCTAssertEqual(desktop.events.filter { $0.hasPrefix("set") }.count, 1)
        XCTAssertEqual(manager.problem, "No wallpapers in ~/empty")
    }

    func testNonImageFilesAreNeverChosen() async throws {
        _ = try WallpaperFixtures.makeFolder(root, "Pictures/Wallpapers", files: ["readme.md", "clip.mov", "x.JPG"])
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop)
        XCTAssertEqual(manager.entries[0].files, ["a.jpg", "b.png", "c.heic", "d.webp", "x.JPG"])
        for _ in 0 ..< 10 {
            await manager.next(.all)
            XCTAssertTrue(WallpaperLibrary.isImage(desktop.screens[0].current!.lastPathComponent))
        }
    }

    func testSettingAFileUsesOnlyThatDisplaysFolder() async throws {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        await manager.set("c.heic", on: WallpaperFixtures.studio.monitorId)
        XCTAssertEqual(desktop.screens[0].current?.lastPathComponent, "c.heic")
        XCTAssertEqual(palette.published.count, 1)
        await manager.set("../secret.jpg", on: WallpaperFixtures.studio.monitorId)
        XCTAssertEqual(desktop.screens[0].current?.lastPathComponent, "c.heic")
        XCTAssertNotNil(manager.problem)
    }

    func testThePaletteIsLeftAloneWhenTheShellDoesNotUseWallpaperColors() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        palette.wallpaperPaletteState.active = false
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)
        XCTAssertTrue(palette.published.isEmpty)
        XCTAssertNil(manager.pin)
        XCTAssertEqual(desktop.events.count, 1)
    }

    func testTheWriterOverrideFollowsOnlyTheWallpaperOmniWMSetAtTheSameSizeAndPlacement() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, palette: FakeWallpaperPalette())
        await manager.next(.all)
        XCTAssertEqual(manager.palettePixels(), manager.pin?.pixels)

        manager.settings.placement = .fit
        XCTAssertNil(manager.palettePixels(), "a placement change invalidates the sample")
        manager.settings.placement = .fill

        desktop.screens[0].current = URL(fileURLWithPath: "/Library/Desktop Pictures/Other.heic")
        XCTAssertNil(manager.palettePixels(), "a wallpaper set elsewhere is read by the writer as before")
    }

    func testAResizedMainDisplayResamplesThePaletteForTheSameWallpaper() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)
        let first = manager.pin
        let current = desktop.screens[0].current

        desktop.screens[0] = WallpaperDisplay(
            displayId: 2, uuid: WallpaperFixtures.studio.uuid, name: "Studio Display",
            size: CGSize(width: 1440, height: 2560), isMain: true, current: current
        )
        desktop.onChange?()
        for _ in 0 ..< 10 { await Task.yield() }
        await manager.next(.display("display:999"))

        XCTAssertEqual(manager.pin?.url, current)
        XCTAssertNotEqual(manager.pin?.key, first?.key)
        XCTAssertEqual(manager.pin?.key.width, 1440)
        XCTAssertEqual(palette.published.count, 2)
        XCTAssertEqual(desktop.screens[0].current, current, "a resize never changes the wallpaper")
    }

    func testChangingThePlacementShowsTheCurrentWallpapersAgainWithIt() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)
        let current = desktop.screens[0].current
        desktop.events = []
        manager.settings.placement = .fit
        manager.settingsDidChange()
        await manager.next(.display("display:999"))
        XCTAssertEqual(
            desktop.events.filter { $0.hasPrefix("set") },
            ["set \(WallpaperFixtures.studio.key) \(current!.lastPathComponent)"]
        )
        XCTAssertEqual(desktop.screens[0].current, current)
        XCTAssertEqual(manager.pin?.key.placement, .fit)
        XCTAssertEqual(manager.palettePixels(), manager.pin?.pixels)
    }

    func testShuffleOrderPersistsAcrossRestartsAndEveryWallpaperShowsOncePerCycle() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        var seen: [String] = []
        var manager = makeManager(desktop)
        await manager.next(.all)
        await manager.next(.all)
        seen += desktop.events.compactMap { $0.split(separator: " ").last.map(String.init) }
        manager.stop()
        manager = makeManager(desktop)
        desktop.events = []
        await manager.next(.all)
        await manager.next(.all)
        seen += desktop.events.compactMap { $0.split(separator: " ").last.map(String.init) }
        XCTAssertEqual(Set(seen), ["a.jpg", "b.png", "c.heic", "d.webp"])
    }

    func testRotationRunsOnTheChosenIntervalAndSurvivesARestart() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        var manager = makeManager(desktop) { $0.rotationMinutes = 15 }
        XCTAssertEqual(manager.nextChange, clock.now.addingTimeInterval(15 * 60))
        XCTAssertEqual(state.nextChange, manager.nextChange)

        clock.now = clock.now.addingTimeInterval(5 * 60)
        manager.stop()
        manager = makeManager(desktop) { $0.rotationMinutes = 15 }
        XCTAssertEqual(manager.nextChange, state.nextChange, "a restart keeps the planned time")

        clock.advance(to: manager.nextChange!)
        for _ in 0 ..< 10 { await Task.yield() }
        await manager.next(.display("display:999"))
        XCTAssertEqual(desktop.events.filter { $0.hasPrefix("set") }.count, 1)
        XCTAssertEqual(manager.nextChange, clock.now.addingTimeInterval(15 * 60))

        manager.setRotation(0)
        XCTAssertNil(manager.nextChange)
        XCTAssertTrue(clock.pending.isEmpty)
        manager.setRotation(45)
        XCTAssertEqual(manager.settings.rotationMinutes, 45)
        XCTAssertEqual(manager.nextChange, clock.now.addingTimeInterval(45 * 60))
    }

    func testTurningTheFeatureOffStopsEverythingAndChangesNothing() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop) { $0.enabled = false }
        XCTAssertFalse(manager.running)
        XCTAssertTrue(clock.timers.isEmpty)
        await manager.next(.all)
        XCTAssertTrue(desktop.events.isEmpty)
        XCTAssertNil(desktop.onChange)
        XCTAssertEqual(state, WallpaperRuntimeState())
    }

    func testHotPlugAddsTheNewDisplayWithTheDefaultFolder() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop)
        desktop.plug(WallpaperFixtures.secondary(WallpaperFixtures.macBook))
        XCTAssertEqual(manager.entries.count, 2)
        XCTAssertEqual(manager.entries[1].folder.path, defaultFolder)
    }

    func testRevealOpensTheDisplaysFolder() {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop)
        manager.reveal(WallpaperFixtures.studio.monitorId)
        XCTAssertEqual(desktop.revealed.map(\.path), [defaultFolder])
    }
}
