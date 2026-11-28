// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import ScriptARCCounters

@MainActor
func measureNamedModes(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("named-modes"))
    try await fixture.namedModeMatchRoutes()
    try await fixture.namedModeDeliveryRoutes()
}

@MainActor
extension ScriptARCFixture {
    func resolvePlainKeyControls() throws -> (settings: HotkeyCommand, script: HotkeyCommand) {
        let settings = controller.settings
        guard let native = settings.hotkeyBindings.first else {
            throw ScriptARCError("Missing Settings shortcut")
        }
        let key = try Self.chord(Self.plainChord, mask: settings.hyperKeyModifiers.carbonMask)
        let loser = HotkeyBinding(id: "audit.masked", command: .focus(.left), trigger: .chord(key))
        settings.hotkeyBindings.append(loser)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        let installed = controller.hotkeys.configuration.bindings
        let matches = installed.filter { $0.binding.chordBinding?.conflicts(with: key) == true }
        guard let winner = matches.first, matches.count == 1, winner.id != loser.id,
              installed.contains(native), settings.hotkeyBindings.contains(loser)
        else { throw ScriptARCError("One Flex shortcut must mask the saved Settings chord") }
        return (native.command, winner.command)
    }

    fileprivate func namedModeMatchRoutes() async throws {
        let hotkeys = controller.hotkeys
        let settings = controller.settings
        let scalar = KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
        let reference = KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: 0)
        let opened = HotkeyCommand.openApp("com.apple.TextEdit")
        let loser = HotkeyBinding(id: "audit.masked", command: .focus(.right), trigger: .chord(scalar))
        settings.systemHyperTrigger = .none
        settings.hotkeyBindings = [
            HotkeyBinding(id: "audit.scalar", command: .focus(.left), trigger: .unassigned, modeKey: scalar),
            HotkeyBinding(id: "audit.reference", command: opened, trigger: .unassigned, modeKey: reference),
            loser
        ]
        let source = """
        local wm = omniwm
        wm.keymap.mode("audit")
        wm.keymap.set("\(scalar.humanReadableString)", wm.cmd.focus("left"), { mode = "audit" })
        """
        let mask = settings.hyperKeyModifiers.carbonMask
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        controller.configScript = script
        precondition(script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask))
        precondition(script.callbackQueue == nil && script.diagnostic == nil)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        guard settings.hotkeyBindings.contains(loser),
              !hotkeys.configuration.bindings
                  .contains(where: { $0.binding.chordBinding?.conflicts(with: scalar) == true }),
              let mode = hotkeys.namedKeyModes.modes.first,
              mode.entries.contains(KeyboardModeTable.Entry(binding: scalar, command: .focus(.left)))
        else { throw ScriptARCError("The named mode must mask the saved Settings chord") }
        hotkeys.updateNamedKeyModes(NamedKeyModes([NamedKeyModes.Mode(
            id: mode.id, name: mode.name,
            entries: mode.entries + [KeyboardModeTable.Entry(binding: reference, command: opened)]
        )]))
        hotkeys.onCommand = { _ in }
        press(scalar.keyCode, in: .window, route: "window/hit", control: "window/hit", consumed: true)
        press(scalar.keyCode, in: .named(0), route: "named/hit", control: "window/hit", consumed: true)
        press(reference.keyCode, in: .window, route: "window/ref-hit", control: "window/ref-hit", consumed: true)
        press(reference.keyCode, in: .named(0), route: "named/ref-hit", control: "window/ref-hit", consumed: true)
        press(UInt32(kVK_ANSI_X), in: .named(0), route: "named/miss", control: "window/hit", consumed: false)
        tap(scalar.keyCode, in: .window, prefix: "window")
        tap(scalar.keyCode, in: .named(0), prefix: "named")
        hotkeys.keyboardModeInput.state = .normal
    }

    fileprivate func namedModeDeliveryRoutes() async throws {
        _ = try await acceptTitleScript("""
        local wm = omniwm
        wm.keymap.mode("audit")
        wm.keymap.set("H", function() end, { mode = "audit" })
        wm.keymap.set("Control+Option+K", function() end)
        """)
        controller.updateHotkeyBindings(controller.settings.hotkeyBindings)
        let hotkeys = controller.hotkeys
        let rows = script.acceptedBindings
        guard let named = rows.first(where: { $0.mode != nil }), let global = rows.first(where: { $0.mode == nil }),
              hotkeys.namedKeyModes.modes.count == 1
        else { throw ScriptARCError("The named mode script must publish one mode and one global key") }
        hotkeys.onCommand = { [controller] invocation in
            _ = CommandHandler.handleHotkeyInvocation(invocation, controller: controller)
        }
        for report in [false, true] {
            try await function(global.command, route: "named/luau-control", busy: false, report: report)
        }
        hotkeys.keyboardModeInput.state = .named(0)
        for report in [false, true] {
            script_arc_begin()
            let consumed = hotkeys.handleKeyboardModeKeyDown(keyCode: named.chord.keyCode, rawFlags: 0)
            script_arc_end()
            hotkeys.suppressedHotkeyKeyCodes.remove(named.chord.keyCode)
            precondition(consumed)
            try await finishWorker(seed: false)
            if report { script_arc_report("named/luau", "named/luau-control", 1) }
        }
        hotkeys.keyboardModeInput.state = .normal
    }

    private func press(
        _ keyCode: UInt32,
        in state: KeyboardModeInput.State,
        route: String,
        control: String,
        consumed: Bool
    ) {
        let hotkeys = controller.hotkeys
        hotkeys.keyboardModeInput.state = state
        precondition(hotkeys.handleKeyboardModeKeyDown(keyCode: keyCode, rawFlags: 0) == consumed)
        hotkeys.suppressedHotkeyKeyCodes.remove(keyCode)
        script_arc_begin()
        let result = hotkeys.handleKeyboardModeKeyDown(keyCode: keyCode, rawFlags: 0)
        script_arc_end()
        hotkeys.suppressedHotkeyKeyCodes.remove(keyCode)
        precondition(result == consumed && hotkeys.keyboardModeInput.state == state)
        script_arc_report(route, control, 0)
    }

    private func tap(_ keyCode: UInt32, in state: KeyboardModeInput.State, prefix: String) {
        let hotkeys = controller.hotkeys
        hotkeys.keyboardModeInput.state = state
        precondition(hotkeys.dispatchCommandKeyDown(keyCode: keyCode, rawFlags: 0))
        precondition(hotkeys.releaseSuppressedKey(keyCode))
        script_arc_begin()
        let pressed = hotkeys.dispatchCommandKeyDown(keyCode: keyCode, rawFlags: 0)
        script_arc_end()
        precondition(pressed)
        script_arc_report(prefix + "/tap-press", "window/tap-press", 0)
        script_arc_begin()
        let released = hotkeys.releaseSuppressedKey(keyCode)
        script_arc_end()
        precondition(released && hotkeys.keyboardModeInput.state == state)
        script_arc_report(prefix + "/tap-release", "window/tap-release", 0)
    }
}
