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
        let names = (0 ..< 5000).map { "wall \"\($0)\" \\ \(String(repeating: "é", count: 20)).jpg" }
        let listed = ShellWallpaper.items(names) { _ in "wallpaper/abc" }
        XCTAssertTrue(listed.truncated)
        var writer = ShellValueWriter()
        for item in listed.items {
            ShellWallpaper.write(item, into: &writer)
        }
        XCTAssertLessThanOrEqual(writer.bytes.count, ShellWallpaper.nameBudget)
        XCTAssertGreaterThan(listed.items.count, 100)
        let few = ShellWallpaper.items(["a.jpg", "b.jpg"]) { _ in nil }
        XCTAssertFalse(few.truncated)
        XCTAssertEqual(few.items.map(\.name), ["a.jpg", "b.jpg"])
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
            override: { pinned.value.map { ShellWallpaperPaletteOverride(url: managedURL, pixels: $0) } },
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

    func testPublishingWritesSynchronouslyAndReportsWhetherTheFileChanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("themes/wallpaper.toml")
        let text = ShellWallpaperPalette.theme(pixels: [0xFF11_2233], scheme: .vibrant)
        XCTAssertTrue(try ShellWallpaperPaletteWriter.publish(text, to: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), text)
        XCTAssertFalse(try ShellWallpaperPaletteWriter.publish(text, to: destination))
    }

    func testTheFeedPublishesOnlyWhileAWidgetReadsIt() async throws {
        let desktop = FakeWallpaperDesktop([WallpaperFixtures.studio])
        let settings = WallpaperSettings()
        settings.enabled = true
        var environment = WallpaperEnvironment()
        environment.sample = { _ in [0xFF33_6699] }
        environment.preview = { _ in nil }
        environment.schedule = { _, _ in {} }
        var state = WallpaperRuntimeState()
        let manager = WallpaperManager(
            settings: settings, desktop: desktop, environment: environment,
            loadState: { state }, saveState: { state = $0 }
        )
        manager.settingsDidChange()
        let feed = ShellDataFeed(wallpaper: WallpaperFeedSource(manager: manager)) { _ in }
        feed.start()
        XCTAssertNil(feed.current.wallpaper)
        XCTAssertFalse(manager.previews.demanded)
        feed.setDemand(ShellDataKey.wallpaper.bit, cadence: .init())
        XCTAssertEqual(feed.current.wallpaper?.enabled, true)
        XCTAssertEqual(feed.current.wallpaper?.displays.map(\.id), [WallpaperFixtures.studio.monitorId])
        XCTAssertTrue(manager.previews.demanded)
        settings.rotationMinutes = 60
        manager.setRotation(60)
        XCTAssertEqual(feed.current.wallpaper?.rotation, 60)
        feed.setDemand(0, cadence: .init())
        XCTAssertNil(feed.current.wallpaper)
        XCTAssertFalse(manager.previews.demanded)
        feed.stop()
    }

    func testPreviewsFollowTheDisplayShapePlacementAndFolderAndStayBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try WallpaperFixtures.makeFolder(root, "w", files: (0 ..< 200).map { "w\($0).jpg" })
        let rendered = RenderedKeys()
        let previews = WallpaperPreviews { key in
            await rendered.add(key)
            return Self.image
        }
        var display = WallpaperFixtures.studio
        display.current = folder.appendingPathComponent("w0.jpg")
        var entry = WallpaperManager.Entry(
            display: display, folder: folder, custom: false, files: WallpaperLibrary.files(in: folder)
        )
        previews.retain(entries: [entry], placement: .fill)
        XCTAssertEqual(previews.count, 0, "nothing is made until a widget reads the feed")
        previews.demanded = true
        try await waitUntil { previews.count == 1 + WallpaperPreviews.defaultWindow }
        let first = try XCTUnwrap(previews.ready(
            display.current!,
            width: WallpaperPreviews.cardWidth,
            display: display,
            placement: .fill
        ))

        previews.retain(entries: [entry], placement: .fit)
        XCTAssertNil(previews.ready(
            display.current!,
            width: WallpaperPreviews.cardWidth,
            display: display,
            placement: .fill
        ))
        try await waitUntil { previews.count == 1 + WallpaperPreviews.defaultWindow }
        XCTAssertNotEqual(
            previews.ready(display.current!, width: WallpaperPreviews.cardWidth, display: display, placement: .fit),
            first
        )

        entry.display = WallpaperDisplay(
            displayId: 2, uuid: display.uuid, name: display.name, size: CGSize(width: 1440, height: 2560), isMain: true,
            current: display.current
        )
        previews.retain(entries: [entry], placement: .fit)
        XCTAssertEqual(previews.count, 0, "a new display shape drops the old previews")

        for offset in stride(from: 0, to: 200, by: 24) {
            previews.setWindow(.init(offset: offset, count: 24), for: entry, placement: .fit)
            try await waitUntil { previews.count == 25 || offset > 180 }
        }
        XCTAssertLessThanOrEqual(previews.count, WallpaperPreviews.limit)
        entry.files = []
        entry.display.current = nil
        previews.retain(entries: [entry], placement: .fit)
        XCTAssertEqual(previews.count, 0, "a folder change drops previews of wallpapers no longer shown")
        previews.demanded = false
        XCTAssertEqual(previews.count, 0)
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

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}
