// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class CommandPaletteControllerTests: XCTestCase {
    func testTabCyclesForwardAndWrapsAcrossAvailableModes() {
        let transitions: [(CommandPaletteMode, CommandPaletteMode)] = [
            (.windows, .menu),
            (.menu, .clipboard),
            (.clipboard, .commands),
            (.commands, .applications),
            (.applications, .files),
            (.files, .windows)
        ]

        for (currentMode, expectedMode) in transitions {
            XCTAssertEqual(
                modeNavigationTarget(currentMode: currentMode),
                expectedMode
            )
        }
    }

    func testShiftTabCyclesBackwardAndWrapsAcrossAvailableModes() {
        let transitions: [(CommandPaletteMode, CommandPaletteMode)] = [
            (.windows, .files),
            (.menu, .windows),
            (.clipboard, .menu),
            (.commands, .clipboard),
            (.applications, .commands),
            (.files, .applications)
        ]

        for (currentMode, expectedMode) in transitions {
            XCTAssertEqual(
                modeNavigationTarget(currentMode: currentMode, modifiers: .shift),
                expectedMode
            )
        }
    }

    func testCycleSkipsUnavailableMenuAndIncludesLauncherModes() {
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .windows, isMenuModeAvailable: false),
            .clipboard
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .clipboard, isMenuModeAvailable: false),
            .commands
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .commands, isMenuModeAvailable: false),
            .applications
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .applications, isMenuModeAvailable: false),
            .files
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .files, isMenuModeAvailable: false),
            .windows
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .windows, isMenuModeAvailable: false, modifiers: .shift),
            .files
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .files, isMenuModeAvailable: false, modifiers: .shift),
            .applications
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .applications, isMenuModeAvailable: false, modifiers: .shift),
            .commands
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .commands, isMenuModeAvailable: false, modifiers: .shift),
            .clipboard
        )
        XCTAssertEqual(
            modeNavigationTarget(currentMode: .clipboard, isMenuModeAvailable: false, modifiers: .shift),
            .windows
        )
    }

    func testModifiedTabDoesNotNavigateModes() {
        let modifiers: [NSEvent.ModifierFlags] = [
            .control,
            .option,
            .command,
            [.control, .shift],
            [.option, .shift],
            [.command, .shift]
        ]

        for modifierFlags in modifiers {
            XCTAssertNil(
                modeNavigationTarget(currentMode: .windows, modifiers: modifierFlags)
            )
        }
    }

    func testCommandShortcutsSelectModesAndPreserveMenuAvailability() {
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_1), characters: "1"),
            .windows
        )
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_2), characters: "2"),
            .menu
        )
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_3), characters: "3"),
            .clipboard
        )
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_4), characters: "4"),
            .commands
        )
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_5), characters: "5"),
            .applications
        )
        XCTAssertEqual(
            directModeTarget(keyCode: UInt16(kVK_ANSI_6), characters: "6"),
            .files
        )
        XCTAssertNil(
            directModeTarget(
                keyCode: UInt16(kVK_ANSI_2),
                characters: "2",
                isMenuModeAvailable: false
            )
        )
    }

    func testModeHintsKeepDirectShortcutsVisible() {
        XCTAssertEqual(
            CommandPalettePresentation.modeHint(for: .windows),
            .init(title: "Windows", shortcut: "⌘1")
        )
        XCTAssertEqual(
            CommandPalettePresentation.modeHint(for: .menu),
            .init(title: "Menu", shortcut: "⌘2")
        )
        XCTAssertEqual(
            CommandPalettePresentation.modeHint(for: .clipboard),
            .init(title: "Clipboard", shortcut: "⌘3")
        )
        XCTAssertEqual(
            CommandPalettePresentation.modeHint(for: .commands),
            .init(title: "Commands", shortcut: "⌘4")
        )
        XCTAssertEqual(
            CommandPalettePresentation.modeHint(for: .applications),
            .init(title: "Applications", shortcut: "⌘5")
        )
        XCTAssertEqual(
            CommandPalettePresentation.modeHint(for: .files),
            .init(title: "Files", shortcut: "⌘6")
        )
    }

    func testCompactModePickerLeaves326PointSearchField() {
        XCTAssertEqual(CommandPaletteModePicker.compactWidth, 304)
        XCTAssertEqual(CommandPalettePanel.width - CommandPaletteModePicker.compactWidth - 10, 326)
    }

    func testHiddenManagedRowsRemainSearchableAndSortAfterVisibleRows() throws {
        let (wmController, visibleToken, hiddenToken) = try makeWindowFixture()

        let items = CommandPaletteSearch.buildWindowItems(from: wmController)

        XCTAssertEqual(items.map(\.id), [visibleToken, hiddenToken])
        XCTAssertEqual(items.map(\.isAppHidden), [false, true])
        XCTAssertTrue(items[0].handle === wmController.workspaceManager.handle(for: visibleToken))
        XCTAssertTrue(items[1].handle === wmController.workspaceManager.handle(for: hiddenToken))
        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "hidden").map(\.id), [hiddenToken])
        XCTAssertTrue(CommandPalettePresentation.allowsSummonRight(items[0]))
        XCTAssertFalse(CommandPalettePresentation.allowsSummonRight(items[1]))
    }

    func testWindowStatusTextDescribesSelectedHiddenWindowPrimaryAction() throws {
        let (wmController, _, hiddenToken) = try makeWindowFixture()
        let hiddenItem = try XCTUnwrap(
            CommandPaletteSearch.buildWindowItems(from: wmController).first { $0.id == hiddenToken }
        )

        XCTAssertEqual(
            CommandPalettePresentation.windowsStatusText(
                selectedItem: hiddenItem,
                isSummonRightAvailable: true
            ),
            "Return · Unhide & Focus"
        )
        XCTAssertEqual(
            CommandPalettePresentation.windowsStatusText(
                selectedItem: hiddenItem,
                isSummonRightAvailable: false
            ),
            "Return · Unhide & Focus"
        )
    }

    func testWindowStatusTextPreservesVisibleWindowGuidance() throws {
        let (wmController, visibleToken, _) = try makeWindowFixture()
        let visibleItem = try XCTUnwrap(
            CommandPaletteSearch.buildWindowItems(from: wmController).first { $0.id == visibleToken }
        )

        XCTAssertEqual(
            CommandPalettePresentation.windowsStatusText(
                selectedItem: visibleItem,
                isSummonRightAvailable: true
            ),
            "Enter jumps. Shift-Enter summons right."
        )
        XCTAssertEqual(
            CommandPalettePresentation.windowsStatusText(
                selectedItem: visibleItem,
                isSummonRightAvailable: false
            ),
            "Enter jumps. Shift-Enter unavailable for this session."
        )
    }

    func testHiddenBadgeDoesNotChangeCommandPaletteWindowRowHeight() {
        let visibleHeight = commandPaletteWindowRowHeight(isAppHidden: false)
        let hiddenHeight = commandPaletteWindowRowHeight(isAppHidden: true)

        XCTAssertEqual(hiddenHeight, visibleHeight, accuracy: 0.5)
    }

    func testClipboardSearchFindsFullContentAndKeepsPinnedResultsFirst() {
        let unpinned = ClipboardPaletteItem(
            id: UUID(), title: "Short", subtitle: "", kind: .text, sourceBundleIdentifier: nil,
            lastCopiedAt: .distantPast, numberOfCopies: 1, byteCount: 20,
            searchText: "matching full text"
        )
        let pinned = ClipboardPaletteItem(
            id: UUID(), title: "Longer title", subtitle: "", kind: .text, sourceBundleIdentifier: nil,
            lastCopiedAt: .distantPast, numberOfCopies: 1, byteCount: 20,
            isPinned: true, searchText: "matching full text"
        )

        XCTAssertEqual(
            CommandPaletteSearch.filterClipboardItems([unpinned, pinned], query: "matching").map(\.id),
            [pinned.id, unpinned.id]
        )
    }

    private func modeNavigationTarget(
        currentMode: CommandPaletteMode,
        isMenuModeAvailable: Bool = true,
        modifiers: NSEvent.ModifierFlags = []
    ) -> CommandPaletteMode? {
        CommandPalettePresentation.modeNavigationTarget(
            currentMode: currentMode,
            isMenuModeAvailable: isMenuModeAvailable,
            keyCode: UInt16(kVK_Tab),
            relevantModifiers: modifiers,
            charactersIgnoringModifiers: "\t"
        )
    }

    private func directModeTarget(
        keyCode: UInt16,
        characters: String,
        isMenuModeAvailable: Bool = true
    ) -> CommandPaletteMode? {
        CommandPalettePresentation.modeNavigationTarget(
            currentMode: .windows,
            isMenuModeAvailable: isMenuModeAvailable,
            keyCode: keyCode,
            relevantModifiers: .command,
            charactersIgnoringModifiers: characters
        )
    }

    private func makeWindowFixture() throws -> (WMController, WindowToken, WindowToken) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCommandPaletteTests-\(UUID().uuidString)", isDirectory: true)
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
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let hiddenToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(92_001), windowId: 92_101),
            pid: 92_001,
            windowId: 92_101,
            to: workspaceId
        )
        let visibleToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(92_002), windowId: 92_102),
            pid: 92_002,
            windowId: 92_102,
            to: workspaceId
        )
        controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .service)
        return (controller, visibleToken, hiddenToken)
    }

    private func commandPaletteWindowRowHeight(isAppHidden: Bool) -> CGFloat {
        let token = WindowToken(pid: 92_003, windowId: isAppHidden ? 92_104 : 92_103)
        let item = CommandPaletteWindowItem(
            id: token,
            handle: WindowHandle(id: token),
            title: "Terminal",
            appName: "Ghostty",
            appIcon: nil,
            workspaceName: "1",
            isAppHidden: isAppHidden
        )
        let hostingView = NSHostingView(rootView: CommandPaletteWindowRow(
            item: item,
            isSelected: false,
            isSummonRightAvailable: false,
            onSelect: {}
        ).frame(width: 620))

        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }
}
