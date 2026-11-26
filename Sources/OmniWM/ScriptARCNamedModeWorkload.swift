// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import ScriptARCCounters

@MainActor
func measureNamedModes(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("named-modes"))
    fixture.namedModeMatchRoutes()
    try await fixture.namedModeDeliveryRoutes()
}

@MainActor
extension ScriptARCFixture {
    fileprivate func namedModeMatchRoutes() {
        let hotkeys = controller.hotkeys
        let scalar = KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
        let reference = KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: 0)
        let opened = HotkeyCommand.openApp("com.apple.TextEdit")
        hotkeys.onCommand = { _ in }
        hotkeys.updateBindings(
            [
                HotkeyBinding(id: "audit.scalar", command: .focus(.left), trigger: .unassigned, modeKey: scalar),
                HotkeyBinding(id: "audit.reference", command: opened, trigger: .unassigned, modeKey: reference)
            ],
            systemHyperTrigger: .none
        )
        hotkeys.updateNamedKeyModes(NamedKeyModes([NamedKeyModes.Mode(id: 1, name: "audit", entries: [
            KeyboardModeTable.Entry(binding: scalar, command: .focus(.left)),
            KeyboardModeTable.Entry(binding: reference, command: opened)
        ])]))
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
