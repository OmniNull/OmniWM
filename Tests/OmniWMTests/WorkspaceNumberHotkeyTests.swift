// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceNumberHotkeyTests: XCTestCase {
    func testCatalogResolvesActionsForWorkspacesAboveNine() throws {
        let switchSpec = try XCTUnwrap(ActionCatalog.spec(for: "switchWorkspace.9"))
        XCTAssertEqual(switchSpec.command, .workspace(.switchTo(9)))
        XCTAssertEqual(switchSpec.title, "Switch to Workspace 10")
        XCTAssertEqual(switchSpec.category, .workspace)
        XCTAssertEqual(switchSpec.defaultBinding, .unassigned)

        XCTAssertEqual(ActionCatalog.spec(for: .workspace(.moveTo(11)))?.id, "moveToWorkspace.11")
        XCTAssertEqual(ActionCatalog.spec(for: .column(.moveToWorkspace(9)))?.id, "moveColumnToWorkspace.9")
        XCTAssertEqual(HotkeyCommand.workspace(.switchTo(9)).displayName, "Switch to Workspace 10")
    }

    func testCatalogRejectsMalformedWorkspaceActionIDs() {
        for id in ["switchWorkspace.09", "switchWorkspace.-1", "switchWorkspace.x", "focusWorkspace.12"] {
            XCTAssertNil(ActionCatalog.spec(for: id), id)
        }
        XCTAssertNil(ActionCatalog.spec(for: "switchWorkspace.\(Int.max)"))
    }

    func testReconcileAddsUnassignedRowsForConfiguredWorkspacesAboveNine() {
        let bindings = HotkeyBindingRegistry.reconcilingWorkspaceNumberBindings(
            HotkeyBindingRegistry.defaults(),
            workspaceNames: ["1", "12", "10"]
        )

        let ids = bindings.map(\.id)
        XCTAssertEqual(ids.count, HotkeyBindingRegistry.defaults().count + 6)
        XCTAssertEqual(ids.rows(after: "moveToWorkspace.8", count: 4), [
            "switchWorkspace.9", "moveToWorkspace.9", "switchWorkspace.11", "moveToWorkspace.11"
        ])
        XCTAssertEqual(ids.rows(after: "moveColumnToWorkspace.8", count: 2), [
            "moveColumnToWorkspace.9", "moveColumnToWorkspace.11"
        ])
        let added = bindings.filter { HotkeyBindingRegistry.defaults().map(\.id).contains($0.id) == false }
        XCTAssertTrue(added.allSatisfy(\.binding.isUnassigned))
    }

    func testReconcileKeepsAssignedRowsAndDropsRowsOfRemovedWorkspaces() throws {
        let chord = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(optionKey)))
        let assigned = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(id: "switchWorkspace.9", trigger: chord))
        let stale = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(id: "switchWorkspace.14", trigger: chord))

        let bindings = HotkeyBindingRegistry.reconcilingWorkspaceNumberBindings(
            HotkeyBindingRegistry.defaults() + [stale, assigned],
            workspaceNames: ["10"]
        )

        XCTAssertEqual(bindings.first { $0.id == "switchWorkspace.9" }?.binding, chord)
        XCTAssertNil(bindings.first { $0.id == "switchWorkspace.14" })
    }

    func testTOMLAcceptsWorkspaceActionsAboveNineAndDoesNotRequireThem() throws {
        var export = SettingsExport.defaults()
        let chord = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(optionKey)))
        try export.hotkeyBindings.append(XCTUnwrap(
            HotkeyBindingRegistry.makeBinding(id: "switchWorkspace.9", trigger: chord)
        ))

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        XCTAssertEqual(decoded.hotkeyBindings.first { $0.id == "switchWorkspace.9" }?.binding, chord)

        let withoutDynamic = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(.defaults()))
        XCTAssertEqual(withoutDynamic.hotkeyBindings, HotkeyBindingRegistry.defaults())
    }

    func testSettingsStoreAddsRowsWhenWorkspaceIsCreatedAndDropsThemWhenRemoved() throws {
        let settings = makeSettingsStore()
        let original = settings.workspaces.configurations
        settings.workspaces.configurations = original + [
            WorkspaceConfiguration(id: UUID(), name: "10", monitorAssignment: .main, layoutType: .niri)
        ]
        XCTAssertNotNil(settings.hotkeyBindings.first { $0.id == "moveToWorkspace.9" })

        let chord = KeyBinding(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(optionKey))
        settings.updateBinding(for: "switchWorkspace.9", newBinding: chord)
        XCTAssertEqual(settings.hotkeyBindings.first { $0.id == "switchWorkspace.9" }?.binding, .chord(chord))

        settings.resetBindings(for: "switchWorkspace.9")
        XCTAssertEqual(settings.hotkeyBindings.first { $0.id == "switchWorkspace.9" }?.binding, .unassigned)

        settings.workspaces.configurations = original
        XCTAssertNil(settings.hotkeyBindings.first { $0.id == "switchWorkspace.9" })
    }

    func testDynamicWorkspaceKeepsHotkeysUntilItIsRemoved() throws {
        let settings = makeSettingsStore()
        let manager = WorkspaceManager(settings: settings)
        let monitor = try XCTUnwrap(manager.monitors.first)
        var reregistrations = 0
        settings.onDynamicHotkeysChanged = { reregistrations += 1 }

        let workspace = try XCTUnwrap(manager.createDynamicWorkspace(named: "10", on: monitor.id))
        XCTAssertFalse(settings.workspaces.configuredNames().contains("10"))
        for id in ["switchWorkspace.9", "moveToWorkspace.9", "moveColumnToWorkspace.9"] {
            XCTAssertNotNil(settings.hotkeyBindings.first { $0.id == id })
        }
        XCTAssertEqual(reregistrations, 1)

        let chord = KeyBinding(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(optionKey))
        settings.updateBinding(for: "switchWorkspace.9", newBinding: chord)
        settings.workspaces.defaultLayoutType = .dwindle
        XCTAssertEqual(settings.hotkeyBindings.first { $0.id == "switchWorkspace.9" }?.binding, .chord(chord))
        XCTAssertEqual(reregistrations, 1)

        manager.removeWorkspaces([workspace.id])
        XCTAssertNil(settings.hotkeyBindings.first { $0.id == "switchWorkspace.9" })
        XCTAssertEqual(reregistrations, 2)
    }

    func testRemovingWorkspaceRequestsHotkeyReregistrationOutsideExportApply() {
        let settings = makeSettingsStore()
        var reregistrations = 0
        settings.onDynamicHotkeysChanged = { reregistrations += 1 }
        let original = settings.workspaces.configurations
        let withTen = original + [WorkspaceConfiguration(name: "10")]

        settings.workspaces.configurations = withTen
        XCTAssertEqual(reregistrations, 1)
        settings.workspaces.configurations = withTen
        XCTAssertEqual(reregistrations, 1)
        settings.workspaces.configurations = original
        XCTAssertEqual(reregistrations, 2)

        var export = settings.toExport()
        export.workspaceConfigurations = withTen
        settings.applyExport(export)
        XCTAssertEqual(reregistrations, 2)
        XCTAssertNotNil(settings.hotkeyBindings.first { $0.id == "switchWorkspace.9" })
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceNumberHotkeyTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
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
    }
}

private extension [String] {
    func rows(after id: String, count: Int) -> [String] {
        guard let index = firstIndex(of: id) else { return [] }
        return Array(dropFirst(index + 1).prefix(count))
    }
}
