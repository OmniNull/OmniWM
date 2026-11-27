// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptModeKeyTests: XCTestCase {
    private let chord = "Control+Option+J"
    private let palette = "open-command-palette"
    private let paletteMember = "openCommandPalette"

    private func binding(_ chord: String, _ member: String, _ modeKey: String? = nil) -> String {
        let options = modeKey.map { ", { modeKey = '\($0)' }" } ?? ""
        return "omniwm.keymap.set('\(chord)', omniwm.cmd.\(member)()\(options))"
    }

    private func evaluate(_ source: String) async throws -> ConfigScriptEvaluation {
        try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: HyperKeyModifiers.default.carbonMask)
    }

    private func publish(_ source: String, into script: ConfigScriptController) async throws {
        let evaluation = try await evaluate(source)
        XCTAssertTrue(script.apply(
            ConfigScriptLoad(versions: [:], result: .success(evaluation)),
            hyperMask: HyperKeyModifiers.default.carbonMask
        ))
    }

    func testModeKeyMatchesSettingsAndChangesPublishOnlyEffectiveEdits() async throws {
        let settings = InputControllerTestSupport.controller(for: self).settings
        settings.hotkeyBindings = []
        var publications: [[HotkeyBinding]] = []
        let script = ConfigScriptController(
            fileURL: settings.settingsFileURL.deletingLastPathComponent()
                .appendingPathComponent("init.luau"),
            settings: settings
        ) { publications.append($0.scriptBindings) }
        let initial = "Shift+F13"
        let replacement = "J"
        let expectedKey = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(initial))
        let expectedChord = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(chord))
        let gui = HotkeyBinding(
            id: palette,
            command: .openCommandPalette,
            trigger: .chord(expectedChord),
            modeKey: expectedKey
        )
        let source = binding(chord, paletteMember, initial)
        try await publish(source, into: script)
        let scriptTable = KeyboardModeTable(bindings: script.effectiveBindings)
        XCTAssertEqual(scriptTable, KeyboardModeTable(bindings: [gui]))
        for state: KeyboardModeInput.State in [.prefix(repeatDeadline: nil), .window] {
            var input = KeyboardModeInput(state: state)
            let decision = input.handleKeyDown(
                keyCode: expectedKey.keyCode, rawFlags: CGEventFlags.maskShift.rawValue,
                isRepeat: false, now: .zero, table: scriptTable
            )
            XCTAssertTrue(decision.consumed)
            XCTAssertEqual(decision.command, gui.command)
        }
        XCTAssertEqual(
            HotkeySettingsDisplayModel.search(initial, scriptBindings: script.acceptedBindings),
            script.acceptedBindings
        )
        try await publish("\n" + source, into: script)
        XCTAssertEqual(publications.count, 1)
        try await publish(binding(chord, paletteMember, replacement), into: script)
        try await publish(binding(chord, paletteMember), into: script)
        let expected: [KeyBinding?] = [expectedKey, try XCTUnwrap(KeySymbolMapper.fromHumanReadable(replacement)), nil]
        XCTAssertEqual(publications.map { $0.first?.modeKey }, expected)
        XCTAssertTrue(settings.hotkeyBindings.isEmpty)
    }

    func testInvalidOptionsAndIneligibleActionsReportTheirDeclaration() async throws {
        let action = "omniwm.cmd.\(paletteMember)()"
        let options = [
            "42",
            "{ mode = 'H' }",
            "{ modeKey = false }",
            "{ modeKey = 'Escape' }",
            "{ modeKey = 'Option+H' }"
        ]
        var invalid = options.map { "omniwm.keymap.set('\(chord)', \(action), \($0))" }
        invalid += [binding(chord, "beginPrefix", "H"), binding("J", paletteMember, "J")]
        for line in invalid {
            do {
                _ = try await evaluate(line)
                XCTFail("Unexpectedly accepted \(line)")
            } catch let error as ConfigScriptError {
                XCTAssertEqual(error.line, 1, line)
                XCTAssertFalse(error.message.isEmpty, line)
            }
        }
    }

    func testScriptLeaderRemainsAssignedOverAnOverlappingSettingsShortcut() async throws {
        let settings = InputControllerTestSupport.controller(for: self).settings
        settings.hotkeyBindings = []
        let file = settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("init.luau")
        let script = ConfigScriptController(fileURL: file, settings: settings) { _ in }
        try await publish(binding(chord, "beginPrefix"), into: script)
        XCTAssertTrue(HotkeySettingsView.hasAssignedModeLeader([], scriptBindings: script.effectiveBindings))
        let key = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(chord))
        let gui = HotkeyBinding(id: palette, command: .openCommandPalette, binding: key)
        let resolution = script.resolveBindings(for: [gui])
        XCTAssertTrue(HotkeySettingsView.hasAssignedModeLeader([gui], scriptBindings: resolution.scriptBindings))
        XCTAssertEqual(resolution.overrides.map(\.bindingID), [gui.id])
    }

    func testScriptModeKeyMasksSettingsAndScriptConflictsStillRetainLastGood() async throws {
        let settings = InputControllerTestSupport.controller(for: self).settings
        settings.hotkeyBindings = []
        let file = settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("init.luau")
        let script = ConfigScriptController(fileURL: file, settings: settings) { _ in }
        let secondKey = "H"
        let expectedKey = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(secondKey))
        let good = binding(chord, paletteMember, secondKey)
        try await publish(good, into: script)
        let accepted = script.effectiveBindings
        let guiMode = HotkeyBinding(id: "gui.mode", command: .focus(.left), trigger: .unassigned, modeKey: expectedKey)
        let guiChord = HotkeyBinding(id: "gui.chord", command: .focus(.left), binding: expectedKey)
        for (owner, field) in [(guiChord, ConfigScriptShortcutOverride.Field.shortcut), (guiMode, .modeKey)] {
            let resolved = script.resolveBindings(for: [owner])
            let entry = KeyboardModeTable.Entry(binding: expectedKey, command: .openCommandPalette)
            XCTAssertEqual(resolved.scriptBindings, accepted)
            XCTAssertEqual(KeyboardModeTable(bindings: resolved.bindings).entries, [entry])
            XCTAssertEqual(resolved.overrides.map(\.bindingID), [owner.id])
            XCTAssertEqual(resolved.overrides.map(\.field), [field])
            XCTAssertTrue(script.resolveBindings(for: []).overrides.isEmpty)
            settings.hotkeyBindings = [owner]
            try await publish(good, into: script)
            XCTAssertNil(script.diagnostic)
            XCTAssertEqual(script.effectiveBindings, accepted)
            XCTAssertEqual(settings.hotkeyBindings, [owner])
        }
        settings.hotkeyBindings = []
        let duplicateMode = binding("Control+Option+K", "rescueOffscreenWindows", secondKey)
        let overlappingShortcut = binding(secondKey, paletteMember)
        for other in [duplicateMode, overlappingShortcut] {
            for source in [[good, other], [other, good]] {
                try await publish(source.joined(separator: "\n"), into: script)
                let diagnostic = try XCTUnwrap(script.diagnostic)
                XCTAssertTrue(diagnostic.contains("init.luau:1"))
                XCTAssertTrue(diagnostic.contains("init.luau:\(source.count):"))
                XCTAssertEqual(script.effectiveBindings, accepted)
            }
        }
    }
}
