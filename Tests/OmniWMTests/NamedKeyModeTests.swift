// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NamedKeyModeTests: XCTestCase {
    private let keyH = UInt32(kVK_ANSI_H)
    private let keyL = UInt32(kVK_ANSI_L)
    private let keyX = UInt32(kVK_ANSI_X)
    private let keyEscape = UInt32(kVK_Escape)
    private let shift = CGEventFlags.maskShift.rawValue
    private let resizeKeys = "local resize = omniwm.keymap.mode('resize')\n"
        + "omniwm.keymap.set('H', omniwm.cmd.focus('left'), { mode = 'resize' })\n"

    private func key(_ code: UInt32, modifiers: Int = 0) -> KeyBinding {
        KeyBinding(keyCode: code, modifiers: UInt32(modifiers))
    }

    private func modes() -> NamedKeyModes {
        NamedKeyModes([
            NamedKeyModes.Mode(id: 1, name: "resize", entries: [
                KeyboardModeTable.Entry(binding: key(keyH), command: .focus(.left)),
                KeyboardModeTable.Entry(binding: key(keyH, modifiers: shiftKey), command: .focus(.up))
            ]),
            NamedKeyModes.Mode(id: 2, name: "move", entries: [
                KeyboardModeTable.Entry(binding: key(keyH), command: .move(.left))
            ])
        ])
    }

    private func evaluate(_ source: String) async throws -> ConfigScriptEvaluation {
        try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: HyperKeyModifiers.default.carbonMask)
    }

    private func refusal(_ source: String) async -> String? {
        do {
            _ = try await evaluate(source)
            return nil
        } catch let error as ConfigScriptError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    private func script(for controller: WMController) -> ConfigScriptController {
        let script = ConfigScriptController(
            fileURL: controller.settings.settingsFileURL.deletingLastPathComponent()
                .appendingPathComponent("init.luau"),
            settings: controller.settings,
            wmController: controller
        ) { [weak controller] resolution in
            guard let controller else { return }
            controller.updateHotkeyBindings(controller.settings.hotkeyBindings, scriptResolution: resolution)
        }
        controller.configScript = script
        return script
    }

    private func publish(_ source: String, into script: ConfigScriptController) async throws {
        let evaluation = try await evaluate(source)
        XCTAssertTrue(script.apply(
            ConfigScriptLoad(versions: [:], result: .success(evaluation)),
            hyperMask: HyperKeyModifiers.default.carbonMask
        ))
    }

    func testEachModeGivesTheSameKeyItsOwnCommand() {
        let modes = modes()
        for (index, expected) in [(0, HotkeyCommand.focus(.left)), (1, .move(.left))] {
            var input = KeyboardModeInput(state: .named(index))
            let decision = input.handleNamedKeyDown(keyCode: keyH, rawFlags: 0, mode: index, in: modes)
            XCTAssertEqual(decision, KeyboardModeInput.Decision(consumed: true, command: expected))
            XCTAssertEqual(input.state, .named(index))
        }
        var input = KeyboardModeInput(state: .named(0))
        XCTAssertEqual(
            input.handleNamedKeyDown(keyCode: keyH, rawFlags: shift, mode: 0, in: modes),
            KeyboardModeInput.Decision(consumed: true, command: .focus(.up))
        )
        XCTAssertEqual(
            input.handleNamedKeyDown(keyCode: keyH, rawFlags: CGEventFlags.maskAlphaShift.rawValue, mode: 0, in: modes),
            KeyboardModeInput.Decision(consumed: true, command: .focus(.left))
        )
    }

    func testUnboundKeysAndCommandChordsPassThroughAndEscapeLeaves() {
        let modes = modes()
        var input = KeyboardModeInput(state: .named(1))
        XCTAssertEqual(input.handleNamedKeyDown(keyCode: keyX, rawFlags: 0, mode: 1, in: modes), .init())
        XCTAssertEqual(input.handleNamedKeyDown(keyCode: keyH, rawFlags: shift, mode: 1, in: modes), .init())
        for flag in [CGEventFlags.maskCommand, .maskControl, .maskAlternate] {
            XCTAssertEqual(
                input.handleNamedKeyDown(keyCode: keyH, rawFlags: flag.rawValue, mode: 1, in: modes),
                .init()
            )
        }
        XCTAssertEqual(input.state, .named(1))
        XCTAssertTrue(input.capturesKeys)
        XCTAssertEqual(input.kind, .named)
        XCTAssertEqual(
            input.handleNamedKeyDown(keyCode: keyEscape, rawFlags: shift, mode: 1, in: modes),
            KeyboardModeInput.Decision(consumed: true)
        )
        XCTAssertEqual(input.state, .normal)
    }

    func testTheTableAcceptsOnlyPlainOrShiftedKeysAndValidNames() {
        XCTAssertNotNil(NamedKeyModes.slot(for: key(keyH, modifiers: shiftKey)))
        XCTAssertNil(NamedKeyModes.slot(for: key(keyH, modifiers: controlKey)))
        XCTAssertNil(NamedKeyModes.slot(for: key(keyEscape)))
        for modifier in [kVK_Shift, kVK_RightShift, kVK_Control, kVK_Option, kVK_Command, kVK_CapsLock, kVK_Function] {
            XCTAssertNil(NamedKeyModes.slot(for: key(UInt32(modifier))), "\(modifier)")
        }
        XCTAssertNil(modes().command(in: 0, keyCode: UInt32(UInt8.max), rawFlags: 0))
        for name in ["resize", "a", "move-2", "x_y", String(repeating: "m", count: NamedKeyModes.nameLimit)] {
            XCTAssertTrue(NamedKeyModes.isValidName(name), name)
        }
        for name in [
            "",
            "Resize",
            "2fast",
            "a b",
            "window",
            "normal",
            "paused",
            "prefix",
            String(repeating: "m", count: NamedKeyModes.nameLimit + 1)
        ] {
            XCTAssertFalse(NamedKeyModes.isValidName(name), name)
        }
    }

    func testEnteringNeedsACurrentModeAndCaptureAndANewTableLeavesIt() {
        let center = HotkeyCenter()
        center.start()
        defer { center.stop() }
        center.updateNamedKeyModes(modes())
        XCTAssertEqual(center.enterNamedKeyMode(Int.max), .refused)
        center.isKeyboardModeArmingBlocked = { true }
        XCTAssertEqual(center.enterNamedKeyMode(2), .refused)
        center.isKeyboardModeArmingBlocked = { false }
        let captureAvailable = center.hyperTriggerTap != nil
        XCTAssertEqual(center.enterNamedKeyMode(2), captureAvailable ? .entered : .refused)
        XCTAssertEqual(center.enterNamedKeyMode(2), captureAvailable ? .alreadyActive : .refused)
        center.keyboardModeInput.state = .named(1)
        XCTAssertEqual(center.activeNamedKeyMode?.name, "move")
        XCTAssertEqual(center.keyboardModeKind, .named)
        center.updateNamedKeyModes(NamedKeyModes())
        XCTAssertEqual(center.keyboardModeKind, .normal)
        XCTAssertNil(center.activeNamedKeyMode)
    }

    func testAnExitKeyInAModeLeavesBeforeTheNextKeyArrives() {
        let keyQ = UInt32(kVK_ANSI_Q)
        let center = HotkeyCenter()
        var routed: [HotkeyCommand] = []
        center.onCommand = { routed.append($0.command) }
        center.updateNamedKeyModes(NamedKeyModes([NamedKeyModes.Mode(id: 1, name: "move", entries: [
            KeyboardModeTable.Entry(binding: key(keyQ), command: .keyboardMode(.exit)),
            KeyboardModeTable.Entry(binding: key(keyH), command: .move(.left))
        ])]))
        center.keyboardModeInput.state = .named(0)
        XCTAssertTrue(center.dispatchCommandKeyDown(keyCode: keyQ, rawFlags: 0))
        XCTAssertEqual(center.keyboardModeKind, .normal)
        XCTAssertFalse(center.dispatchCommandKeyDown(keyCode: keyH, rawFlags: 0))
        XCTAssertEqual(routed, [])
    }

    func testAnEntryShortcutRoutesInsideTheHotkeyOwner() {
        let center = HotkeyCenter()
        var routed: [HotkeyCommand] = []
        center.onCommand = { routed.append($0.command) }
        center.updateNamedKeyModes(modes())
        center.routeHotkeyInvocation(HotkeyInvocation(command: .namedKeyMode(1)))
        center.routeHotkeyInvocation(HotkeyInvocation(command: .focus(.left)))
        XCTAssertEqual(routed, [.focus(.left)])
    }

    func testTheScriptDeclaresModesAndTheirKeys() async throws {
        let evaluation = try await evaluate(resizeKeys + """
        local move = omniwm.keymap.mode('move')
        omniwm.keymap.set('Control+Option+Shift+Y', resize)
        omniwm.keymap.set('H', omniwm.cmd.move('left'), { mode = 'move' })
        omniwm.keymap.set('Shift+L', function() end, { mode = 'move', reads = { 'windows' } })
        """)
        XCTAssertEqual(evaluation.namedModes.map(\.name), ["resize", "move"])
        let ids = evaluation.namedModes.map(\.id)
        let entry = try XCTUnwrap(evaluation.bindings.first { $0.mode == nil })
        XCTAssertEqual(entry.command, .namedKeyMode(ids[0]))
        let named = evaluation.bindings.filter { $0.mode != nil }
        XCTAssertEqual(named.map(\.mode), [ids[0], ids[1], ids[1]])
        XCTAssertEqual(named.map(\.modeName), ["resize", "move", "move"])
        XCTAssertEqual(named.map(\.chord), [key(keyH), key(keyH), key(keyL, modifiers: shiftKey)])
        XCTAssertEqual(named.last?.reads, [.windows])
    }

    func testDeclarationErrorsNameTheProblem() async {
        let cases: [(String, String)] = [
            ("omniwm.keymap.set('H', omniwm.cmd.focus('left'), { mode = 'resize' })", "isn't declared"),
            ("omniwm.keymap.mode('Resize')", "lowercase"),
            ("omniwm.keymap.mode('window')", "can't be normal, paused, prefix or window"),
            ("omniwm.keymap.mode('resize') omniwm.keymap.mode('resize')", "already declared"),
            (resizeKeys + "omniwm.keymap.set('H', omniwm.cmd.focus('right'), { mode = 'resize' })", "already bound"),
            (resizeKeys + "omniwm.keymap.set('Escape', omniwm.cmd.focus('right'), { mode = 'resize' })", "one key"),
            (
                resizeKeys + "omniwm.keymap.set('Control+L', omniwm.cmd.focus('right'), { mode = 'resize' })",
                "one key"
            ),
            (
                resizeKeys + "omniwm.keymap.set('L', omniwm.cmd.focus('right'), { mode = 'resize', modeKey = 'J' })",
                "modeKey or mode, not both"
            ),
            ("omniwm.keymap.mode('idle')", "has no keys"),
            (
                resizeKeys + "omniwm.keymap.set('LeftShift', omniwm.cmd.focus('right'), { mode = 'resize' })",
                "one key"
            )
        ]
        for (source, expected) in cases {
            let message = await refusal(source)
            XCTAssertTrue(message?.contains(expected) == true, "\(source): \(message ?? "accepted")")
        }
    }

    func testModeAndKeyLimitsComeFromTheTable() async {
        let modes = (0 ... NamedKeyModes.modeLimit).map { index in
            "omniwm.keymap.mode('m\(index)') omniwm.keymap.set('H', omniwm.cmd.focus('left'), { mode = 'm\(index)' })"
        }
        let tooMany = await refusal(modes.joined(separator: "\n"))
        XCTAssertTrue(tooMany?.contains("at most \(NamedKeyModes.modeLimit) modes") == true, tooMany ?? "accepted")
        let plain = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init)
        let names = plain + plain.map { "Shift+" + $0 }
        XCTAssertGreaterThan(names.count, NamedKeyModes.keyLimit)
        let keys = names.prefix(NamedKeyModes.keyLimit + 1).map {
            "omniwm.keymap.set('\($0)', omniwm.cmd.focus('left'), { mode = 'many' })"
        }
        let full = await refusal("omniwm.keymap.mode('many')\n" + keys.joined(separator: "\n"))
        XCTAssertTrue(full?.contains("at most \(NamedKeyModes.keyLimit) keys") == true, full ?? "accepted")
    }

    func testPublishingHandsTheTablesToTheHotkeyOwnerAndAReloadLeavesTheMode() async throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let script = script(for: controller)
        try await publish(resizeKeys, into: script)
        let modes = controller.hotkeys.namedKeyModes.modes
        XCTAssertEqual(modes.map(\.name), ["resize"])
        XCTAssertEqual(modes.first?.entries, [KeyboardModeTable.Entry(binding: key(keyH), command: .focus(.left))])
        controller.hotkeys.keyboardModeInput.state = .named(0)
        XCTAssertEqual(controller.keyboardModeName, "resize")
        try await publish(resizeKeys, into: script)
        XCTAssertEqual(controller.hotkeys.keyboardModeKind, .normal)
        XCTAssertNotEqual(controller.hotkeys.namedKeyModes.modes.first?.id, modes.first?.id)
        script.stop()
        XCTAssertTrue(controller.hotkeys.namedKeyModes.isEmpty)
    }

    func testTheRecipeLoadsOverTheDefaultShortcuts() async throws {
        let controller = InputControllerTestSupport.controller(for: self)
        controller.settings.hotkeyBindings = DefaultHotkeyBindings.all()
        let script = script(for: controller)
        try await publish(ConfigScriptWindowFixture.recipe("Resize and move with the same keys"), into: script)
        XCTAssertNil(controller.settings.configScriptLoadError)
        let modes = controller.hotkeys.namedKeyModes
        XCTAssertEqual(modes.modes.map(\.name), ["resize", "move"])
        XCTAssertEqual(modes.modes.map(\.entries.count), [2, 3])
        let resize = modes.command(in: 0, keyCode: keyH, rawFlags: 0)
        let move = modes.command(in: 1, keyCode: keyH, rawFlags: 0)
        XCTAssertNotNil(resize)
        XCTAssertEqual(move, .move(.left))
        XCTAssertNotEqual(resize, move)
    }

    func testANamedModeKeyMasksAnOverlappingSettingsShortcut() async throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let script = script(for: controller)
        let name = "resize"
        let chord = "Shift+H"
        let lines = [
            "omniwm.keymap.mode('\(name)')",
            "omniwm.keymap.set('\(chord)', omniwm.cmd.focus('left'), { mode = '\(name)' })"
        ]
        let winner = KeyboardModeTable.Entry(binding: key(keyH, modifiers: shiftKey), command: .focus(.left))
        for savedChord in [chord, "Left\(chord)"] {
            let trigger = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(savedChord))
            let saved = HotkeyBinding(id: "focus.right", command: .focus(.right), binding: trigger)
            controller.settings.hotkeyBindings = [saved]
            try await publish(lines.joined(separator: "\n"), into: script)
            let mode = try XCTUnwrap(controller.hotkeys.namedKeyModes.modes.first)
            XCTAssertEqual(mode.name, name)
            XCTAssertEqual(mode.entries, [winner])
            XCTAssertNil(controller.settings.configScriptLoadError)
            XCTAssertEqual(controller.settings.hotkeyBindings, [saved])
            XCTAssertNil(controller.hotkeys.configuration.bindings.first { $0.id == saved.id }?.binding.chordBinding)
            let conflict = try XCTUnwrap(controller.settings.configScriptShortcutConflicts)
            XCTAssertEqual(conflict.overrides.map(\.bindingID), [saved.id])
            XCTAssertEqual(conflict.overrides.map(\.field), [.shortcut])
            XCTAssertEqual(conflict.overrides.map(\.line), [lines.count])
            XCTAssertEqual(conflict.overrides.map(\.modeName), [name])
        }
    }

    func testALaterSettingsShortcutIsMaskedAndBothModesKeepTheirKey() async throws {
        let controller = InputControllerTestSupport.controller(for: self)
        controller.settings.hotkeyBindings = []
        let script = script(for: controller)
        try await publish(
            resizeKeys
                + "omniwm.keymap.set('L', omniwm.cmd.focus('right'), { mode = 'resize' })\n"
                + "local move = omniwm.keymap.mode('move')\n"
                + "omniwm.keymap.set('H', omniwm.cmd.move('left'), { mode = 'move' })",
            into: script
        )
        let modes = controller.hotkeys.namedKeyModes
        let resize = try XCTUnwrap(modes.modes.first { $0.name == "resize" })
        let move = try XCTUnwrap(modes.modes.first { $0.name == "move" })
        let resizeIndex = try XCTUnwrap(modes.index(of: resize.id))
        let moveIndex = try XCTUnwrap(modes.index(of: move.id))
        let saved = HotkeyBinding(id: "focus.up", command: .focus(.up), binding: key(keyH))
        controller.hotkeys.keyboardModeInput.state = .named(resizeIndex)
        controller.settings.hotkeyBindings = [saved]
        controller.updateHotkeyBindings(controller.settings.hotkeyBindings)
        XCTAssertEqual(controller.hotkeys.namedKeyModes, modes)
        XCTAssertEqual(modes.command(in: resizeIndex, keyCode: keyH, rawFlags: 0), .focus(.left))
        XCTAssertEqual(modes.command(in: moveIndex, keyCode: keyH, rawFlags: 0), .move(.left))
        XCTAssertEqual(controller.settings.hotkeyBindings, [saved])
        XCTAssertNil(controller.hotkeys.configuration.bindings.first { $0.id == saved.id }?.binding.chordBinding)
        XCTAssertEqual(controller.settings.configScriptShortcutConflicts?.overrides.map(\.bindingID), [saved.id])
        XCTAssertNil(script.diagnostic)
        XCTAssertEqual(controller.keyboardModeName, "resize")
        controller.settings.hotkeyBindings = []
        controller.updateHotkeyBindings(controller.settings.hotkeyBindings)
        XCTAssertNil(controller.settings.configScriptShortcutConflicts)
        XCTAssertEqual(controller.hotkeys.namedKeyModes, modes)
        XCTAssertEqual(controller.keyboardModeName, "resize")
    }

    func testAnEntryThatCannotArmStopsTheCallbackAtItsLine() async throws {
        let display = NiriGatherFixture.monitor(displayId: 1)
        let base = try NiriGatherFixture(
            prefix: "named-mode-entry", monitors: [display],
            workspaces: [.init(name: "1", monitor: display), .init(name: "2", monitor: display)]
        )
        let fixture = ConfigScriptWindowFixture(base: base)
        XCTAssertTrue(base.manager.setActiveWorkspace(base.workspace("1"), on: display.id))
        let lines = resizeKeys.split(separator: "\n").count
        try await fixture.load(resizeKeys + """
        omniwm.command('Enter', function()
            omniwm.dispatch(resize)
            omniwm.dispatch(omniwm.cmd.switchWorkspace('2'))
        end)
        """)
        XCTAssertFalse(base.controller.hotkeys.namedKeyModes.isEmpty)
        let enter = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == "Enter" }?.function)
        XCTAssertEqual(
            base.controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: .configFunction(enter))),
            .executed
        )
        await fixture.script.callbackQueue?.waitUntilParked()
        let diagnostic = try XCTUnwrap(fixture.script.diagnostic)
        XCTAssertTrue(
            diagnostic.contains("init.luau:\(lines + 2): Key mode: keys can't be captured now"),
            diagnostic
        )
        XCTAssertEqual(base.controller.hotkeys.keyboardModeKind, .normal)
        XCTAssertEqual(base.manager.activeWorkspace(on: display.id)?.id, base.workspace("1"))
    }

    func testANamedModeKeyOverlappingAScriptGlobalShortcutStillRejectsTheReload() async throws {
        let controller = InputControllerTestSupport.controller(for: self)
        controller.settings.hotkeyBindings = []
        let script = script(for: controller)
        try await publish(resizeKeys, into: script)
        let originalModes = controller.hotkeys.namedKeyModes
        try await publish(
            resizeKeys + "omniwm.keymap.set('H', omniwm.cmd.focus('right'))",
            into: script
        )
        XCTAssertTrue(controller.settings.configScriptLoadError?.contains("in a mode conflicts with") == true)
        XCTAssertEqual(controller.hotkeys.namedKeyModes, originalModes)
        XCTAssertTrue(controller.hotkeys.configuration.bindings.isEmpty)
        XCTAssertNil(controller.settings.configScriptShortcutConflicts)
    }
}
