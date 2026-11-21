// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteShellWindowSessionTests: XCTestCase {
    private static let process: pid_t = 94_320

    func testUnifiedEmptyQueryDrawsWindowsAfterAClipboardSession() throws {
        let fixture = makeFixture(initialMode: .clipboard)
        defer { fixture.cleanup() }
        let tokens = try addWindows([94_321, 94_322], to: fixture.controller)

        _ = try fixture.show(mode: .clipboard)
        XCTAssertFalse(fixture.palette.isUnifiedSearch)
        XCTAssertTrue(fixture.palette.filteredWindowItems.isEmpty)
        fixture.palette.dismiss(reason: .cancel)

        _ = try fixture.show()
        try assertUnifiedWindows(tokens, fixture: fixture)
    }

    func testASecondUnifiedOpenDrawsTheChangedWindowMembership() throws {
        let fixture = makeFixture(initialMode: .windows)
        defer { fixture.cleanup() }
        let original = try addWindows([94_323, 94_324], to: fixture.controller)

        _ = try fixture.show()
        try assertUnifiedWindows(original, fixture: fixture)
        fixture.palette.dismiss(reason: .cancel)

        let removed = try XCTUnwrap(original.first)
        XCTAssertNotNil(fixture.controller.workspaceManager.removeWindow(pid: removed.pid, windowId: removed.windowId))
        let added = try addWindows([94_325], to: fixture.controller)
        let remaining = Array(original.dropFirst()) + added

        _ = try fixture.show()
        try assertUnifiedWindows(remaining, fixture: fixture)
        let data = fixture.palette.shellData(size: fixture.palette.presentation.shellLayoutSize(expanded: true))
        XCTAssertFalse(data.rows.contains { $0.id == CommandPaletteController.shellRowID(removed) })
    }

    private func makeFixture(initialMode: CommandPaletteMode) -> CommandPaletteFocusFixture {
        let fixture = CommandPaletteFocusFixture(initialMode: initialMode)
        fixture.controller.settings.commandPalette.unifiedSearch = true
        fixture.controller.settings.commandPalette.searchedModes = [.windows]
        return fixture
    }

    private func addWindows(_ ids: [Int], to controller: WMController) throws -> [WindowToken] {
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        return ids.map { id in
            manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(Self.process), windowId: id),
                pid: Self.process,
                windowId: id,
                to: workspace
            )
        }
    }

    private func assertUnifiedWindows(_ tokens: [WindowToken], fixture: CommandPaletteFocusFixture) throws {
        XCTAssertTrue(fixture.palette.isUnifiedSearch)
        XCTAssertEqual(fixture.palette.searchText, "")
        XCTAssertNotNil(fixture.palette.presentation.shell)
        fixture.palette.expandResults()
        let size = fixture.palette.presentation.shellLayoutSize(expanded: true)
        let expected = Set(tokens.map(CommandPaletteController.shellRowID))
        let data = fixture.palette.shellData(size: size)
        XCTAssertEqual(data.state, "results")
        XCTAssertEqual(data.total, tokens.count)
        XCTAssertEqual(Set(data.rows.map(\.id)), expected)
        XCTAssertTrue(data.rows.allSatisfy { $0.kind == .window })
        XCTAssertEqual(Set(fixture.palette.currentSelectionList()), Set(tokens.map(CommandPaletteSelectionID.window)))

        for code in [kVK_DownArrow, kVK_UpArrow] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(code)
            ))
            XCTAssertTrue(fixture.palette.handleKeyDown(event))
            guard case let .window(token)? = fixture.palette.selectedItemID else {
                return XCTFail("An arrow selects a current window")
            }
            XCTAssertTrue(tokens.contains(token))
            let moved = fixture.palette.shellData(size: size)
            let selected = CommandPaletteController.shellRowID(token)
            XCTAssertEqual(moved.selected, selected)
            XCTAssertEqual(moved.rows.filter(\.selected).map(\.id), [selected])
            XCTAssertEqual(Set(moved.rows.map(\.id)), expected)
        }
    }
}
