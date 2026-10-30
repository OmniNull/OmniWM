// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellTextInputFocusTests: XCTestCase {
    private final class Panel: ShellFocusPanel {
        var calls = 0
        var depth = 0
        var maximumDepth = 0

        override var isVisible: Bool {
            true
        }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            calls += 1
            depth += 1
            maximumDepth = max(maximumDepth, depth)
            defer { depth -= 1 }
            guard calls < 32, depth < 8 else { return false }
            return super.makeFirstResponder(responder)
        }
    }

    private func panel(for widget: ShellRenderedWidget) -> Panel {
        let panel = Panel(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.acceptsDeclaredFocus = true
        panel.contentView = widget.surface.view
        widget.surface.view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        widget.surface.layoutTextInputs()
        return panel
    }

    private func assertFocused(_ input: ShellTextInput, in panel: Panel) throws {
        XCTAssertTrue(input.editing)
        XCTAssertFalse(input.pendingFocus)
        XCTAssertTrue(input.surface?.declaredFocus == true)
        XCTAssertEqual(input.surface?.focused, input.handle)
        let editor = try XCTUnwrap(input.textEditor)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertLessThan(panel.maximumDepth, 3)
        XCTAssertLessThan(panel.calls, 16)
    }

    func testDeclaredSingleLineFocusReplacesAndBlursWithoutResponderReentry() throws {
        _ = NSApplication.shared
        let widget = try ShellRenderedWidget(name: "declared-input-focus", source: """
        function render(ctx)
            return ui.input{key=tostring(ctx.data.seconds),w=160,h=24,focus=true,
                text='draft',onFocus=function() end,onCommit=function() end}
        end
        """)
        widget.set("seconds") { $0.number(0) }
        widget.render(ShellBarData())
        let surface = widget.surface
        let panel = panel(for: widget)
        defer {
            surface.blurDeclaredFocus()
            panel.contentView = nil
        }
        var focusChanges: [Bool] = []
        surface.onFocusChange = { active in
            focusChanges.append(active)
            if active { surface.realizeTextInputFocus() }
        }
        surface.realizeTextInputFocus()
        let first = try XCTUnwrap(surface.textInputs.values.first)
        try assertFocused(first, in: panel)
        XCTAssertEqual(focusChanges, [true])
        let calls = panel.calls
        surface.focusDeclared(first.handle)
        surface.realizeTextInputFocus()
        XCTAssertEqual(panel.calls, calls)
        first.field?.stringValue = "accepted"
        XCTAssertTrue(first.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(first.editing)
        XCTAssertFalse(surface.declaredFocus)
        XCTAssertEqual(focusChanges, [true, false])

        widget.set("seconds") { $0.number(1) }
        surface.sequence += 1
        widget.render(ShellBarData())
        let replacement = try XCTUnwrap(surface.textInputs.values.first)
        XCTAssertFalse(replacement === first)
        XCTAssertNil(first.view.superview)
        try assertFocused(replacement, in: panel)
        XCTAssertEqual(focusChanges, [true, false, true])
        XCTAssertTrue(panel.makeFirstResponder(surface.view))
        XCTAssertFalse(replacement.editing)
        XCTAssertFalse(surface.declaredFocus)
        XCTAssertEqual(focusChanges, [true, false, true, false])
    }

    func testNativeEntryAndTabTransferRecordFocusWithoutRefocusingTheFieldEditor() throws {
        _ = NSApplication.shared
        let widget = try ShellRenderedWidget(name: "native-input-focus", source: """
        function render(ctx)
            return ui.column{ui.input{key='a',w=160,h=24},ui.input{key='b',w=160,h=24}}
        end
        """)
        widget.render(ShellBarData())
        let surface = widget.surface
        let panel = panel(for: widget)
        defer {
            surface.blurDeclaredFocus()
            panel.contentView = nil
        }
        surface.onFocusChange = { active in
            if active { surface.realizeTextInputFocus() }
        }
        let inputs = surface.textInputs.values.sorted { $0.view.frame.minY < $1.view.frame.minY }
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(panel.makeFirstResponder(inputs[0].responder))
        try assertFocused(inputs[0], in: panel)
        surface.moveTextInputFocus(from: inputs[0].handle, backwards: false)
        XCTAssertFalse(inputs[0].editing)
        try assertFocused(inputs[1], in: panel)
    }
}
