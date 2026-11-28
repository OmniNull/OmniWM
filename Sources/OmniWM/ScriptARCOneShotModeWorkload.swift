// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import ScriptARCCounters

@MainActor
func measureOneShotModes(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("one-shot"))
    let hotkeys = fixture.controller.hotkeys
    defer {
        hotkeys.onCommand = nil
        fixture.script.stop()
    }
    try await fixture.measureOneShotModeRoutes()
}

private struct OneShotKeyStep {
    enum Input {
        case press, repeatPress, release
    }

    let input: Input
    let after: KeyboardModeInput.State
    let route: String
    let control: String
    var consumes = true
    var fires = false
}

@MainActor
extension ScriptARCFixture {
    fileprivate func measureOneShotModeRoutes() async throws {
        let hotkeys = controller.hotkeys
        let settings = controller.settings
        settings.systemHyperTrigger = .none
        hotkeys.onKeyboardModeChange = nil
        let source = """
        local wm = omniwm
        wm.keymap.mode("audit-ordinary")
        wm.keymap.mode("audit-once", { oneShot = true })
        local focus = wm.cmd.focusMonitor("next")
        wm.keymap.set("H", focus, { mode = "audit-ordinary" })
        wm.keymap.set("H", focus, { mode = "audit-once" })
        wm.keymap.set("J", focus, { mode = "audit-once", repeatWhileHeld = true })
        wm.keymap.set("K", focus, { mode = "audit-once", onRelease = true })
        """
        let mask = settings.hyperKeyModifiers.carbonMask
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        controller.configScript = script
        guard script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask),
              script.callbackQueue == nil, script.diagnostic == nil
        else { throw ScriptARCError("Cannot install one-shot mode fixture") }
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        let modes = hotkeys.namedKeyModes.modes
        guard let ordinary = modes.firstIndex(where: { $0.name == "audit-ordinary" }),
              let oneShot = modes.firstIndex(where: { $0.name == "audit-once" }),
              !modes[ordinary].oneShot, modes[oneShot].oneShot
        else { throw ScriptARCError("Missing one-shot mode control or treatment") }
        measureOneShotPresses(ordinary: .named(ordinary), oneShot: .named(oneShot))
        measureOneShotHeldKeys(in: .named(oneShot))
        hotkeys.keyboardModeInput.state = .normal
    }

    private func measureOneShotPresses(ordinary: KeyboardModeInput.State, oneShot: KeyboardModeInput.State) {
        let hit = UInt32(kVK_ANSI_H)
        measureOneShotKey(UInt32(kVK_Escape), from: ordinary, steps: [
            OneShotKeyStep(input: .press, after: .normal, route: "oneshot/escape", control: "native")
        ])
        measureOneShotKey(hit, from: ordinary, steps: [
            OneShotKeyStep(
                input: .press,
                after: ordinary,
                route: "oneshot/ordinary-press",
                control: "held/window-press",
                fires: true
            )
        ])
        measureOneShotKey(UInt32(kVK_ANSI_X), from: oneShot, steps: [
            OneShotKeyStep(input: .press, after: oneShot, route: "oneshot/miss", control: "named/miss", consumes: false)
        ])
        measureOneShotKey(hit, from: oneShot, steps: [
            OneShotKeyStep(
                input: .press,
                after: .normal,
                route: "oneshot/press",
                control: "oneshot/ordinary-press",
                fires: true
            )
        ])
    }

    private func measureOneShotHeldKeys(in mode: KeyboardModeInput.State) {
        measureOneShotKey(UInt32(kVK_ANSI_J), from: mode, steps: [
            OneShotKeyStep(
                input: .press,
                after: .normal,
                route: "oneshot/held-press",
                control: "held/named-press",
                fires: true
            ),
            OneShotKeyStep(
                input: .repeatPress,
                after: .normal,
                route: "oneshot/held-repeat",
                control: "held/named-repeat",
                fires: true
            )
        ])
        measureOneShotKey(UInt32(kVK_ANSI_K), from: mode, steps: [
            OneShotKeyStep(input: .press, after: mode, route: "oneshot/release-press", control: "release/named-press"),
            OneShotKeyStep(
                input: .release,
                after: .normal,
                route: "oneshot/release",
                control: "release/named-release",
                fires: true
            )
        ])
    }

    private func measureOneShotKey(_ key: UInt32, from mode: KeyboardModeInput.State, steps: [OneShotKeyStep]) {
        let hotkeys = controller.hotkeys
        for report in [false, true] {
            hotkeys.keyboardModeInput.state = mode
            for step in steps {
                if report {
                    hotkeys.onCommand = { [controller] invocation in
                        precondition(CommandHandler
                            .handleHotkeyInvocation(invocation, controller: controller) == .noChange)
                    }
                } else {
                    let expected = step.after
                    hotkeys.onCommand = { [controller] invocation in
                        precondition(controller.hotkeys.keyboardModeInput.state == expected)
                        precondition(CommandHandler
                            .handleHotkeyInvocation(invocation, controller: controller) == .noChange)
                    }
                }
                let before = controller.userActionCount
                script_arc_begin()
                let consumed = switch step.input {
                case .press: hotkeys.dispatchCommandKeyDown(keyCode: key, rawFlags: 0)
                case .repeatPress: hotkeys.dispatchCommandKeyDown(keyCode: key, rawFlags: 0, isRepeat: true)
                case .release: hotkeys.releaseSuppressedKey(key)
                }
                script_arc_end()
                precondition(consumed == step.consumes && hotkeys.keyboardModeInput.state == step.after)
                precondition(controller.userActionCount == before + (step.fires ? 1 : 0))
                if report { script_arc_report(step.route, step.control, 0) }
            }
            _ = hotkeys.releaseSuppressedKey(key)
        }
    }
}
