// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class CommandPaletteShellTests: XCTestCase {
    private static let fieldFrame = CGRect(x: 0, y: 0, width: 200, height: CommandPalettePanel.searchFieldHeight)

    func testPinnedQueryFieldExistsBeforeAnyTreeAndKeepsEditingAcrossRebuildsResetsAndAbsence() throws {
        _ = NSApplication.shared
        var changes: [String] = []
        let widget = try ShellRenderedWidget(name: "pinned", source: """
        function render(ctx)
            if ctx.data.seconds == 1 then
                return ui.box{ w = 40, h = 20 }
            end
            return ui.row{ w = 300, h = 40, ui.input{ key = "\(CommandPaletteShellPresenter.queryKey)",
                text = "model", placeholder = "Search" } }
        end
        """)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = widget.surface.view
        defer { window.makeFirstResponder(nil)
            window.contentView = nil
        }
        let field = widget.surface.pinTextInput(key: CommandPaletteShellPresenter.queryKey, frame: Self.fieldFrame) {
            if $0.kind == .textChange, let text = $0.text { changes.append(text) }
        }
        XCTAssertTrue(field.view.superview === widget.surface.view)
        XCTAssertEqual(field.view.frame, Self.fieldFrame)
        let editor = try XCTUnwrap(field.field)
        XCTAssertTrue(window.makeFirstResponder(editor))
        field.beganEditing()
        let fieldEditor = try XCTUnwrap(field.textEditor)
        fieldEditor.insertText("draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        field.changed()
        XCTAssertEqual(changes, ["draft"])

        func render(_ seconds: Double) {
            widget.set("seconds") { $0.number(seconds) }
            widget.surface.sequence += 1
            widget.render(ShellBarData())
        }

        func assertStillEditing(_ label: String) {
            XCTAssertTrue(field.view.superview === widget.surface.view, label)
            XCTAssertTrue(field.editing, label)
            XCTAssertTrue(window.firstResponder === field.textEditor, label)
            XCTAssertEqual(field.text, "draft", label)
            XCTAssertFalse(widget.surface.declaredFocus, label)
        }

        render(0)
        XCTAssertTrue(widget.surface.textInputs.values.contains { $0 === field })
        XCTAssertEqual(widget.surface.textInputs.count, 1)
        assertStillEditing("bound to the rendered element")

        render(1)
        XCTAssertTrue(widget.surface.textInputs.isEmpty)
        assertStillEditing("element absent")

        render(0)
        XCTAssertTrue(widget.surface.textInputs.values.contains { $0 === field })
        assertStillEditing("rebound")

        widget.surface.reset(text: ShellTextStore())
        XCTAssertTrue(widget.surface.textInputs.isEmpty)
        assertStillEditing("after a surface reset")

        fieldEditor.setMarkedText(
            "日本",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        render(0)
        render(1)
        widget.surface.reset(text: ShellTextStore())
        render(0)
        XCTAssertTrue(fieldEditor.hasMarkedText())
        XCTAssertTrue(window.firstResponder === field.textEditor)
        XCTAssertEqual(changes, ["draft"])
        fieldEditor.unmarkText()
        XCTAssertEqual(changes, ["draft", "draft日本"])

        field.setText("cleared by swift")
        XCTAssertEqual(field.text, "cleared by swift")
        XCTAssertEqual(changes, ["draft", "draft日本"])
    }

    func testSwiftQueryChangesReachTheFieldOnlyOutsideInputMethodComposition() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let presenter = try CommandPaletteShellPresenter(
            source: ShellCommandPaletteSource(
                config: ShellConfig(),
                fingerprint: [:],
                source: ShellRenderedWidget.bundledSource(ShellWidgetHost.commandPaletteWidget),
                directories: [],
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                resourceStore: ShellResourceStore(directory: directory),
                permissions: ShellNetworkPermissions()
            ),
            scale: 2,
            fieldFrame: Self.fieldFrame
        )
        defer { presenter.close() }
        var reported: [String] = []
        presenter.onQuery = { reported.append($0) }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = presenter.chrome
        defer { window.makeFirstResponder(nil)
            window.contentView = nil
        }
        presenter.focusField(in: window)
        presenter.field.beganEditing()
        let editor = try XCTUnwrap(presenter.field.textEditor)
        editor.setMarkedText(
            "日本",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        var data = ShellCommandPaletteData()
        data.open = true
        data.query = "set by a mode switch"
        presenter.publish(data)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(presenter.field.text, "日本")
        XCTAssertEqual(reported, [])

        editor.unmarkText()
        XCTAssertEqual(reported, ["日本"])
        data.query = "日本"
        presenter.publish(data)
        XCTAssertEqual(presenter.field.text, "日本")

        data.query = ""
        presenter.publish(data)
        XCTAssertEqual(presenter.field.text, "")
        XCTAssertEqual(reported, ["日本"])
    }

    func testElementKeysMatchTheRendererAndRevealScrollsTheTargetFullyIntoView() throws {
        _ = NSApplication.shared
        let rows = 20
        let rowHeight = 30.0
        let viewport = 100.0
        let widget = try ShellRenderedWidget(name: "reveal", source: """
        function render(ctx)
            local list = { key = "\(CommandPaletteShellPresenter.resultsKey)", scroll = true, w = 200,
                h = \(viewport), gap = 0 }
            for index = 1, \(rows) do
                list[#list + 1] = ui.box{ key = "row-" .. index, w = 200, h = \(rowHeight) }
            end
            return ui.column(list)
        end
        """)
        widget.render(ShellBarData())
        let layout = widget.surface.layout
        let container = try XCTUnwrap(layout.handle(forKey: CommandPaletteShellPresenter.resultsKey))
        XCTAssertNil(layout.handle(forKey: "row-\(rows + 1)"))
        let containerFrame = layout.core.absoluteFrame(of: container)

        func frame(_ key: String) throws -> Rect {
            try layout.core.absoluteFrame(of: XCTUnwrap(layout.handle(forKey: key)))
        }

        let below = "row-\(rows / 2)"
        widget.surface.reveal(key: below, within: CommandPaletteShellPresenter.resultsKey)
        let revealedBelow = try frame(below)
        XCTAssertEqual(revealedBelow.y + revealedBelow.height, containerFrame.y + containerFrame.height)

        let above = "row-2"
        widget.surface.reveal(key: above, within: CommandPaletteShellPresenter.resultsKey)
        XCTAssertEqual(try frame(above).y, containerFrame.y)

        let offset = layout.core.scrollOffset(of: container)
        widget.surface.reveal(key: above, within: CommandPaletteShellPresenter.resultsKey)
        XCTAssertEqual(layout.core.scrollOffset(of: container), offset)
    }
}
