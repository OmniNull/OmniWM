// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteNativeMenuTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool {
            true
        }
    }

    func testModeMenuUsesModeOrderHintsAvailabilityAndSelection() {
        let selected = CommandPaletteMode.clipboard
        let items = CommandPaletteNativeMenu.modes(selected: selected, menuAvailable: false, clearHistory: true)
        let selectedActions = actions(in: items)
        XCTAssertEqual(selectedActions, CommandPaletteMode.allCases.map { .mode($0) } + [.clipboardClear])
        for (mode, item) in zip(CommandPaletteMode.allCases, items) {
            guard case let .action(title, action, enabled, checked) = item else {
                return XCTFail("Every mode is an action")
            }
            XCTAssertEqual(action, .mode(mode))
            XCTAssertTrue(title.contains(mode.localizedDisplayName))
            XCTAssertTrue(title.contains(CommandPalettePresentation.modeHint(for: mode).shortcut))
            XCTAssertEqual(enabled, mode != .menu)
            XCTAssertEqual(checked, mode == selected)
        }
        XCTAssertEqual(items.dropLast().last, .separator)
        let withoutClear = CommandPaletteNativeMenu.modes(
            selected: selected, menuAvailable: true, clearHistory: false
        )
        XCTAssertEqual(actions(in: withoutClear), CommandPaletteMode.allCases.map { .mode($0) })
        XCTAssertFalse(withoutClear.contains(.separator))
    }

    func testClipboardMenuKeepsOrderAndCurrentPinAndPlainTextAvailability() {
        let plain = clipboardItem(canPastePlainText: false)
        XCTAssertEqual(actions(in: CommandPaletteNativeMenu.clipboard(plain)), [
            .clipboardPin(plain.id, true), .clipboardDelete(plain.id)
        ])
        let pinned = clipboardItem(isPinned: true, canPastePlainText: true)
        XCTAssertEqual(actions(in: CommandPaletteNativeMenu.clipboard(pinned)), [
            .clipboardPastePlain(pinned.id), .clipboardPin(pinned.id, false), .clipboardDelete(pinned.id)
        ])
    }

    func testNativeMenuCarriesTypedActionsAndDeclaredAvailability() throws {
        _ = NSApplication.shared
        let presenter = CommandPaletteNativeMenu()
        let entries: [CommandPaletteNativeMenu.Item] = [
            .action("Available", .mode(.windows), checked: true),
            .separator,
            .action("Unavailable", .mode(.menu), enabled: false)
        ]
        let menu = presenter.makeMenu(entries)
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.count, entries.count)
        var actionIndex = 0
        for (entry, native) in zip(entries, menu.items) {
            switch entry {
            case let .action(title, _, enabled, checked):
                XCTAssertEqual(native.title, title)
                XCTAssertEqual(native.tag, actionIndex)
                XCTAssertEqual(native.isEnabled, enabled)
                XCTAssertEqual(native.state, checked ? .on : .off)
                XCTAssertTrue(native.target === presenter)
                XCTAssertNotNil(native.action)
                actionIndex += 1
            case .separator:
                XCTAssertTrue(native.isSeparatorItem)
            }
        }
        XCTAssertFalse(presenter.isTracking)
        presenter.cancel()
        XCTAssertFalse(presenter.isTracking)
    }

    func testMenuAnchorUsesTheClickedControlInItsSurfaceCoordinates() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 140, y: 180, width: 500, height: 400),
            styleMask: .borderless, backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        let view = FlippedView(frame: CGRect(x: 20, y: 30, width: 300, height: 200))
        window.contentView = root
        root.addSubview(view)
        let control = CGRect(x: 25, y: 35, width: 50, height: 24)
        let screen = window.convertToScreen(view.convert(control, to: nil))
        let anchor = ShellAnchor(frame: screen, level: .normal)
        XCTAssertEqual(
            CommandPaletteNativeMenu.location(for: anchor, in: view),
            CGPoint(x: control.minX, y: control.maxY)
        )
        XCTAssertNil(CommandPaletteNativeMenu.location(for: anchor, in: NSView()))
    }

    func testControllerRejectsRemovedFilteredAndDisabledClipboardTargets() throws {
        let item = clipboardItem(canPastePlainText: true)
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in [item] }
            environment.clipboardItemPreview = { _, _ in nil }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .clipboard)
        fixture.palette.expandResults()
        let target = try clipboardTarget(fixture)
        XCTAssertEqual(actions(in: fixture.palette.shellMenuItems(for: target)), [
            .clipboardPastePlain(item.id), .clipboardPin(item.id, true), .clipboardDelete(item.id)
        ])
        fixture.palette.searchText = "does not match the declared item"
        XCTAssertTrue(fixture.palette.shellMenuItems(for: target).isEmpty)
        XCTAssertFalse(fixture.palette.performShellMenuAction(.clipboardDelete(item.id), target: target))
        fixture.palette.searchText = ""
        fixture.palette.isClipboardHistoryEnabled = false
        XCTAssertTrue(fixture.palette.shellMenuItems(for: target).isEmpty)
        fixture.palette.isClipboardHistoryEnabled = true
        fixture.palette.clipboardItems = []
        XCTAssertFalse(fixture.palette.performShellMenuAction(.clipboardPastePlain(item.id), target: target))
    }

    func testControllerRevalidatesPinStateBeforeDispatching() async throws {
        let item = clipboardItem()
        let changed = clipboardItem(id: item.id, isPinned: true)
        let pinned = expectation(description: "The current menu dispatches the requested unpin")
        var requests: [(UUID, Bool)] = []
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in [item] }
            environment.clipboardItemPreview = { _, _ in nil }
            environment.setClipboardItemPinned = { _, id, state in
                requests.append((id, state))
                pinned.fulfill()
                return [item]
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .clipboard)
        fixture.palette.expandResults()
        let target = try clipboardTarget(fixture)
        fixture.palette.clipboardItems = [changed]
        XCTAssertFalse(fixture.palette.performShellMenuAction(.clipboardPin(item.id, true), target: target))
        XCTAssertTrue(fixture.palette.performShellMenuAction(.clipboardPin(item.id, false), target: target))
        await fulfillment(of: [pinned], timeout: failureBound)
        XCTAssertEqual(requests.map(\.0), [item.id])
        XCTAssertEqual(requests.map(\.1), [false])
    }

    func testClearHistoryCancellationKeepsThePaletteAndItems() throws {
        let item = clipboardItem()
        var confirmations = 0
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in [item] }
            environment.clipboardItemPreview = { _, _ in nil }
            environment.confirmClearClipboardHistory = {
                confirmations += 1
                return false
            }
            environment.clearClipboardHistory = { _ in
                XCTFail("Cancelled confirmation cannot clear history")
                return []
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .clipboard)
        fixture.palette.expandResults()
        XCTAssertTrue(fixture.palette.performShellMenuAction(.clipboardClear, target: "modes"))
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertFalse(fixture.palette.isConfirmingClipboardClear)
        XCTAssertEqual(fixture.palette.clipboardItems.map(\.id), [item.id])
        fixture.palette.isUnifiedSearch = true
        XCTAssertTrue(fixture.palette.shellMenuItems(for: "modes").isEmpty)
        XCTAssertFalse(fixture.palette.performShellMenuAction(.clipboardClear, target: "modes"))
    }

    private func clipboardTarget(_ fixture: CommandPaletteFocusFixture) throws -> String {
        let data = fixture.palette.shellData(size: fixture.palette.presentation.shellLayoutSize(expanded: true))
        return try XCTUnwrap(data.rows.first { $0.kind == .clipboard }?.id)
    }

    private func actions(in items: [CommandPaletteNativeMenu.Item]) -> [CommandPaletteNativeMenu.Action] {
        items.compactMap { item in
            guard case let .action(_, action, _, _) = item else { return nil }
            return action
        }
    }

    private func clipboardItem(
        id: UUID = UUID(), isPinned: Bool = false, canPastePlainText: Bool = false
    ) -> ClipboardPaletteItem {
        ClipboardPaletteItem(
            id: id, title: "Declared clipboard item", subtitle: "Fixture", kind: .text,
            sourceBundleIdentifier: nil, lastCopiedAt: Date(timeIntervalSince1970: 0), numberOfCopies: 1,
            byteCount: 0, isPinned: isPinned, canPastePlainText: canPastePlainText
        )
    }
}
