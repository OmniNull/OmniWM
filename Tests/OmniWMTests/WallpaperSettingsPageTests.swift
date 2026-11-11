// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class WallpaperSettingsPageTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperSettingsPage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture() throws -> (SettingsStore, WMController, FakeWallpaperDesktop) {
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
        let shared = try WallpaperFixtures.makeFolder(directory, "Wallpapers", files: [])
        let ultrawide = try WallpaperFixtures.makeFolder(directory, "Wallpapers/ultrawide", files: [])
        for (index, colors) in ShellBundledWidgetTests.wallpaperPalettes.enumerated() {
            for folder in [shared, ultrawide] {
                let image = ShellBundledWidgetTests.wallpaperGradient(320, 180, colors)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    .write(to: folder.appendingPathComponent("wall-\(index).png"))
            }
        }
        var oled = WallpaperDisplay(
            displayId: 1, uuid: "AAAAAAAA-1111-2222-3333-444444444444", name: "MPG491CX OLED",
            size: CGSize(width: 5120, height: 1440), isMain: true
        )
        oled.current = ultrawide.appendingPathComponent("wall-0.png")
        let builtin = WallpaperFixtures.secondary(WallpaperFixtures.macBook)
        let desktop = FakeWallpaperDesktop([oled, builtin])
        settings.wallpaper.folder = shared.path
        settings.wallpaper.enabled = true
        settings.wallpaper.setFolder(ultrawide.path, for: oled.monitor)
        settings.wallpaper.displays.append(MonitorWallpaperSettings(
            monitorName: "Studio Display", monitorDisplayUUID: "BBBBBBBB-1111-2222-3333-444444444444",
            folder: "~/Pictures/Studio"
        ))
        var environment = WallpaperEnvironment()
        environment.schedule = { _, _ in {} }
        controller.wallpaperManager = WallpaperManager(
            settings: settings.wallpaper, desktop: desktop, environment: environment,
            loadState: { WallpaperRuntimeState() }, saveState: { _ in }
        )
        controller.wallpaperManager.settingsDidChange()
        return (settings, controller, desktop)
    }

    func testThePageListsEveryDisplayWithItsFolderAndCountAndRendersInBothAppearances() async throws {
        let (settings, controller, _) = try fixture()
        await controller.wallpaperManager.sampleMainWallpaper()
        XCTAssertNotNil(controller.wallpaperManager.paletteSample)
        for dark in [false, true] {
            let page = WallpaperSettingsPage(settings: settings, controller: controller)
                .frame(width: 640, height: 1180)
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: page)
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.frame = CGRect(x: 0, y: 0, width: 640, height: 1180)
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.appearance = hosting.appearance
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            for _ in 0 ..< 10 {
                try await Task.sleep(for: .milliseconds(30))
                hosting.layoutSubtreeIfNeeded()
            }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            XCTAssertEqual(bitmap.pixelsWide, Int(640 * window.backingScaleFactor))
            if let path = ProcessInfo.processInfo.environment["OMNIWM_SETTINGS_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("settings-wallpaper-\(dark ? "dark" : "light").png"))
            }
            window.contentView = nil
        }
    }

    func testRotationChoicesMapToMinutes() {
        XCTAssertEqual(WallpaperRotationChoice(0), .off)
        XCTAssertEqual(WallpaperRotationChoice(15), .minutes(15))
        XCTAssertEqual(WallpaperRotationChoice(60), .minutes(60))
        XCTAssertEqual(WallpaperRotationChoice(45), .custom)
    }
}
