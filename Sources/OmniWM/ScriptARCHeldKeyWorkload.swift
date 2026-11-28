// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
import Foundation
import IOKit.hidsystem
import OmniWMScriptHost
import ScriptARCCounters

@MainActor
func measureHeldKeys(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("held-keys"))
    let hotkeys = fixture.controller.hotkeys
    hotkeys.onCommand = { [controller = fixture.controller] invocation in
        precondition(CommandHandler.handleHotkeyInvocation(invocation, controller: controller) == .noChange)
    }
    defer {
        hotkeys.onCommand = nil
        fixture.script.stop()
    }
    try await fixture.measureHeldKeyRoutes()
    try await fixture.measureReleaseKeyRoutes()
}

private enum HeldKeyAuditChord {
    static let mode = "H"
    static let sided = "LeftControl+J"
    static let sidedFlags = CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK)
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
        let modeChord = HeldKeyAuditChord.mode
        let sidedChord = HeldKeyAuditChord.sided
        let modeKey = try Self.chord(modeChord, mask: mask)
        let sidedKey = try Self.chord(sidedChord, mask: mask)
        let sidedFlags = HeldKeyAuditChord.sidedFlags
        let command = HotkeyCommand.monitorFocus(.next)
        settings.systemHyperTrigger = .none
        settings.hotkeyBindings = [
            HotkeyBinding(id: "audit.window", command: command, trigger: .unassigned, modeKey: modeKey),
            HotkeyBinding(id: "audit.sided", command: command, trigger: .chord(sidedKey))
        ]

        controller.updateHotkeyBindings(settings.hotkeyBindings)
        installHeldKeySidedMatcher()
        measureNativeHeldKeyRoutes(modeKey, sidedKey: sidedKey, sidedFlags: sidedFlags)

        let source = """
        local wm = omniwm
        wm.keymap.mode("audit")
        wm.keymap.set("\(modeChord)", wm.cmd.focusMonitor("next"), { mode = "audit", repeatWhileHeld = true })
        wm.keymap.set("\(sidedChord)", wm.cmd.focusMonitor("next"), { repeatWhileHeld = true })
        """
        try await installHeldKeySource(source, mask: mask)
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

    fileprivate func measureReleaseKeyRoutes() async throws {
        let hotkeys = controller.hotkeys
        let mask = controller.settings.hyperKeyModifiers.carbonMask
        let modeChord = HeldKeyAuditChord.mode
        let sidedChord = HeldKeyAuditChord.sided
        let modeKey = try Self.chord(modeChord, mask: mask)
        let sidedKey = try Self.chord(sidedChord, mask: mask)
        let plainChord = Self.plainChord
        let source = """
        local wm = omniwm
        wm.keymap.mode("audit")
        wm.keymap.set("\(modeChord)", wm.cmd.focusMonitor("next"), { mode = "audit", onRelease = true })
        wm.keymap.set("\(sidedChord)", wm.cmd.focusMonitor("next"), { onRelease = true })
        wm.keymap.set("\(plainChord)", wm.cmd.focusMonitor("next"), { onRelease = true })
        """
        try await installHeldKeySource(source, mask: mask)
        measureHeldKey(
            modeKey, flags: 0, through: hotkeys,
            route: .init(name: "release/named", control: "held/window", mode: .named(0), firesOnRepeat: false),
            firesOnRelease: true
        )
        measureHeldKey(
            sidedKey, flags: HeldKeyAuditChord.sidedFlags, through: hotkeys,
            route: .init(name: "release/sided", control: "held/settings-sided", mode: .normal, firesOnRepeat: false),
            firesOnRelease: true
        )
        measureRetiredRelease(modeKey)
        try measureCarbonReleaseRoutes(mask: mask)
    }

    private func installHeldKeySource(_ source: String, mask: UInt32) async throws {
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        controller.configScript = script
        precondition(script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask))
        controller.updateHotkeyBindings(controller.settings.hotkeyBindings)
        precondition(script.callbackQueue == nil && script.diagnostic == nil)
        precondition(controller.hotkeys.namedKeyModes.modes.count == 1)
        installHeldKeySidedMatcher()
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
        _ key: KeyBinding, flags: UInt64, through hotkeys: HotkeyCenter, route: HeldKeyAuditRoute,
        firesOnRelease: Bool = false
    ) {
        for report in [false, true] {
            hotkeys.keyboardModeInput.state = route.mode
            let before = controller.userActionCount
            let vmEntries = omni_config_vm_entry_count()
            let afterPress = before + (firesOnRelease ? 0 : 1)
            let afterRepeat = afterPress + (route.firesOnRepeat ? 1 : 0)
            script_arc_begin()
            let pressed = hotkeys.dispatchCommandKeyDown(keyCode: key.keyCode, rawFlags: flags)
            script_arc_end()
            precondition(pressed && controller.userActionCount == afterPress)
            precondition(omni_config_vm_entry_count() == vmEntries)
            if report { route.report("press") }

            hotkeys.keyboardModeInput.state = .normal
            script_arc_begin()
            let repeated = hotkeys.dispatchCommandKeyDown(keyCode: key.keyCode, rawFlags: flags, isRepeat: true)
            script_arc_end()
            precondition(repeated && controller.userActionCount == afterRepeat)
            precondition(omni_config_vm_entry_count() == vmEntries)
            if report { route.report("repeat") }

            script_arc_begin()
            let released = hotkeys.releaseSuppressedKey(key.keyCode)
            script_arc_end()
            precondition(released && controller.userActionCount == afterRepeat + (firesOnRelease ? 1 : 0))
            precondition(omni_config_vm_entry_count() == vmEntries)
            if report { route.report("release") }
        }
    }

    private func measureRetiredRelease(_ key: KeyBinding) {
        let hotkeys = controller.hotkeys
        let before = controller.userActionCount
        let vmEntries = omni_config_vm_entry_count()
        hotkeys.keyboardModeInput.state = .named(0)
        precondition(hotkeys.dispatchCommandKeyDown(keyCode: key.keyCode, rawFlags: 0))
        hotkeys.retireHeldBindings()
        hotkeys.keyboardModeInput.state = .normal
        script_arc_begin()
        let consumed = hotkeys.releaseSuppressedKey(key.keyCode)
        script_arc_end()
        precondition(consumed && controller.userActionCount == before)
        precondition(omni_config_vm_entry_count() == vmEntries)
        script_arc_report("release/retired-release", "held/window-release", 0)
    }

    private func measureCarbonReleaseRoutes(mask: UInt32) throws {
        let hotkeys = controller.hotkeys
        let plan = HotkeyCenter.registrationPlan(for: hotkeys.configuration.bindings)
        guard let release = plan.registrations.first(where: \.onRelease) else {
            throw ScriptARCError("Missing release shortcut")
        }
        let chord = try Self.chord("Control+Option+I", mask: mask)
        let owner = hotkeys.carbonRegistrations
        let controlID = chord.keyCode
        let releaseID = release.binding.keyCode
        precondition(controlID != releaseID)
        owner.recordRegistration(.init(binding: chord, command: release.command), id: controlID)
        measureCarbonKey(controlID, name: "release/carbon-native", control: nil, firesOnRelease: false)
        owner.recordRegistration(release, id: releaseID)
        measureCarbonKey(
            controlID, name: "release/carbon-mixed", control: "release/carbon-native", firesOnRelease: false
        )
        measureCarbonKey(releaseID, name: "release/carbon", control: "release/carbon-mixed", firesOnRelease: true)
    }

    private func measureCarbonKey(_ id: UInt32, name: String, control: String?, firesOnRelease: Bool) {
        let hotkeys = controller.hotkeys
        let press = UInt32(kEventHotKeyPressed)
        let release = UInt32(kEventHotKeyReleased)
        let events = [
            ("press", press, !firesOnRelease),
            ("repeat", press, !firesOnRelease),
            ("release", release, firesOnRelease)
        ]
        for report in [false, true] {
            for (event, kind, fires) in events {
                let before = controller.userActionCount
                let vmEntries = omni_config_vm_entry_count()
                script_arc_begin()
                hotkeys.handleCarbonHotkey(id: id, kind: kind)
                script_arc_end()
                precondition(controller.userActionCount == before + (fires ? 1 : 0))
                precondition(omni_config_vm_entry_count() == vmEntries)
                if report { script_arc_report(name + "-" + event, control.map { $0 + "-" + event } ?? "native", 0) }
            }
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
