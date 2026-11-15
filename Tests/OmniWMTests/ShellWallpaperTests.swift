// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import OmniWMMaterialColor
import XCTest

@MainActor
final class ShellWallpaperTests: XCTestCase {
    func testWallpaperActionsParseFromWidgetCommands() {
        let name = "été 2.jpg"
        let cases: [(String, ShellWallpaperCommand?)] = [
            ("wallpaper next", .next(.all)),
            ("wallpaper next all", .next(.all)),
            ("wallpaper next display:3", .next(.display("display:3"))),
            ("wallpaper set display:3 \(WallpaperLibrary.token(for: name))", .set(display: "display:3", name: name)),
            ("wallpaper page display:3 12 12", .page(display: "display:3", offset: 12, count: 12)),
            ("wallpaper rotation off", .rotation(minutes: 0)),
            ("wallpaper rotation 45", .rotation(minutes: 45)),
            ("wallpaper open display:3", .reveal(display: "display:3")),
            ("wallpaper folder display:3", .chooseFolder(display: "display:3")),
            ("wallpaper folder display:3 reset", .resetFolder(display: "display:3")),
            ("wallpaper scheme fruitSalad", .scheme(.fruitSalad)),
            ("wallpaper settings", .settings),
            ("wallpaper next screen", nil),
            ("wallpaper rotation 99999", nil),
            ("wallpaper rotation -5", nil),
            ("wallpaper set display:3 \(WallpaperLibrary.token(for: "notes.txt"))", nil),
            ("wallpaper set display:3 \(WallpaperLibrary.token(for: "../x.jpg"))", nil),
            ("wallpaper page display:3 0 500", nil),
            ("wallpaper scheme matugen", nil)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ShellAction(text), expected.map(ShellAction.wallpaper), text)
        }
    }

    func testTheDataFeedStaysWithinItsBudgetWhateverTheFileNames() {
        let long = String(repeating: "é", count: ShellWallpaper.nameBudget / WallpaperPreviews.pageLimit)
        let names = (0 ..< WallpaperPreviews.pageLimit).map { "wall \"\($0)\" \\ \(long).jpg" }
        let listed = ShellWallpaper.items(names[...])
        XCTAssertTrue(listed.truncated)
        var writer = ShellValueWriter()
        for item in listed.items {
            writer.string(item)
        }
        XCTAssertLessThanOrEqual(writer.bytes.count, ShellWallpaper.nameBudget)
        XCTAssertFalse(listed.items.isEmpty)
        let few = ShellWallpaper.items(["a.jpg", "b.jpg"])
        XCTAssertFalse(few.truncated)
        XCTAssertEqual(few.items, ["a.jpg", "b.jpg"])
    }

    func testSwatchesCoverEverySchemeInBothAppearances() {
        let pixels = [UInt32](repeating: 0xFF22_66CC, count: 64) + [UInt32](repeating: 0xFFEE_8844, count: 64)
        let swatches = ShellWallpaperPalette.swatches(pixels: pixels)
        XCTAssertEqual(swatches.map(\.scheme), ShellWallpaperScheme.allCases.map(\.rawValue))
        XCTAssertTrue(swatches.allSatisfy { $0.light.count == 4 && $0.dark.count == 4 })
        XCTAssertNotEqual(
            swatches.first { $0.scheme == "tonalSpot" }?.dark,
            swatches.first { $0.scheme == "monochrome" }?.dark
        )
        let tonal = ShellMaterialPalette.colors(
            seed: pixels.withUnsafeBufferPointer { omni_material_seed($0.baseAddress, $0.count, 0) },
            variant: ShellWallpaperScheme.tonalSpot.variant, dark: true
        )
        XCTAssertEqual(swatches[0].dark[0], "#" + String(format: "%06X", tonal[.accent] ?? 0))
    }

    func testTheWriterUsesThePublishedWallpaperInsteadOfAMidFadeCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("themes/wallpaper.toml")
        let filePixels = [UInt32](repeating: 0xFF20_40E0, count: 256)
        let capture = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        capture.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        capture.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let staleImage = try XCTUnwrap(capture.makeImage())
        let pinned = PinnedPixels(filePixels)
        let managedURL = root.appendingPathComponent("managed.png")
        let writer = ShellWallpaperPaletteWriter(
            destination: destination, scheme: .tonalSpot,
            source: {
                let showsManaged = pinned.value != nil
                return {
                    showsManaged ? .still(ShellWallpaperPalette.StillWallpaper(
                        url: managedURL, size: 1, modified: Date(timeIntervalSince1970: 1)
                    ), aerial: false) : .capture(aerial: false)
                }
            },
            read: { _ in nil }, image: { _ in staleImage },
            override: {
                pinned.value.map {
                    ShellWallpaperPaletteOverride(
                        file: WallpaperFileStamp(path: managedURL.path, modified: 1, bytes: 1), pixels: $0
                    )
                }
            },
            perform: { $0() }, deliver: { MainActor.assumeIsolated($0) }
        ) { _ in }
        writer.refresh()
        let expected = ShellWallpaperPalette.theme(pixels: filePixels, scheme: .tonalSpot)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), expected)

        pinned.value = nil
        writer.refresh()
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            ShellWallpaperPalette.theme(pixels: ShellWallpaperPalette.pixels(of: staleImage), scheme: .tonalSpot),
            "without a published wallpaper the writer reads the screen as before"
        )
    }

    func testPublishingWritesOnTheWriterQueueAndReportsWhetherTheFileChanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("themes/wallpaper.toml")
        let pixels: [UInt32] = [0xFF11_2233]
        let first = try await ShellWallpaperPaletteWriter.publish(pixels, scheme: .vibrant, to: destination)
        XCTAssertTrue(first)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            ShellWallpaperPalette.theme(pixels: pixels, scheme: .vibrant)
        )
        let again = try await ShellWallpaperPaletteWriter.publish(pixels, scheme: .vibrant, to: destination)
        XCTAssertFalse(again)
    }

    private func feedManager(_ root: URL, preview: @escaping @Sendable (WallpaperPreviewKey) async -> CGImage?)
        -> WallpaperManager
    {
        var display = WallpaperFixtures.studio
        display.current = root.appendingPathComponent("Pictures/Wallpapers/a.jpg")
        let desktop = FakeWallpaperDesktop([display])
        let settings = WallpaperSettings()
        settings.enabled = true
        var environment = WallpaperFixtures.environment(state: WallpaperStateBox(), home: root.path)
        environment.sample = { _ in [0xFF33_6699] }
        environment.preview = preview
        let manager = WallpaperManager(settings: settings, desktop: desktop, environment: environment)
        manager.start(resumingRotation: false)
        return manager
    }

    func testTheFeedPublishesOnlyWhileAWidgetReadsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try WallpaperFixtures.makeFolder(root, "Pictures/Wallpapers", files: ["a.jpg"])
        let manager = feedManager(root) { _ in nil }
        let feed = ShellDataFeed { _ in }
        feed.setWallpaper(manager)
        feed.start()
        XCTAssertNil(feed.current.wallpaper)
        feed.setDemand(ShellDataKey.wallpaper.bit, cadence: .init())
        XCTAssertEqual(feed.current.wallpaper?.enabled, true)
        XCTAssertEqual(feed.current.wallpaper?.displays.map(\.id), [WallpaperFixtures.studio.monitorId])
        let minutes = SettingsExport.Wallpaper.rotationPresets[0]
        manager.setRotation(minutes)
        XCTAssertEqual(feed.current.wallpaper?.rotation, minutes)
        feed.setDemand(0, cadence: .init())
        XCTAssertNil(feed.current.wallpaper)
        feed.stop()
    }

    func testPreviewsAreMadeOnlyForAWidgetThatReadsThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try WallpaperFixtures.makeFolder(root, "Pictures/Wallpapers", files: ["a.jpg", "b.jpg"])
        let rendered = RenderedKeys()
        let manager = feedManager(root) { key in
            await rendered.add(key)
            return Self.image
        }
        let feed = ShellDataFeed { _ in }
        feed.setWallpaper(manager)
        feed.start()
        defer { feed.stop() }
        feed.setDemand(ShellDataKey.wallpaper.bit, cadence: .init())
        await manager.previews.settle()
        XCTAssertFalse(manager.previews.demanded, "a widget that shows names never makes previews")
        XCTAssertEqual(manager.previews.count, 0)
        XCTAssertNil(feed.current.wallpaperPreviews)
        let none = await rendered.keys
        XCTAssertTrue(none.isEmpty)

        feed.setDemand(ShellDataKey.wallpaper.bit | ShellDataKey.wallpaperPreviews.bit, cadence: .init())
        await manager.previews.settle()
        XCTAssertTrue(manager.previews.demanded)
        let shown = try XCTUnwrap(feed.current.wallpaperPreviews?.displays[WallpaperFixtures.studio.monitorId])
        XCTAssertNotNil(shown.card)
        XCTAssertEqual(Set(shown.items.keys), ["a.jpg", "b.jpg"])

        feed.setDemand(ShellDataKey.wallpaper.bit, cadence: .init())
        XCTAssertFalse(manager.previews.demanded)
        XCTAssertEqual(manager.previews.count, 0, "closing the picker drops its previews")
    }

    func testPreviewsFollowTheDisplayShapePlacementAndFolderAndStayBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 2 * WallpaperPreviews.pageLimit + 1
        let folder = try WallpaperFixtures.makeFolder(root, "w", files: (0 ..< count).map { "w\($0).jpg" })
        let rendered = RenderedKeys()
        let previews = WallpaperPreviews { key in
            await rendered.add(key)
            return Self.image
        }
        var display = WallpaperFixtures.studio
        display.current = folder.appendingPathComponent("w0.jpg")
        var entry = try WallpaperManager.Entry(
            display: display, folder: folder, custom: false, files: WallpaperLibrary.files(in: folder)
        )
        var stamps: [String: WallpaperFileStamp] = [:]
        for name in entry.files {
            let url = folder.appendingPathComponent(name)
            stamps[url.standardizedFileURL.path] = WallpaperFileStamp(url)
        }
        previews.retain(entries: [entry], stamps: stamps, placement: .fill)
        XCTAssertEqual(previews.count, 0, "nothing is made until a widget reads the feed")
        previews.demanded = true
        previews.retain(entries: [entry], stamps: stamps, placement: .fill)
        await previews.settle()
        XCTAssertEqual(previews.count, 1 + WallpaperPreviews.defaultWindow)
        let first = try XCTUnwrap(previews.ready(
            display.current!,
            width: WallpaperPreviews.cardWidth,
            display: display,
            placement: .fill
        ))

        previews.retain(entries: [entry], stamps: stamps, placement: .fit)
        XCTAssertNil(previews.ready(
            display.current!,
            width: WallpaperPreviews.cardWidth,
            display: display,
            placement: .fill
        ))
        await previews.settle()
        XCTAssertEqual(previews.count, 1 + WallpaperPreviews.defaultWindow)
        XCTAssertNotEqual(
            previews.ready(display.current!, width: WallpaperPreviews.cardWidth, display: display, placement: .fit),
            first
        )

        entry.display = WallpaperDisplay(
            displayId: 2, uuid: display.uuid, name: display.name, size: CGSize(width: 1440, height: 2560), isMain: true,
            current: display.current
        )
        previews.retain(entries: [entry], stamps: stamps, placement: .fit)
        XCTAssertEqual(previews.count, 0, "a new display shape drops the old previews")

        for offset in stride(from: 0, to: entry.files.count, by: WallpaperPreviews.pageLimit) {
            previews.setWindow(.init(offset: offset, count: WallpaperPreviews.pageLimit), for: entry)
            previews.retain(entries: [entry], stamps: stamps, placement: .fit)
            await previews.settle()
            XCTAssertEqual(previews.count, 1 + min(WallpaperPreviews.pageLimit, entry.files.count - offset))
            XCTAssertLessThanOrEqual(previews.count, 1 + WallpaperPreviews.pageLimit, "one card and one page")
        }
        entry.files = []
        entry.display.current = nil
        previews.retain(entries: [entry], stamps: stamps, placement: .fit)
        XCTAssertEqual(previews.count, 0, "a folder change drops previews of wallpapers no longer shown")
        previews.demanded = false
        XCTAssertEqual(previews.count, 0)
    }

    func testEveryPreviewOnThreeFullPagesStaysReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = WallpaperPreviews { _ in Self.image }
        previews.demanded = true
        let displays = [
            WallpaperFixtures.macBook,
            WallpaperFixtures.secondary(WallpaperFixtures.studio),
            WallpaperFixtures.twinRight
        ]
        var entries: [WallpaperManager.Entry] = []
        var stamps: [String: WallpaperFileStamp] = [:]
        for (index, screen) in displays.enumerated() {
            let names = (0 ..< WallpaperPreviews.pageLimit).map { "w\(index)-\($0).jpg" }
            let folder = try WallpaperFixtures.makeFolder(root, "w\(index)", files: names)
            var display = screen
            display.current = folder.appendingPathComponent(names[0])
            let entry = WallpaperManager.Entry(display: display, folder: folder, custom: false, files: names)
            for name in names {
                let url = folder.appendingPathComponent(name)
                stamps[url.standardizedFileURL.path] = WallpaperFileStamp(url)
            }
            previews.setWindow(.init(offset: 0, count: WallpaperPreviews.pageLimit), for: entry)
            entries.append(entry)
        }
        previews.retain(entries: entries, stamps: stamps, placement: .fill)
        await previews.settle()

        XCTAssertEqual(previews.count, displays.count * (1 + WallpaperPreviews.pageLimit))
        for entry in entries {
            let current = try XCTUnwrap(entry.display.current)
            XCTAssertNotNil(previews.ready(
                current, width: WallpaperPreviews.cardWidth, display: entry.display, placement: .fill
            ))
            for name in entry.files {
                XCTAssertNotNil(
                    previews.ready(
                        entry.folder.appendingPathComponent(name), width: WallpaperPreviews.gridWidth,
                        display: entry.display, placement: .fill
                    ),
                    "\(name) is on screen, so its preview stays"
                )
            }
        }
    }

    private nonisolated static let image: CGImage = {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()

    @MainActor
    private final class PinnedPixels {
        var value: [UInt32]?
        init(_ value: [UInt32]?) {
            self.value = value
        }
    }

    private actor RenderedKeys {
        var keys: [WallpaperPreviewKey] = []
        func add(_ key: WallpaperPreviewKey) {
            keys.append(key)
        }
    }

    func testAReadyPreviewIsFoundWithoutLookingAtTheFileAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try WallpaperFixtures.makeFolder(root, "w", files: ["a.jpg", "b.jpg"])
        let previews = WallpaperPreviews { _ in Self.image }
        let entry = WallpaperManager.Entry(
            display: WallpaperFixtures.studio, folder: folder, custom: false, files: ["a.jpg", "b.jpg"]
        )
        var stamps: [String: WallpaperFileStamp] = [:]
        for name in entry.files {
            let url = folder.appendingPathComponent(name)
            stamps[url.standardizedFileURL.path] = WallpaperFileStamp(url)
        }
        previews.demanded = true
        previews.retain(entries: [entry], stamps: stamps, placement: .fill)
        await previews.settle()
        let file = folder.appendingPathComponent("a.jpg")
        func ready() -> String? {
            previews.ready(
                file, width: WallpaperPreviews.gridWidth, display: WallpaperFixtures.studio, placement: .fill
            )
        }
        let id = try XCTUnwrap(ready())
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(ready(), id, "publishing the shell data does not stat every listed wallpaper")
    }

    func testAPublishedPaletteIsRecordedSoTheRecheckLeavesItAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("themes/wallpaper.toml")
        let managed = WallpaperFileStamp(path: root.appendingPathComponent("managed.png").path, modified: 1, bytes: 1)
        let pixels: [UInt32] = [0xFF20_40E0]
        let writer = ShellWallpaperPaletteWriter(
            destination: destination, scheme: .tonalSpot,
            source: {
                { .still(ShellWallpaperPalette.StillWallpaper(
                    url: URL(fileURLWithPath: managed.path), size: managed.bytes,
                    modified: Date(timeIntervalSince1970: managed.modified)
                ), aerial: false) }
            },
            read: { _ in nil }, image: { _ in nil },
            override: { ShellWallpaperPaletteOverride(file: managed, pixels: pixels) },
            perform: { $0() }, deliver: { MainActor.assumeIsolated($0) }
        ) { _ in }
        _ = try await writer.publish(pixels, scheme: .tonalSpot)
        let edited = "edited by hand"
        try Data(edited.utf8).write(to: destination)
        writer.refreshIfChanged()
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8), edited,
            "the recheck knows the palette it published and does not write it again"
        )
    }

    func testAnEventBeforeTheStoreShowsThePublishedWallpaperKeepsItsColorsAndTheRecheckFollowsTheStore()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("themes/wallpaper.toml")
        let shown = ShellWallpaperPalette.StillWallpaper(
            url: root.appendingPathComponent("old.png"), size: 1, modified: Date(timeIntervalSince1970: 1)
        )
        let newPixels: [UInt32] = [0xFFE0_4020]
        let stale = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let followsStore = ShellWallpaperPalette.theme(
            pixels: ShellWallpaperPalette.pixels(of: stale),
            scheme: .tonalSpot
        )
        let pin = PinnedOverride(nil)
        let writer = ShellWallpaperPaletteWriter(
            destination: destination, scheme: .tonalSpot,
            source: { { .still(shown, aerial: false) } },
            read: { _ in stale }, image: { _ in nil },
            override: { pin.value },
            perform: { $0() }, deliver: { MainActor.assumeIsolated($0) }
        ) { _ in }
        writer.refresh()
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), followsStore)

        pin.value = ShellWallpaperPaletteOverride(
            file: WallpaperFileStamp(
                path: root.appendingPathComponent("new.png").path, modified: shown.modified.timeIntervalSince1970,
                bytes: shown.size
            ),
            pixels: newPixels
        )
        _ = try await writer.publish(newPixels, scheme: .tonalSpot)
        let published = ShellWallpaperPalette.theme(pixels: newPixels, scheme: .tonalSpot)
        writer.refresh()
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8), published,
            "a Space or Store event before the Store shows the new wallpaper keeps the colors made for it"
        )
        writer.refreshIfChanged()
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8), followsStore,
            "the recheck bounds the hold and follows what the Store shows"
        )
    }

    @MainActor
    private final class PinnedOverride {
        var value: ShellWallpaperPaletteOverride?
        init(_ value: ShellWallpaperPaletteOverride?) {
            self.value = value
        }
    }
}
