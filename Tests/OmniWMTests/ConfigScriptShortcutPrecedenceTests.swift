// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptShortcutPrecedenceTests: XCTestCase {
    func testVimRecipeMasksTheSavedShortcutAndItsRemovalRestoresIt() async throws {
        let fixture = Fixture(test: self)
        let chord = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("Option+Shift+L"))
        let saved = try XCTUnwrap(DefaultHotkeyBindings.all().first { $0.binding.chordBinding == chord })
        let vim = try ConfigScriptWindowFixture.recipe("Vim-style keys alongside the defaults")
        let winner = HotkeyCommand.move(.right)
        let removal = #"bind("L", "right")"#
        XCTAssertTrue(vim.contains(removal))
        fixture.setSettings([saved])
        let exported = fixture.settings.toExport().hotkeyBindings
        try await fixture.load(vim)
        XCTAssertEqual(fixture.settings.toExport().hotkeyBindings, exported)
        XCTAssertEqual(fixture.plannedCommands(for: chord), [winner])
        let mask = try XCTUnwrap(fixture.settings.configScriptShortcutConflicts?.overrides.first)
        XCTAssertEqual(mask.bindingID, saved.id)
        XCTAssertEqual(mask.field, .shortcut)

        fixture.controller.setHotkeyRecordingActive(true)
        XCTAssertTrue(fixture.controller.hotkeys.commandHotkeysSuspended)
        fixture.controller.setHotkeyRecordingActive(false)
        XCTAssertFalse(fixture.controller.hotkeys.commandHotkeysSuspended)
        XCTAssertEqual(fixture.plannedCommands(for: chord), [winner])
        XCTAssertTrue(fixture.controller.hotkeys.setKeyboardMode(.paused))
        XCTAssertTrue(fixture.controller.hotkeys.setKeyboardMode(.normal))
        XCTAssertEqual(fixture.plannedCommands(for: chord), [winner])

        let rejected = vim + "\nomniwm.cmd.mistyped()"
        try await fixture.load(rejected, accepted: false)
        XCTAssertEqual(fixture.settings.configScriptShortcutConflicts?.overrides.first, mask)
        XCTAssertEqual(fixture.plannedCommands(for: chord), [winner])

        try await fixture.load(vim.replacingOccurrences(of: removal, with: ""))
        XCTAssertEqual(fixture.settings.toExport().hotkeyBindings, exported)
        XCTAssertNil(fixture.settings.configScriptShortcutConflicts)
        XCTAssertEqual(fixture.plannedCommands(for: chord), [saved.command])
    }

    func testDisabledFlexCommandCannotMaskTheSettingsChord() async throws {
        let fixture = Fixture(test: self)
        let text = "Control+Option+U"
        let chord = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(text))
        let saved = HotkeyBinding(id: "focus.right", command: .focus(.right), binding: chord)
        let winner = HotkeyCommand.presentation(.overview)
        fixture.settings.overview.enabled = false
        fixture.setSettings([saved])
        try await fixture.load("omniwm.keymap.set('\(text)', omniwm.cmd.toggleOverview())")
        XCTAssertEqual(fixture.plannedCommands(for: chord), [saved.command])
        XCTAssertNil(fixture.settings.configScriptShortcutConflicts)

        fixture.settings.overview.enabled = true
        fixture.controller.updateHotkeyBindings(fixture.settings.hotkeyBindings)
        XCTAssertEqual(fixture.plannedCommands(for: chord), [winner])
        XCTAssertEqual(fixture.settings.configScriptShortcutConflicts?.overrides.map(\.bindingID), [saved.id])

        fixture.settings.overview.enabled = false
        fixture.controller.updateHotkeyBindings(fixture.settings.hotkeyBindings)
        XCTAssertEqual(fixture.plannedCommands(for: chord), [saved.command])
        XCTAssertNil(fixture.settings.configScriptShortcutConflicts)
    }

    @MainActor
    private struct Fixture {
        let controller: WMController
        let script: ConfigScriptController

        var settings: SettingsStore {
            controller.settings
        }

        init(test: XCTestCase) {
            let controller = InputControllerTestSupport.controller(for: test)
            self.controller = controller
            let settings = controller.settings
            script = ConfigScriptController(
                fileURL: settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent(
                    ConfigScriptController.fileName
                ),
                settings: settings, wmController: controller
            ) { [weak controller] resolution in
                controller?.updateHotkeyBindings(settings.hotkeyBindings, scriptResolution: resolution)
            }
            controller.configScript = script
        }

        func setSettings(_ rows: [HotkeyBinding]) {
            settings.hotkeyBindings = rows
            controller.updateHotkeyBindings(rows)
        }

        func load(_ source: String, accepted: Bool = true) async throws {
            let hyper = settings.hyperKeyModifiers.carbonMask
            let result: Result<ConfigScriptEvaluation?, ConfigScriptError>
            do {
                result = .success(try await script.loader.evaluate(Data(source.utf8), hyperMask: hyper))
            } catch let error as ConfigScriptError {
                result = .failure(error)
            }
            XCTAssertTrue(script.apply(ConfigScriptLoad(versions: [:], result: result), hyperMask: hyper))
            XCTAssertEqual(settings.configScriptLoadError == nil, accepted)
        }

        func plannedCommands(for chord: KeyBinding) -> [HotkeyCommand] {
            let plan = HotkeyCenter.registrationPlan(for: controller.hotkeys.configuration.bindings)
            XCTAssertTrue(plan.failures.isEmpty)
            return plan.registrations.filter { $0.binding == chord }.map(\.command)
        }
    }
}
