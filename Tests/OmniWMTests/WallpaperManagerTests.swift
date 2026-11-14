// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WallpaperManagerTests: XCTestCase {
    private var root: URL!
    private var box = WallpaperStateBox()
    private var clock: ManualWallpaperClock!

    private let presets = SettingsExport.Wallpaper.rotationPresets

    private func later(_ minutes: Int) -> Date {
        clock.now.addingTimeInterval(TimeInterval(minutes) * WallpaperManager.minute)
    }

    private var state: WallpaperRuntimeState {
        get { box.state }
        set { box.state = newValue }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try WallpaperFixtures.makeFolder(root, "Pictures/Wallpapers", files: ["a.jpg", "b.png", "c.heic", "d.webp"])
        box = WallpaperStateBox()
        clock = ManualWallpaperClock()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager(
        _ desktop: FakeWallpaperDesktop,
        palette: FakeWallpaperPalette? = nil,
        configure: (WallpaperSettings) -> Void = { _ in },
        environment change: (inout WallpaperEnvironment) -> Void = { _ in }
    ) -> WallpaperManager {
        let settings = WallpaperSettings()
        settings.enabled = true
        configure(settings)
        var environment = WallpaperFixtures.environment(state: box, home: root.path)
        environment.seed = 7
        environment.now = { [clock] in clock!.now }
        environment.schedule = { [clock] due, action in clock!.schedule(due, action) }
        environment.sample = { key in
            [UInt32(truncatingIfNeeded: key.file.path.utf8.count)]
        }
        change(&environment)
        let manager = WallpaperManager(settings: settings, desktop: desktop, environment: environment)
        settings.onChange = { [weak manager] in manager?.settingsDidChange() }
        palette?.desktop = desktop
        manager.palette = palette
        manager.start(resumingRotation: true)
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

    func testUnplugMidRotationSetsTheRemainingDisplayAndKeepsTheOtherHistory() async throws {
        let desktop = FakeWallpaperDesktop([
            WallpaperFixtures.studio,
            WallpaperFixtures.secondary(WallpaperFixtures.macBook)
        ])
        let manager = makeManager(desktop) { $0.rotationMinutes = self.presets[1] }
        await manager.next(.all)
        let history = state.shuffle.displays[WallpaperFixtures.macBook.key]
        XCTAssertNotNil(history)
        let due = try XCTUnwrap(manager.nextChange)

        desktop.unplug(WallpaperFixtures.macBook.key)
        desktop.events = []
        clock.advance(to: due)
        await manager.idle()
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
        XCTAssertEqual(manager.problem, String(localized: "No wallpapers in ~/empty"))
    }

    func testNonImageFilesAreNeverChosen() async throws {
        _ = try WallpaperFixtures.makeFolder(root, "Pictures/Wallpapers", files: ["readme.md", "clip.mov", "x.JPG"])
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop)
        XCTAssertEqual(manager.entries[0].files, ["a.jpg", "b.png", "c.heic", "d.webp", "x.JPG"])
        for _ in 0 ..< 2 * manager.entries[0].files.count {
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

    func testTheWriterOverrideFollowsOnlyTheUnchangedFileOmniWMSet() async throws {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)
        XCTAssertNotNil(manager.pin)
        XCTAssertEqual(manager.palettePixels(), manager.pin?.pixels)

        manager.settings.placement = .fit
        XCTAssertEqual(manager.palettePixels(), manager.pin?.pixels, "the placement does not change the palette")
        manager.settings.placement = .fill

        let current = try XCTUnwrap(desktop.screens[0].current)
        let refreshed = palette.refreshed
        try Data("changed".utf8).write(to: current)
        desktop.onChange?()
        XCTAssertNil(manager.palettePixels(), "a replaced file is read again by the writer")
        XCTAssertNil(manager.pin, "the pin is let go once the Store shows a different file")
        XCTAssertEqual(palette.refreshed, refreshed + 1, "and the writer is asked to follow the Store again")

        desktop.screens[0].current = URL(fileURLWithPath: "/Library/Desktop Pictures/Other.heic")
        desktop.onChange?()
        XCTAssertNil(manager.palettePixels(), "a wallpaper set elsewhere is read by the writer as before")
    }

    func testAResizedMainDisplayKeepsThePaletteOfTheSameWallpaper() async {
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
        await manager.idle()

        XCTAssertEqual(manager.pin, first)
        XCTAssertEqual(manager.palettePixels(), first?.pixels)
        XCTAssertEqual(palette.published.count, 1, "a resize neither resamples nor republishes")
        XCTAssertEqual(desktop.screens[0].current, current, "a resize never changes the wallpaper")
    }

    func testChangingThePlacementShowsTheCurrentWallpapersAgainWithIt() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)
        let current = desktop.screens[0].current
        let pixels = manager.pin?.pixels
        desktop.events = []
        manager.settings.placement = .fit
        await manager.idle()
        XCTAssertEqual(
            desktop.events.filter { $0.hasPrefix("set") },
            ["set \(WallpaperFixtures.studio.key) \(current!.lastPathComponent)"]
        )
        XCTAssertEqual(desktop.screens[0].current, current)
        XCTAssertEqual(manager.pin?.pixels, pixels)
        XCTAssertEqual(manager.palettePixels(), pixels)
    }

    func testTheSameFileGivesTheSamePaletteOnAnyDisplayAndPlacement() async throws {
        let folder = try WallpaperFixtures.makeFolder(root, "real", files: [])
        let url = folder.appendingPathComponent("dunes.png")
        try NSBitmapImageRep(cgImage: ShellBundledWidgetTests.wallpaperGradient(
            640, 360, ShellBundledWidgetTests.wallpaperPalettes[0]
        )).representation(using: .png, properties: [:])!.write(to: url)
        let expected = try XCTUnwrap(ShellWallpaperPalette.read(url).map(ShellWallpaperPalette.pixels(of:)))
        let ultrawide = WallpaperDisplay(
            displayId: 7, uuid: "77777777-7777-7777-7777-777777777777", name: "Ultrawide",
            size: CGSize(width: 5120, height: 1440), isMain: true
        )
        let laptop = WallpaperDisplay(
            displayId: 8, uuid: "88888888-8888-8888-8888-888888888888", name: "Laptop",
            size: CGSize(width: 1728, height: 1080), isMain: true, isBuiltin: true, hasNotch: true
        )
        var palettes: [[UInt32]] = []
        for (display, placement) in [(ultrawide, WallpaperPlacement.fill), (laptop, .fit), (laptop, .fill)] {
            let desktop = FakeWallpaperDesktop([display])
            let palette = FakeWallpaperPalette()
            let settings = WallpaperSettings()
            settings.enabled = true
            settings.placement = placement
            settings.setFolder(folder.path, for: display.monitor)
            let manager = WallpaperManager(
                settings: settings, desktop: desktop,
                environment: WallpaperFixtures.environment(state: WallpaperStateBox(), home: root.path)
            )
            manager.palette = palette
            manager.start(resumingRotation: false)
            await manager.set("dunes.png", on: display.monitorId)
            palettes.append(try XCTUnwrap(palette.published.last))
        }
        XCTAssertEqual(palettes, [expected, expected, expected])
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
        var manager = makeManager(desktop) { $0.rotationMinutes = self.presets[0] }
        XCTAssertEqual(manager.nextChange, later(presets[0]))
        XCTAssertEqual(state.nextChange, manager.nextChange)

        clock.now = later(presets[0]).addingTimeInterval(-WallpaperManager.minute)
        manager.stop()
        manager = makeManager(desktop) { $0.rotationMinutes = self.presets[0] }
        XCTAssertEqual(manager.nextChange, state.nextChange, "a restart keeps the planned time")

        clock.advance(to: manager.nextChange!)
        await manager.idle()
        XCTAssertEqual(desktop.events.filter { $0.hasPrefix("set") }.count, 1)
        XCTAssertEqual(manager.nextChange, later(presets[0]))

        manager.setRotation(0)
        XCTAssertNil(manager.nextChange)
        XCTAssertTrue(clock.pending.isEmpty)
        let custom = presets[0] + presets[1]
        XCTAssertFalse(presets.contains(custom))
        manager.setRotation(custom)
        XCTAssertEqual(manager.settings.rotationMinutes, custom)
        XCTAssertEqual(manager.nextChange, later(custom))
    }

    func testTurningTheFeatureOnLeavesRotationOffUntilAnIntervalIsChosen() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop)
        XCTAssertTrue(manager.running)
        XCTAssertNil(manager.nextChange)
        XCTAssertTrue(clock.pending.isEmpty)
        XCTAssertTrue(desktop.events.isEmpty, "turning it on does not change any wallpaper")
        manager.setRotation(presets[1])
        XCTAssertEqual(manager.nextChange, later(presets[1]))
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

    func testANextStillSamplingWhenManagementTurnsOffChangesNothing() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        palette.wallpaperPaletteState.active = false
        let gate = WallpaperSampleGate(holding: ["a.jpg", "b.png", "c.heic", "d.webp"])
        let manager = makeManager(desktop, palette: palette, environment: { $0.sample = { await gate.sample($0) } })
        palette.wallpaperPaletteState.active = true
        let next = Task { await manager.next(.all) }
        await gate.requested()

        manager.settings.enabled = false
        gate.release()
        await next.value

        XCTAssertTrue(desktop.events.isEmpty, "a Next overtaken by turning management off sets nothing")
        XCTAssertEqual(state.shuffle, WallpaperShuffle())
    }

    func testANextWhosePaletteIsBeingWrittenWhenManagementTurnsOffGivesThePaletteBack() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        palette.holding = true
        let manager = makeManager(desktop, palette: palette)
        let next = Task { await manager.next(.all) }
        await palette.publishing()

        manager.settings.enabled = false
        palette.release()
        await next.value

        XCTAssertFalse(desktop.events.contains { $0.hasPrefix("set") })
        XCTAssertEqual(palette.refreshed, 1, "the palette written for a wallpaper never set is made again")
        XCTAssertNil(manager.pin)
    }

    func testThePalettePinIsCheckedByTheWriterWithoutReadingTheDesktopOnTheMainThread() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)
        XCTAssertNotNil(manager.pin)
        let reads = desktop.reads
        let pin = manager.palettePin()
        XCTAssertEqual(pin?.file, manager.pin?.key.file, "the writer compares the file it finds with this stamp")
        XCTAssertEqual(desktop.reads, reads)
    }

    func testAFailedWallpaperOnTheMainDisplayGivesThePaletteBackToTheWallpaperShown() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        desktop.failing = [WallpaperFixtures.studio.key]
        let palette = FakeWallpaperPalette()
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)

        XCTAssertEqual(palette.published.count, 1)
        XCTAssertEqual(palette.refreshed, 1, "the palette follows the wallpaper the display still shows")
        XCTAssertNil(manager.pin)
        XCTAssertNotNil(manager.problem)
    }

    func testAPaletteThatCannotBeWrittenIsNotKeptForTheNewWallpaper() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        palette.accepts = false
        let manager = makeManager(desktop, palette: palette)
        await manager.next(.all)

        XCTAssertNil(manager.pin, "the palette writer reads the new wallpaper itself")
        XCTAssertEqual(desktop.events.filter { $0.hasPrefix("set") }.count, 1)
    }

    func testADisplayWhoseWallpaperFailsKeepsItsShufflePosition() async {
        let desktop = FakeWallpaperDesktop([
            WallpaperFixtures.studio,
            WallpaperFixtures.secondary(WallpaperFixtures.macBook)
        ])
        desktop.failing = [WallpaperFixtures.macBook.key]
        let manager = makeManager(desktop)
        await manager.next(.all)

        XCTAssertNotNil(state.shuffle.displays[WallpaperFixtures.studio.key])
        XCTAssertNil(
            state.shuffle.displays[WallpaperFixtures.macBook.key],
            "a wallpaper that was never shown is still the next one for that display"
        )
    }

    func testARotationDueWhileOmniWMWasQuitRunsAtStartup() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let overdue = clock.now.addingTimeInterval(-WallpaperManager.minute)
        state.nextChange = overdue
        let manager = makeManager(desktop) { $0.rotationMinutes = self.presets[0] }
        XCTAssertEqual(manager.nextChange, clock.now, "quitting does not postpone the rotation")

        clock.advance(to: clock.now)
        await manager.idle()
        XCTAssertEqual(desktop.events.filter { $0.hasPrefix("set") }.count, 1)
        XCTAssertEqual(manager.nextChange, later(presets[0]))
    }

    func testTurningManagementOnAgainDoesNotRunAChangePlannedBeforeItWasOff() throws {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop) { $0.rotationMinutes = self.presets[0] }
        let planned = try XCTUnwrap(state.nextChange)
        manager.settings.enabled = false
        let saves = box.saves
        clock.now = later(presets[2])
        manager.settings.enabled = true
        XCTAssertEqual(box.saves, saves + 1)
        XCTAssertNotEqual(manager.nextChange, planned, "turning it on again does not change the wallpaper at once")
        XCTAssertEqual(manager.nextChange, later(presets[0]))
        XCTAssertTrue(desktop.events.isEmpty)
    }

    func testAnOlderMainSampleNeverReplacesTheSchemePreviewOfANewerWallpaper() async {
        var display = WallpaperFixtures.studio
        display.current = root.appendingPathComponent("Pictures/Wallpapers/a.jpg")
        let desktop = FakeWallpaperDesktop([display])
        let palette = FakeWallpaperPalette()
        palette.wallpaperPaletteState.active = false
        let gate = WallpaperSampleGate(holding: ["a.jpg"])
        let manager = makeManager(desktop, palette: palette, environment: { $0.sample = { await gate.sample($0) } })
        palette.wallpaperPaletteState.active = true
        manager.showSwatches(true, for: .widget)
        await gate.requested("a.jpg")

        await manager.set("b.png", on: WallpaperFixtures.studio.monitorId)
        gate.release("a.jpg")
        await manager.idle()
        XCTAssertEqual(manager.paletteSample, WallpaperSampleGate.pixels("b.png"))

        desktop.screens[0].current = root.appendingPathComponent("Pictures/Wallpapers/c.heic")
        desktop.onChange?()
        await manager.idle()
        XCTAssertEqual(
            manager.paletteSample,
            WallpaperSampleGate.pixels("c.heic"),
            "a wallpaper chosen elsewhere updates the scheme previews"
        )
    }

    func testDisplaysSharingAFolderScanItOncePerRescan() {
        let desktop = FakeWallpaperDesktop([
            WallpaperFixtures.studio,
            WallpaperFixtures.secondary(WallpaperFixtures.macBook)
        ])
        let scans = WallpaperCounter()
        let manager = makeManager(desktop, environment: { environment in
            environment.files = { folder in
                scans.add(folder.lastPathComponent)
                return try WallpaperLibrary.files(in: folder)
            }
        })
        XCTAssertEqual(scans.values, ["Wallpapers"])
        manager.refresh(rescan: true)
        XCTAssertEqual(scans.values, ["Wallpapers", "Wallpapers"])
    }

    func testTheShellDataPagesThroughAFolderLargerThanAnyOnePage() async throws {
        let names = (0 ... 2 * WallpaperPreviews.pageLimit).map { String(format: "w%04d.jpg", $0) }
        let big = try WallpaperFixtures.makeFolder(root, "big", files: names)
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop) { $0.setFolder(big.path, for: WallpaperFixtures.studio.monitor) }
        let last = names.count - names.count % WallpaperPreviews.defaultWindow
        manager.perform(
            .page(display: WallpaperFixtures.studio.monitorId, offset: last, count: WallpaperPreviews.defaultWindow),
            chooseFolder: { _ in nil }
        )
        let shown = try XCTUnwrap(manager.shellValue().displays.first)
        XCTAssertEqual(shown.count, names.count)
        XCTAssertEqual(shown.offset, last)
        XCTAssertEqual(shown.items, Array(names[last...]), "the last wallpapers can be reached")
    }

    func testChangingTheFolderResetsThePageAndMakesItsPreviews() async throws {
        let count = WallpaperPreviews.pageLimit + WallpaperPreviews.defaultWindow
        let many = try WallpaperFixtures.makeFolder(root, "many", files: (0 ..< count).map { "m\($0).jpg" })
        let few = try WallpaperFixtures.makeFolder(root, "few", files: ["f1.jpg", "f2.jpg", "f3.jpg", "f4.jpg"])
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let image = WallpaperManagerTests.image
        let manager = makeManager(
            desktop,
            configure: { $0.setFolder(many.path, for: WallpaperFixtures.studio.monitor) },
            environment: { $0.preview = { _ in image } }
        )
        let id = WallpaperFixtures.studio.monitorId
        let page = WallpaperPreviews.pageLimit
        manager.perform(
            .page(display: id, offset: page, count: WallpaperPreviews.defaultWindow), chooseFolder: { _ in nil }
        )
        XCTAssertEqual(manager.shellValue().displays.first?.offset, page)

        manager.showPreviews(true)
        manager.setFolder(few, for: id)
        await manager.previews.settle()
        let shown = try XCTUnwrap(manager.shellValue().displays.first)
        XCTAssertEqual(shown.offset, 0, "a page beyond the new folder starts over")
        XCTAssertEqual(shown.items, ["f1.jpg", "f2.jpg", "f3.jpg", "f4.jpg"])
        XCTAssertEqual(manager.previews.count, 4, "the new folder's wallpapers get their previews")
    }

    private nonisolated static let image: CGImage = {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()

    func testAnOlderOutsideSampleNeverReplacesANewerOneInTheSchemePreviews() async {
        var display = WallpaperFixtures.studio
        display.current = root.appendingPathComponent("Pictures/Wallpapers/a.jpg")
        let desktop = FakeWallpaperDesktop([display])
        let gate = WallpaperSampleGate(holding: ["a.jpg", "b.png"])
        let manager = makeManager(desktop, environment: { $0.sample = { await gate.sample($0) } })
        manager.showSwatches(true, for: .widget)
        await gate.requested("a.jpg")

        desktop.screens[0].current = root.appendingPathComponent("Pictures/Wallpapers/b.png")
        desktop.onChange?()
        await gate.requested("b.png")
        gate.release("b.png")
        await gate.finished("b.png")
        XCTAssertEqual(manager.paletteSample, WallpaperSampleGate.pixels("b.png"))
        gate.release("a.jpg")
        await gate.finished("a.jpg")
        XCTAssertEqual(
            manager.paletteSample, WallpaperSampleGate.pixels("b.png"),
            "the slow sample of the wallpaper shown before does not replace the newer one"
        )
    }
}
