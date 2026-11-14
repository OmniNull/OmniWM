// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WallpaperPassTests: XCTestCase {
    private var root: URL!
    private var box = WallpaperStateBox()
    private let worker = WallpaperHeldWork()
    private let hops = WallpaperHeldHops()
    private let scans = WallpaperCounter()
    private let stamps = WallpaperCounter()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-pass-\(UUID().uuidString)")
        _ = try WallpaperFixtures.makeFolder(root, "Pictures/Wallpapers", files: ["a.jpg", "b.png", "c.heic"])
        box = WallpaperStateBox()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String) -> URL {
        root.appendingPathComponent("Pictures/Wallpapers").appendingPathComponent(name)
    }

    private func makeManager(
        _ desktop: FakeWallpaperDesktop,
        held: Bool,
        holdsDelivery: Bool = true,
        palette: FakeWallpaperPalette? = nil,
        change: (inout WallpaperEnvironment) -> Void = { _ in }
    ) -> WallpaperManager {
        let settings = WallpaperSettings()
        settings.enabled = true
        var environment = WallpaperFixtures.environment(state: box, home: root.path)
        let (scans, stamps) = (scans, stamps)
        environment.files = { folder in
            scans.add(folder.lastPathComponent)
            return try WallpaperLibrary.files(in: folder)
        }
        environment.stamp = { url in
            stamps.add(url.lastPathComponent)
            return WallpaperFileStamp(url)
        }
        environment.sample = { key in [UInt32(truncatingIfNeeded: key.file.path.utf8.count)] }
        if held {
            environment.perform = worker.perform
            if holdsDelivery { environment.deliver = hops.deliver }
        }
        change(&environment)
        let manager = WallpaperManager(settings: settings, desktop: desktop, environment: environment)
        settings.onChange = { [weak manager] in manager?.settingsDidChange() }
        manager.palette = palette
        manager.start(resumingRotation: false)
        return manager
    }

    private func land() {
        while worker.count > 0 || hops.count > 0 {
            worker.release()
            hops.release()
        }
    }

    func testTheStoreFoldersAndFilesAreReadOnTheWorkerNotOnTheMainThread() {
        var display = WallpaperFixtures.studio
        display.current = file("a.jpg")
        let desktop = FakeWallpaperDesktop([display])
        let manager = makeManager(desktop, held: true)
        XCTAssertEqual(desktop.reads, 0, "starting reads nothing until the worker runs")
        XCTAssertEqual(scans.values, [])
        XCTAssertEqual(stamps.values, [])
        XCTAssertTrue(manager.entries.isEmpty)

        worker.release()
        XCTAssertEqual(desktop.reads, 1)
        XCTAssertEqual(scans.values, ["Wallpapers"])
        XCTAssertEqual(stamps.values, ["a.jpg"])
        XCTAssertTrue(manager.entries.isEmpty, "nothing is shown before the main thread takes the snapshot")
        hops.release()
        XCTAssertEqual(manager.entries.first?.currentName, "a.jpg")
    }

    func testAnOlderSnapshotHeldOnTheWorkerNeverReplacesANewerOne() {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: true)
        land()

        desktop.screens[0].current = file("a.jpg")
        desktop.onChange?()
        desktop.screens[0].current = file("b.png")
        desktop.onChange?()
        worker.release()
        XCTAssertEqual(hops.count, 2)
        hops.releaseNewest()
        XCTAssertEqual(manager.entries.first?.currentName, "b.png")
        hops.release()
        XCTAssertEqual(
            manager.entries.first?.currentName, "b.png", "a snapshot taken before a newer one is dropped"
        )
    }

    func testASnapshotDeliveredAfterManagementTurnsOffChangesNothing() {
        var display = WallpaperFixtures.studio
        display.current = file("a.jpg")
        let desktop = FakeWallpaperDesktop([display])
        let manager = makeManager(desktop, held: true)
        var changes = 0
        manager.onChange = { changes += 1 }
        worker.release()

        manager.settings.enabled = false
        let afterStop = changes
        hops.release()
        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertTrue(manager.lists.isEmpty)
        XCTAssertEqual(changes, afterStop, "nothing lands once management is off")
        XCTAssertNil(desktop.onChange)
    }

    func testDesktopEventsReuseTheFolderListAndOnlyActionsReadItAgain() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: false)
        XCTAssertEqual(scans.values.count, 1)

        desktop.onChange?()
        desktop.plug(WallpaperFixtures.secondary(WallpaperFixtures.macBook))
        XCTAssertEqual(manager.entries.count, 2)
        XCTAssertEqual(scans.values.count, 1, "a Space switch, a Store change or a new display does not rescan")

        await manager.next(.all)
        XCTAssertEqual(scans.values.count, 2, "Next reads the folder again")
    }

    func testAPageAsksTheWorkerForItsFileStampsAndPreviewsNeverStatOnTheMainThread() {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: true)
        land()
        XCTAssertEqual(stamps.values, [])

        manager.showPreviews(true)
        XCTAssertEqual(stamps.values, [], "showing previews stats nothing on the main thread")
        land()
        XCTAssertEqual(Set(stamps.values), ["a.jpg", "b.png", "c.heic"])
    }

    func testAFolderThatCannotBeReadIsReportedInsteadOfShownAsEmpty() async throws {
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a folder".utf8).write(to: blocked)
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: false)
        manager.settings.folder = blocked.path
        let entry = try XCTUnwrap(manager.entries.first)
        XCTAssertNotNil(entry.failure)
        let shown = try XCTUnwrap(manager.shellValue().displays.first)
        XCTAssertEqual(shown.problem, manager.folderProblem(entry))
        XCTAssertNotEqual(shown.problem, String(localized: "No wallpapers in ~/blocked"))

        await manager.next(.all)
        XCTAssertEqual(manager.problem, manager.folderProblem(entry))
        XCTAssertTrue(desktop.events.isEmpty)
    }

    func testEveryDisplayThatFailsIsReported() async {
        let desktop = FakeWallpaperDesktop([
            WallpaperFixtures.studio,
            WallpaperFixtures.secondary(WallpaperFixtures.macBook)
        ])
        desktop.failing = [WallpaperFixtures.studio.key, WallpaperFixtures.macBook.key]
        let manager = makeManager(desktop, held: false)
        await manager.next(.all)
        let problem = manager.problem ?? ""
        XCTAssertTrue(problem.contains(WallpaperFixtures.studio.name), problem)
        XCTAssertTrue(problem.contains(WallpaperFixtures.macBook.name), problem)
    }

    func testAShuffleThatCannotBeSavedIsShownUntilASaveWorks() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: false)
        box.failing = true
        await manager.next(.all)
        let problem = manager.problem ?? ""
        XCTAssertTrue(problem.contains(WallpaperStateBox.Failure().localizedDescription), problem)
        XCTAssertEqual(desktop.events.count, 1, "the wallpaper itself still changed")

        box.failing = false
        await manager.next(.all)
        XCTAssertNil(manager.problem)
        XCTAssertNotNil(box.state.shuffle.displays[WallpaperFixtures.studio.key])
    }

    func testAPaletteThatFailsToWriteIsReported() async {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        palette.fails = true
        let manager = makeManager(desktop, held: false, palette: palette)
        await manager.next(.all)
        let problem = manager.problem ?? ""
        XCTAssertTrue(problem.contains(FakeWallpaperPalette.Refused().localizedDescription), problem)
        XCTAssertNil(manager.pin)
        XCTAssertEqual(desktop.events.filter { $0.hasPrefix("set") }.count, 1)
    }

    func testSchemeSwatchesAreMadeOnTheWorker() {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: true)
        land()
        manager.paletteSample = [0xFF22_66CC]
        manager.showSwatches(true, for: .settings)
        XCTAssertTrue(manager.paletteSwatches.isEmpty, "no swatch is computed on the main thread")
        land()
        XCTAssertEqual(manager.paletteSwatches, ShellWallpaperPalette.swatches(pixels: [0xFF22_66CC]))
    }

    func testAStoppedManagerNeitherSamplesNorLooksAtTheDesktop() async {
        var display = WallpaperFixtures.studio
        display.current = file("a.jpg")
        let desktop = FakeWallpaperDesktop([display])
        let gate = WallpaperSampleGate()
        let manager = makeManager(desktop, held: false) { $0.sample = { await gate.sample($0) } }
        manager.settings.enabled = false
        let reads = desktop.reads
        manager.showSwatches(true, for: .widget)
        manager.refresh(rescan: true)
        manager.setRotation(SettingsExport.Wallpaper.rotationPresets[0])
        await manager.idle()
        XCTAssertEqual(desktop.reads, reads)
        XCTAssertEqual(gate.requests, [])
        XCTAssertEqual(manager.settings.rotationMinutes, 0, "a rotation command does not write settings while off")
    }

    func testTheWriterAlreadyHoldsTheNewPinWhileThePaletteIsBeingWritten() async throws {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let palette = FakeWallpaperPalette()
        palette.holding = true
        let manager = makeManager(desktop, held: false, palette: palette)
        let next = Task { await manager.set("b.png", on: WallpaperFixtures.studio.monitorId) }
        await palette.publishing()
        XCTAssertEqual(
            manager.palettePin()?.file, WallpaperFileStamp(file("b.png")),
            "a recheck that starts while the palette is written already compares against the new wallpaper"
        )
        palette.release()
        await next.value
        XCTAssertEqual(manager.palettePin()?.file, WallpaperFileStamp(file("b.png")))
    }

    func testAPickKeepsItsFolderRescanWhenADesktopEventOvertakesIt() async throws {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: true, holdsDelivery: false)
        worker.release()
        try Data("d".utf8).write(to: file("d.jpg"))
        let pick = Task { await manager.set("d.jpg", on: WallpaperFixtures.studio.monitorId) }
        await worker.queued()
        desktop.onChange?()
        worker.release()
        await pick.value
        XCTAssertEqual(
            desktop.screens[0].current?.lastPathComponent, "d.jpg",
            "a Space switch during a pick does not hand the pick the folder list from before"
        )
        XCTAssertNil(manager.problem)
    }

    func testThePinStaysWhileTheStoreStillShowsTheWallpaperFromBeforeTheChange() async throws {
        var display = WallpaperFixtures.studio
        display.current = file("a.jpg")
        let desktop = FakeWallpaperDesktop([display])
        let palette = FakeWallpaperPalette()
        palette.holding = true
        let manager = makeManager(desktop, held: false, palette: palette)
        let pick = Task { await manager.set("b.png", on: WallpaperFixtures.studio.monitorId) }
        await palette.publishing()
        desktop.onChange?()
        XCTAssertEqual(
            manager.palettePin()?.file, WallpaperFileStamp(file("b.png")),
            "a Store event before the new wallpaper shows keeps the pin, so the writer keeps the new colors"
        )
        XCTAssertEqual(palette.refreshed, 0)
        palette.release()
        await pick.value
        desktop.onChange?()
        XCTAssertEqual(manager.palettePin()?.file, WallpaperFileStamp(file("b.png")))

        desktop.screens[0].current = file("c.heic")
        desktop.onChange?()
        XCTAssertNil(manager.pin, "a wallpaper chosen elsewhere afterwards lets the writer follow the Store")
        XCTAssertEqual(palette.refreshed, 1)
    }

    func testOpeningThePickerLooksAtTheDesktopOnce() {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: false)
        let source = WallpaperFeedSource(manager: manager)
        let reads = desktop.reads
        source.listen(data: true, previews: true)
        XCTAssertEqual(desktop.reads, reads + 1, "starting to show names and previews is one pass, not two")
        XCTAssertTrue(manager.previews.demanded)
        source.listen(data: false, previews: false)
    }

    func testQuittingWaitsForTheRotationStateToBeWritten() {
        let drains = WallpaperCounter()
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let manager = makeManager(desktop, held: false) { environment in
            environment.drain = { drains.add("drain") }
        }
        manager.flushState()
        XCTAssertEqual(drains.values, ["drain"])
    }
}
