// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class WindowSwitcherOrderTests: XCTestCase {
    func testLayoutOrderIgnoresFocusRecency() {
        let items = (1 ... 3).map(makeItem)
        let tokens = items.map(\.handle.id)
        let ordered = WindowSwitcherOrder.omniLayout.orderedItems(items, recent: tokens.reversed())
        XCTAssertEqual(ordered.map(\.handle.id), tokens)
    }

    func testLastUsedOrdersAcrossWorkspacesAndAppendsUnfocusedWindowsInLayoutOrder() {
        let items = (1 ... 4).map(makeItem)
        let tokens = items.map(\.handle.id)
        let outsideScope = WindowToken(pid: 123, windowId: 5)
        let ordered = WindowSwitcherOrder.lastUsed.orderedItems(
            items, recent: [outsideScope, tokens[2], tokens[0], tokens[2]]
        )
        XCTAssertEqual(ordered.map(\.handle.id), [tokens[2], tokens[0], tokens[1], tokens[3]])
    }

    func testMissingFocusHistoryPreservesLayoutOrder() {
        let items = (1 ... 3).map(makeItem)
        XCTAssertEqual(
            WindowSwitcherOrder.lastUsed.orderedItems(items, recent: []).map(\.handle.id),
            items.map(\.handle.id)
        )
        XCTAssertTrue(WindowSwitcherOrder.lastUsed.orderedItems([], recent: items.map(\.handle.id)).isEmpty)
    }

    private func makeItem(_ id: Int) -> WindowSwitcherItem {
        WindowSwitcherItem(
            handle: WindowHandle(id: WindowToken(pid: 123, windowId: id)),
            title: "Window \(id)", appName: "App", icon: nil, workspaceName: String(id), isMinimized: false
        )
    }
}
