// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import IOKit.hidsystem
import OmniWMScriptHost
import ScriptARCCounters

@MainActor
func measureHeldKeys(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("held-keys"))
    defer { fixture.script.stop() }
    try await fixture.measureHeldKeyRoutes()
}

private struct HeldKeyAuditRoute {
    let name: String
    let control: String?
    let mode: KeyboardModeInput.State
    let firesOnRepeat: Bool

    func report(_ event: String) {
        script_arc_report(name + "-" + event, control.map { $0 + "-" + event } ?? "native", 0)
    }
}

@MainActor
extension ScriptARCFixture {
    fileprivate func measureHeldKeyRoutes() async throws {
        let hotkeys = controller.hotkeys
        let settings = controller.settings
        let mask = settings.hyperKeyModifiers.carbonMask
        let modeChord = "H"
        let sidedChord = "LeftControl+J"
        let modeKey = try Self.chord(modeChord, mask: mask)
        let sidedKey = try Self.chord(sidedChord, mask: mask)
        let sidedFlags = CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK)
        let command = HotkeyCommand.monitorFocus(.next)
        settings.systemHyperTrigger = .none
        settings.hotkeyBindings = [
            HotkeyBinding(id: "audit.window", command: command, trigger: .unassigned, modeKey: modeKey),
            HotkeyBinding(id: "audit.sided", command: command, trigger: .chord(sidedKey))
        ]

        controller.updateHotkeyBindings(settings.hotkeyBindings)
        hotkeys.onCommand = { [controller] invocation in
            precondition(CommandHandler.handleHotkeyInvocation(invocation, controller: controller) == .noChange)
        }
        defer { hotkeys.onCommand = nil }
        installHeldKeySidedMatcher()
        measureNativeHeldKeyRoutes(modeKey, sidedKey: sidedKey, sidedFlags: sidedFlags)

        let source = """
        local wm = omniwm
        wm.keymap.mode("audit")
        wm.keymap.set("\(modeChord)", wm.cmd.focusMonitor("next"), { mode = "audit", repeatWhileHeld = true })
        wm.keymap.set("\(sidedChord)", wm.cmd.focusMonitor("next"), { repeatWhileHeld = true })
        """
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        controller.configScript = script
        precondition(script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask))
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        precondition(script.callbackQueue == nil && script.diagnostic == nil && hotkeys.namedKeyModes.modes.count == 1)
        installHeldKeySidedMatcher()
        measureHeldKey(
            modeKey, flags: 0, through: hotkeys,
            route: .init(name: "held/named", control: "held/window", mode: .named(0), firesOnRepeat: true)
        )
        measureHeldKey(
            sidedKey, flags: sidedFlags, through: hotkeys,
            route: .init(name: "held/sided", control: "held/settings-sided", mode: .normal, firesOnRepeat: true)
        )
        measureUnboundRepeat(sidedKey.keyCode)
    }

    private func measureNativeHeldKeyRoutes(_ modeKey: KeyBinding, sidedKey: KeyBinding, sidedFlags: UInt64) {
        let hotkeys = controller.hotkeys
        let windowHotkeys = HotkeyCenter(now: { .zero })
        windowHotkeys.keyboardModeTable = hotkeys.keyboardModeTable
        windowHotkeys.onCommand = hotkeys.onCommand
        defer { windowHotkeys.onCommand = nil }
        measureHeldKey(
            modeKey, flags: 0, through: windowHotkeys,
            route: .init(name: "held/window", control: nil, mode: .window, firesOnRepeat: false)
        )
        measureHeldKey(
            sidedKey, flags: sidedFlags, through: hotkeys,
            route: .init(name: "held/settings-sided", control: nil, mode: .normal, firesOnRepeat: false)
        )
    }

    private func installHeldKeySidedMatcher() {
        let hotkeys = controller.hotkeys
        let plan = HotkeyCenter.registrationPlan(for: hotkeys.configuration.bindings)
        precondition(plan.sideSpecificRegistrations.count == 1 && plan.failures.isEmpty)
        hotkeys.sideSpecificDispatch = plan.sideSpecificRegistrations.map(\.tapEntry)
    }

    private func measureHeldKey(
        _ key: KeyBinding, flags: UInt64, through hotkeys: HotkeyCenter, route: HeldKeyAuditRoute
    ) {
        for report in [false, true] {
            hotkeys.keyboardModeInput.state = route.mode
            let before = controller.userActionCount
            let vmEntries = omni_config_vm_entry_count()
            script_arc_begin()
            let pressed = hotkeys.dispatchCommandKeyDown(keyCode: key.keyCode, rawFlags: flags)
            script_arc_end()
            precondition(pressed && controller.userActionCount == before + 1)
            precondition(omni_config_vm_entry_count() == vmEntries)
            if report { route.report("press") }

            hotkeys.keyboardModeInput.state = .normal
            script_arc_begin()
            let repeated = hotkeys.dispatchCommandKeyDown(keyCode: key.keyCode, rawFlags: flags, isRepeat: true)
            script_arc_end()
            precondition(repeated && controller.userActionCount == before + (route.firesOnRepeat ? 2 : 1))
            precondition(omni_config_vm_entry_count() == vmEntries)
            if report { route.report("repeat") }

            precondition(hotkeys.releaseSuppressedKey(key.keyCode))
        }
    }

    private func measureUnboundRepeat(_ keyCode: UInt32) {
        let hotkeys = controller.hotkeys
        let before = controller.userActionCount
        let vmEntries = omni_config_vm_entry_count()
        script_arc_begin()
        let consumed = hotkeys.dispatchCommandKeyDown(keyCode: keyCode, rawFlags: 0, isRepeat: true)
        script_arc_end()
        precondition(!consumed && controller.userActionCount == before)
        precondition(omni_config_vm_entry_count() == vmEntries)
        script_arc_report("held/unbound-repeat", "native", 0)
    }
}
