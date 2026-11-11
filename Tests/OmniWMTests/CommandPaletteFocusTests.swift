// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Combine
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteFocusTests: XCTestCase {
    func testAnimatedPaletteRevealsCompactAndExpandsWhileSearchStaysFocused() async throws {
        let fixture = CommandPaletteFocusFixture(animationsEnabled: true)
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        let compactFrame = panel.frame

        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(fixture.palette.isExpanded)
        XCTAssertLessThan(compactFrame.height, 100)

        let revealed = expectation(description: "Compact palette completes its reveal")
        let revealObservation = panel.publisher(for: \.alphaValue, options: [.initial, .new])
            .first { $0 >= 0.99 }
            .sink { _ in revealed.fulfill() }
        await fulfillment(of: [revealed], timeout: failureBound)
        revealObservation.cancel()
        XCTAssertEqual(panel.frame.height, compactFrame.height)

        let expanded = expectation(description: "Animated panel reaches expanded height")
        let resizeEvents = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .compactMap { ($0.object as? NSPanel)?.frame.height }
            .share()
        let expandedObservation = resizeEvents
            .first { $0 >= CommandPalettePanel.expandedHeight - 0.5 }
            .sink { _ in expanded.fulfill() }

        try fixture.insertText("first")
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(panel.frame.height, compactFrame.height)
        await fulfillment(of: [expanded], timeout: failureBound)
        expandedObservation.cancel()
        fixture.layout()
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(panel.frame.height, CommandPalettePanel.expandedHeight)
        XCTAssertTrue(panel.firstResponder is NSTextView)
        try fixture.insertText(" second")
        XCTAssertEqual(fixture.palette.searchText, "first second")

        let closing = expectation(description: "Cancel animation starts collapsing the panel")
        let closingObservation = resizeEvents
            .first { $0 < CommandPalettePanel.expandedHeight - 0.5 }
            .sink { _ in closing.fulfill() }
        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertEqual(panel.frame.height, CommandPalettePanel.expandedHeight)
        XCTAssertEqual(fixture.palette.searchText, "first second")
        await fulfillment(of: [closing], timeout: failureBound)
        closingObservation.cancel()
        XCTAssertEqual(fixture.palette.searchText, "first second")

        let reopenedPanel = try await showAndWaitForEditing(fixture)
        XCTAssertTrue(reopenedPanel === panel)
        let reopenedExpansion = expectation(description: "Reopened palette reaches expanded height")
        let reopenedObservation = resizeEvents
            .first { $0 >= CommandPalettePanel.expandedHeight - 0.5 }
            .sink { _ in reopenedExpansion.fulfill() }
        try fixture.insertText("reopened")
        await fulfillment(of: [reopenedExpansion], timeout: failureBound)
        reopenedObservation.cancel()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(fixture.palette.searchText, "reopened")
        XCTAssertTrue(panel.firstResponder is NSTextView)
    }

    func testCollapsedDownAndEnterExpandWindowsWithoutSkippingFirstRow() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let manager = fixture.controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        for windowId in [92_201, 92_202] {
            _ = manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(92_200), windowId: windowId),
                pid: 92_200,
                windowId: windowId,
                to: workspaceId
            )
        }
        _ = try fixture.show()
        let first = try XCTUnwrap(fixture.palette.filteredWindowItems.first?.id)
        let second = try XCTUnwrap(fixture.palette.filteredWindowItems.dropFirst().first?.id)
        XCTAssertFalse(fixture.palette.isExpanded)
        XCTAssertEqual(fixture.palette.selectedItemID, .window(first))

        fixture.palette.moveSelection(by: 1)
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(fixture.palette.selectedItemID, .window(first))
        fixture.palette.moveSelection(by: 1)
        XCTAssertEqual(fixture.palette.selectedItemID, .window(second))

        fixture.palette.toggle(wmController: fixture.controller)
        _ = try fixture.show()
        XCTAssertFalse(fixture.palette.isExpanded)
        fixture.palette.selectCurrent()
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(fixture.palette.selectedItemID, .window(first))
    }

    func testTypingExpandsCompactPaletteAndKeepsSearchEditable() async throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        let compactFrame = panel.frame

        XCTAssertFalse(fixture.palette.isExpanded)
        XCTAssertLessThan(compactFrame.height, 100)

        try fixture.insertText("first")
        fixture.layout()

        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertGreaterThan(panel.frame.height, compactFrame.height + 200)
        XCTAssertEqual(panel.frame.maxY, compactFrame.maxY)
        try fixture.insertText(" second")
        XCTAssertEqual(fixture.palette.searchText, "first second")
    }

    func testModeSelectionExpandsCompactPaletteAndKeepsSearchEditable() async throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        let compactFrame = panel.frame

        fixture.palette.selectMode(.clipboard)
        fixture.layout()

        XCTAssertEqual(fixture.palette.selectedMode, .clipboard)
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertGreaterThan(panel.frame.height, compactFrame.height + 200)
        XCTAssertEqual(panel.frame.maxY, compactFrame.maxY)
        await waitForSearchEditing(panel)
        try fixture.insertText("clipboard")
        XCTAssertEqual(fixture.palette.searchText, "clipboard")
    }

    func testResizedExpandedPaletteKeepsPlacementAcrossReopen() async throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)

        fixture.palette.selectMode(.clipboard)
        fixture.layout()
        let initialFrame = panel.frame
        let requestedFrame = panel.constrainFrameRect(
            NSRect(
                x: initialFrame.minX + 24,
                y: initialFrame.minY + 20,
                width: initialFrame.width + 40,
                height: initialFrame.height + 32
            ),
            to: try XCTUnwrap(panel.screen)
        )
        panel.setFrame(requestedFrame, display: true)
        fixture.layout()
        let resizedFrame = panel.frame

        XCTAssertGreaterThan(resizedFrame.width, initialFrame.width + 20)
        XCTAssertGreaterThan(resizedFrame.height, initialFrame.height + 16)
        XCTAssertEqual(resizedFrame.minX, requestedFrame.minX)
        XCTAssertEqual(resizedFrame.minY, requestedFrame.minY)

        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertFalse(panel.isVisible)

        let reopenedPanel = try await showAndWaitForEditing(fixture)
        XCTAssertTrue(reopenedPanel === panel)
        XCTAssertFalse(fixture.palette.isExpanded)
        XCTAssertEqual(reopenedPanel.frame.minX, resizedFrame.minX)
        XCTAssertEqual(reopenedPanel.frame.width, resizedFrame.width)
        XCTAssertEqual(reopenedPanel.frame.maxY, resizedFrame.maxY)

        fixture.palette.selectMode(.clipboard)
        fixture.layout()
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(reopenedPanel.frame.minX, resizedFrame.minX)
        XCTAssertEqual(reopenedPanel.frame.width, resizedFrame.width)
        XCTAssertEqual(reopenedPanel.frame.height, resizedFrame.height)
        XCTAssertEqual(reopenedPanel.frame.maxY, resizedFrame.maxY)
    }

    func testOpeningAndReopeningFocusSearchWithoutClicking() async throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)

        try fixture.insertText("first")
        XCTAssertEqual(fixture.palette.searchText, "first")

        fixture.palette.toggle(wmController: fixture.controller)
        fixture.layout()
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertFalse(panel.isVisible)

        let reopenedPanel = try await showAndWaitForEditing(fixture)
        XCTAssertTrue(reopenedPanel === panel)
        XCTAssertEqual(fixture.palette.searchText, "")
        try fixture.insertText("second")
        XCTAssertEqual(fixture.palette.searchText, "second")
    }

    func testChangingModeReturnsFocusToSearch() async throws {
        let app = NSRunningApplication.current
        let fixture = CommandPaletteFocusFixture { environment in
            environment.frontmostApplication = { app }
            environment.runningApplication = { pid in pid == app.processIdentifier ? app : nil }
            environment.ownBundleIdentifier = { "org.example.palette-test" }
            environment.fetchMenuItems = { _ in [] }
        }
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        for mode in [CommandPaletteMode.clipboard, .windows, .commands, .menu] {
            XCTAssertTrue(panel.makeFirstResponder(nil))
            fixture.palette.selectedMode = mode
            fixture.layout()
            await waitForSearchEditing(panel)
            try fixture.insertText(mode.rawValue)
            XCTAssertTrue(fixture.palette.searchText.hasSuffix(mode.rawValue))
            XCTAssertEqual(fixture.palette.selectedMode, mode)
        }
    }

    func testRequestedModeOpensSwitchesAndClosesPalette() throws {
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard)
        defer { fixture.cleanup() }

        _ = try fixture.show(mode: .windows)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertEqual(fixture.palette.selectedMode, .windows)
        XCTAssertEqual(fixture.controller.settings.commandPaletteLastMode, .windows)

        fixture.palette.searchText = "query"
        fixture.palette.toggle(wmController: fixture.controller, mode: .commands)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertEqual(fixture.palette.selectedMode, .commands)
        XCTAssertEqual(fixture.palette.searchText, "query")

        fixture.palette.toggle(wmController: fixture.controller, mode: .commands)
        XCTAssertFalse(fixture.palette.isVisible)

        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertEqual(fixture.palette.selectedMode, .commands)
    }

    func testArrowKeysNavigateBeforeAnyMouseInteraction() async throws {
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard)
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        let first = try XCTUnwrap(fixture.palette.filteredClipboardItems.first)
        let last = try XCTUnwrap(fixture.palette.filteredClipboardItems.last)
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(first.id))

        try sendKey(keyCode: 125, characters: "\u{F701}", to: panel)
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(last.id))
        try sendKey(keyCode: 126, characters: "\u{F700}", to: panel)
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(first.id))

        try fixture.insertText("typed")
        XCTAssertEqual(fixture.palette.searchText, "typed")
    }

    func testMarkedTextKeepsClipboardNavigationAndSelectionInTextEditor() async throws {
        var copyCount = 0
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.copyClipboardItem = { _, _ in
                copyCount += 1
                return true
            }
        }
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        let selection = fixture.palette.selectedItemID

        editor.setMarkedText(
            "候",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())
        try sendKey(keyCode: 125, characters: "\u{F701}", to: panel)
        XCTAssertEqual(fixture.palette.selectedItemID, selection)

        editor.setMarkedText(
            "候",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())
        try sendKey(keyCode: 36, characters: "\r", to: panel)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertEqual(copyCount, 0)

        editor.setMarkedText(
            "候",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try sendKey(keyCode: 53, characters: "\u{1B}", to: panel)
        XCTAssertTrue(fixture.palette.isVisible)

        editor.setMarkedText(
            "候",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try sendKey(keyCode: 48, characters: "\t", to: panel)
        XCTAssertEqual(fixture.palette.selectedMode, .clipboard)
    }

    func testClipboardReturnCopiesSelectedItem() async throws {
        var copiedIDs: [UUID] = []
        let copied = expectation(description: "Selected clipboard item was copied")
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.copyClipboardItem = { _, id in
                copiedIDs.append(id)
                copied.fulfill()
                return true
            }
        }
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        fixture.palette.selectMode(.clipboard)
        let selected = try XCTUnwrap(fixture.palette.filteredClipboardItems.dropFirst().first)
        XCTAssertEqual(selected.title, "Beta")
        fixture.palette.selectedItemID = .clipboard(selected.id)

        try sendKey(keyCode: 36, characters: "\r", to: panel)
        await fulfillment(of: [copied], timeout: failureBound)
        XCTAssertEqual(copiedIDs, [selected.id])
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testClipboardChangesReloadSelectedPreviewAndUnsubscribeOnDismiss() async throws {
        let first = ClipboardPaletteItem(
            id: UUID(), title: "First", subtitle: "", kind: .text, sourceBundleIdentifier: nil,
            lastCopiedAt: .distantPast, numberOfCopies: 1, byteCount: 5
        )
        let second = ClipboardPaletteItem(
            id: UUID(), title: "Second", subtitle: "", kind: .text, sourceBundleIdentifier: nil,
            lastCopiedAt: .distantPast, numberOfCopies: 1, byteCount: 6
        )
        let firstPreview = expectation(description: "First selected item preview loaded")
        let secondPreview = expectation(description: "New selected item preview loaded")
        var observer: (@MainActor @Sendable ([ClipboardPaletteItem]) -> Void)?
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in [first] }
            environment.observeClipboardItems = { _, callback in observer = callback }
            environment.clipboardItemPreview = { _, id in
                if id == first.id {
                    firstPreview.fulfill()
                    return .text("First full text")
                }
                secondPreview.fulfill()
                return .text("Second full text")
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()
        await fulfillment(of: [firstPreview], timeout: failureBound)
        XCTAssertEqual(fixture.palette.clipboardPreview, .text("First full text"))

        observer?([second])
        await fulfillment(of: [secondPreview], timeout: failureBound)
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(second.id))
        XCTAssertEqual(fixture.palette.clipboardPreview, .text("Second full text"))

        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertNil(observer)
    }

    func testClipboardDisableWhileOpenClearsModeAndRejectsEdits() throws {
        let item = ClipboardPaletteItem(
            id: UUID(), title: "Saved", subtitle: "", kind: .text, sourceBundleIdentifier: nil,
            lastCopiedAt: .distantPast, numberOfCopies: 1, byteCount: 5
        )
        var historyEnabled = true
        var observer: (@MainActor @Sendable ([ClipboardPaletteItem]) -> Void)?
        var mutationCalls = 0
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in [item] }
            environment.isClipboardHistoryEnabled = { _ in historyEnabled }
            environment.observeClipboardItems = { _, callback in observer = callback }
            environment.setClipboardItemPinned = { _, _, _ in
                mutationCalls += 1
                return []
            }
            environment.deleteClipboardItem = { _, _ in
                mutationCalls += 1
                return []
            }
            environment.confirmClearClipboardHistory = {
                mutationCalls += 1
                return true
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(item.id))

        historyEnabled = false
        observer?([])

        XCTAssertFalse(fixture.palette.isClipboardHistoryEnabled)
        XCTAssertTrue(fixture.palette.clipboardItems.isEmpty)
        XCTAssertNil(fixture.palette.selectedItemID)
        XCTAssertNil(fixture.palette.clipboardPreview)
        fixture.palette.setClipboardItemPinned(true, id: item.id)
        fixture.palette.deleteClipboardItem(item.id)
        fixture.palette.clearClipboardHistory()
        XCTAssertEqual(mutationCalls, 0)
    }

    func testClipboardClearFailureKeepsItemsAndShowsError() async throws {
        enum ClearFailure: Error { case saveFailed }
        let failed = expectation(description: "Clipboard clear failed")
        var resignKey: (() -> Void)?
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.confirmClearClipboardHistory = {
                resignKey?()
                return true
            }
            environment.clearClipboardHistory = { _ in
                failed.fulfill()
                throw ClearFailure.saveFailed
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.selectMode(.clipboard)
        let itemCount = fixture.palette.clipboardItems.count
        resignKey = { fixture.palette.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification)) }

        let error = String(localized: "Could not clear clipboard history.")
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        let rendered = expectation(description: "The shell draws the clipboard clear failure")
        let previousTree = shell.onTree
        defer { shell.onTree = previousTree }
        shell.onTree = {
            previousTree?()
            guard !shell.surface.layout.core.elements(matching: {
                $0.text != 0 && shell.surface.text?.string($0.text) == error
            }).isEmpty else { return }
            shell.onTree = previousTree
            rendered.fulfill()
        }
        fixture.palette.clearClipboardHistory()
        await fulfillment(of: [failed, rendered], timeout: failureBound)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(fixture.palette.clipboardItems.count, itemCount)
        XCTAssertEqual(fixture.palette.clipboardErrorText, error)
        XCTAssertEqual(
            fixture.palette.shellData(size: fixture.palette.presentation.shellLayoutSize(expanded: true)).error,
            error
        )
        resignKey?()
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testCommandSelectionRunsThroughDispatcherAndDismisses() throws {
        var dispatched: [HotkeyCommand] = []
        let fixture = CommandPaletteFocusFixture { environment in
            environment.performCommand = { _, command in
                dispatched.append(command)
                return .executed
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.selectMode(.commands)
        fixture.palette.selectedItemID = .command("openMenuAnywhere")
        fixture.palette.selectCurrent()

        XCTAssertEqual(dispatched, [.openMenuAnywhere])
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testCommandForInactiveLayoutCannotBeSelected() throws {
        var dispatched: [HotkeyCommand] = []
        let fixture = CommandPaletteFocusFixture { environment in
            environment.performCommand = { _, command in
                dispatched.append(command)
                return .executed
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let incompatible = try XCTUnwrap(fixture.palette.commandItems.first { !$0.isLayoutCompatible })

        fixture.palette.selectMode(.commands)
        fixture.palette.selectedItemID = .command(incompatible.id)
        fixture.palette.selectCurrent()

        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertTrue(fixture.palette.isVisible)
    }

    func testSelectingPaletteToggleClosesWithoutReopening() throws {
        var dispatched: [HotkeyCommand] = []
        let fixture = CommandPaletteFocusFixture { environment in
            environment.performCommand = { _, command in
                dispatched.append(command)
                return .executed
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.selectMode(.commands)
        fixture.palette.selectedItemID = .command("openCommandPalette")
        fixture.palette.selectCurrent()

        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertTrue(dispatched.isEmpty)
    }

    func testSelectingPaletteModeCommandClearsQueryAndSwitchesModeInPlace() throws {
        var dispatched: [HotkeyCommand] = []
        let fixture = CommandPaletteFocusFixture { environment in
            environment.performCommand = { _, command in
                dispatched.append(command)
                return .executed
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.selectMode(.commands)
        fixture.palette.searchText = "clipboard"
        fixture.palette.selectedItemID = .command("openCommandPalette.clipboard")
        fixture.palette.selectCurrent()

        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertEqual(fixture.palette.selectedMode, .clipboard)
        XCTAssertEqual(fixture.palette.searchText, "")
        XCTAssertEqual(fixture.palette.filteredClipboardItems.map(\.title), ["Alpha", "Beta"])
        XCTAssertTrue(dispatched.isEmpty)
    }

    func testSelectingLauncherModeCommandStartsWithEmptyQuery() throws {
        for mode in [CommandPaletteMode.applications, .files] {
            var submittedQueries: [String] = []
            let fixture = CommandPaletteFocusFixture { environment in
                environment.submitApplicationSearch = { _, query, _, _, _ in submittedQueries.append(query) }
                environment.submitFileSearch = { _, query, _, _, _ in submittedQueries.append(query) }
            }
            defer { fixture.cleanup() }
            _ = try fixture.show(mode: .commands)

            fixture.palette.searchText = mode.rawValue
            fixture.palette.selectedItemID = .command("openCommandPalette.\(mode.rawValue)")
            fixture.palette.selectCurrent()

            XCTAssertTrue(fixture.palette.isVisible)
            XCTAssertEqual(fixture.palette.selectedMode, mode)
            XCTAssertEqual(submittedQueries, [""])
        }
    }

    func testSelectingCurrentPaletteModeCommandKeepsQueryAndStaysOpen() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .commands)

        fixture.palette.searchText = "commands"
        fixture.palette.selectedItemID = .command("openCommandPalette.commands")
        fixture.palette.selectCurrent()

        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertEqual(fixture.palette.selectedMode, .commands)
        XCTAssertEqual(fixture.palette.searchText, "commands")
        XCTAssertEqual(fixture.palette.selectedItemID, .command("openCommandPalette.commands"))
    }

    func testCommandWaitsForCapturedAppAndWindowFocus() {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let app = NSRunningApplication.current
        var frontmostApp: NSRunningApplication?
        var focusedWindowID: CGWindowID = 43
        var dispatched: [HotkeyCommand] = []
        var environment = CommandPaletteEnvironment()
        environment.ownProcessIdentifier = { -1 }
        environment.runningApplication = { pid in pid == app.processIdentifier ? app : nil }
        environment.frontmostApplication = { frontmostApp }
        environment.restoreCommandFocus = { _ in true }
        environment.focusedWindowID = { _ in focusedWindowID }
        environment.performCommand = { _, command in
            dispatched.append(command)
            return .executed
        }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        let target = CommandPaletteFocusTarget(app: .init(app: app), focusedWindow: nil, focusedWindowID: 42)

        executor.perform(.command(fixture.controller, .openMenuAnywhere, target))
        XCTAssertTrue(dispatched.isEmpty)
        frontmostApp = app
        executor.applicationActivated(pid: app.processIdentifier)
        XCTAssertTrue(dispatched.isEmpty)
        focusedWindowID = 42
        executor.focusedWindowChanged(pid: app.processIdentifier)
        executor.focusedWindowChanged(pid: app.processIdentifier)
        XCTAssertEqual(dispatched, [.openMenuAnywhere])
    }

    func testCancelledCommandHandoffDoesNotDispatch() {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let app = NSRunningApplication.current
        var frontmostApp: NSRunningApplication?
        var dispatched: [HotkeyCommand] = []
        var presentedMessages: [String] = []
        var environment = CommandPaletteEnvironment()
        environment.ownProcessIdentifier = { -1 }
        environment.runningApplication = { pid in pid == app.processIdentifier ? app : nil }
        environment.frontmostApplication = { frontmostApp }
        environment.restoreCommandFocus = { _ in true }
        environment.performCommand = { _, command in
            dispatched.append(command)
            return .executed
        }
        environment.presentCommandFailure = { presentedMessages.append($0) }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        let target = CommandPaletteFocusTarget(app: .init(app: app), focusedWindow: nil, focusedWindowID: nil)

        executor.perform(.command(fixture.controller, .openMenuAnywhere, target))
        executor.cancelPendingCommand()
        frontmostApp = app
        executor.applicationActivated(pid: app.processIdentifier)
        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertTrue(presentedMessages.isEmpty)
    }

    func testUnrelatedActivationCancelsCommandHandoff() {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let app = NSRunningApplication.current
        var frontmostApp: NSRunningApplication?
        var dispatched: [HotkeyCommand] = []
        var presentedMessages: [String] = []
        var environment = CommandPaletteEnvironment()
        environment.ownProcessIdentifier = { -1 }
        environment.runningApplication = { pid in pid == app.processIdentifier ? app : nil }
        environment.frontmostApplication = { frontmostApp }
        environment.restoreCommandFocus = { _ in true }
        environment.performCommand = { _, command in
            dispatched.append(command)
            return .executed
        }
        environment.presentCommandFailure = { presentedMessages.append($0) }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        let target = CommandPaletteFocusTarget(app: .init(app: app), focusedWindow: nil, focusedWindowID: nil)

        executor.perform(.command(fixture.controller, .openMenuAnywhere, target))
        executor.applicationActivated(pid: app.processIdentifier + 1)
        frontmostApp = app
        executor.applicationActivated(pid: app.processIdentifier)
        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertEqual(presentedMessages, ["Focus moved to another app."])
    }

    func testUnavailableCommandTargetReportsFailureWithoutRetargeting() {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let app = NSRunningApplication.current
        var dispatched = false
        var presentedMessages: [String] = []
        var environment = CommandPaletteEnvironment()
        environment.ownProcessIdentifier = { -1 }
        environment.runningApplication = { _ in nil }
        environment.performCommand = { _, _ in
            dispatched = true
            return .executed
        }
        environment.presentCommandFailure = { presentedMessages.append($0) }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        let target = CommandPaletteFocusTarget(app: .init(app: app), focusedWindow: nil, focusedWindowID: nil)

        executor.perform(.command(fixture.controller, .openMenuAnywhere, target))

        XCTAssertFalse(dispatched)
        XCTAssertEqual(presentedMessages, ["The original app is no longer available."])
    }

    func testCommandDispatcherFailureIsReported() {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        var presentedMessages: [String] = []
        var environment = CommandPaletteEnvironment()
        environment.performCommand = { _, _ in .windowActionFailed }
        environment.presentCommandFailure = { presentedMessages.append($0) }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)

        executor.perform(.command(fixture.controller, .windowState(.close), nil))

        XCTAssertEqual(presentedMessages, ["The command could not be completed."])
    }

    func testCommandNoChangeDoesNotPresentFailure() {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        var presentedMessages: [String] = []
        var environment = CommandPaletteEnvironment()
        environment.performCommand = { _, _ in .noChange }
        environment.presentCommandFailure = { presentedMessages.append($0) }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)

        executor.perform(.command(fixture.controller, .openMenuAnywhere, nil))

        XCTAssertTrue(presentedMessages.isEmpty)
    }

    func testClipboardPasteWaitsForExpectedAppAndWindowAndCancelPreventsLatePaste() async {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let app = NSRunningApplication.current
        let itemID = UUID()
        var frontmostApp: NSRunningApplication?
        var focusedWindowID: CGWindowID?
        var ownWindowKey = true
        var focusedInputPID: pid_t?
        var pasteCount = 0
        var copyCount = 0
        var readyExpectation: XCTestExpectation?
        var environment = CommandPaletteEnvironment()
        environment.runningApplication = { pid in pid == app.processIdentifier ? app : nil }
        environment.frontmostApplication = {
            readyExpectation?.fulfill()
            readyExpectation = nil
            return frontmostApp
        }
        environment.focusedWindowID = { _ in focusedWindowID }
        environment.isOwnWindowKey = { ownWindowKey }
        environment.focusedInputProcessIdentifier = { focusedInputPID }
        environment.copyClipboardItem = { _, _ in
            copyCount += 1
            return true
        }
        environment.isAccessibilityTrusted = { true }
        environment.isSecureInputActive = { false }
        environment.isLockScreenActive = { _ in false }
        environment.postPasteShortcut = {
            pasteCount += 1
            return true
        }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        let focusTarget = CommandPaletteFocusTarget(
            app: .init(app: app), focusedWindow: nil, focusedWindowID: 42
        )
        let pasteTarget = CommandPaletteClipboardPasteTarget(focusTarget: focusTarget, expectedWindowId: 42)

        let firstReady = expectation(description: "First paste is waiting for focus")
        readyExpectation = firstReady
        executor.perform(.pasteClipboard(fixture.controller, itemID, pasteTarget, false))
        await fulfillment(of: [firstReady], timeout: failureBound)
        XCTAssertEqual(copyCount, 1)
        XCTAssertEqual(pasteCount, 0)

        frontmostApp = app
        executor.applicationActivated(pid: app.processIdentifier)
        XCTAssertEqual(pasteCount, 0)
        focusedWindowID = 42
        executor.focusedWindowChanged(pid: app.processIdentifier)
        XCTAssertEqual(pasteCount, 0)
        ownWindowKey = false
        executor.focusedWindowChanged(pid: app.processIdentifier)
        XCTAssertEqual(pasteCount, 0)
        focusedInputPID = app.processIdentifier
        executor.focusedWindowChanged(pid: app.processIdentifier)
        XCTAssertEqual(pasteCount, 1)

        frontmostApp = nil
        focusedWindowID = nil
        ownWindowKey = true
        focusedInputPID = nil
        let secondReady = expectation(description: "Second paste is waiting for focus")
        readyExpectation = secondReady
        executor.perform(.pasteClipboard(fixture.controller, itemID, pasteTarget, false))
        await fulfillment(of: [secondReady], timeout: failureBound)
        XCTAssertEqual(copyCount, 2)
        executor.cancelPendingCommand()
        frontmostApp = app
        focusedWindowID = 42
        executor.applicationActivated(pid: app.processIdentifier)
        executor.focusedWindowChanged(pid: app.processIdentifier)
        XCTAssertEqual(pasteCount, 1)
    }

    func testPasteWithoutWindowTargetCopiesWithoutSendingShortcut() async {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let app = NSRunningApplication.current
        let copied = expectation(description: "Clipboard item copied")
        var pasteCount = 0
        var environment = CommandPaletteEnvironment()
        environment.runningApplication = { pid in pid == app.processIdentifier ? app : nil }
        environment.frontmostApplication = { app }
        environment.copyClipboardItem = { _, _ in
            copied.fulfill()
            return true
        }
        environment.isAccessibilityTrusted = { true }
        environment.isSecureInputActive = { false }
        environment.isLockScreenActive = { _ in false }
        environment.postPasteShortcut = {
            pasteCount += 1
            return true
        }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        executor.perform(.pasteClipboard(fixture.controller, UUID(), nil, false))
        await fulfillment(of: [copied], timeout: failureBound)
        XCTAssertEqual(pasteCount, 0)
        executor.focusedWindowChanged(pid: app.processIdentifier)
        XCTAssertEqual(pasteCount, 0)
    }

    func testSecureInputBlocksClipboardPasteAfterCopy() async {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let copied = expectation(description: "Clipboard item copied before secure input check")
        let awaitingFocus = expectation(description: "Paste waits for target focus")
        let app = NSRunningApplication.current
        var frontmostApp: NSRunningApplication?
        var readyExpectation: XCTestExpectation? = awaitingFocus
        var secureInputChecks = 0
        var pasteCount = 0
        var environment = CommandPaletteEnvironment()
        environment.runningApplication = { pid in pid == app.processIdentifier ? app : nil }
        environment.frontmostApplication = {
            readyExpectation?.fulfill()
            readyExpectation = nil
            return frontmostApp
        }
        environment.focusedWindowID = { _ in 42 }
        environment.isOwnWindowKey = { false }
        environment.focusedInputProcessIdentifier = { app.processIdentifier }
        environment.copyClipboardItem = { _, _ in
            copied.fulfill()
            return true
        }
        environment.isSecureInputActive = {
            secureInputChecks += 1
            return secureInputChecks > 1
        }
        environment.isAccessibilityTrusted = { true }
        environment.isLockScreenActive = { _ in false }
        environment.postPasteShortcut = {
            pasteCount += 1
            return true
        }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        let focusTarget = CommandPaletteFocusTarget(app: .init(app: app), focusedWindow: nil, focusedWindowID: 42)
        let pasteTarget = CommandPaletteClipboardPasteTarget(focusTarget: focusTarget, expectedWindowId: 42)

        executor.perform(.pasteClipboard(fixture.controller, UUID(), pasteTarget, false))
        await fulfillment(of: [copied, awaitingFocus], timeout: failureBound)
        XCTAssertEqual(secureInputChecks, 1)
        XCTAssertEqual(pasteCount, 0)
        frontmostApp = app
        executor.applicationActivated(pid: app.processIdentifier)
        XCTAssertEqual(secureInputChecks, 2)
        XCTAssertEqual(pasteCount, 0)
    }

    func testPasteWithoutFormattingUsesPlainTextCopy() async {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let plainCopied = expectation(description: "Plain text representation copied")
        var environment = CommandPaletteEnvironment()
        environment.copyClipboardItem = { _, _ in
            XCTFail("Formatted copy must not run")
            return false
        }
        environment.copyClipboardItemPlainText = { _, _ in
            plainCopied.fulfill()
            return true
        }
        let focusSession = CommandPaletteFocusSession(environment: environment)
        let executor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)

        executor.perform(.pasteClipboard(fixture.controller, UUID(), nil, true))
        await fulfillment(of: [plainCopied], timeout: failureBound)
    }

    func testShellPrewarmWaitsUntilThePaletteCloses() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let manager = fixture.controller.workspaceBarManager
        _ = try fixture.show()
        let shown = try XCTUnwrap(fixture.palette.presentation.shell)
        let host = makePaletteHost(fixture.root)
        manager.shellHost = host
        defer { manager.shellHost = nil }
        XCTAssertNotEqual(host.config, shown.config)
        fixture.palette.prewarmShell(from: manager)
        XCTAssertTrue(fixture.palette.presentation.shell === shown)
        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertFalse(fixture.palette.isVisible)
        let rebuilt = try XCTUnwrap(fixture.palette.presentation.shell)
        XCTAssertFalse(rebuilt === shown)
        XCTAssertEqual(rebuilt.config, host.config)
    }

    func testShellRebuildsWhenStyleFilesChangeAndWaitsUntilThePaletteCloses() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let host = makePaletteHost(fixture.root)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: host.shellDirectory), [])
        host.config = ShellConfig.resolve(shellDirectory: host.shellDirectory)
        fixture.controller.workspaceBarManager.shellHost = host
        defer { fixture.controller.workspaceBarManager.shellHost = nil }
        let look = try XCTUnwrap(host.config.file("lib/look.luau"))
        func editLook() throws {
            let text = try String(contentsOf: look, encoding: .utf8)
            try (text + "\n").write(to: look, atomically: true, encoding: .utf8)
        }

        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
        let original = try XCTUnwrap(fixture.palette.presentation.shell)
        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
        XCTAssertTrue(fixture.palette.presentation.shell === original)

        try editLook()
        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
        let updated = try XCTUnwrap(fixture.palette.presentation.shell)
        XCTAssertFalse(updated === original)

        _ = try fixture.show()
        XCTAssertTrue(fixture.palette.presentation.shell === updated)
        try editLook()
        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
        XCTAssertTrue(fixture.palette.presentation.shell === updated)
        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertFalse(fixture.palette.isVisible)
        let reopened = try XCTUnwrap(fixture.palette.presentation.shell)
        XCTAssertFalse(reopened === updated)
    }

    func testShellPaletteUsesTheSelectedStyleWithTheBarOff() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let manager = fixture.controller.workspaceBarManager
        XCTAssertNil(manager.shellHost)
        let shellDirectory = manager.shellConfiguration.shellDirectory
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shellDirectory), [])
        let profile = try XCTUnwrap(ShellStyleFixture.names().first)
        XCTAssertTrue(try ShellProfiles.select(profile, in: shellDirectory))
        let managed = shellDirectory.appendingPathComponent(
            "\(ShellDefaults.profile)/widgets/\(ShellWidgetHost.commandPaletteWidget)", isDirectory: true
        )
        try FileManager.default.removeItem(at: managed)
        manager.shellConfigurationSaved(ShellConfig.resolve(shellDirectory: shellDirectory))
        fixture.palette.prewarmShell(from: manager)
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        XCTAssertEqual(shell.config.profile, profile)
        XCTAssertFalse(shell.fallback)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.appendingPathComponent("init.luau").path))
        try awaitPaletteTree(shell) { shell.hasTree }
    }

    func testShellChromeStaysHiddenUntilTheFirstTreeArrives() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        let firstTree = expectation(description: "The palette widget delivers its first tree")
        let applyChrome = shell.onTree
        shell.onTree = {
            applyChrome?()
            firstTree.fulfill()
        }
        fixture.palette.syncShellContent()
        XCTAssertFalse(shell.hasTree)
        XCTAssertTrue(shell.chrome.effectView.isHidden)
        XCTAssertTrue(shell.chrome.glassView.isHidden)
        wait(for: [firstTree], timeout: failureBound)
        XCTAssertTrue(shell.hasTree)
        XCTAssertEqual(shell.chrome.glassView.isHidden, !shell.surface.chrome.glass)
        XCTAssertEqual(shell.chrome.effectView.isHidden, shell.surface.chrome.glass || shell.surface.chrome.clear)
    }

    func testShellCommandRowsMatchTheListAndGroupOnlyWithoutAQuery() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.selectMode(.commands)
        let size = wholeCommandListSize(fixture)
        let items = Dictionary(uniqueKeysWithValues: fixture.palette.commandItems.map { ($0.id, $0) })
        guard case let .command(selectedID)? = fixture.palette.selectedItemID else {
            return XCTFail("Commands mode opens with a command selected")
        }

        let grouped = fixture.palette.shellData(size: size)
        var sections: [(ShellCommandPaletteRowKind, String)] = []
        for category in HotkeyCategory.allCases {
            let members = fixture.palette.commandItems.filter { $0.spec.category == category }
            guard !members.isEmpty else { continue }
            sections.append((.heading, category.localizedDisplayName))
            sections += members.map { (.command, $0.spec.localizedTitle) }
        }
        XCTAssertEqual(grouped.first, 0)
        XCTAssertEqual(grouped.rows.map(\.kind), sections.map(\.0))
        XCTAssertEqual(grouped.rows.map(\.title), sections.map(\.1))
        XCTAssertEqual(grouped.rows.filter(\.selected).map(\.id), [selectedID])
        XCTAssertEqual(grouped.selected, selectedID)
        XCTAssertEqual(grouped.total, grouped.rows.count)
        XCTAssertTrue(grouped.rows.allSatisfy { $0.kind != .heading || (!$0.enabled && $0.badges.isEmpty) })
        let commands = grouped.rows.filter { $0.kind == .command }
        XCTAssertTrue(commands.contains { !$0.enabled })
        XCTAssertTrue(commands.contains { $0.badges.contains { $0.tone == .shortcutMuted } })
        for row in commands {
            let item = try XCTUnwrap(items[row.id])
            XCTAssertEqual(row.subtitle, "")
            XCTAssertEqual(row.enabled, item.isLayoutCompatible)
            XCTAssertEqual(row.badges, [
                .init(
                    text: item.spec.layoutCompatibility.localizedDisplayName,
                    tone: item.isLayoutCompatible ? .neutral : .warning,
                    symbol: nil
                ),
                .init(text: item.shortcut, tone: item.hasShortcut ? .shortcut : .shortcutMuted, symbol: nil)
            ])
        }

        for query in [".", "focus"] {
            fixture.palette.searchText = query
            let flat = fixture.palette.shellData(size: size)
            XCTAssertEqual(flat.rows.map(\.id), fixture.palette.filteredCommandItems.map(\.id), query)
            XCTAssertEqual(
                flat.rows.map(\.subtitle),
                fixture.palette.filteredCommandItems.map(\.spec.category.localizedDisplayName),
                query
            )
        }
    }

    func testShellActivateRunsOnlyEnabledCommandRows() throws {
        var dispatched: [HotkeyCommand] = []
        let fixture = CommandPaletteFocusFixture { environment in
            environment.performCommand = { _, command in
                dispatched.append(command)
                return .executed
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.selectMode(.commands)
        fixture.palette.expandResults()
        let rows = fixture.palette.shellData(size: wholeCommandListSize(fixture)).rows
        let disabled = rows.filter { !$0.enabled }
        XCTAssertTrue(disabled.contains { $0.kind == .heading })
        XCTAssertTrue(disabled.contains { $0.kind == .command })
        let selection = fixture.palette.selectedItemID
        for row in disabled {
            fixture.palette.performShellCommand("activate " + row.id)
        }
        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertEqual(fixture.palette.selectedItemID, selection)
        XCTAssertTrue(fixture.palette.isVisible)

        let target = try XCTUnwrap(fixture.palette.commandItems.first { $0.spec.command == .openMenuAnywhere })
        fixture.palette.performShellCommand("activate " + target.id)
        XCTAssertEqual(dispatched, [target.spec.command])
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testShellListDrawsOnlyNearbyRowsAndRevealsTheLastSelection() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let host = makePaletteHost(fixture.root)
        fixture.controller.workspaceBarManager.shellHost = host
        defer { fixture.controller.workspaceBarManager.shellHost = nil }
        let (shell, tokens) = try showLongWindowList(fixture, host: host)
        let ids = tokens.map(CommandPaletteController.shellRowID)
        func drawn(_ id: String) -> Bool {
            shell.surface.layout.handle(forKey: id) != nil
        }
        func fullyVisible(_ id: String) -> Bool {
            paletteRowFullyVisible(shell, id)
        }

        let opened = try XCTUnwrap(shell.published)
        XCTAssertLessThan(opened.rows.count, tokens.count)
        XCTAssertEqual(opened.first, 0)
        XCTAssertGreaterThan(opened.after, 0)
        XCTAssertTrue(fullyVisible(ids[0]))

        try scrollPaletteToEnd(shell, ids: ids)
        XCTAssertFalse(drawn(ids[0]))
        let scrolled = try XCTUnwrap(shell.published)
        XCTAssertEqual(scrolled.selected, ids[0])
        XCTAssertEqual(scrolled.first + scrolled.rows.count, tokens.count)
        XCTAssertGreaterThan(scrolled.before, 0)

        fixture.palette.moveSelection(by: 1)
        XCTAssertEqual(fixture.palette.selectedItemID, .window(tokens[1]))
        try awaitPaletteTree(shell) { fullyVisible(ids[1]) }
        XCTAssertFalse(drawn(ids[ids.count - 1]))
        XCTAssertEqual(shell.published?.selected, ids[1])
    }

    func testShellRedrawRepaintsWithTheNewThemeAndKeepsScrollAndComposition() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let host = makePaletteHost(fixture.root)
        fixture.controller.workspaceBarManager.shellHost = host
        defer { fixture.controller.workspaceBarManager.shellHost = nil }
        let (shell, tokens) = try showLongWindowList(fixture, host: host)
        let ids = tokens.map(CommandPaletteController.shellRowID)
        let panel = try XCTUnwrap(fixture.palette.presentation.panel)
        try scrollPaletteToEnd(shell, ids: ids)
        let published = try XCTUnwrap(shell.published)
        XCTAssertGreaterThan(published.before, 0)
        let scrolled = try XCTUnwrap(shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey))
        let offset = shell.surface.layout.core.scrollOffset(of: scrolled)
        shell.focusField(in: panel)
        shell.field.beganEditing()
        let editor = try XCTUnwrap(shell.field.textEditor)
        editor.setMarkedText(
            "日本",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let foreground = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        var theme = host.config.theme
        theme.light[ShellRole.foreground.rawValue] = foreground
        theme.dark[ShellRole.foreground.rawValue] = foreground
        XCTAssertNotEqual(shell.field.field?.textColor?.cgColor, foreground.cgColor)
        let resources = try XCTUnwrap(fixture.controller.workspaceBarManager.commandPaletteResources)
        resources.palette.refresh(theme: theme, appearance: panel.effectiveAppearance)
        shell.redraw()

        XCTAssertTrue(fixture.palette.presentation.shell === shell)
        XCTAssertEqual(shell.field.field?.textColor?.cgColor, foreground.cgColor)
        let redrawn = try XCTUnwrap(shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey))
        XCTAssertEqual(shell.surface.layout.core.scrollOffset(of: redrawn), offset)
        XCTAssertEqual(shell.published, published)
        XCTAssertTrue(shell.drawsPublishedList())
        XCTAssertTrue(paletteRowFullyVisible(shell, ids[ids.count - 1]))
        XCTAssertTrue(panel.firstResponder === shell.field.textEditor)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(shell.field.text, "日本")
    }

    func testShellRedrawKeepsAScrollPastTheDrawnRows() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let host = makePaletteHost(fixture.root)
        fixture.controller.workspaceBarManager.shellHost = host
        defer { fixture.controller.workspaceBarManager.shellHost = nil }
        let (shell, tokens) = try showLongWindowList(fixture, host: host)
        let ids = tokens.map(CommandPaletteController.shellRowID)
        let list = try XCTUnwrap(shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey))
        let listFrame = CGRect(shell.surface.layout.core.absoluteFrame(of: list))
        let listLength = ids.reduce(Float(0)) { $0 + shell.rowWindow.advance(of: $1) }
        XCTAssertTrue(shell.surface.scroll(
            at: CGPoint(x: listFrame.midX, y: listFrame.midY),
            event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: CGFloat(listLength / 2))
        ))
        let offset = shell.surface.layout.core.scrollOffset(of: list)
        XCTAssertFalse(ids.contains { paletteRowFullyVisible(shell, $0) })

        shell.redraw()

        let redrawn = try XCTUnwrap(shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey))
        XCTAssertEqual(shell.surface.layout.core.scrollOffset(of: redrawn), offset)
        try awaitPaletteTree(shell) { paletteSettled(shell, ids: ids) }
        XCTAssertGreaterThan(try XCTUnwrap(shell.published).first, 0)
        XCTAssertTrue(ids.contains { paletteRowFullyVisible(shell, $0) })
    }

    func testShellFilterAfterADeepScrollKeepsTheMatches() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let host = makePaletteHost(fixture.root)
        fixture.controller.workspaceBarManager.shellHost = host
        defer { fixture.controller.workspaceBarManager.shellHost = nil }
        let (shell, tokens) = try showLongWindowList(fixture, host: host)
        let ids = tokens.map(CommandPaletteController.shellRowID)
        try scrollPaletteToEnd(shell, ids: ids)
        let visible = try XCTUnwrap(shell.published).rows.map(\.id).filter { paletteRowFullyVisible(shell, $0) }

        let query = "Window 7"
        fixture.palette.searchText = query
        let matches = fixture.palette.filteredWindowItems.map { CommandPaletteController.shellRowID($0.id) }
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(Set(matches).isDisjoint(with: visible))
        try awaitPaletteTree(shell) { shell.published?.query == query && paletteSettled(shell, ids: matches) }
        let filtered = try XCTUnwrap(shell.published)
        XCTAssertEqual(filtered.state, "results")
        XCTAssertEqual(filtered.total, matches.count)
        XCTAssertEqual(filtered.first + filtered.rows.count, matches.count)
        XCTAssertTrue(paletteRowFullyVisible(shell, matches[matches.count - 1]))
    }

    func testShellRevealKeepsTheLastRowInViewWhenTallerRowsChangeTheEstimate() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let host = makePaletteHost(fixture.root)
        fixture.controller.workspaceBarManager.shellHost = host
        defer { fixture.controller.workspaceBarManager.shellHost = nil }
        let marked = Self.longListCount / 2
        let (shell, tokens) = try showLongWindowList(fixture, host: host) { $0 >= marked ? ["work"] : [] }
        let ids = tokens.map(CommandPaletteController.shellRowID)
        XCTAssertTrue(try XCTUnwrap(shell.published).rows.allSatisfy { (ids.firstIndex(of: $0.id) ?? marked) < marked })
        func spacer() -> Float? {
            shell.surface.layout.core.firstHandle(withKey: CommandPaletteShellPresenter.beforeKey)
                .map { shell.surface.layout.core.layoutFrame(of: $0).height }
        }

        fixture.palette.moveSelection(by: -1)
        XCTAssertEqual(fixture.palette.selectedItemID, .window(tokens[tokens.count - 1]))
        try awaitPaletteTree(shell) { paletteRowFullyVisible(shell, ids[ids.count - 1]) }
        let revealed = try XCTUnwrap(spacer())
        try awaitPaletteTree(shell) { paletteSettled(shell, ids: ids) }

        XCTAssertGreaterThan(shell.rowWindow.advance(of: ids[ids.count - 1]), shell.rowWindow.advance(of: ids[0]))
        XCTAssertNotEqual(try XCTUnwrap(spacer()), revealed)
        XCTAssertTrue(paletteRowFullyVisible(shell, ids[ids.count - 1]))
        XCTAssertEqual(shell.published?.selected, ids[ids.count - 1])
    }

    private func wholeCommandListSize(_ fixture: CommandPaletteFocusFixture) -> CGSize {
        XCTAssertEqual(fixture.palette.presentation.shell?.rowWindow.viewport, 0)
        let entries = fixture.palette.commandItems.count + HotkeyCategory.allCases.count
        return CGSize(
            width: fixture.palette.presentation.shellLayoutSize(expanded: true).width,
            height: CGFloat(entries) * CGFloat(CommandPaletteRowWindow.shortestRow)
        )
    }

    private static let longListCount = 200
    private static let longListProcess: pid_t = 92_011

    private func paletteRowFullyVisible(_ shell: CommandPaletteShellPresenter, _ id: String) -> Bool {
        guard let row = shell.surface.layout.handle(forKey: id),
              let list = shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey)
        else { return false }
        let frame = shell.surface.layout.core.absoluteFrame(of: row)
        let viewport = shell.surface.layout.core.absoluteFrame(of: list)
        return frame.y >= viewport.y && frame.y + frame.height <= viewport.y + viewport.height
    }

    private func scrollPaletteToEnd(_ shell: CommandPaletteShellPresenter, ids: [String]) throws {
        let list = try XCTUnwrap(shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey))
        let listFrame = CGRect(shell.surface.layout.core.absoluteFrame(of: list))
        let listLength = ids.reduce(Float(0)) { $0 + shell.rowWindow.advance(of: $1) }
        XCTAssertTrue(shell.surface.scroll(
            at: CGPoint(x: listFrame.midX, y: listFrame.midY),
            event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: CGFloat(listLength))
        ))
        try awaitPaletteTree(shell) {
            paletteRowFullyVisible(shell, ids[ids.count - 1]) && paletteSettled(shell, ids: ids)
        }
    }

    private func showLongWindowList(
        _ fixture: CommandPaletteFocusFixture,
        host: ShellWidgetHost,
        marks: (Int) -> [String] = { _ in [] }
    ) throws -> (CommandPaletteShellPresenter, [WindowToken]) {
        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        _ = try fixture.show()
        XCTAssertTrue(fixture.palette.presentation.shell === shell)
        let tokens = (0 ..< Self.longListCount).map { WindowToken(pid: Self.longListProcess, windowId: $0) }
        fixture.palette.windows = tokens.enumerated().map { index, token in
            CommandPaletteWindowItem(
                id: token, handle: WindowHandle(id: token), title: "Window \(token.windowId)", appName: "Notes",
                workspaceName: "1", isAppHidden: false, markNames: marks(index)
            )
        }
        fixture.palette.expandResults()
        let ids = tokens.map(CommandPaletteController.shellRowID)
        try awaitPaletteTree(shell) {
            shell.published?.total == tokens.count && shell.surface.layout.handle(forKey: ids[0]) != nil
                && paletteSettled(shell, ids: ids)
        }
        return (shell, tokens)
    }

    private func paletteSettled(_ shell: CommandPaletteShellPresenter, ids: [String]) -> Bool {
        guard let published = shell.published, shell.rowWindow.viewport > 0, shell.drawsPublishedList() else {
            return false
        }
        let slice = shell.slice(ids: ids, selected: nil, limit: Float(published.height))
        return published.first == slice.range.lowerBound && published.rows.count == slice.range.count
            && Float(published.before) == slice.before && Float(published.after) == slice.after
    }

    private func showAndWaitForEditing(_ fixture: CommandPaletteFocusFixture) async throws -> NSPanel {
        let panel = try fixture.show()
        await waitForSearchEditing(panel)
        return panel
    }

    private func waitForSearchEditing(_ panel: NSPanel) async {
        let editing = expectation(description: "Search becomes the first responder")
        let observation = panel.publisher(for: \.firstResponder, options: [.initial, .new])
            .first { $0 is NSTextView }
            .sink { _ in editing.fulfill() }
        await fulfillment(of: [editing], timeout: failureBound)
        observation.cancel()
    }

    private func sendKey(keyCode: UInt16, characters: String, to panel: NSPanel) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        NSApp.sendEvent(event)
    }
}

