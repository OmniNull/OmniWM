// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellTextInputTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let widget: ShellRenderedWidget
        var events: [ShellClick] = []

        init(_ body: String) throws {
            _ = NSApplication.shared
            widget = try ShellRenderedWidget(name: "text-input", source: "function render(ctx) " + body + " end")
            widget.surface.view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
            widget.surface.onAction = { [weak self] in self?.events.append($0) }
            render()
        }

        func render(_ value: Double = 0) {
            widget.set("seconds") { $0.number(value) }
            widget.surface.sequence += 1
            widget.render(ShellBarData())
        }

        func input() throws -> ShellTextInput {
            try XCTUnwrap(widget.surface.textInputs.values.first)
        }
    }

    func testKeyPreservesSubviewAndFocusedTextAcrossModelRenders() throws {
        let fixture =
            try Fixture("return ui.input{key='query',text=tostring(ctx.data.seconds),onChange=function() end}")
        let input = try fixture.input()
        let handle = input.handle
        XCTAssertEqual(input.text, "0")
        input.beganEditing()
        input.field?.stringValue = "native draft"
        input.changed()
        fixture.render(1)
        XCTAssertTrue(fixture.widget.surface.textInputs[handle] === input)
        XCTAssertEqual(input.text, "native draft")
        XCTAssertEqual(fixture.events.last?.event.text, "native draft")
        fixture.widget.surface.blurDeclaredFocus()
        fixture.render(2)
        XCTAssertTrue(fixture.widget.surface.textInputs[handle] === input)
        XCTAssertEqual(input.text, "2")
    }

    func testRemovedEditorIsRetiredAndCannotRetainDeclaredFocus() throws {
        let fixture =
            try Fixture(
                "if ctx.data.seconds==0 then return ui.input{key='query',text='edit',onFocus=function() end} end return ui.box{w=40,h=20}"
            )
        let input = try fixture.input()
        input.beganEditing()
        XCTAssertTrue(fixture.widget.surface.declaredFocus)
        fixture.render(1)
        XCTAssertTrue(fixture.widget.surface.textInputs.isEmpty)
        XCTAssertNil(input.view.superview)
        XCTAssertFalse(input.editing)
        XCTAssertFalse(fixture.widget.surface.declaredFocus)
        XCTAssertEqual(fixture.events.filter { $0.event.kind == .textFocus }.map(\.event.focused), [true, false])
    }

    func testModelFocusIsAnEdgeRequestAndDoesNotReopenAfterBlur() throws {
        let fixture = try Fixture("return ui.input{key='query',text='value',focus=ctx.data.seconds~=2}")
        let input = try fixture.input()
        XCTAssertTrue(input.pendingFocus)
        XCTAssertFalse(fixture.widget.surface.declaredFocus)
        input.beganEditing()
        fixture.widget.surface.blurDeclaredFocus()
        fixture.render(1)
        XCTAssertFalse(input.pendingFocus)
        XCTAssertFalse(fixture.widget.surface.declaredFocus)
        fixture.render(2)
        fixture.render(3)
        XCTAssertTrue(input.pendingFocus)
        XCTAssertFalse(fixture.widget.surface.declaredFocus)
    }

    func testRemovedSettingsSubtreeRetiresHexEditorsAndPreservesSurvivingInput() throws {
        let fixture = try Fixture("""
        local tree = {key='root'}
        if ctx.data.seconds==0 then
            tree[#tree+1] = ui.column{key='appearance',
                ui.input{key='background',text='#000000',multiline=true,onFocus=function() end},
                ui.input{key='highlight',text='#ffffff22'}}
        end
        tree[#tree+1] = ui.input{key='survivor',text='keep'}
        return ui.column(tree)
        """)
        let surface = fixture.widget.surface
        let inputs = Array(surface.textInputs.values)
        let survivor = try XCTUnwrap(inputs.first { $0.text == "keep" })
        let background = try XCTUnwrap(inputs.first { $0.text == "#000000" })
        background.beganEditing()
        XCTAssertEqual(surface.textInputs.count, 3)
        XCTAssertTrue(surface.declaredFocus)

        fixture.render(1)

        XCTAssertEqual(surface.textInputs.count, 1)
        XCTAssertTrue(surface.textInputs[survivor.handle] === survivor)
        XCTAssertTrue(survivor.view.superview === surface.view)
        for input in inputs where input !== survivor {
            XCTAssertNil(input.view.superview)
            XCTAssertFalse(input.editing)
        }
        XCTAssertTrue(surface.declaredFocus)
        XCTAssertEqual(surface.focused, survivor.handle)
        XCTAssertEqual(surface.view.subviews.count, 1)

        fixture.render(0)

        XCTAssertEqual(surface.textInputs.count, 3)
        XCTAssertEqual(surface.view.subviews.count, 3)
        XCTAssertTrue(surface.textInputs[survivor.handle] === survivor)
        XCTAssertFalse(surface.textInputs.values.contains { $0 === background })
    }

    func testRootReplacementRetiresNestedTextEditors() throws {
        let fixture = try Fixture("""
        if ctx.data.seconds==0 then
            return ui.column{key='settings',ui.column{key='appearance',
                ui.input{key='background',text='#000000'},
                ui.input{key='highlight',text='#ffffff22',multiline=true}}}
        end
        return ui.box{key='compact',w=40,h=20}
        """)
        let surface = fixture.widget.surface
        let inputs = Array(surface.textInputs.values)
        XCTAssertEqual(inputs.count, 2)
        try XCTUnwrap(inputs.first).beganEditing()
        XCTAssertTrue(surface.declaredFocus)

        fixture.render(1)

        XCTAssertTrue(surface.textInputs.isEmpty)
        XCTAssertTrue(surface.view.subviews.isEmpty)
        XCTAssertFalse(surface.declaredFocus)
        for input in inputs { XCTAssertNil(input.view.superview) }
    }

    func testMaxLengthCountsGraphemesAndDoesNotRewriteMarkedText() throws {
        let fixture =
            try Fixture("return ui.input{key='query',w=120,h=60,multiline=true,maxLength=2,onChange=function() end}")
        let input = try fixture.input()
        let editor = try XCTUnwrap(input.editor)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.widget.surface.view
        XCTAssertTrue(window.makeFirstResponder(editor))
        defer { window.makeFirstResponder(nil)
            window.contentView = nil
        }
        input.beganEditing()
        editor.setMarkedText(
            "日本語",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())
        input.changed()
        fixture.render(1)
        XCTAssertEqual(editor.string, "日本語")
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(fixture.events.contains { $0.event.kind == .textChange })
        editor.unmarkText()
        XCTAssertEqual(editor.string, "日本")
        XCTAssertEqual(fixture.events.last?.event.text, "日本")
        editor.string = "👩‍👩‍👧‍👦e\u{301}x"
        input.changed()
        XCTAssertEqual(editor.string, "👩‍👩‍👧‍👦e\u{301}")
    }

    func testCommitCancelAndFocusCallbacksUseCurrentTextWithoutImplicitRevert() throws {
        let fixture =
            try Fixture(
                "return ui.input{key='query',text='before',onChange=function() end,onCommit=function() end,onCancel=function() end,onFocus=function() end}"
            )
        let input = try fixture.input()
        input.beganEditing()
        input.field?.stringValue = "accepted"
        XCTAssertTrue(input.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(fixture.events.map(\.event.kind), [.textFocus, .textChange, .textCommit, .textFocus])
        XCTAssertEqual(fixture.events.first?.event.focused, true)
        XCTAssertEqual(fixture.events[2].event.text, "accepted")
        XCTAssertEqual(fixture.events.last?.event.focused, false)
        XCTAssertFalse(fixture.widget.surface.declaredFocus)
        fixture.events.removeAll()
        input.beganEditing()
        input.field?.stringValue = "cancelled edit"
        XCTAssertTrue(input.command(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(fixture.events.map(\.event.kind), [.textFocus, .textChange, .textCancel, .textFocus])
        XCTAssertEqual(input.text, "cancelled edit")
        XCTAssertNil(fixture.events[2].event.text)
    }

    func testMultilineReturnAndMarkedEscapeRemainWithTheNativeEditor() throws {
        let fixture =
            try Fixture(
                "return ui.input{key='query',w=120,h=60,multiline=true,onCommit=function() end,onCancel=function() end}"
            )
        let input = try fixture.input()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = fixture.widget.surface.view
        XCTAssertTrue(window.makeFirstResponder(input.responder))
        defer { window.makeFirstResponder(nil)
            window.contentView = nil
        }
        input.beganEditing()
        XCTAssertFalse(input.command(#selector(NSResponder.insertNewline(_:))))
        let editor = try XCTUnwrap(input.editor)
        editor.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertFalse(input.command(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(fixture.widget.surface.declaredFocus)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testInputFramesUseLayoutAndScrollClippingAndResetRemovesAllSubviews() throws {
        let fixture =
            try Fixture(
                "return ui.column{key='clip',w=80,h=20,scroll=true,ui.input{key='query',w=80,h=40,text='clipped'}}"
            )
        let input = try fixture.input()
        XCTAssertEqual(input.view.frame, CGRect(x: 0, y: 0, width: 80, height: 20))
        XCTAssertEqual(input.field?.frame.size, CGSize(width: 80, height: 40))
        fixture.widget.surface.reset(text: fixture.widget.text)
        XCTAssertTrue(fixture.widget.surface.textInputs.isEmpty)
        XCTAssertNil(input.view.superview)
    }

    func testTextChangeCoalescingIsLatestPerFieldAndNeverMergesDifferentEditors() throws {
        let box = ShellGestureBox()
        let bar = ShellBarKey(monitor: .init(displayId: 91100), island: .all)
        func change(_ text: String, target: UInt64, sequence: Int) -> ShellGestureBox.Gesture {
            var event = ShellEvent(button: .none)
            event.kind = .textChange
            event.phase = .changed
            event.text = text
            event.coalescingTarget = target
            XCTAssertTrue(event.isGesture)
            return ShellGestureBox.Gesture(bar: bar, view: .bar, action: 42, sequence: sequence, event: event)
        }
        let first = try XCTUnwrap(box.post(change("a", target: 1, sequence: 1)))
        XCTAssertNil(box.post(change("ab", target: 1, sequence: 2)))
        let second = try XCTUnwrap(box.post(change("second", target: 2, sequence: 3)))
        XCTAssertNil(box.post(change("abc", target: 1, sequence: 4)))
        XCTAssertEqual(first.take()?.event.text, "abc")
        XCTAssertEqual(second.take()?.event.text, "second")
        box.seal()
        XCTAssertNotNil(box.post(change("abc", target: 1, sequence: 4)))
    }
}
