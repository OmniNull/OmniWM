// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class CommandPaletteShellInteractionTests: XCTestCase {
    func testKeyboardRevealAndRewindowDoNotMoveSelectionToTheStationaryPointer() async throws {
        let items = (0 ..< 200).map { item("Clipboard \($0)") }
        let fixture = clipboardFixture(items)
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .clipboard)
        fixture.palette.expandResults()
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        let firstID = fixture.palette.cachedShellRow(items[0]).id
        await drawn(shell) { shell.drawsPublishedList() && self.fullyVisible(shell, id: firstID) }
        let hoveredID = fixture.palette.cachedShellRow(items[1]).id
        shell.surface.hover(at: try point(shell, id: hoveredID))
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(items[1].id))

        fixture.palette.moveSelection(by: -1)
        fixture.palette.moveSelection(by: -1)
        let selected = try XCTUnwrap(items.last)
        let selectedID = fixture.palette.cachedShellRow(selected).id
        await drawn(shell) { shell.drawsPublishedList() && self.fullyVisible(shell, id: selectedID) }
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(selected.id))
        XCTAssertEqual(shell.published?.selected, selectedID)
        let previousFirst = try XCTUnwrap(shell.published?.first)
        let list = try XCTUnwrap(shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey))
        let viewport = CGRect(shell.surface.layout.core.absoluteFrame(of: list))
        XCTAssertTrue(shell.surface.scroll(
            at: CGPoint(x: viewport.midX, y: viewport.midY),
            event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: -viewport.height)
        ))
        await drawn(shell) { shell.drawsPublishedList() && (shell.published?.first ?? previousFirst) < previousFirst }
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(selected.id))
        XCTAssertEqual(shell.published?.selected, selectedID)

        let visible = try XCTUnwrap(shell.published?.rows.first { self.fullyVisible(shell, id: $0.id) })
        let source = try XCTUnwrap(items.first { fixture.palette.cachedShellRow($0).id == visible.id })
        XCTAssertNotEqual(source.id, selected.id)
        shell.surface.hover(at: nil)
        shell.surface.hover(at: try point(shell, id: visible.id))
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(source.id))
    }

    func testRemovingTheFocusedPreviewReturnsTypingToTheQueryWithoutStealingLivePreviewFocus() async throws {
        let items = [item("First"), item("Second")]
        let fixture = clipboardFixture(items)
        defer { fixture.cleanup() }
        let panel = try fixture.show(mode: .clipboard)
        fixture.palette.expandResults()
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        let initialFeedback = "Preview information"
        fixture.palette.actionFeedbackText = initialFeedback
        await drawn(shell) { shell.drawsPublishedList() && shell.published?.preview?.state == "text"
            && self.readOnlyInput(shell)?.text == items[0].id.uuidString && self.drawsText(shell, initialFeedback)
        }
        let preview = try XCTUnwrap(readOnlyInput(shell))
        XCTAssertTrue(panel.makeFirstResponder(preview.responder))
        XCTAssertTrue(panel.firstResponder === preview.editor)
        fixture.palette.actionFeedbackText = "Keep the preview focused"
        await drawn(shell) { shell.published?.feedback == fixture.palette.actionFeedbackText
            && shell.drawsPublishedList() && self.drawsText(shell, "Keep the preview focused")
        }
        XCTAssertTrue(readOnlyInput(shell) === preview)
        XCTAssertTrue(panel.firstResponder === preview.editor)

        fixture.palette.selectedItemID = .clipboard(items[1].id)
        await drawn(shell) { shell.published?.preview?.state == "text"
            && shell.published?.preview?.text == items[1].id.uuidString && self.readOnlyInput(shell) !== preview
            && self.readOnlyInput(shell)?.text == items[1].id.uuidString
            && shell.drawsPublishedList()
        }
        XCTAssertTrue(panel.firstResponder === shell.field.textEditor)
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        let query = "Second"
        editor.insertText(query, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.palette.searchText, query)
    }

    private func clipboardFixture(_ items: [ClipboardPaletteItem]) -> CommandPaletteFocusFixture {
        CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in items }
            environment.clipboardItemPreview = { _, id in .text(id.uuidString) }
        }
    }

    private func item(_ title: String) -> ClipboardPaletteItem {
        ClipboardPaletteItem(
            id: UUID(), title: title, subtitle: "Source", kind: .text, sourceBundleIdentifier: nil,
            lastCopiedAt: .distantPast, numberOfCopies: 1, byteCount: title.utf8.count
        )
    }

    private func drawn(_ shell: CommandPaletteShellPresenter, until condition: @escaping () -> Bool) async {
        if condition() { return }
        let tree = expectation(description: "The shell draws the requested interaction state")
        let previous = shell.onTree
        defer { shell.onTree = previous }
        shell.onTree = {
            previous?()
            guard condition() else { return }
            shell.onTree = previous
            tree.fulfill()
        }
        await fulfillment(of: [tree], timeout: failureBound)
    }

    private func readOnlyInput(_ shell: CommandPaletteShellPresenter) -> ShellTextInput? {
        shell.surface.textInputs.values.first {
            $0.editor != nil && shell.surface.layout.core.contains($0.handle)
                && !shell.surface.layout.core.content(of: $0.handle).inputEditable
        }
    }

    private func drawsText(_ shell: CommandPaletteShellPresenter, _ text: String) -> Bool {
        !shell.surface.layout.core.elements(matching: {
            $0.text != 0 && shell.surface.text?.string($0.text) == text
        }).isEmpty
    }

    private func point(_ shell: CommandPaletteShellPresenter, id: String) throws -> CGPoint {
        let row = try XCTUnwrap(shell.surface.layout.handle(forKey: id))
        let frame = CGRect(shell.surface.layout.core.absoluteFrame(of: row))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func fullyVisible(_ shell: CommandPaletteShellPresenter, id: String) -> Bool {
        guard let row = shell.surface.layout.handle(forKey: id),
              let list = shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey)
        else { return false }
        let frame = shell.surface.layout.core.absoluteFrame(of: row)
        let viewport = shell.surface.layout.core.absoluteFrame(of: list)
        return frame.y >= viewport.y && frame.y + frame.height <= viewport.y + viewport.height
    }
}
