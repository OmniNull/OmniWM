// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptNativePressTests: XCTestCase {
    func testSidedPrefixAndWindowModeMatchesEnterNativeHandlerWithZeroVMEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
        settings.hotkeyBindings = []
        settings.windowSwitcher.enabled = false
        settings.workspaces.configurations = settings.workspaces.configurations.map { $0.with(layoutType: .niri) }
        let missingWorkspace = WorkspaceIDPolicy.lowestUnusedRawID(in: settings.workspaces.configurations.map(\.name))
        let missingIndex = try XCTUnwrap(Int(missingWorkspace)) - 1
        let missingSlot = settings.workspaces.configurations.count + 1
        let inputs: [(words: [String], expected: HotkeyCommand)] = [
            (["switch-workspace", missingWorkspace], .workspace(.switchTo(missingIndex))),
            (["switch-workspace", "anywhere", missingWorkspace], .workspace(.switchAnywhere(missingIndex))),
            (["switch-workspace", "slot", String(missingSlot)], .workspace(.switchSlot(missingSlot))),
            (["move-to-workspace", missingWorkspace], .workspace(.moveTo(missingIndex))),
            (
                ["move-to-workspace", "on-monitor", missingWorkspace, "right"],
                .workspace(.moveToOnMonitor(missingIndex, .right))
            ),
            (["move-to-workspace", "slot", String(missingSlot)], .workspace(.moveToSlot(missingSlot))),
            (["focus-monitor", "next"], .monitorFocus(.next)),
            (["swap-workspace-with-monitor", "right"], .workspace(.swapWithMonitor(.right))),
            (["open-command-palette", "commands"], .openCommandPaletteMode(.commands)),
            (["window-switcher", "next", "all-workspaces"], .windowSwitcher(direction: .next, scope: .allWorkspaces)),
            (["raise-all-floating-windows"], .raiseAllFloatingWindows),
            (["rescue-offscreen-windows"], .rescueOffscreenWindows),
            (["set-workspace-layout", "niri"], .workspace(.setLayout(.niri)))
        ]
        let keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".prefix(inputs.count).map(String.init)
        XCTAssertEqual(keys.count, inputs.count)
        let source = zip(keys, inputs).map { key, input in
            let args = input.words.map { "'\($0)'" }.joined(separator: ", ")
            return "omniwm.keymap.set('Left Option+\(key)', omniwm.cmd(\(args)), { modeKey = '\(key)' })"
        }.joined(separator: "\n")
        let beforeLoad = omni_config_vm_entry_count()
        let mask = settings.hyperKeyModifiers.carbonMask
        let evaluated = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: mask)
        let afterLoad = omni_config_vm_entry_count()
        XCTAssertEqual(afterLoad - beforeLoad, 1)
        XCTAssertEqual(omni_config_live_vm_count(), 0)

        let controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: directory,
            diagnosticsDirectory: directory
        )
        controller.workspaceManager
            .applyMonitorConfigurationChange(Array(controller.workspaceManager.monitors.prefix(1)))
        let center = controller.hotkeys
        let script = ConfigScriptController(
            fileURL: directory.appendingPathComponent("init.luau"),
            settings: settings
        ) {
            controller.updateHotkeyBindings(settings.hotkeyBindings, scriptBindings: $0)
        }
        XCTAssertTrue(script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluated)), hyperMask: mask))
        XCTAssertNil(script.diagnostic)
        let plan = HotkeyCenter.registrationPlan(for: script.effectiveBindings)
        XCTAssertTrue(plan.failures.isEmpty)
        XCTAssertEqual(plan.sideSpecificRegistrations.count, inputs.count)
        center.sideSpecificDispatch = plan.sideSpecificRegistrations.map {
            CommandHotkeyTapMatcher.Entry(binding: $0.binding, command: $0.command)
        }
        center.onKeyboardModeChange = nil
        let route = try XCTUnwrap(center.onCommand)
        var delivered: HotkeyInvocation?
        center.onCommand = { invocation in
            delivered = invocation
            route(invocation)
        }
        let paths: [(state: KeyboardModeInput.State, flags: UInt64)] = [
            (.normal, CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)),
            (.prefix(repeatDeadline: nil), 0),
            (.window, 0)
        ]
        var matches = 0
        for (key, input) in zip(keys, inputs) {
            let keyCode = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(key)).keyCode
            controller.isEnabled = input.expected != .openCommandPaletteMode(.commands)
            for path in paths {
                delivered = nil
                center.keyboardModeInput.state = path.state
                let userActions = controller.userActionCount
                let beforePress = omni_config_vm_entry_count()
                XCTAssertTrue(center.dispatchCommandKeyDown(keyCode: keyCode, rawFlags: path.flags))
                XCTAssertEqual(try XCTUnwrap(delivered).command, input.expected)
                XCTAssertEqual(controller.userActionCount - userActions, controller.isEnabled ? 1 : 0)
                XCTAssertEqual(omni_config_vm_entry_count() - beforePress, 0)
                matches += 1
            }
        }
        XCTAssertEqual(matches, paths.count * inputs.count)
        XCTAssertEqual(omni_config_vm_entry_count() - afterLoad, 0)
        print("Config Luau entries during load=\(afterLoad - beforeLoad), matched presses=\(matches), "
            + "entries during presses=\(omni_config_vm_entry_count() - afterLoad)")
    }
}
