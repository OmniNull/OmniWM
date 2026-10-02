// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WindowSwitcherPanelTests: XCTestCase {
    func testClosingIdenticallyNamedWindowsKeepsSurvivingCardsAndCloseTargets() throws {
        let panel = WindowSwitcherPanel(ownedWindowRegistry: OwnedWindowRegistry())
        defer { panel.close() }
        let items = (1 ... 3).map(makeItem)
        var closed: [WindowToken] = []
        var selected: [WindowToken] = []
        panel.onClose = { closed.append($0) }
        panel.onSelect = { selected.append($0) }
        update(panel, items: items)
        let original = tiles(in: try XCTUnwrap(panel.contentView))
        XCTAssertEqual(original.count, 3)
        try clickClose(original[1])
        XCTAssertEqual(closed, [items[1].handle.id])
        XCTAssertTrue(selected.isEmpty)

        update(panel, items: [items[0], items[2]])
        let remaining = tiles(in: try XCTUnwrap(panel.contentView))
        XCTAssertEqual(remaining.map(\.handle.id), [items[0].handle.id, items[2].handle.id])
        XCTAssertTrue(remaining[0] === original[0])
        XCTAssertTrue(remaining[1] === original[2])
        XCTAssertNil(original[1].superview)
        try clickClose(remaining[1])
        XCTAssertEqual(closed, [items[1].handle.id, items[2].handle.id])
        XCTAssertTrue(selected.isEmpty)

        update(panel, items: [items[0]])
        XCTAssertEqual(tiles(in: try XCTUnwrap(panel.contentView)).map(\.handle.id), [items[0].handle.id])
        update(panel, items: [])
        XCTAssertTrue(tiles(in: try XCTUnwrap(panel.contentView)).isEmpty)
    }

    func testHoverUsesNewCardPositionAfterRemovalAndPanelResize() throws {
        let panel = WindowSwitcherPanel(ownedWindowRegistry: OwnedWindowRegistry())
        defer { panel.close() }
        let items = (1 ... 3).map(makeItem)
        update(panel, items: items)
        let original = tiles(in: try XCTUnwrap(panel.contentView))
        let tile = original[2]
        tile.updateTrackingAreas()
        let button = try XCTUnwrap(tile.subviews.compactMap { $0 as? NSButton }.first)
        let oldPoint = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
        tile.updateHover(at: oldPoint)
        XCTAssertFalse(button.isHidden)

        update(panel, items: [items[0], items[2]])
        tile.updateHover(at: oldPoint)
        XCTAssertTrue(button.isHidden)
        let newPoint = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
        tile.updateHover(at: newPoint)
        XCTAssertFalse(button.isHidden)
        let retiredExit = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: oldPoint, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        tile.mouseExited(with: retiredExit)
        XCTAssertFalse(button.isHidden, "An exit from a retired tracking area must not override the current hover")
        try clickClose(tile)
    }

    private func clickClose(_ tile: WindowSwitcherTile) throws {
        let button = try XCTUnwrap(tile.subviews.compactMap { $0 as? NSButton }.first)
        let center = NSPoint(x: button.frame.midX, y: button.frame.midY)
        tile.updateHover(at: tile.convert(center, to: nil))
        XCTAssertFalse(button.isHidden)
        let target = tile.hitTest(tile.convert(center, to: tile.superview))
        XCTAssertTrue(target === button)
        button.performClick(nil)
    }

    private func update(_ panel: WindowSwitcherPanel, items: [WindowSwitcherItem]) {
        panel.updateContent(
            .init(items: items, selected: items.first?.handle.id, scope: .activeWorkspace, hasCaptureAccess: true),
            screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 900)
        )
    }

    private func tiles(in view: NSView) -> [WindowSwitcherTile] {
        if let tile = view as? WindowSwitcherTile { return [tile] }
        return view.subviews.flatMap { tiles(in: $0) }
    }

    private func makeItem(_ id: Int) -> WindowSwitcherItem {
        WindowSwitcherItem(
            handle: WindowHandle(id: WindowToken(pid: 123, windowId: id)),
            title: "empty project", appName: "Zed", icon: nil, workspaceName: "1", isMinimized: false
        )
    }
}
