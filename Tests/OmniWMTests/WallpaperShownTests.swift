// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WallpaperShownTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var aerials: URL!
    private var index: [String: Any] = [:]
    private var applied: [URL] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperShown-\(UUID().uuidString)")
        folder = try WallpaperFixtures.makeFolder(root, "Pictures/Wallpapers", files: [])
        aerials = root.appendingPathComponent("aerials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: aerials.appendingPathComponent("thumbnails"), withIntermediateDirectories: true
        )
        for name in ["a.png", "b.png"] {
            try WallpaperFixtures.writeImage(
                folder.appendingPathComponent(name),
                width: 64,
                height: 36,
                color: (0.3, 0.5, 0.7)
            )
        }
        try WallpaperFixtures.writeImage(
            aerials.appendingPathComponent("thumbnails/A1.png"), width: 64, height: 36, color: (0.8, 0.4, 0.2)
        )
        applied = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func content(file: URL? = nil, aerial: String? = nil, shuffle: Bool = false) throws -> [String: Any] {
        let configuration: Data
        let provider: String
        if let aerial {
            configuration = try PropertyListSerialization.data(
                fromPropertyList: ["assetID": aerial], format: .binary, options: 0
            )
            provider = ShellWallpaperPalette.aerialProvider
        } else {
            configuration = try PropertyListSerialization.data(
                fromPropertyList: ["type": "imageFile", "url": ["relative": (file ?? folder).absoluteString]],
                format: .binary, options: 0
            )
            provider = ShellWallpaperPalette.stillImageProvider
        }
        let choice: [String: Any] = ["Configuration": configuration, "Files": [Any](), "Provider": provider]
        let desktop: [String: Any] = ["Content": [
            "Choices": [choice],
            "Shuffle": shuffle ? ["Interval": 300] : "$null"
        ]]
        return ["Desktop": desktop, "Type": "individual"]
    }

    private func show(_ content: [String: Any]) {
        index = ["Spaces": ["SPACE": ["Displays": ["UUID-1": content]]]]
    }

    private func desktop() -> LiveWallpaperDesktop {
        LiveWallpaperDesktop(
            screens: {
                [WallpaperDisplay(
                    displayId: 1, uuid: "UUID-1", name: "Studio Display", size: CGSize(width: 2560, height: 1440),
                    isMain: true
                )]
            },
            store: { [unowned self] in try? PropertyListSerialization.data(
                fromPropertyList: index,
                format: .binary,
                options: 0
            ) },
            location: { _ in ("UUID-1", "SPACE") },
            aerials: aerials,
            apply: { [unowned self] url, _, _ in applied.append(url) }
        )
    }

    private func manager(_ desktop: LiveWallpaperDesktop) -> WallpaperManager {
        let settings = WallpaperSettings()
        settings.enabled = true
        settings.folder = folder.path
        var environment = WallpaperEnvironment()
        environment.schedule = { _, _ in {} }
        environment.preview = { _ in nil }
        let manager = WallpaperManager(
            settings: settings, desktop: desktop, environment: environment,
            loadState: { WallpaperRuntimeState() }, saveState: { _ in }
        )
        manager.settingsDidChange()
        return manager
    }

    func testTheShownWallpaperFollowsEveryStoreChange() throws {
        show(try content(file: folder.appendingPathComponent("a.png")))
        let desktop = desktop()
        let manager = manager(desktop)
        XCTAssertEqual(manager.shellValue().displays.first?.current, "a.png")
        XCTAssertEqual(manager.shellValue().displays.first?.kind, "file")

        show(try content(file: folder.appendingPathComponent("b.png")))
        desktop.storeDidChange()
        XCTAssertEqual(manager.shellValue().displays.first?.current, "b.png", "a file chosen in System Settings")

        show(try content(aerial: "A1"))
        desktop.storeDidChange()
        var shown = try XCTUnwrap(manager.shellValue().displays.first)
        XCTAssertNil(shown.current, "no wallpaper in the folder is marked Now while an Aerial shows")
        XCTAssertEqual(shown.kind, "aerial")
        XCTAssertEqual(manager.entries.first?.display.thumbnail?.lastPathComponent, "A1.png")

        show(try content(file: folder, shuffle: true))
        desktop.storeDidChange()
        shown = try XCTUnwrap(manager.shellValue().displays.first)
        XCTAssertNil(shown.current)
        XCTAssertEqual(shown.kind, "shuffle", "a folder macOS shuffles")
    }

    func testTheShownWallpaperComesFromTheStoreNotFromWhatOmniWMRemembersSetting() async throws {
        show(try content(file: folder.appendingPathComponent("b.png")))
        let desktop = desktop()
        let manager = manager(desktop)
        await manager.set("a.png", on: "display:1")
        XCTAssertEqual(applied.map(\.lastPathComponent), ["a.png"])
        XCTAssertEqual(
            manager.shellValue().displays.first?.current, "b.png",
            "until the Store names a.png, the display still shows b.png"
        )
        show(try content(file: folder.appendingPathComponent("a.png")))
        desktop.storeDidChange()
        XCTAssertEqual(manager.shellValue().displays.first?.current, "a.png")
    }

    func testAStoreChangeNotifiesTheManagerAndTheFeed() throws {
        show(try content(file: folder.appendingPathComponent("a.png")))
        let desktop = desktop()
        let manager = manager(desktop)
        var changes = 0
        manager.onChange = { changes += 1 }
        show(try content(aerial: "A1"))
        desktop.storeDidChange()
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(manager.shellValue().displays.first?.kind, "aerial")
    }
}
