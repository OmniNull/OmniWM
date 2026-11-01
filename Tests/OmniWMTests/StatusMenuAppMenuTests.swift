// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@preconcurrency import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class StatusMenuAppMenuTests: XCTestCase {
    func testItemsPreserveOrderAndFormatShortcuts() {
        let snapshots = [
            snapshot(title: "New", command: "n"),
            snapshot(title: "Open…", command: "o"),
            snapshot(title: "Save", enabled: false, command: "s"),
            snapshot(role: "AXSeparator"),
            snapshot(title: "Close", command: nil)
        ]

        let items = StatusMenuAppMenuLoader.makeItems(from: snapshots, groupID: "File", pid: 42)

        XCTAssertEqual(items.map(\.title), ["New", "Open…", "Save", "", "Close"])
        XCTAssertEqual(items.map(\.isSeparator), [false, false, false, true, false])
        XCTAssertEqual(items[0].shortcut, "⌘N")
        XCTAssertEqual(items[2].shortcut, "⌘S")
        XCTAssertFalse(items[2].isEnabled)
        XCTAssertNil(items[4].shortcut)
        XCTAssertEqual(items.map(\.pid), [42, 42, 42, 42, 42])
    }

    func testItemsTrimLeadingTrailingAndRepeatedSeparators() {
        let snapshots = [
            snapshot(role: "AXSeparator"),
            snapshot(title: "Cut", command: "x"),
            snapshot(role: "AXSeparator"),
            snapshot(role: "AXSeparator"),
            snapshot(title: "Paste", command: "v"),
            snapshot(role: "AXSeparator")
        ]

        let items = StatusMenuAppMenuLoader.makeItems(from: snapshots, groupID: "Edit", pid: 7)

        XCTAssertEqual(items.map(\.title), ["Cut", "", "Paste"])
        XCTAssertEqual(items.map(\.isSeparator), [false, true, false])
    }

    func testItemsSkipUntitledEntriesThatAreNotSeparators() {
        let snapshots = [
            snapshot(title: ""),
            snapshot(title: "Bring All to Front")
        ]

        let items = StatusMenuAppMenuLoader.makeItems(from: snapshots, groupID: "Window", pid: 9)

        XCTAssertEqual(items.map(\.title), ["Bring All to Front"])
    }

    func testItemTitlesKeepAmpersandsVerbatim() {
        let snapshots = [snapshot(title: "Save &As…")]

        let items = StatusMenuAppMenuLoader.makeItems(from: snapshots, groupID: "File", pid: 1)

        XCTAssertEqual(items.map(\.title), ["Save &As…"])
    }

    func testItemsMarkSubmenuParentsAndDefaultToDisabledWhenStateIsMissing() {
        let snapshots = [
            snapshot(title: "Share", submenu: true),
            snapshot(enabled: nil, attributes: ["AXTitle": "No Enabled Attribute", "AXRole": "AXMenuItem"])
        ]

        let items = StatusMenuAppMenuLoader.makeItems(from: snapshots, groupID: "File", pid: 3)

        XCTAssertEqual(items.map(\.hasSubmenu), [true, false])
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertFalse(items[1].isEnabled)
    }

    func testGroupsSkipAppleMenuEmptyTitlesAndMenusWithoutSubmenus() {
        XCTAssertNil(
            StatusMenuAppMenuLoader.makeGroup(snapshot(title: "Apple", role: "AXMenuBarItem", submenu: true), index: 0)
        )
        XCTAssertNil(
            StatusMenuAppMenuLoader.makeGroup(snapshot(title: "", role: "AXMenuBarItem", submenu: true), index: 1)
        )
        XCTAssertNil(StatusMenuAppMenuLoader.makeGroup(snapshot(title: "File", role: "AXMenuBarItem"), index: 2))

        let file = StatusMenuAppMenuLoader.makeGroup(
            snapshot(title: "File", role: "AXMenuBarItem", submenu: true),
            index: 3
        )
        XCTAssertEqual(file?.title, "File")
        XCTAssertEqual(file?.id, "File#3")
    }

    func testGroupIdentifiersStayUniqueForDuplicateTitles() {
        let first = StatusMenuAppMenuLoader.makeGroup(
            snapshot(title: "Window", role: "AXMenuBarItem", submenu: true),
            index: 1
        )
        let second = StatusMenuAppMenuLoader.makeGroup(
            snapshot(title: "Window", role: "AXMenuBarItem", submenu: true),
            index: 4
        )

        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testShortcutFormatterCombinesModifiersInOrder() {
        let shortcut = MenuShortcutFormatter.format(
            key: "p",
            modifiers: [.control, .option, .shift, .command]
        )
        XCTAssertEqual(shortcut, "⌃⌥⇧⌘P")
    }

    private func snapshot(
        title: String = "",
        role: String = "AXMenuItem",
        enabled: Bool? = true,
        command: String? = nil,
        modifiers: Int = 0,
        submenu: Bool = false,
        attributes extra: [String: Any] = [:]
    ) -> MenuItemSnapshot {
        var attributes: [String: Any] = [
            "AXTitle": title,
            "AXRole": role
        ]
        if let enabled {
            attributes["AXEnabled"] = enabled
        }
        if let command {
            attributes["AXMenuItemCmdChar"] = command
            attributes["AXMenuItemCmdModifiers"] = modifiers
        }
        for (key, value) in extra {
            attributes[key] = value
        }
        return MenuItemSnapshot(
            element: AXUIElementCreateSystemWide(),
            attributes: attributes,
            submenuRoot: submenu ? AXUIElementCreateSystemWide() : nil
        )
    }
}