@MainActor
final class CommandPaletteFocusFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OmniWMPaletteFocusTests-\(UUID())")
    let controller: WMController
    let palette: CommandPaletteController
    let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
    private(set) var panel: NSPanel?

    init(
        initialMode: CommandPaletteMode = .windows,
        animationsEnabled: Bool = false,
        configureEnvironment: ((inout CommandPaletteEnvironment) -> Void)? = nil
    ) {
        _ = NSApplication.shared
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.commandPaletteLastMode = initialMode
        controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard"),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics"),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        var environment = CommandPaletteEnvironment()
        environment.frontmostApplication = { nil }
        environment.runningApplication = { _ in nil }
        environment.isClipboardHistoryEnabled = { _ in true }
        environment.clipboardItems = { _ in
            ["Alpha", "Beta"].map { title in
                ClipboardPaletteItem(
                    id: UUID(),
                    title: title,
                    subtitle: "",
                    kind: .text,
                    sourceBundleIdentifier: nil,
                    lastCopiedAt: Date(timeIntervalSince1970: 0),
                    numberOfCopies: 1,
                    byteCount: title.utf8.count
                )
            }
        }
        configureEnvironment?(&environment)
        palette = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: animationsEnabled),
            environment: environment,
            ownedWindowRegistry: registry
        )
    }

    func show(mode: CommandPaletteMode? = nil) throws -> NSPanel {
        palette.show(wmController: controller, mode: mode)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.delegate === palette } as? NSPanel)
        panel.isReleasedWhenClosed = false
        self.panel = panel
        layout()
        return panel
    }

    func layout() {
        panel?.contentView?.needsLayout = true
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
    }

    func insertText(_ text: String) throws {
        let panel = try XCTUnwrap(panel)
        let editor = try XCTUnwrap(
            panel.firstResponder as? NSTextView,
            "visible=\(palette.isVisible) key=\(panel.isKeyWindow) responder=\(String(describing: panel.firstResponder))"
        )
        XCTAssertTrue(editor.isFieldEditor)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func cleanup() {
        if palette.isVisible {
            palette.toggle(wmController: controller)
        }
        if let panel {
            registry.unregister(panel)
            panel.close()
            panel.contentView = nil
            panel.delegate = nil
        }
        try? FileManager.default.removeItem(at: root)
    }
}

extension XCTestCase {
    @MainActor
    func awaitPaletteTree(_ shell: CommandPaletteShellPresenter, until condition: () -> Bool) throws {
        let previous = shell.onTree
        defer { shell.onTree = previous }
        while !condition() {
            let tree = expectation(description: "The palette applies its next tree")
            shell.onTree = {
                shell.onTree = previous
                previous?()
                tree.fulfill()
            }
            guard XCTWaiter().wait(for: [tree], timeout: failureBound) == .completed else {
                XCTFail("The palette stopped applying trees before the expected state")
                return
            }
        }
    }

    @MainActor
    func makePaletteHost(_ root: URL) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: root.appendingPathComponent("config"),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: root.appendingPathComponent("resources")),
            world: { ShellWorldData() },
            vars: { [:] },
            bars: { [:] },
            onLayoutChange: {},
            onCommand: { _, _ in },
            onMenu: { _ in },
            onPreview: { _ in },
            onDrag: { _ in },
            onPopoutChange: {},
            onTitleDemandChange: { _ in }
        )
    }
}
