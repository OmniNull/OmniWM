// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellToggleHotkeyTests: XCTestCase {
    private final class Names {
        var value = ["controls"]
    }

    private let chord = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey)))

    func testShellToggleActionsResolveForAnyWidgetOrDrawerName() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: "toggleShellWidget.controls"))
        XCTAssertEqual(spec.command, .shellToggle("controls"))
        XCTAssertEqual(spec.title, "Toggle controls")
        XCTAssertEqual(spec.category, .focus)
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertNil(spec.ipcCommandName)
        XCTAssertEqual(HotkeyCommand.shellToggle("controls").layoutCompatibility, .shared)
        XCTAssertEqual(ActionCatalog.spec(for: .shellToggle("controls")), spec)
        for id in ["toggleShellWidget.", "toggleShellWidget.two words", "toggleShell.controls"] {
            XCTAssertNil(ActionCatalog.spec(for: id), id)
        }
        let persisted = [PersistedHotkeyBinding(id: "toggleShellWidget.controls", trigger: chord)]
        let resolved = try HotkeyBindingRegistry.resolve(persisted)
        XCTAssertEqual(resolved.first { $0.id == "toggleShellWidget.controls" }?.binding, chord)
    }

    func testReconcileAddsRowsForShellNamesWithoutEverDroppingAssignedOnes() throws {
        let assigned = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(id: "toggleShellWidget.old", trigger: chord))
        let stale = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(id: "toggleShellWidget.gone", trigger: .unassigned))
        let defaults = HotkeyBindingRegistry.defaults()
        let afterWorkspaces = HotkeyBindingRegistry.reconcilingWorkspaceNumberBindings(
            defaults + [assigned, stale],
            workspaceNames: []
        )
        XCTAssertEqual(Array(afterWorkspaces.suffix(2)), [assigned, stale])

        let bindings = HotkeyBindingRegistry.reconcilingShellToggleBindings(
            afterWorkspaces,
            names: ["media", "controls", "media"]
        )
        XCTAssertEqual(Array(bindings.prefix(defaults.count)), defaults)
        XCTAssertEqual(bindings.dropFirst(defaults.count).map(\.id), [
            "toggleShellWidget.controls", "toggleShellWidget.media", "toggleShellWidget.old"
        ])
        XCTAssertEqual(bindings.last?.binding, chord)
        XCTAssertEqual(
            HotkeyBindingRegistry.reconcilingShellToggleBindings(bindings, names: []).dropFirst(defaults.count),
            [assigned]
        )
    }

    func testSettingsListShellTogglesFromTheLiveNames() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let names = Names()
        var reregistrations = 0
        settings.liveShellNamesForHotkeys = { names.value }
        settings.onDynamicHotkeysChanged = { reregistrations += 1 }
        settings.reconcileDynamicHotkeys()
        XCTAssertEqual(settings.hotkeyBindings.last?.id, "toggleShellWidget.controls")
        XCTAssertEqual(reregistrations, 1)

        settings.updateBinding(for: "toggleShellWidget.controls", newBinding: KeyBinding(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(optionKey)
        ))
        names.value = []
        settings.reconcileDynamicHotkeys()
        XCTAssertEqual(settings.hotkeyBindings.last?.binding, chord)
    }

    func testWidgetsDeclareWhetherTheyHaveAPopout() throws {
        for (source, expected) in [
            ("function render(ctx) return ui.box{} end", false),
            ("function render(ctx) return ui.box{} end\nfunction popout(ctx) return ui.box{} end", true),
            ("popout = 3\nfunction render(ctx) return ui.box{} end", false)
        ] {
            let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
            defer { _ = omni_vm_destroy(vm) }
            var error = [CChar](repeating: 0, count: 256)
            XCTAssertEqual(
                omni_vm_load(vm, "=test", source, source.utf8.count, 100_000_000, &error, error.count),
                OMNI_OK
            )
            XCTAssertEqual(ShellWidgetDeclaration(vm: vm).hasPopout, expected, source)
        }
    }
}
