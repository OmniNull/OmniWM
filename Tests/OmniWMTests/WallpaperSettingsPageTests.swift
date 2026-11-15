// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
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
        let environment = WallpaperFixtures.environment(state: WallpaperStateBox(), home: directory.path)
        controller.wallpaperManager = WallpaperManager(
            settings: settings.wallpaper, desktop: desktop, environment: environment
        )
        settings.wallpaper.folder = shared.path
        settings.wallpaper.enabled = true
        settings.wallpaper.setFolder(ultrawide.path, for: oled.monitor)
        settings.wallpaper.displays.append(MonitorWallpaperSettings(
            monitorName: "Studio Display", monitorDisplayUUID: "BBBBBBBB-1111-2222-3333-444444444444",
            folder: "~/Studio"
        ))
        controller.applyWallpaperSettings()
        return (settings, controller, desktop)
    }

    func testThePageListsEveryDisplayWithItsFolderAndCountAndRendersInBothAppearances() async throws {
        let (settings, controller, _) = try fixture()
        let manager = try XCTUnwrap(controller.wallpaperManager)
        manager.showSwatches(true, for: .settings)
        await manager.idle()
        XCTAssertNotNil(manager.paletteSample)
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
            await display(window)
            await display(window)
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

    func testTheBordersPageOffersFollowWallpaperColors() async throws {
        let (settings, controller, _) = try fixture()
        settings.borders.enabled = true
        settings.borders.width = 2
        settings.borders.colorSource = .palette
        for dark in [false, true] {
            let page = BorderSettingsTab(settings: settings, controller: controller)
                .frame(width: 640, height: 760)
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: page)
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.frame = CGRect(x: 0, y: 0, width: 640, height: 760)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = hosting.appearance
            window.contentView = hosting
            await display(window)
            await display(window)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["OMNIWM_SETTINGS_SNAPSHOTS"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: path)
                        .appendingPathComponent("settings-borders-\(dark ? "dark" : "light").png")
                )
            }
            window.contentView = nil
        }
        XCTAssertEqual(settings.toExport().borders.colorSource, .palette)
    }

    private func display(_ window: NSWindow) async {
        await withCheckedContinuation { continuation in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { continuation.resume() }
            window.contentView?.layoutSubtreeIfNeeded()
            window.display()
            CATransaction.commit()
            CATransaction.flush()
        }
    }

    func testRotationChoicesMapToMinutes() {
        XCTAssertEqual(WallpaperRotationChoice(0), .off)
        for minutes in SettingsExport.Wallpaper.rotationPresets {
            XCTAssertEqual(WallpaperRotationChoice(minutes), .minutes(minutes))
        }
        let custom = SettingsExport.Wallpaper.rotationPresets[0] + 1
        XCTAssertFalse(SettingsExport.Wallpaper.rotationPresets.contains(custom))
        XCTAssertEqual(WallpaperRotationChoice(custom), .custom)
    }

    func testTheColorsSectionFollowsAPaletteChangeMadeWhileItIsOpen() async throws {
        let (settings, controller, _) = try fixture()
        let manager = try XCTUnwrap(controller.wallpaperManager)
        let host = ShellWidgetHost(
            configDirectory: directory,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("resources")),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        controller.workspaceBarManager.shellHost = host
        defer { controller.workspaceBarManager.shellHost = nil }
        func render() -> NSWindow {
            let section = Form { WallpaperSchemeSection(settings: settings, controller: controller) }
                .formStyle(.grouped)
                .frame(width: 640, height: 420)
            let hosting = NSHostingView(rootView: section)
            hosting.frame = CGRect(x: 0, y: 0, width: 640, height: 420)
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = hosting
            return window
        }
        func pixels(_ window: NSWindow) async throws -> Data? {
            await display(window)
            await display(window)
            let hosting = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        let open = render()
        _ = try await pixels(open)
        await manager.idle()
        XCTAssertFalse(manager.paletteSwatches.isEmpty)
        let before = try await pixels(open)

        let configuration = controller.workspaceBarManager.shellConfiguration
        let original = configuration.config
        var config = original
        config.themeName = ShellWallpaperPalette.themeName
        config.wallpaperScheme = .vibrant
        configuration.adopt(config)
        let after = try await pixels(open)
        XCTAssertNotEqual(after, before, "a scheme chosen from the shell shows in the open section")
        configuration.adopt(original)
        let restored = try await pixels(open)
        XCTAssertEqual(restored, before, "going back to the style palette shows in the open section too")
        open.contentView = nil
    }

    func testThePageTakesFolderCountsFromTheManagerAndNeverScansOnTheMainThread() async throws {
        let (settings, controller, _) = try fixture()
        let manager = try XCTUnwrap(controller.wallpaperManager)
        let held = WallpaperHeldWork()
        let probe = WallpaperManager(
            settings: settings.wallpaper, desktop: FakeWallpaperDesktop([WallpaperFixtures.studio]),
            environment: {
                var environment = manager.environment
                environment.perform = held.perform
                return environment
            }()
        )
        controller.wallpaperManager = probe
        probe.start(resumingRotation: false)
        let page = WallpaperSettingsPage(settings: settings, controller: controller).frame(width: 640, height: 1180)
        let hosting = NSHostingView(rootView: page)
        hosting.frame = CGRect(x: 0, y: 0, width: 640, height: 1180)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        await display(window)
        XCTAssertTrue(probe.listsEveryFolder, "the open page asks the manager for every folder's count")
        XCTAssertTrue(probe.lists.isEmpty, "nothing is listed until the worker runs")
        held.release()
        let studio = try XCTUnwrap(WallpaperLibrary.folderURL("~/Studio", home: directory.path))
        XCTAssertNotNil(probe.list(for: studio))
        window.contentView = nil
    }
}
