// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
        await fulfillment(of: [revealed], timeout: 1)
        revealObservation.cancel()
        XCTAssertEqual(panel.frame.height, compactFrame.height, accuracy: 0.5)

        let intermediate = expectation(description: "Animated panel passes through intermediate height")
        let expanded = expectation(description: "Animated panel reaches expanded height")
        let resizeEvents = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .compactMap { ($0.object as? NSPanel)?.frame.height }
            .share()
        let intermediateObservation = resizeEvents
            .first { $0 > compactFrame.height + 10 && $0 < CommandPalettePanel.expandedHeight - 10 }
            .sink { _ in intermediate.fulfill() }
        let expandedObservation = resizeEvents
            .first { $0 >= CommandPalettePanel.expandedHeight - 0.5 }
            .sink { _ in expanded.fulfill() }

        try fixture.insertText("first")
        await fulfillment(of: [intermediate, expanded], timeout: 2)
        intermediateObservation.cancel()
        expandedObservation.cancel()
        fixture.layout()
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(panel.frame.height, CommandPalettePanel.expandedHeight, accuracy: 0.5)
        XCTAssertTrue(panel.firstResponder is NSTextView)
        try fixture.insertText(" second")
        XCTAssertEqual(fixture.palette.searchText, "first second")

        let closing = expectation(description: "Cancel animation reaches its closing frames")
        let closingObservation = resizeEvents
            .first { $0 < 180 && $0 > CommandPalettePanel.collapsedHeight + 10 }
            .sink { _ in closing.fulfill() }
        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertEqual(fixture.palette.searchText, "first second")
        await fulfillment(of: [closing], timeout: 2)
        closingObservation.cancel()
        XCTAssertEqual(fixture.palette.searchText, "first second")

        let reopenedPanel = try await showAndWaitForEditing(fixture)
        XCTAssertTrue(reopenedPanel === panel)
        let reopenedExpansion = expectation(description: "Reopened palette reaches expanded height")
        let reopenedObservation = resizeEvents
            .first { $0 >= CommandPalettePanel.expandedHeight - 0.5 }
            .sink { _ in reopenedExpansion.fulfill() }
        try fixture.insertText("reopened")
        await fulfillment(of: [reopenedExpansion], timeout: 2)
        reopenedObservation.cancel()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(fixture.palette.searchText, "reopened")
        XCTAssertTrue(panel.firstResponder is NSTextView)
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
        XCTAssertEqual(panel.frame.maxY, compactFrame.maxY, accuracy: 0.5)
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
        XCTAssertEqual(panel.frame.maxY, compactFrame.maxY, accuracy: 0.5)
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
        let requestedFrame = NSRect(
            x: initialFrame.minX + 24,
            y: initialFrame.minY + 20,
            width: initialFrame.width + 40,
            height: initialFrame.height + 32
        )
        panel.setFrame(requestedFrame, display: true)
        fixture.layout()
        let resizedFrame = panel.frame

        XCTAssertGreaterThan(resizedFrame.width, initialFrame.width + 20)
        XCTAssertGreaterThan(resizedFrame.height, initialFrame.height + 16)
        XCTAssertEqual(resizedFrame.minX, requestedFrame.minX, accuracy: 0.5)
        XCTAssertEqual(resizedFrame.minY, requestedFrame.minY, accuracy: 0.5)

        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertFalse(panel.isVisible)

        let reopenedPanel = try await showAndWaitForEditing(fixture)
        XCTAssertTrue(reopenedPanel === panel)
        XCTAssertFalse(fixture.palette.isExpanded)
        XCTAssertEqual(reopenedPanel.frame.minX, resizedFrame.minX, accuracy: 0.5)
        XCTAssertEqual(reopenedPanel.frame.width, resizedFrame.width, accuracy: 0.5)
        XCTAssertEqual(reopenedPanel.frame.maxY, resizedFrame.maxY, accuracy: 0.5)

        fixture.palette.selectMode(.clipboard)
        fixture.layout()
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(reopenedPanel.frame.minX, resizedFrame.minX, accuracy: 0.5)
        XCTAssertEqual(reopenedPanel.frame.width, resizedFrame.width, accuracy: 0.5)
        XCTAssertEqual(reopenedPanel.frame.height, resizedFrame.height, accuracy: 0.5)
        XCTAssertEqual(reopenedPanel.frame.maxY, resizedFrame.maxY, accuracy: 0.5)
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

    func testPalettePanelIsNonactivatingAndSearchRemainsFocused() async throws {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(originalPolicy) }
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(
            panel.isKeyWindow,
            "active=\(NSApp.isActive) visible=\(panel.isVisible) key=\(String(describing: NSApp.keyWindow))"
        )
        try fixture.insertText("search")
        XCTAssertEqual(fixture.palette.searchText, "search")
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
            try fixture.insertText(mode.rawValue)
            XCTAssertTrue(fixture.palette.searchText.hasSuffix(mode.rawValue))
            XCTAssertEqual(fixture.palette.selectedMode, mode)
        }
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
        let copied = expectation(description: "Selected clipboard item was copied")
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.copyClipboardItem = { _, _ in
                copied.fulfill()
                return true
            }
        }
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        fixture.palette.selectMode(.clipboard)

        try sendKey(keyCode: 36, characters: "\r", to: panel)
        await fulfillment(of: [copied], timeout: 1)
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
        await fulfillment(of: [firstPreview], timeout: 1)
        XCTAssertEqual(fixture.palette.clipboardPreview, .text("First full text"))

        observer?([second])
        await fulfillment(of: [secondPreview], timeout: 1)
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(second.id))
        XCTAssertEqual(fixture.palette.clipboardPreview, .text("Second full text"))

        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertNil(observer)
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

        fixture.palette.clearClipboardHistory()
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertEqual(fixture.palette.clipboardItems.count, itemCount)
        XCTAssertEqual(fixture.palette.clipboardStatusText, "Could not clear clipboard history.")
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
        await fulfillment(of: [firstReady], timeout: 1)
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
        await fulfillment(of: [secondReady], timeout: 1)
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
        await fulfillment(of: [copied], timeout: 1)
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
        await fulfillment(of: [copied, awaitingFocus], timeout: 1)
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
        await fulfillment(of: [plainCopied], timeout: 1)
    }

    func testCapturesFocusedManagedTokenBeforeActivatingPalette() throws {
        let token = WindowToken(pid: 92_401, windowId: 92_501)
        var events: [String] = []
        let fixture = CommandPaletteFocusFixture { environment in
            environment.focusedManagedWindowToken = { _ in
                events.append("capture")
                return token
            }
            environment.activateOmniWM = { events.append("activate") }
        }
        defer { fixture.cleanup() }

        _ = try fixture.show()

        XCTAssertEqual(fixture.palette.focusSession.focusedMarkTargetToken, token)
        XCTAssertEqual(events, ["capture", "activate"])
    }

    private func showAndWaitForEditing(_ fixture: CommandPaletteFocusFixture) async throws -> NSPanel {
        let panel = try fixture.show()
        let editing = expectation(description: "Search becomes the first responder")
        let observation = panel.publisher(for: \.firstResponder, options: [.initial, .new])
            .first { $0 is NSTextView }
            .sink { _ in editing.fulfill() }
        await fulfillment(of: [editing], timeout: 1)
        observation.cancel()
        return panel
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

    func show() throws -> NSPanel {
        palette.show(wmController: controller)
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
