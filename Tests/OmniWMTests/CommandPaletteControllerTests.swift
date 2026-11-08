// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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

    func testCommandShortcutsUsePhysicalNumberRowOnAzerty() {
        let azertyRow: [Int: (String, CommandPaletteMode)] = [
            kVK_ANSI_1: ("&", .windows),
            kVK_ANSI_2: ("é", .menu),
            kVK_ANSI_3: ("\"", .clipboard),
            kVK_ANSI_4: ("'", .commands),
            kVK_ANSI_5: ("(", .applications),
            kVK_ANSI_6: ("§", .files)
        ]
        for (keyCode, (characters, mode)) in azertyRow {
            XCTAssertEqual(directModeTarget(keyCode: UInt16(keyCode), characters: characters), mode, characters)
        }
    }

    func testCommandShortcutsAcceptKeypadDigits() {
        let keypad: [(Int, CommandPaletteMode)] = [
            (kVK_ANSI_Keypad1, .windows),
            (kVK_ANSI_Keypad2, .menu),
            (kVK_ANSI_Keypad3, .clipboard),
            (kVK_ANSI_Keypad4, .commands),
            (kVK_ANSI_Keypad5, .applications),
            (kVK_ANSI_Keypad6, .files)
        ]
        for (keyCode, mode) in keypad {
            XCTAssertEqual(directModeTarget(keyCode: UInt16(keyCode), characters: "x"), mode)
        }
        XCTAssertNil(directModeTarget(keyCode: UInt16(kVK_ANSI_Keypad7), characters: "7"))
    }

    func testNumberRowWithoutCommandDoesNotSwitchModes() {
        XCTAssertNil(
            CommandPalettePresentation.modeNavigationTarget(
                currentMode: .windows,
                isMenuModeAvailable: true,
                keyCode: UInt16(kVK_ANSI_1),
                relevantModifiers: [],
                charactersIgnoringModifiers: "&"
            )
        )
    }

    func testLetterKeyEquivalentsFollowTypedLetterAndFallBackToPositionOnNonLatinLayouts() {
        XCTAssertTrue(KeyEquivalent.matches(
            "y",
            ansiKeyCode: kVK_ANSI_Y,
            keyCode: UInt16(kVK_ANSI_Y),
            charactersIgnoringModifiers: "y"
        ))
        XCTAssertTrue(KeyEquivalent.matches(
            "y",
            ansiKeyCode: kVK_ANSI_Y,
            keyCode: UInt16(kVK_ANSI_Z),
            charactersIgnoringModifiers: "Y"
        ))
        XCTAssertFalse(KeyEquivalent.matches(
            "y",
            ansiKeyCode: kVK_ANSI_Y,
            keyCode: UInt16(kVK_ANSI_Y),
            charactersIgnoringModifiers: "z"
        ))
        XCTAssertTrue(KeyEquivalent.matches(
            "r",
            ansiKeyCode: kVK_ANSI_R,
            keyCode: UInt16(kVK_ANSI_R),
            charactersIgnoringModifiers: "к"
        ))
        XCTAssertFalse(KeyEquivalent.matches(
            "r",
            ansiKeyCode: kVK_ANSI_R,
            keyCode: UInt16(kVK_ANSI_T),
            charactersIgnoringModifiers: "е"
        ))
    }

    func testModeHintsKeepDirectShortcutsVisible() {
        let expected: [(CommandPaletteMode, String, String)] = [
            (.windows, "Windows", "⌘1"),
            (.menu, "Menu", "⌘2"),
            (.clipboard, "Clipboard", "⌘3"),
            (.commands, "Commands", "⌘4"),
            (.applications, "Launcher", "⌘5"),
            (.files, "Files", "⌘6")
        ]
        for (mode, title, shortcut) in expected {
            XCTAssertEqual(
                CommandPalettePresentation.modeHint(for: mode),
                .init(title: title, shortcut: shortcut)
            )
        }
    }

    func testMarkActionShortcutsStayVisibleAndMapToPaletteActions() {
        let markModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]

        XCTAssertEqual(CommandPalettePresentation.setMarkShortcut, "⌃⌥⇧M")
        XCTAssertEqual(CommandPalettePresentation.removeMarkShortcut, "⌃⌥⇧R")
        XCTAssertEqual(
            CommandPalettePresentation.markAction(
                forKeyCode: UInt16(kVK_ANSI_M),
                relevantModifiers: markModifiers
            ),
            .set
        )
        XCTAssertEqual(
            CommandPalettePresentation.markAction(
                forKeyCode: UInt16(kVK_ANSI_R),
                relevantModifiers: markModifiers
            ),
            .remove
        )
        XCTAssertNil(
            CommandPalettePresentation.markAction(
                forKeyCode: UInt16(kVK_ANSI_M),
                relevantModifiers: .control
            )
        )
        XCTAssertNil(
            CommandPalettePresentation.markAction(
                forKeyCode: UInt16(kVK_ANSI_M),
                relevantModifiers: [.control, .option]
            )
        )
        XCTAssertNil(
            CommandPalettePresentation.markAction(
                forKeyCode: UInt16(kVK_ANSI_X),
                relevantModifiers: markModifiers
            )
        )
    }

    func testMarkChordsWorkInPaletteEvenWhenBoundGlobally() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let markChord = KeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey | shiftKey))
        fixture.controller.settings.updateTrigger(for: "openMenuAnywhere", newTrigger: .chord(markChord))
        let hotkeys = fixture.controller.hotkeys
        hotkeys.updateBindings(fixture.controller.settings.hotkeyBindings, systemHyperTrigger: .none)
        hotkeys.start()
        defer { hotkeys.stop() }
        XCTAssertTrue(hotkeys.carbonRegistrations.registeredCommands.contains(.openMenuAnywhere))

        _ = try fixture.show()
        XCTAssertFalse(hotkeys.carbonRegistrations.registeredCommands.contains(.openMenuAnywhere))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "M",
            charactersIgnoringModifiers: "M",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_M)
        ))
        XCTAssertTrue(fixture.palette.handleKeyDown(event))
        XCTAssertEqual(fixture.palette.actionFeedbackText, "Select a window row before changing its marks.")

        fixture.palette.dismiss(reason: .selection)
        XCTAssertTrue(hotkeys.carbonRegistrations.registeredCommands.contains(.openMenuAnywhere))
    }

    func testKeyboardLayoutChangeWhilePaletteIsOpenMovesReservedLetterChords() throws {
        var previewKey = UInt16(kVK_ANSI_Y)
        var onLayoutChange: (@MainActor () -> Void)?
        let fixture = CommandPaletteFocusFixture { environment in
            environment.paletteShortcuts = { PaletteShortcuts(previewKeyCode: previewKey, revealKeyCode: nil) }
            environment.observeKeyboardLayout = { onLayoutChange = $0 }
        }
        defer { fixture.cleanup() }
        let commandY = KeyBinding(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey))
        let commandZ = KeyBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey))
        _ = try fixture.show()
        let hotkeys = fixture.controller.hotkeys
        XCTAssertTrue(hotkeys.yieldsToPalette(commandY))
        XCTAssertFalse(hotkeys.yieldsToPalette(commandZ))

        previewKey = UInt16(kVK_ANSI_Z)
        try XCTUnwrap(onLayoutChange)()

        XCTAssertFalse(hotkeys.yieldsToPalette(commandY))
        XCTAssertTrue(hotkeys.yieldsToPalette(commandZ))

        fixture.palette.dismiss(reason: .selection)
        XCTAssertNil(onLayoutChange)
        XCTAssertFalse(hotkeys.yieldsToPalette(commandZ))
    }

    func testCompactModePickerLeaves326PointSearchField() {
        XCTAssertEqual(CommandPaletteModePicker.compactWidth, 304)
        XCTAssertEqual(CommandPalettePanel.width - CommandPaletteModePicker.compactWidth - 10, 326)
    }

    func testHiddenManagedRowsRemainSearchableAndSortAfterVisibleRows() throws {
        let (wmController, visibleToken, hiddenToken) = try makeWindowFixture()

        let focusedWindow = CommandPaletteFocusTarget(
            app: .init(
                processIdentifier: hiddenToken.pid, bundleIdentifier: nil, localizedName: nil, isTerminated: false
            ),
            focusedWindow: nil,
            focusedWindowID: CGWindowID(hiddenToken.windowId)
        )
        let items = CommandPaletteSearch.buildWindowItems(from: wmController, focusedWindow: focusedWindow)

        XCTAssertEqual(items.map(\.id), [visibleToken, hiddenToken])
        XCTAssertEqual(items.map(\.isAppHidden), [false, true])
        XCTAssertTrue(items.allSatisfy { $0.markNames.isEmpty })
        XCTAssertTrue(items[0].handle === wmController.workspaceManager.handle(for: visibleToken))
        XCTAssertTrue(items[1].handle === wmController.workspaceManager.handle(for: hiddenToken))
        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "hidden").map(\.id), [hiddenToken])
        XCTAssertTrue(CommandPalettePresentation.allowsSummonRight(
            items[0], isTiling: true, isCurrentWorkspaceEmpty: false
        ))
        XCTAssertFalse(CommandPalettePresentation.allowsSummonRight(
            items[1], isTiling: true, isCurrentWorkspaceEmpty: false
        ))
    }

    func testFloatingWindowAlternateActionRequiresEmptyWorkspace() throws {
        let (wmController, _, floatingToken) = try makeWindowFixture()
        wmController.workspaceManager.setAppHidden(false, pid: floatingToken.pid, source: .service)
        XCTAssertTrue(wmController.workspaceManager.setWindowMode(.floating, for: floatingToken))
        let palette = CommandPaletteController(motionPolicy: MotionPolicy(animationsEnabled: false))
        palette.wmController = wmController
        palette.refreshWindowItems()
        let item = try XCTUnwrap(palette.windows.first { $0.id == floatingToken })
        palette.selectedItemID = .window(floatingToken)

        XCTAssertFalse(palette.allowsWindowAlternateAction(item))
        XCTAssertNil(palette.resolvedSelectionAction(for: .alternate))
        XCTAssertEqual(
            CommandPalettePresentation.windowsStatusText(
                selectedItem: item,
                isSummonRightAvailable: true,
                isSelectedWindowEligibleForSummon: false
            ),
            "Enter jumps. Shift-Enter unavailable for this window."
        )
        XCTAssertTrue(CommandPalettePresentation.allowsSummonRight(
            item, isTiling: false, isCurrentWorkspaceEmpty: true
        ))

        XCTAssertEqual(wmController.windowMarkRegistry.set("floating", for: floatingToken), .inserted)
        palette.refreshWindowItems()
        palette.selectedItemID = .window(floatingToken)
        XCTAssertNil(palette.resolvedSelectionAction(for: .alternate))

        XCTAssertTrue(wmController.workspaceManager.setWindowMode(.tiling, for: floatingToken))
        XCTAssertTrue(palette.allowsWindowAlternateAction(item))
    }

    func testWindowRowsUseFocusRecencyForInitialSelectionAndChromeSearch() {
        let older = makeWindowItem(windowId: 92_120, title: "Chrome Beta", appName: "Google Chrome")
        let recentlyFocused = makeWindowItem(windowId: 92_121, title: "Chrome Zulu", appName: "Google Chrome")
        let items = CommandPaletteSearch.orderWindowItems(
            [older, recentlyFocused],
            focusRecencyOrder: [recentlyFocused.id, older.id]
        )

        XCTAssertEqual(items.map(\.id), [recentlyFocused.id, older.id])
        XCTAssertEqual(
            CommandPaletteSearch.filterWindowItems(items, query: "Chrome").map(\.id),
            [recentlyFocused.id, older.id]
        )

        let palette = CommandPaletteController(motionPolicy: MotionPolicy(animationsEnabled: false))
        palette.windows = items
        XCTAssertEqual(palette.selectedItemID, .window(recentlyFocused.id))
    }

    func testCapturedPrePaletteWindowOverridesStaleFocusAndIsSelected() throws {
        let older = makeWindowItem(windowId: 92_120, title: "Chrome Beta", appName: "Google Chrome")
        let focused = makeWindowItem(windowId: 92_121, title: "Chrome Zulu", appName: "Google Chrome")
        let ordered = CommandPaletteSearch.orderWindowItems(
            [older, focused],
            focusRecencyOrder: [older.id, focused.id],
            focusedWindowToken: focused.id
        )
        XCTAssertEqual(ordered.map(\.id), [focused.id, older.id])
        XCTAssertEqual(
            CommandPaletteSearch.filterWindowItems(ordered, query: "Chrome").map(\.id),
            [focused.id, older.id]
        )

        let (wmController, _, capturedToken) = try makeWindowFixture()
        wmController.workspaceManager.setAppHidden(false, pid: capturedToken.pid, source: .service)
        let focusedWindow = CommandPaletteFocusTarget(
            app: .init(
                processIdentifier: capturedToken.pid, bundleIdentifier: nil, localizedName: nil, isTerminated: false
            ),
            focusedWindow: nil,
            focusedWindowID: CGWindowID(capturedToken.windowId)
        )
        let palette = CommandPaletteController(motionPolicy: MotionPolicy(animationsEnabled: false))
        palette.windows = CommandPaletteSearch.buildWindowItems(from: wmController, focusedWindow: focusedWindow)
        XCTAssertEqual(palette.windows.first?.id, capturedToken)
        XCTAssertEqual(palette.selectedItemID, .window(capturedToken))
    }

    func testConfirmedFocusBeatsPreviousAppCaptureWhenOpeningPalette() throws {
        let chrome = makeWindowItem(windowId: 92_120, title: "Chrome", appName: "Google Chrome")
        let wezTerm = makeWindowItem(windowId: 92_121, title: "WezTerm", appName: "WezTerm")
        let markEdit = makeWindowItem(windowId: 92_122, title: "MarkEdit", appName: "MarkEdit")

        for (current, previous) in [(wezTerm, chrome), (markEdit, wezTerm)] {
            let items = CommandPaletteSearch.orderWindowItems(
                [previous, current],
                focusRecencyOrder: [current.id, previous.id],
                confirmedFocusToken: current.id,
                focusedWindowToken: previous.id
            )
            XCTAssertEqual(items.first?.id, current.id)
            let palette = CommandPaletteController(motionPolicy: MotionPolicy(animationsEnabled: false))
            palette.windows = items
            XCTAssertEqual(palette.selectedItemID, .window(current.id))
        }

        let (wmController, currentToken, previousToken) = try makeWindowFixture()
        wmController.workspaceManager.setAppHidden(false, pid: previousToken.pid, source: .service)
        let workspaceId = try XCTUnwrap(wmController.workspaceManager.entry(for: currentToken)?.workspaceId)
        _ = wmController.workspaceManager.recordReconcileEvent(.managedFocusConfirmed(
            token: currentToken, workspaceId: workspaceId, monitorId: nil,
            requestId: nil, source: .workspaceManager
        ))
        XCTAssertEqual(wmController.workspaceManager.selectedManagedToken, currentToken)
        let previousFocus = CommandPaletteFocusTarget(
            app: .init(
                processIdentifier: previousToken.pid, bundleIdentifier: nil, localizedName: nil, isTerminated: false
            ),
            focusedWindow: nil,
            focusedWindowID: CGWindowID(previousToken.windowId)
        )
        let palette = CommandPaletteController(motionPolicy: MotionPolicy(animationsEnabled: false))
        palette.windows = CommandPaletteSearch.buildWindowItems(from: wmController, focusedWindow: previousFocus)
        XCTAssertEqual(palette.windows.first?.id, currentToken)
        XCTAssertEqual(palette.selectedItemID, .window(currentToken))
    }

    func testWindowSearchPrioritizesMatchingMarksThenTitleRelevance() {
        let recent = makeWindowItem(windowId: 92_130, title: "Home tabs", appName: "Google Chrome")
        let next = makeWindowItem(windowId: 92_131, title: "Omni notes", appName: "Google Chrome")
        let marked = makeWindowItem(
            windowId: 92_132, title: "Unrelated page", appName: "Google Chrome", markNames: ["Omni"]
        )
        let windows = [recent, next, marked]

        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(windows, query: "").map(\.id), windows.map(\.id))
        XCTAssertEqual(
            CommandPaletteSearch.filterWindowItems(windows, query: "OM").map(\.id),
            [marked.id, next.id, recent.id]
        )

        let palette = CommandPaletteController(motionPolicy: MotionPolicy(animationsEnabled: false))
        palette.windows = windows
        XCTAssertEqual(palette.selectedItemID, .window(recent.id))
        palette.searchText = "OM"
        XCTAssertEqual(palette.selectedItemID, .window(marked.id))
    }

    func testWindowSearchRanksTitleBeforeAppBeforeWorkspaceAndUsesRecencyForTies() {
        let workspace = makeWindowItem(windowId: 92_140, title: "Diary", appName: "Notes")
        let app = makeWindowItem(windowId: 92_141, title: "Diary", appName: "Research App")
        let title = makeWindowItem(windowId: 92_142, title: "Research", appName: "Notes")
        let olderTitle = makeWindowItem(windowId: 92_143, title: "Research", appName: "Notes")
        let windows = [workspace, app, title, olderTitle]

        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(windows, query: "").map(\.id), windows.map(\.id))
        XCTAssertEqual(
            CommandPaletteSearch.filterWindowItems(windows, query: "research").map(\.id),
            [title.id, olderTitle.id, app.id, workspace.id]
        )
    }

    func testMarkTargetsSelectedWindowEvenWhenSelectionChangesDuringPrompt() throws {
        let (wmController, otherToken, selectedToken) = try makeWindowFixture()
        var palette: CommandPaletteController!
        var environment = CommandPaletteEnvironment()
        environment.requestWindowMarkName = {
            XCTAssertTrue(palette.isPresentingModalPrompt)
            palette.selectedItemID = .window(otherToken)
            return "review"
        }
        palette = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: false), environment: environment
        )
        palette.wmController = wmController
        palette.windows = CommandPaletteSearch.buildWindowItems(from: wmController)
        palette.selectedItemID = .window(selectedToken)

        palette.setMarkOnSelectedWindow()

        XCTAssertFalse(palette.isPresentingModalPrompt)
        XCTAssertEqual(wmController.windowMarkRegistry.lookup("review"), .found(selectedToken))
        XCTAssertTrue(wmController.windowMarkRegistry.names(for: otherToken).isEmpty)
    }

    func testMarkWithNoSelectedWindowDoesNotPromptOrTargetFirstResult() throws {
        let (wmController, firstToken, _) = try makeWindowFixture()
        var promptCount = 0
        var environment = CommandPaletteEnvironment()
        environment.requestWindowMarkName = {
            promptCount += 1
            return "review"
        }
        let palette = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: false), environment: environment
        )
        palette.wmController = wmController
        palette.windows = CommandPaletteSearch.buildWindowItems(from: wmController)
        palette.selectedItemID = nil

        palette.setMarkOnSelectedWindow()

        XCTAssertEqual(promptCount, 0)
        XCTAssertNil(palette.selectedItemID)
        XCTAssertTrue(wmController.windowMarkRegistry.names(for: firstToken).isEmpty)
        XCTAssertEqual(palette.actionFeedbackText, "Select a current window row before changing its marks.")
    }

    func testWindowRowsReadAllLiveRegistryMarksAndSearchEveryName() throws {
        let (wmController, visibleToken, hiddenToken) = try makeWindowFixture()
        XCTAssertEqual(wmController.windowMarkRegistry.set("editor", for: visibleToken), .inserted)
        XCTAssertEqual(wmController.windowMarkRegistry.set("focus-later", for: visibleToken), .inserted)
        XCTAssertEqual(wmController.windowMarkRegistry.set("hidden-review", for: hiddenToken), .inserted)

        let items = CommandPaletteSearch.buildWindowItems(from: wmController)
        let visibleItem = try XCTUnwrap(items.first { $0.id == visibleToken })
        let hiddenItem = try XCTUnwrap(items.first { $0.id == hiddenToken })

        XCTAssertEqual(visibleItem.markNames, ["editor", "focus-later"])
        XCTAssertEqual(hiddenItem.markNames, ["hidden-review"])
        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "later").map(\.id), [visibleToken])
        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "hidden-review").map(\.id), [hiddenToken])

        XCTAssertEqual(wmController.windowMarkRegistry.remove("focus-later"), .removed)
        let refreshedItems = CommandPaletteSearch.buildWindowItems(from: wmController)
        XCTAssertEqual(refreshedItems.first { $0.id == visibleToken }?.markNames, ["editor"])
        XCTAssertTrue(CommandPaletteSearch.filterWindowItems(refreshedItems, query: "later").isEmpty)
    }

    func testWindowSearchMatchesAnyLiteralMarkNameAndPreservesExistingFields() {
        let item = makeWindowItem(windowId: 92_110, markNames: ["editor", "late-review"])
        let items = [item]

        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "EDITOR").map(\.id), [item.id])
        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "review").map(\.id), [item.id])
        XCTAssertTrue(CommandPaletteSearch.filterWindowItems(items, query: "@editor").isEmpty)
        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "quarterly").map(\.id), [item.id])
        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "drafts").map(\.id), [item.id])
        XCTAssertEqual(CommandPaletteSearch.filterWindowItems(items, query: "research").map(\.id), [item.id])
    }

    func testWindowRowShowsEachMarkIndividuallyAndAccessibly() {
        let markedRow = CommandPaletteWindowRow(
            item: makeWindowItem(windowId: 92_111, markNames: ["editor", "research"]),
            isSelected: false,
            isSummonRightAvailable: false,
            onSelect: {}
        )
        let unmarkedRow = CommandPaletteWindowRow(
            item: makeWindowItem(windowId: 92_112),
            isSelected: false,
            isSummonRightAvailable: false,
            onSelect: {}
        )

        XCTAssertEqual(markedRow.markLabels, ["Mark: editor", "Mark: research"])
        XCTAssertEqual(markedRow.accessibilityLabel, "Quarterly review, Drafts, Mark: editor, Mark: research")
        XCTAssertTrue(unmarkedRow.markLabels.isEmpty)
        XCTAssertEqual(unmarkedRow.accessibilityLabel, "Quarterly review, Drafts")
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
            "Enter jumps. Shift-Enter unavailable without an anchor."
        )
    }

    func testWindowStatusTextExplainsEmptyWorkspaceMoveAndAnchoredSummon() {
        let item = makeWindowItem(windowId: 92_113)

        XCTAssertEqual(
            CommandPalettePresentation.windowsStatusText(
                selectedItem: item,
                isSummonRightAvailable: false,
                isCurrentWorkspaceEmpty: true
            ),
            "Enter jumps. Shift-Enter moves here (empty workspace)."
        )
        XCTAssertEqual(
            CommandPalettePresentation.windowsStatusText(
                selectedItem: item,
                isSummonRightAvailable: true,
                isCurrentWorkspaceEmpty: false
            ),
            "Enter jumps. Shift-Enter summons right."
        )
    }

    func testHiddenBadgeDoesNotChangeCommandPaletteWindowRowHeight() {
        let visibleHeight = commandPaletteWindowRowHeight(isAppHidden: false)
        let hiddenHeight = commandPaletteWindowRowHeight(isAppHidden: true)

        XCTAssertEqual(hiddenHeight, visibleHeight)
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

    private func makeWindowItem(
        windowId: Int,
        title: String = "Quarterly review",
        appName: String = "Drafts",
        markNames: [String] = []
    ) -> CommandPaletteWindowItem {
        let token = WindowToken(pid: 92_010, windowId: windowId)
        return CommandPaletteWindowItem(
            id: token,
            handle: WindowHandle(id: token),
            title: title,
            appName: appName,
            appIcon: nil,
            workspaceName: "Research",
            isAppHidden: false,
            markNames: markNames
        )
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
            isAppHidden: isAppHidden,
            markNames: []
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
