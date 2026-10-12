// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import GhosttyKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalKeyMappingTests: XCTestCase {
    func testWindowForwardsFormerHardcodedShortcutsToContent() throws {
        let window = QuakeTerminalWindow()
        let view = KeyEquivalentView()
        window.contentView = view
        window.makeFirstResponder(view)
        defer { window.close() }

        for (keyCode, modifiers): (UInt16, NSEvent.ModifierFlags) in [
            (17, .command), (13, .command), (2, .command), (18, .command),
            (13, [.command, .shift]), (2, [.command, .shift]),
            (30, [.command, .shift]), (33, [.command, .shift]), (24, [.command, .shift]),
            (123, [.command, .option]), (48, .control), (48, [.control, .shift])
        ] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
            ))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertTrue(view.lastEvent === event)
        }
    }

    func testTabActionsUseOriginatingTabAndRejectMissingTargets() async throws {
        let (tabs, window) = makeTabs()
        defer { tabs.removeAll()
            window.close()
        }
        let first = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
        let second = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
        let third = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)

        XCTAssertTrue(tabs.handleGhosttyAction(goToTab(1), from: third))
        XCTAssertTrue(tabs.surfaceView === first)
        XCTAssertTrue(tabs.handleGhosttyAction(goToTab(GHOSTTY_GOTO_TAB_NEXT.rawValue), from: first))
        XCTAssertTrue(tabs.surfaceView === second)
        XCTAssertTrue(tabs.handleGhosttyAction(goToTab(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue), from: first))
        XCTAssertTrue(tabs.surfaceView === third)
        XCTAssertTrue(tabs.handleGhosttyAction(goToTab(1), from: third))
        XCTAssertTrue(tabs.handleGhosttyAction(goToTab(GHOSTTY_GOTO_TAB_LAST.rawValue), from: first))
        XCTAssertTrue(tabs.surfaceView === third)
        XCTAssertFalse(tabs.handleGhosttyAction(goToTab(0), from: first))
        XCTAssertFalse(tabs.handleGhosttyAction(goToTab(4), from: first))
        XCTAssertFalse(tabs.handleGhosttyAction(action(GHOSTTY_ACTION_NEW_TAB), from: makeView()))
        XCTAssertFalse(tabs.handleGhosttyAction(action(GHOSTTY_ACTION_QUIT), from: first))
        XCTAssertTrue(tabs.handleGhosttyAction(action(GHOSTTY_ACTION_NEW_TAB), from: second))
        XCTAssertTrue(tabs.surfaceView === third)
        await drainMainQueue()
        XCTAssertFalse(tabs.surfaceView === third)
    }

    func testSplitsHonorAllDirectionsAndNavigationUsesSourcePane() async throws {
        for (direction, navigation, horizontal, before) in [
            (GHOSTTY_SPLIT_DIRECTION_RIGHT, GHOSTTY_GOTO_SPLIT_LEFT, true, false),
            (GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_GOTO_SPLIT_UP, false, false),
            (GHOSTTY_SPLIT_DIRECTION_LEFT, GHOSTTY_GOTO_SPLIT_RIGHT, true, true),
            (GHOSTTY_SPLIT_DIRECTION_UP, GHOSTTY_GOTO_SPLIT_DOWN, false, true)
        ] {
            let (tabs, window) = makeTabs()
            defer { tabs.removeAll()
                window.close()
            }
            let tab = try XCTUnwrap(tabs.createTab())
            let original = try XCTUnwrap(tab.focusedSurfaceView)
            var split = action(GHOSTTY_ACTION_NEW_SPLIT)
            split.action.new_split = direction
            XCTAssertTrue(tabs.handleGhosttyAction(split, from: original))
            XCTAssertEqual(tab.splitContainer.root.leafCount(), 1)
            await drainMainQueue()
            let added = try XCTUnwrap(tabs.surfaceView)
            XCTAssertFalse(added === original)
            XCTAssertEqual(tab.splitContainer.root.leafCount(), 2)
            if horizontal {
                XCTAssertEqual(added.frame.minX < original.frame.minX, before)
            } else {
                XCTAssertEqual(added.frame.minY > original.frame.minY, before)
            }
            var focus = action(GHOSTTY_ACTION_GOTO_SPLIT)
            focus.action.goto_split = navigation
            XCTAssertTrue(tabs.handleGhosttyAction(focus, from: added))
            XCTAssertTrue(tabs.surfaceView === original)
            focus.action.goto_split = GHOSTTY_GOTO_SPLIT_NEXT
            XCTAssertTrue(tabs.handleGhosttyAction(focus, from: original))
            XCTAssertTrue(tabs.surfaceView === added)
            focus.action.goto_split = GHOSTTY_GOTO_SPLIT_PREVIOUS
            XCTAssertTrue(tabs.handleGhosttyAction(focus, from: added))
            XCTAssertTrue(tabs.surfaceView === original)

            let info = try XCTUnwrap(tab.splitContainer.root.calculateDividers(
                in: tab.splitContainer.bounds, visibleThickness: 2, hitThickness: 12
            ).first)
            tab.splitContainer.handleDividerDrag(info: info, delta: 40)
            XCTAssertNotEqual(tab.splitContainer.root.ratio, 0.5)
            XCTAssertTrue(tabs.handleGhosttyAction(action(GHOSTTY_ACTION_EQUALIZE_SPLITS), from: original))
            XCTAssertEqual(tab.splitContainer.root.ratio, 0.5)
            tabs.surfaceClosed(added)
            XCTAssertEqual(tab.splitContainer.root.leafCount(), 1)
            XCTAssertTrue(tabs.surfaceView === original)
        }
    }

    func testCloseTabDefersSurfaceRemovalAndKeepsItsOriginalTarget() async throws {
        let (tabs, window) = makeTabs()
        defer { tabs.removeAll()
            window.close()
        }
        let first = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
        let second = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
        let close = action(GHOSTTY_ACTION_CLOSE_TAB)
        XCTAssertTrue(tabs.handleGhosttyAction(close, from: first))
        XCTAssertTrue(tabs.handleGhosttyAction(goToTab(1), from: second))
        XCTAssertTrue(tabs.surfaceView === first)
        await drainMainQueue()
        XCTAssertTrue(tabs.surfaceView === second)
        XCTAssertFalse(tabs.handleGhosttyAction(close, from: first))
    }

    func testQueuedCloseDoesNotCloseReplacementTabAfterRemoval() async throws {
        let (tabs, window) = makeTabs()
        defer { tabs.removeAll()
            window.close()
        }
        let first = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
        XCTAssertTrue(tabs.handleGhosttyAction(action(GHOSTTY_ACTION_CLOSE_TAB), from: first))
        tabs.closeTab(at: 0)
        let replacement = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
        await drainMainQueue()
        XCTAssertTrue(tabs.surfaceView === replacement)
    }

    func testQueuedCreationDiscardsRemovedSources() async throws {
        let (tabs, window) = makeTabs()
        defer { tabs.removeAll()
            window.close()
        }
        let original = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
        XCTAssertTrue(tabs.handleGhosttyAction(action(GHOSTTY_ACTION_NEW_TAB), from: original))
        XCTAssertTrue(tabs.handleGhosttyAction(action(GHOSTTY_ACTION_NEW_SPLIT), from: original))
        tabs.closeTab(at: 0)
        let replacement = try XCTUnwrap(tabs.createTab())
        await drainMainQueue()
        XCTAssertTrue(tabs.surfaceView === replacement.focusedSurfaceView)
        XCTAssertEqual(replacement.splitContainer.root.leafCount(), 1)
        XCTAssertFalse(tabs.handleGhosttyAction(goToTab(2), from: try XCTUnwrap(tabs.surfaceView)))
    }

    func testCloseOtherAndRightTabsKeepSourceTab() async throws {
        for mode in [GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER, GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT] {
            let (tabs, window) = makeTabs()
            defer { tabs.removeAll()
                window.close()
            }
            let first = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
            let source = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
            let third = try XCTUnwrap(tabs.createTab()?.focusedSurfaceView)
            var close = action(GHOSTTY_ACTION_CLOSE_TAB)
            close.action.close_tab_mode = mode
            XCTAssertTrue(tabs.handleGhosttyAction(close, from: source))
            await drainMainQueue()
            XCTAssertTrue(tabs.surfaceView === source)
            XCTAssertFalse(tabs.handleGhosttyAction(close, from: third))
            if mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER {
                XCTAssertFalse(tabs.handleGhosttyAction(close, from: first))
            } else {
                XCTAssertTrue(tabs.handleGhosttyAction(goToTab(1), from: source))
                XCTAssertTrue(tabs.surfaceView === first)
            }
        }
    }

    private func makeTabs() -> (QuakeTerminalTabs, QuakeTerminalWindow) {
        let tabs = QuakeTerminalTabs()
        let window = QuakeTerminalWindow()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        window.contentView = container
        tabs.attach(to: window, container: container)
        tabs.connect(makeSurfaceView: { self.makeView() }, onLastTabClosed: {})
        return (tabs, window)
    }

    private func makeView() -> GhosttySurfaceView {
        GhosttySurfaceView(occlusionHandlerForTests: { _ in })
    }

    private func action(_ tag: ghostty_action_tag_e) -> ghostty_action_s {
        var action = ghostty_action_s()
        action.tag = tag
        return action
    }

    private func goToTab(_ rawValue: Int32) -> ghostty_action_s {
        var action = action(GHOSTTY_ACTION_GOTO_TAB)
        action.action.goto_tab = ghostty_action_goto_tab_e(rawValue: rawValue)
        return action
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class KeyEquivalentView: NSView {
    var lastEvent: NSEvent?
    override var acceptsFirstResponder: Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        lastEvent = event
        return true
    }
}
