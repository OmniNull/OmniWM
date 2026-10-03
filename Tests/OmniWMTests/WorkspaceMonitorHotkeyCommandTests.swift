// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

final class WorkspaceMonitorHotkeyCommandTests: XCTestCase {
    func testDirectionalWorkspaceMoveActionsAreRegistered() throws {
        let cases: [(direction: Direction, id: String, title: String)] = [
            (.left, "moveWorkspaceToMonitor.left", "Move Workspace to Monitor on Left"),
            (.right, "moveWorkspaceToMonitor.right", "Move Workspace to Monitor on Right"),
            (.up, "moveWorkspaceToMonitor.up", "Move Workspace to Monitor Above"),
            (.down, "moveWorkspaceToMonitor.down", "Move Workspace to Monitor Below")
        ]

        for entry in cases {
            let command = HotkeyCommand.workspace(.moveWorkspaceToMonitor(entry.direction))
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))

            XCTAssertEqual(spec.id, entry.id)
            XCTAssertEqual(spec.title, entry.title)
            XCTAssertEqual(spec.category, .monitor)
            XCTAssertEqual(spec.visibility, .normal)
            XCTAssertEqual(spec.layoutCompatibility, .shared)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertNil(spec.ipcCommandName)
            XCTAssertNil(spec.ipcDescriptor)
            XCTAssertEqual(HotkeyBindingRegistry.command(for: entry.id), command)

            let searchTerms = Set(spec.searchTerms.map(ActionCatalog.normalizedSearchTerm))
            for term in ["display", "home monitor", "force", "runtime override"] {
                XCTAssertTrue(searchTerms.contains(term))
            }
        }
    }

    func testWorkspaceSlotActionsAreRegistered() throws {
        for slot in ActionCatalog.workspaceSlotRange {
            let cases: [(command: HotkeyCommand, id: String, title: String, ipcName: IPCCommandName)] = [
                (
                    .workspace(.switchSlot(slot)),
                    "switchWorkspaceSlot.\(slot)",
                    "Switch to Workspace Slot \(slot)",
                    .workspace(.switchSlot)
                ),
                (
                    .workspace(.moveToSlot(slot)),
                    "moveToWorkspaceSlot.\(slot)",
                    "Move Focused Window to Workspace Slot \(slot)",
                    .workspace(.moveToSlot)
                )
            ]

            for entry in cases {
                let spec = try XCTUnwrap(ActionCatalog.spec(for: entry.command))

                XCTAssertEqual(spec.id, entry.id)
                XCTAssertEqual(spec.title, entry.title)
                XCTAssertEqual(spec.category, .workspace)
                XCTAssertEqual(spec.layoutCompatibility, .shared)
                XCTAssertEqual(spec.defaultBinding, .unassigned)
                XCTAssertEqual(spec.ipcCommandName, entry.ipcName)
                XCTAssertNotNil(spec.ipcDescriptor)
                XCTAssertEqual(HotkeyBindingRegistry.command(for: entry.id), entry.command)
            }
        }

        let numeric = try XCTUnwrap(ActionCatalog.spec(for: .workspace(.switchTo(0))))
        XCTAssertEqual(numeric.id, "switchWorkspace.0")
        XCTAssertNotEqual(numeric.defaultBinding, .unassigned)
        XCTAssertTrue(SettingsTOMLMigration.hotkeyIDsAddedInVersionTwo.contains("switchWorkspaceSlot.9"))
        XCTAssertTrue(SettingsTOMLMigration.hotkeyIDsAddedInVersionTwo.contains("moveToWorkspaceSlot.1"))
    }

    func testDirectionalWindowMoveActionsAreRegistered() throws {
        let cases: [(direction: Direction, id: String, title: String)] = [
            (.left, "moveWindowToMonitor.left", "Move Focused Window to Monitor on Left"),
            (.right, "moveWindowToMonitor.right", "Move Focused Window to Monitor on Right"),
            (.up, "moveWindowToMonitor.up", "Move Focused Window to Monitor Above"),
            (.down, "moveWindowToMonitor.down", "Move Focused Window to Monitor Below")
        ]

        for entry in cases {
            let command = HotkeyCommand.workspace(.moveToMonitor(entry.direction))
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))

            XCTAssertEqual(spec.id, entry.id)
            XCTAssertEqual(spec.title, entry.title)
            XCTAssertEqual(spec.category, .monitor)
            XCTAssertEqual(spec.visibility, .normal)
            XCTAssertEqual(spec.layoutCompatibility, .shared)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.ipcCommandName, .workspace(.moveToMonitor))
            let descriptor = try XCTUnwrap(spec.ipcDescriptor)
            XCTAssertEqual(descriptor.name, .workspace(.moveToMonitor))
            XCTAssertEqual(descriptor.commandWords, ["move-to-monitor"])
            XCTAssertEqual(descriptor.layoutCompatibility, .shared)
            XCTAssertEqual(HotkeyBindingRegistry.command(for: entry.id), command)

            let searchTerms = Set(spec.searchTerms.map(ActionCatalog.normalizedSearchTerm))
            for term in ["display", "adjacent monitor", "send window", "active workspace", "current workspace"] {
                XCTAssertTrue(searchTerms.contains(term))
            }
        }
    }
}
