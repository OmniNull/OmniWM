// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class OpenAppHotkeyTests: XCTestCase {
    private let finderID = "openApp.com.apple.finder"
    private let chord = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey)))

    func testOpenAppActionsResolveFromBundleIdentifier() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: finderID))
        XCTAssertEqual(spec.command, .openApp("com.apple.finder"))
        XCTAssertEqual(spec.title, "Open Finder")
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertNil(spec.ipcCommandName)
        XCTAssertEqual(ActionCatalog.spec(for: .openApp("com.apple.finder")), spec)
        for id in ["openApp.", "openApp.two words"] {
            XCTAssertNil(ActionCatalog.spec(for: id), id)
        }
        let resolved = try HotkeyBindingRegistry.resolve([PersistedHotkeyBinding(id: finderID, trigger: chord)])
        XCTAssertEqual(resolved.first { $0.id == finderID }?.binding, chord)
    }

    func testLauncherAppEntriesGetRowsAndAssignedRowsOutliveTheEntry() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        var reregistrations = 0
        settings.onDynamicHotkeysChanged = { reregistrations += 1 }
        var finder = LauncherEntry()
        finder.kind = .application
        finder.path = "/System/Library/CoreServices/Finder.app"
        var command = LauncherEntry()
        command.command = "true"

        settings.launcher.entries = [finder, command]
        XCTAssertEqual(settings.hotkeyBindings.filter { $0.id.hasPrefix(ActionCatalog.openAppPrefix) }.map(\.id), [
            finderID
        ])
        XCTAssertEqual(reregistrations, 1)

        settings.updateTrigger(for: finderID, newTrigger: chord)
        settings.launcher.entries = []
        XCTAssertEqual(settings.hotkeyBindings.last?.id, finderID)
        XCTAssertEqual(settings.hotkeyBindings.last?.binding, chord)
    }
}
