// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import GhosttyKit
@testable import OmniWM
import os
import XCTest

@MainActor
final class QuakeGhosttyRuntimeTests: XCTestCase {
    func testRepeatedCleanupBeforeStartupKeepsRuntimeAndWindowUninitialized() {
        let controller = makeController()
        let runtime = controller.ghosttyRuntime

        for _ in 0 ..< 2 {
            controller.cleanup()

            XCTAssertNil(controller.window)
            XCTAssertFalse(controller.visible)
            XCTAssertNil(runtime.makeSurfaceView(for: controller))
        }
    }

    func testConfigurationCreationFailureCanRetryWithoutCreatingSurfaceOrWindow() {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        var operations = QuakeGhosttyConfigOperations.live
        operations.makeConfig = {
            attempts.withLock { $0 += 1 }
            return nil
        }
        let controller = makeController(configBuilder: QuakeGhosttyConfigBuilder(operations: operations))

        for expectedAttempts in 1 ... 2 {
            XCTAssertFalse(controller.ghosttyRuntime.startIfNeeded(for: controller))
            XCTAssertEqual(attempts.withLock { $0 }, expectedAttempts)
            XCTAssertNil(controller.ghosttyRuntime.makeSurfaceView(for: controller))
            XCTAssertNil(controller.window)
            XCTAssertFalse(controller.visible)
            controller.cleanup()
        }
    }

    func testQuakeDefaultsUseGhosttyBindingsBeforeUserConfiguration() throws {
        try checkConfiguration("") { config in
            var confirmation: UnsafePointer<CChar>?
            XCTAssertTrue(ghostty_config_get(config, &confirmation, "confirm-close-surface", 21))
            XCTAssertEqual(confirmation.map { String(cString: $0) }, "false")
            let closeTab = ghostty_config_trigger(config, "close_tab", 9)
            XCTAssertEqual(closeTab.key.unicode, 119)
            XCTAssertEqual(closeTab.mods, GHOSTTY_MODS_SUPER)
            let closePane = ghostty_config_trigger(config, "close_surface", 13)
            XCTAssertEqual(closePane.key.unicode, 119)
            XCTAssertEqual(closePane.mods.rawValue, GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
            let tabNine = ghostty_config_trigger(config, "goto_tab:9", 10)
            XCTAssertEqual(tabNine.key.unicode, 57)
            let equalize = ghostty_config_trigger(config, "equalize_splits", 15)
            XCTAssertEqual(equalize.key.physical, GHOSTTY_KEY_EQUAL)
            XCTAssertEqual(equalize.mods.rawValue, GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
        }
    }

    func testUserCanRemapAndUnbindFormerHardcodedShortcuts() throws {
        try checkConfiguration("""
        keybind = cmd+t=unbind
        keybind = ctrl+shift+t=new_tab
        keybind = cmd+w=text:keep-open
        keybind = cmd+shift+w=unbind
        """) { config in
            let newTab = ghostty_config_trigger(config, "new_tab", 7)
            XCTAssertEqual(newTab.key.unicode, 116)
            XCTAssertEqual(newTab.mods.rawValue, GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
            let closePane = ghostty_config_trigger(config, "close_surface", 13)
            XCTAssertEqual(closePane.key.physical, GHOSTTY_KEY_UNIDENTIFIED)
            let text = ghostty_config_trigger(config, "text:keep-open", 14)
            XCTAssertEqual(text.key.unicode, 119)
            XCTAssertEqual(text.mods, GHOSTTY_MODS_SUPER)
        }
    }

    func testIncludedConfigOverridesQuakeDefaults() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "keybind = ctrl+w=close_tab\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try checkConfiguration("config-file = \(file.path)") { config in
            let binding = ghostty_config_trigger(config, "close_tab", 9)
            XCTAssertEqual(binding.key.unicode, 119)
            XCTAssertEqual(binding.mods, GHOSTTY_MODS_CTRL)
        }
    }

    func testUserCloseConfirmationPreferenceOverridesQuakeDefault() throws {
        for value in ["true", "always"] {
            try checkConfiguration("confirm-close-surface = \(value)") { config in
                var confirmation: UnsafePointer<CChar>?
                XCTAssertTrue(ghostty_config_get(config, &confirmation, "confirm-close-surface", 21))
                XCTAssertEqual(confirmation.map { String(cString: $0) }, value)
            }
        }
    }

    private func checkConfiguration(
        _ content: String,
        check: @escaping @Sendable (ghostty_config_t) -> Void
    ) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try content.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var operations = QuakeGhosttyConfigOperations.live
        operations.loadDefaultFiles = { config in
            file.path.withCString { ghostty_config_load_file(config, $0) }
        }
        let checked = OSAllocatedUnfairLock(initialState: false)
        operations.finalize = { config in
            ghostty_config_finalize(config)
            XCTAssertEqual(ghostty_config_diagnostics_count(config), 0)
            check(config)
            checked.withLock { $0 = true }
        }
        let controller = makeController(configBuilder: QuakeGhosttyConfigBuilder(operations: operations))
        defer { controller.cleanup() }
        XCTAssertTrue(controller.ghosttyRuntime.startIfNeeded(for: controller))
        XCTAssertTrue(checked.withLock { $0 })
    }

    private func makeController(configBuilder: QuakeGhosttyConfigBuilder = QuakeGhosttyConfigBuilder())
        -> QuakeTerminalController
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeRuntimeTests-\(UUID().uuidString)", isDirectory: true)
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
        return QuakeTerminalController(
            settings: settings,
            motionPolicy: MotionPolicy(),
            ghosttyConfigBuilder: configBuilder
        )
    }
}
