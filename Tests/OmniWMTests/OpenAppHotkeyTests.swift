// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
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

    func testOpenAppHotkeyOpensTheInstalledApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WMController(
            settings: makeSettings(root),
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard"),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics"),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        var opened: [URL] = []
        var environment = CommandPaletteEnvironment()
        environment.runningApplicationForResult = { _ in nil }
        environment.openApplication = { url, _ in opened.append(url) }
        environment.presentCommandFailure = { XCTFail($0) }
        controller.commandPaletteController = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: false),
            environment: environment
        )
        let press = { controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: .openApp($0))) }

        XCTAssertEqual(press("com.apple.finder"), .executed)
        let finder = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        XCTAssertEqual(opened, [finder])
        XCTAssertEqual(press("com.example.absent"), .notFound)
        XCTAssertEqual(opened, [finder])
    }

    func testLauncherAppEntriesGetRowsAndAssignedRowsOutliveTheEntry() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettings(root)
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

    private func makeSettings(_ root: URL) -> SettingsStore {
        SettingsStore(
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
    }
}
