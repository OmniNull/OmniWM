// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class WallpaperSettingsTests: XCTestCase {
    @MainActor
    func testTheFeatureIsOffByDefaultAndLeavesTheSettingsFileUnchanged() throws {
        let defaults = SettingsExport.defaults()
        XCTAssertFalse(defaults.wallpaper.enabled)
        XCTAssertEqual(defaults.wallpaper.rotationMinutes, 0, "rotation stays off until the user picks an interval")
        XCTAssertEqual(WallpaperSettings().rotationMinutes, 0)
        let text = try XCTUnwrap(String(data: SettingsTOMLCodec.encode(defaults), encoding: .utf8))
        XCTAssertFalse(text.contains("wallpaper"), "a user who never turns it on gets no new settings")
        XCTAssertEqual(try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(defaults)), defaults)
    }

    func testFoldersIntervalPlacementAndDisplaysRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.wallpaper.enabled = true
        export.wallpaper.folder = "~/Pictures/Walls"
        let custom = SettingsExport.Wallpaper.rotationPresets[0] + SettingsExport.Wallpaper.rotationPresets[1]
        export.wallpaper.rotationMinutes = custom
        export.wallpaper.placement = .fit
        export.wallpaper.displays = [
            MonitorWallpaperSettings(
                monitorName: "DELL U2723QE", monitorDisplayUUID: "33333333-3333-3333-3333-333333333333",
                folder: "~/Pictures/Walls/left"
            ),
            MonitorWallpaperSettings(monitorName: "Projector", monitorDisplayId: 7, folder: "/Volumes/Art")
        ]
        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        guard case let .table(wallpaper)? = tree["wallpaper"] else { return XCTFail("no [wallpaper] table") }
        XCTAssertEqual(wallpaper["rotationMinutes"], .integer(.init(custom)))
        XCTAssertEqual(wallpaper["placement"], .string("fit"))
    }

    func testMissingOrOutOfRangeValuesFallBackSafely() throws {
        var tree = try TOMLDecoder().decode(
            [String: TOMLNode].self, from: SettingsTOMLCodec.encode(.defaults())
        )
        tree["wallpaper"] = .table([
            "enabled": .boolean(true),
            "rotationMinutes": .integer(.init(SettingsExport.Wallpaper.rotationLimit + 1)),
            "folder": .string("  ")
        ])
        let decoded = try SettingsTOMLCodec.decode(TOMLEncoder().encode(tree)).wallpaper
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.rotationMinutes, SettingsExport.Wallpaper.rotationLimit)
        XCTAssertEqual(decoded.folder, WallpaperLibrary.defaultFolder)
        XCTAssertEqual(decoded.placement, .fill)

        tree["wallpaper"] = .table(["enabled": .boolean(true)])
        XCTAssertEqual(try SettingsTOMLCodec.decode(TOMLEncoder().encode(tree)).wallpaper.rotationMinutes, 0)

        tree["wallpaper"] = .table(["enabled": .string("yes")])
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(TOMLEncoder().encode(tree)))
    }

    @MainActor
    func testEditsPersistThroughTheStoreAndTheStateFileKeepsTheShuffle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
        var changes = 0
        settings.onWallpaperSettingsChanged = { changes += 1 }
        settings.wallpaper.enabled = true
        settings.wallpaper.setFolder("~/Pictures/Left", for: WallpaperFixtures.twinLeft.monitor)
        settings.wallpaper.rotationMinutes = SettingsExport.Wallpaper.rotationPresets[0]
        XCTAssertEqual(changes, 3)

        let saved = try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL))
        XCTAssertTrue(saved.wallpaper.enabled)
        XCTAssertEqual(saved.wallpaper.rotationMinutes, SettingsExport.Wallpaper.rotationPresets[0])
        XCTAssertEqual(saved.wallpaper.displays.map(\.folder), ["~/Pictures/Left"])
        XCTAssertEqual(saved.wallpaper.displays.map(\.monitorDisplayUUID), [WallpaperFixtures.twinLeft.uuid])
        XCTAssertEqual(settings.wallpaper.folder(for: WallpaperFixtures.twinLeft.monitor)?.folder, "~/Pictures/Left")
        XCTAssertNil(
            settings.wallpaper.folder(for: WallpaperFixtures.twinRight.monitor),
            "identical twins differ by UUID"
        )

        settings.wallpaper.setFolder(nil, for: WallpaperFixtures.twinLeft.monitor)
        XCTAssertTrue(settings.wallpaper.displays.isEmpty)

        var state = WallpaperRuntimeState()
        var random = WallpaperRandom(seed: 3)
        _ = state.shuffle.next(display: "A", folder: "/w", files: ["a.jpg", "b.jpg"], using: &random)
        state.nextChange = Date(timeIntervalSince1970: 1_800_000_000)
        let file = directory.appendingPathComponent(WallpaperStateFile.name)
        XCTAssertEqual(try WallpaperStateFile.load(file), WallpaperRuntimeState(), "no file is a fresh start")
        try WallpaperStateFile.save(state, to: file)
        XCTAssertEqual(try WallpaperStateFile.load(file), state)
        try Data("not json".utf8).write(to: file)
        XCTAssertThrowsError(try WallpaperStateFile.load(file), "a damaged file is reported, not read as empty")
    }

    @MainActor
    func testFolderChoicesWaitUntilManagementIsOn() {
        let settings = WallpaperSettings()
        let choice = WallpaperFolderChoice(settings: settings, home: "/Users/someone")
        let chosen = URL(fileURLWithPath: "/Users/someone/Pictures/Elsewhere", isDirectory: true)
        choice.setDefault(chosen)
        choice.set(chosen, for: WallpaperFixtures.studio.monitor)
        XCTAssertEqual(settings.export(), SettingsExport.Wallpaper(), "nothing is written before it is turned on")

        settings.enabled = true
        choice.setDefault(chosen)
        choice.set(chosen, for: WallpaperFixtures.studio.monitor)
        XCTAssertEqual(settings.folder, "~/Pictures/Elsewhere")
        XCTAssertEqual(settings.displays.map(\.folder), ["~/Pictures/Elsewhere"])
    }

    func testTheStateFileIsPrivateLikeOmniWMsOtherState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state").appendingPathComponent(WallpaperStateFile.name)
        try WallpaperStateFile.save(WallpaperRuntimeState(), to: file)
        let folder = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        let saved = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, WallpaperStateFile.folderPermissions)
        XCTAssertEqual((saved[.posixPermissions] as? NSNumber)?.intValue, WallpaperStateFile.filePermissions)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
            [WallpaperStateFile.name], "no temporary file is left behind"
        )
    }
}
