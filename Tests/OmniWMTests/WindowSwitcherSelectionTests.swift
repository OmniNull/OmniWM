// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class WindowSwitcherSelectionTests: XCTestCase {
    private let first = WindowToken(pid: 1, windowId: 1)
    private let second = WindowToken(pid: 1, windowId: 2)
    private let third = WindowToken(pid: 2, windowId: 3)

    func testLastUsedSelectionPreservesLayoutOrderAndQuickSwitchesBack() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first, second, third], current: first, reverse: false, recent: [first, third, second])
        XCTAssertEqual(selection.selected, third)
        XCTAssertEqual(selection.tokens, [first, second, third])
        selection.cycle(reverse: false)
        XCTAssertEqual(selection.selected, first)
        selection.cycle(reverse: false)
        XCTAssertEqual(selection.selected, second)
        selection.begin(tokens: [first, second, third], current: third, reverse: false, recent: [third, first, second])
        XCTAssertEqual(selection.selected, first)
    }

    func testLastUsedSelectionSkipsOutOfScopeWindowsAndReverseFollowsLayout() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first, second], current: first, reverse: false, recent: [third, first, second])
        XCTAssertEqual(selection.selected, second)
        selection.begin(tokens: [first, second], current: first, reverse: false, recent: [third])
        XCTAssertEqual(selection.selected, second)
        selection.begin(tokens: [first, second, third], current: first, reverse: true, recent: [first, second, third])
        XCTAssertEqual(selection.selected, third)
    }

    func testDirectSwitchRequiresExactlyTwoWindowsGloballyAndInScope() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first, second], current: first, reverse: false)
        XCTAssertEqual(selection.directSwitchTarget(totalWindowCount: 2), second)
        XCTAssertNil(selection.directSwitchTarget(totalWindowCount: 3))
        selection.begin(tokens: [first, second], current: second, reverse: true)
        XCTAssertEqual(selection.directSwitchTarget(totalWindowCount: 2), first)
        selection.begin(tokens: [first], current: first, reverse: false)
        XCTAssertNil(selection.directSwitchTarget(totalWindowCount: 2))
        selection.reconcile(tokens: [])
        XCTAssertNil(selection.directSwitchTarget(totalWindowCount: 0))
    }

    func testRowNavigationClampsToShortFinalRowAndWraps() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first, second, third], current: first, reverse: false)
        selection.moveRow(columns: 2, reverse: false)
        XCTAssertEqual(selection.selected, third)
        selection.moveRow(columns: 2, reverse: false)
        XCTAssertEqual(selection.selected, first)
        selection.moveRow(columns: 2, reverse: true)
        XCTAssertEqual(selection.selected, third)
    }

    func testInitialSelectionSkipsCurrentWindowAndWrapsInBothDirections() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first, second, third], current: first, reverse: false)
        XCTAssertEqual(selection.selected, second)
        selection.cycle(reverse: false)
        XCTAssertEqual(selection.selected, third)
        selection.cycle(reverse: false)
        XCTAssertEqual(selection.selected, first)
        selection.cycle(reverse: true)
        XCTAssertEqual(selection.selected, third)
    }

    func testUnmanagedFrontmostApplicationStartsAtFirstCandidate() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first, second], current: third, reverse: false)
        XCTAssertEqual(selection.selected, first)
    }

    func testScopeChangesRetainSelectionWhenPresentAndChooseValidReplacement() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first, second, third], current: first, reverse: false)
        selection.reconcile(tokens: [second, third])
        XCTAssertEqual(selection.selected, second)
        selection.reconcile(tokens: [third])
        XCTAssertEqual(selection.selected, third)
        selection.reconcile(tokens: [])
        XCTAssertNil(selection.selected)
        selection.cycle(reverse: true)
        XCTAssertNil(selection.selected)
        selection.reconcile(tokens: [first, second, third])
        XCTAssertEqual(selection.selected, first)
    }

    func testClosingSelectedLastWindowSelectsSurvivingWindow() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first, second, third], current: first, reverse: true)
        XCTAssertEqual(selection.selected, third)
        selection.reconcile(tokens: [first, second])
        XCTAssertEqual(selection.selected, second)
        selection.select(third)
        XCTAssertEqual(selection.selected, second)
    }

    func testSingleWindowRemainsSelected() {
        var selection = WindowSwitcherSelection()
        selection.begin(tokens: [first], current: first, reverse: true)
        selection.cycle(reverse: false)
        XCTAssertEqual(selection.selected, first)
    }
}
