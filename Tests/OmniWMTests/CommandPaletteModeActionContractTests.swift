// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

final class CommandPaletteModeActionContractTests: XCTestCase {
    func testPaletteModeActionsAreUnassignedSharedHotkeysWithIPCName() throws {
        let expected: [(IPCCommandPaletteMode, String, String)] = [
            (.windows, "openCommandPalette.windows", "Command Palette: Windows"),
            (.menu, "openCommandPalette.menu", "Command Palette: Menu"),
            (.clipboard, "openCommandPalette.clipboard", "Command Palette: Clipboard"),
            (.commands, "openCommandPalette.commands", "Command Palette: Commands"),
            (.applications, "openCommandPalette.applications", "Command Palette: Applications"),
            (.files, "openCommandPalette.files", "Command Palette: Files")
        ]
        XCTAssertEqual(expected.map(\.0), IPCCommandPaletteMode.allCases)
        for (mode, id, title) in expected {
            let command = HotkeyCommand.openCommandPaletteMode(mode)
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))
            XCTAssertEqual(ActionCatalog.spec(for: id), spec)
            XCTAssertEqual(spec.title, title)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.category, .focus)
            XCTAssertEqual(spec.ipcCommandName, .openCommandPaletteMode)
            XCTAssertEqual(command.layoutCompatibility, .shared)
            XCTAssertTrue(HotkeyBindingRegistry.defaults().contains { $0.id == id && $0.command == command })
        }
    }
}
