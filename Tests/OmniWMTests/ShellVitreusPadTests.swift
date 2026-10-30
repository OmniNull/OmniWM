// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
private final class VitreusPanel: ShellFocusPanel {
    override var isVisible: Bool {
        true
    }
}

@MainActor
final class ShellVitreusPadTests: XCTestCase {
    private func panel(_ widget: ShellRenderedWidget) -> VitreusPanel {
        _ = NSApplication.shared
        let surface = widget.surface
        let panel = VitreusPanel(
            contentRect: CGRect(origin: .zero, size: surface.size), styleMask: [], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.acceptsDeclaredFocus = true
        panel.contentView = surface.view
        surface.view.frame = CGRect(origin: .zero, size: surface.size)
        surface.layoutTextInputs()
        addTeardownBlock { @MainActor in
            surface.blurDeclaredFocus()
            panel.contentView = nil
        }
        return panel
    }

    private func focus(_ widget: ShellRenderedWidget, _ input: ShellTextInput) {
        let frame = CGRect(widget.surface.presentedFrame(of: input.handle))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        widget.surface.press(at: point)
        widget.surface.release(at: point)
    }

    private func type(_ widget: ShellRenderedWidget, _ text: String) throws {
        var event = ShellEvent()
        event.text = text
        widget.invoke(try input(widget).content.action, event: event)
        VitreusFixture.show(widget)
    }

    private func deliver(_ widget: ShellRenderedWidget, _ kind: ShellEvent.Kind) throws {
        let event = try XCTUnwrap(widget.events.last { $0.event.kind == kind })
        widget.invoke(event.action, event: event.event)
        VitreusFixture.show(widget)
    }

    private func pad(seed: [String: [UInt8]] = [:]) throws -> ShellRenderedWidget {
        let shell = try VitreusFixture.shell()
        let folder = shell.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let widget = try VitreusFixture.clocked(shell, now: 1000, seed: seed)
        try VitreusFixture.click(widget, key: "tab-pad")
        _ = VitreusFixture.drain(widget)
        return widget
    }

    private func items(_ requests: [VitreusRequest]) -> [ShellServiceValue] {
        VitreusFixture.saved(requests, "pad", "tasks")?.fields?["items"]?.values ?? []
    }

    private func rows(_ widget: ShellRenderedWidget) -> [Int: ElementHandle] {
        let layout = widget.surface.layout
        return Dictionary(uniqueKeysWithValues: (1 ... 20).compactMap { id in
            layout.core.elements { _ in true }.first { layout.core.key(of: $0) == VitreusFixture.key("task-\(id)") }
                .map { (id, $0) }
        })
    }

    private func input(_ widget: ShellRenderedWidget) throws -> TreeNode {
        try XCTUnwrap(widget.tree().first { $0.kind == .input })
    }

    func testPadTrimsTextAndKeepsAtMostNineTasksWithStableIDs() throws {
        let widget = try pad()
        XCTAssertTrue(widget.strings().contains("Nothing to do. Nice."))
        try VitreusFixture.commit(widget, "   ")
        XCTAssertTrue(items(VitreusFixture.drain(widget)).isEmpty)
        try VitreusFixture.commit(widget, "  Write the brief  ")
        var saved = items(VitreusFixture.drain(widget))
        XCTAssertEqual(saved.map { $0.fields?["text"]?.string }, ["Write the brief"])
        XCTAssertEqual(saved.map { $0.fields?["id"]?.number }, [1])
        for index in 2 ... 10 {
            try VitreusFixture.commit(widget, "Task \(index)")
        }
        saved = items(VitreusFixture.drain(widget))
        XCTAssertEqual(saved.compactMap { $0.fields?["id"]?.number }, (1 ... 9).map(Double.init))
        XCTAssertEqual(rows(widget).keys.sorted(), Array(1 ... 9))
        XCTAssertFalse(widget.strings().contains("Task 10"))
        var draft = ShellEvent()
        draft.text = "Task 11"
        widget.invoke(try input(widget).content.action, event: draft)
        VitreusFixture.show(widget)
        try VitreusFixture.commit(widget, "Task 11")
        XCTAssertEqual(widget.text.string(try input(widget).content.text), "Task 11")
        try VitreusFixture.click(widget, key: "task-2")
        XCTAssertEqual(items(VitreusFixture.drain(widget))[1].fields?["done"]?.boolean, true)
    }

    func testDeletingAMiddleTaskRemovesItsOwnRowAndTheRestKeepTheirKeys() throws {
        let widget = try pad()
        for text in ["One", "Two", "Three"] {
            try VitreusFixture.commit(widget, text)
        }
        _ = VitreusFixture.drain(widget)
        let before = rows(widget)
        let layout = widget.surface.layout
        let second = try XCTUnwrap(before[2])
        let delete = try XCTUnwrap(layout.core.elements { $0.action != 0 }.first {
            layout.core.key(of: $0) == VitreusFixture.key("delete") && layout.core.parent(of: $0) == second
        })
        let target = CGRect(layout.core.absoluteFrame(of: delete))
        let slot = CGRect(layout.core.absoluteFrame(of: second)).midY
        VitreusFixture.click(widget, at: CGPoint(x: target.midX, y: target.midY))
        XCTAssertEqual(items(VitreusFixture.drain(widget)).compactMap { $0.fields?["id"]?.number }, [1, 3])
        let after = rows(widget)
        XCTAssertNil(after[2])
        XCTAssertEqual(after[1], before[1])
        XCTAssertEqual(after[3], before[3])
        XCTAssertEqual(CGRect(layout.core.absoluteFrame(of: try XCTUnwrap(after[3]))).midY, slot, accuracy: 0.01)
        try VitreusFixture.commit(widget, "Four")
        XCTAssertEqual(items(VitreusFixture.drain(widget)).last?.fields?["id"]?.number, 4)
    }

    func testReseedingTheStoreRestoresOrderIDsAndDoneFlags() throws {
        let widget = try pad()
        for text in ["One", "Two", "Three"] {
            try VitreusFixture.commit(widget, text)
        }
        try VitreusFixture.click(widget, key: "task-2")
        let store = try XCTUnwrap(VitreusFixture.drain(widget).last {
            $0.kind == OMNI_SERVICE_STORE && $0.name.hasSuffix("pad")
        })
        let restored = try pad(seed: ["pad": store.bytes])
        XCTAssertEqual(rows(restored).keys.sorted(), [1, 2, 3])
        let layout = restored.surface.layout
        let accent = UInt16(ShellRole.accent.rawValue + 1)
        let checked = Set(layout.core.elements { _ in true }
            .filter { layout.core.paint(of: $0).fill.role & 0xFF == accent }.map { layout.core.parent(of: $0) })
        XCTAssertEqual(
            rows(restored).sorted { $0.key < $1.key }.map { checked.contains($0.value) },
            [false, true, false]
        )
        let labels = VitreusFixture.labels(restored).filter { ["One", "Two", "Three"].contains($0.text) }
            .sorted { $0.frame.minY < $1.frame.minY }.map(\.text)
        XCTAssertEqual(labels, ["One", "Two", "Three"])
    }

    func testPadDraftSurvivesTabsAndCommitRequestsANewEmptyEditor() throws {
        let widget = try pad()
        let first = try input(widget)
        XCTAssertEqual(first.content.inputMaxLength, 200)
        XCTAssertEqual(first.content.inputFocus, -1)
        var event = ShellEvent()
        event.text = "Half a thought"
        widget.invoke(first.content.action, event: event)
        VitreusFixture.show(widget)
        XCTAssertEqual(widget.text.string(try input(widget).content.text), "Half a thought")
        try VitreusFixture.click(widget, key: "tab-focus")
        XCTAssertNil(widget.tree().first { $0.kind == .input })
        try VitreusFixture.click(widget, key: "tab-pad")
        XCTAssertEqual(widget.text.string(try input(widget).content.text), "Half a thought")
        try VitreusFixture.commit(widget, "Half a thought")
        let after = try input(widget)
        XCTAssertNotEqual(after.key, first.key)
        XCTAssertEqual(after.content.inputFocus, 1)
        XCTAssertEqual(widget.text.string(after.content.text), "")
        XCTAssertEqual(widget.surface.textInputs.values.first?.text, "")
        XCTAssertTrue(widget.strings().contains("Half a thought"))
    }

    func testTheDeleteCrossAppearsOnlyWhileItsRowIsHovered() throws {
        let widget = try pad()
        try VitreusFixture.commit(widget, "Hover me")
        let layout = widget.surface.layout
        func crosses() throws -> Int {
            let zone = try XCTUnwrap(layout.core.elements { $0.action != 0 }.first {
                layout.core.key(of: $0) == VitreusFixture.key("delete")
            })
            return layout.core.elements { _ in true }.count {
                layout.core.kind(of: $0) == .path && layout.core.parent(of: $0) == zone
            }
        }
        XCTAssertEqual(try crosses(), 0)
        for name in ["task-1", "delete"] {
            let zone = try VitreusFixture.element(widget, key: name)
            XCTAssertEqual(layout.core.content(of: zone).cursor, .pointer, name)
        }
        for (phase, expected) in [(ShellEvent.Phase.began, 1), (.ended, 0)] {
            var event = ShellEvent()
            event.phase = phase
            let row = try VitreusFixture.element(widget, key: "task-1")
            widget.invoke(layout.core.content(of: row).hoverAction, event: event)
            VitreusFixture.show(widget)
            XCTAssertEqual(try crosses(), expected)
        }
    }

    func testThePadFieldIsAnOwnedEditorDrawnAsTextUntilClickedThenTypesCommitsAndRefocuses() throws {
        let widget = try pad()
        let surface = widget.surface
        try type(widget, "Half a thought")
        let field = try XCTUnwrap(surface.textInputs.values.first)
        XCTAssertEqual(surface.manipulationOwner(of: field.handle), try VitreusFixture.element(widget, key: "desk"))
        XCTAssertNotNil(surface.manipulationTargets[try VitreusFixture.element(widget, key: "desk")])
        let panel = panel(widget)
        XCTAssertTrue(field.view.isHidden)
        XCTAssertEqual(surface.inputAppearances[field.handle]?.text, "Half a thought")
        focus(widget, field)
        let editor = try XCTUnwrap(field.textEditor)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(field.editing)
        XCTAssertFalse(field.view.isHidden)
        XCTAssertEqual(field.view.alphaValue, 1)
        XCTAssertEqual(surface.inputAppearances[field.handle]?.text, "")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(", then milk", replacementRange: NSRange(location: NSNotFound, length: 0))
        field.changed()
        try deliver(widget, .textChange)
        XCTAssertEqual(widget.text.string(try input(widget).content.text), "Half a thought, then milk")
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(field.command(#selector(NSResponder.insertNewline(_:))))
        try deliver(widget, .textCommit)
        XCTAssertTrue(widget.strings().contains("Half a thought, then milk"))
        let next = try XCTUnwrap(surface.textInputs.values.first)
        XCTAssertFalse(next === field)
        XCTAssertTrue(next.editing)
        XCTAssertTrue(panel.firstResponder === next.textEditor)
        XCTAssertEqual(next.text, "")
    }

    func testAFocusedPadEditorSurvivesATabSwitchRevealAndIsReleasedWhenTheDeskCloses() throws {
        let shell = try VitreusFixture.shell()
        let folder = shell.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell, animations: true)
        )
        let surface = widget.surface
        let clock = ShellManipulationSurfaceTests.Clock()
        surface.clock = { clock.now }
        VitreusFixture.show(widget)
        let panel = panel(widget)
        VitreusFixture.trigger(widget.instance, "desk-open", VitreusFixture.bar().monitorId)
        VitreusFixture.show(widget)
        let desk = try VitreusFixture.element(widget, key: "desk")
        let plan = try XCTUnwrap(surface.reveals[desk]?.plan)
        clock.now += 0.1
        let tab = CGRect(surface.presentedFrame(of: try VitreusFixture.element(widget, key: "tab-pad")))
        VitreusFixture.click(widget, at: CGPoint(x: tab.midX, y: tab.midY))
        XCTAssertEqual(surface.reveals[desk]?.plan?.begin, plan.begin)
        try type(widget, "Milk")
        let field = try XCTUnwrap(surface.textInputs.values.first)
        XCTAssertTrue(surface.isRevealing(field.handle, in: surface.presentation))
        focus(widget, field)
        let editor = try XCTUnwrap(field.textEditor)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(field.editing)
        XCTAssertTrue(field.presentsTransiently)
        XCTAssertEqual(field.view.alphaValue, 0)
        XCTAssertFalse(field.view.isHidden)
        XCTAssertEqual(surface.inputAppearances[field.handle]?.text, "Milk")
        clock.now = plan.end
        surface.revealSettled(desk.slot, token: try XCTUnwrap(surface.reveals[desk]?.token))
        XCTAssertNil(surface.reveals[desk]?.plan)
        XCTAssertFalse(field.presentsTransiently)
        XCTAssertEqual(field.view.alphaValue, 1)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(field.editing)
        XCTAssertEqual(field.text, "Milk")
        XCTAssertEqual(surface.inputAppearances[field.handle]?.text, "")
        VitreusFixture.trigger(widget.instance, "desk-close", nil)
        VitreusFixture.show(widget)
        XCTAssertTrue(surface.textInputs.isEmpty)
        XCTAssertFalse(surface.declaredFocus)
        XCTAssertFalse(field.editing)
        XCTAssertFalse(panel.firstResponder === editor)
    }
}
