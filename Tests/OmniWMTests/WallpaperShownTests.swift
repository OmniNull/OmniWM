// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import os
import XCTest

@MainActor
final class WallpaperShownTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var aerials: URL!
    private var applied: [URL] = []
    private let store = StoreFile()

    private final class StoreFile: Sendable {
        private let state = OSAllocatedUnfairLock<(data: Data?, failure: String?, reads: Int)>(
            initialState: (nil, nil, 0)
        )

        var reads: Int {
            state.withLock { $0.reads }
        }

        func show(_ index: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
            state.withLock { $0.data = data }
        }

        func remove() {
            state.withLock { $0.data = nil }
        }

        func fail(_ reason: String?) {
            state.withLock { $0.failure = reason }
        }

        func read() throws -> Data? {
            try state.withLock { state in
                state.reads += 1
                if let failure = state.failure { throw CocoaError(.fileReadNoPermission, userInfo: [
                    NSLocalizedDescriptionKey: failure
                ]) }
                return state.data
            }
        }
    }

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

    private func show(_ content: [String: Any], on displays: [String] = ["UUID-1"]) throws {
        var shown: [String: Any] = [:]
        for display in displays {
            shown[display] = content
        }
        try store.show(["Spaces": ["SPACE": ["Displays": shown]]])
    }

    private static let main = WallpaperDisplay(
        displayId: 1, uuid: "UUID-1", name: "Studio Display", size: CGSize(width: 2560, height: 1440), isMain: true
    )

    private static let side = WallpaperDisplay(
        displayId: 2, uuid: "UUID-2", name: "Built-in Retina Display", size: CGSize(width: 1512, height: 982),
        isMain: false, isBuiltin: true, hasNotch: true
    )

    private func desktop(_ screens: [WallpaperDisplay] = [main]) -> LiveWallpaperDesktop {
        let store = store
        return LiveWallpaperDesktop(
            screens: { screens },
            store: { try store.read() },
            location: { id in ("UUID-\(id)", "SPACE") },
            aerials: aerials,
            apply: { [unowned self] url, _, _ in applied.append(url) },
            events: ShellWallpaperEvents(store: root)
        )
    }

    private func manager(_ desktop: LiveWallpaperDesktop) -> WallpaperManager {
        let settings = WallpaperSettings()
        settings.enabled = true
        settings.folder = folder.path
        let manager = WallpaperManager(
            settings: settings, desktop: desktop,
            environment: WallpaperFixtures.environment(state: WallpaperStateBox(), home: root.path)
        )
        manager.start(resumingRotation: false)
        return manager
    }

    func testTheShownWallpaperFollowsEveryStoreChange() throws {
        try show(try content(file: folder.appendingPathComponent("a.png")))
        let desktop = desktop()
        let manager = manager(desktop)
        XCTAssertEqual(manager.shellValue().displays.first?.current, "a.png")
        XCTAssertEqual(manager.shellValue().displays.first?.kind, "file")

        try show(try content(file: folder.appendingPathComponent("b.png")))
        desktop.onChange?()
        XCTAssertEqual(manager.shellValue().displays.first?.current, "b.png", "a file chosen in System Settings")

        try show(try content(aerial: "A1"))
        desktop.onChange?()
        var shown = try XCTUnwrap(manager.shellValue().displays.first)
        XCTAssertNil(shown.current, "no wallpaper in the folder is marked Now while an Aerial shows")
        XCTAssertEqual(shown.kind, "aerial")
        XCTAssertEqual(manager.entries.first?.display.thumbnail?.lastPathComponent, "A1.png")

        try show(try content(file: folder, shuffle: true))
        desktop.onChange?()
        shown = try XCTUnwrap(manager.shellValue().displays.first)
        XCTAssertNil(shown.current)
        XCTAssertEqual(shown.kind, "shuffle", "a folder macOS shuffles")
    }

    func testTheShownWallpaperComesFromTheStoreNotFromWhatOmniWMRemembersSetting() async throws {
        try show(try content(file: folder.appendingPathComponent("b.png")))
        let desktop = desktop()
        let manager = manager(desktop)
        await manager.set("a.png", on: "display:1")
        XCTAssertEqual(applied.map(\.lastPathComponent), ["a.png"])
        XCTAssertEqual(
            manager.shellValue().displays.first?.current, "b.png",
            "until the Store names a.png, the display still shows b.png"
        )
        try show(try content(file: folder.appendingPathComponent("a.png")))
        desktop.onChange?()
        XCTAssertEqual(manager.shellValue().displays.first?.current, "a.png")
    }

    func testAStoreChangeNotifiesTheManagerAndTheFeed() throws {
        try show(try content(file: folder.appendingPathComponent("a.png")))
        let desktop = desktop()
        let manager = manager(desktop)
        var changes = 0
        manager.onChange = { changes += 1 }
        try show(try content(aerial: "A1"))
        desktop.onChange?()
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(manager.shellValue().displays.first?.kind, "aerial")
    }

    func testOneLookAtTheDesktopReadsTheStoreOnceForEveryDisplay() throws {
        try show(try content(file: folder.appendingPathComponent("a.png")), on: ["UUID-1", "UUID-2"])
        let manager = manager(desktop([Self.main, Self.side]))
        XCTAssertEqual(store.reads, 1, "two displays share one read and one parse of the Store")
        XCTAssertEqual(manager.entries.map(\.currentName), ["a.png", "a.png"])
    }

    func testAStoreThatCannotBeReadIsReportedInsteadOfShownAsMissing() throws {
        try show(try content(file: folder.appendingPathComponent("a.png")))
        let desktop = desktop()
        let manager = manager(desktop)
        XCTAssertNil(manager.problem)

        store.fail("Permission denied")
        desktop.onChange?()
        let problem = try XCTUnwrap(manager.problem)
        XCTAssertTrue(problem.contains("Permission denied"), problem)
        XCTAssertEqual(manager.entries.first?.display.kind, .other)

        store.fail(nil)
        store.remove()
        desktop.onChange?()
        XCTAssertNil(manager.problem, "a Store that does not exist yet is not a failure")
    }
}
