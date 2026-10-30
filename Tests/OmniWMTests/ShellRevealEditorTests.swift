// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellRevealEditorTests: XCTestCase {
    private typealias Fixture = ShellManipulationSurfaceTests.Fixture
    private typealias Clock = ShellManipulationSurfaceTests.Clock
    private typealias Window = ShellManipulationSurfaceTests.Window

    private static let body = """
    return ui.stack{w=400,h=300,
        ctx.data.open and ui.stack{key='reveal',reveal={response=0.482,bounce=0.31},
            align='topLeading',dx=100,dy=50,w=200,h=200,
            ui.stack{key='content',w=200,h=200,morph={anchor={x=1,y=0.5},stops={
                {at=0,scale=0.05,opacity=0},{at=0.02,scale=0.05,opacity=0},
                {at=0.0201,scale=0.05},{at=0.03125,scale=0.05},{at=0.625},{at=1}}},
                ui.input{key='field',align='topLeading',dx=20,dy=20,w=80,h=24,text='note'}}} or nil}
    """

    private func open(_ fixture: Fixture) {
        var writer = ShellValueWriter()
        writer.bool(true)
        _ = writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "open", $0.baseAddress, $0.count)
        }
        fixture.render()
    }

    private func settle(_ fixture: Fixture) throws {
        let reveal = try XCTUnwrap(fixture.surface.reveals.first)
        fixture.surface.revealSettled(reveal.key.slot, token: reveal.value.token)
    }

    func testNonOwnedUnfocusedEditorIsAlphaHiddenWhileItsRevealGroupIsHidden() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.body, animations: true) { clock.now }
        open(fixture)
        let surface = fixture.surface
        let input = try XCTUnwrap(surface.textInputs.values.first)
        XCTAssertNil(surface.manipulationOwner(of: input.handle))
        XCTAssertFalse(surface.declaredFocus)
        XCTAssertEqual(input.view.alphaValue, 0)
        XCTAssertFalse(input.view.isHidden)
        XCTAssertTrue(input.presentsTransiently)
        let frozen = input.view.frame
        clock.now += 0.005
        surface.layoutTextInputs()
        XCTAssertEqual(input.view.alphaValue, 0)
        XCTAssertEqual(input.view.frame, frozen)
        clock.now += 0.055
        surface.layoutTextInputs()
        XCTAssertFalse(input.presentsTransiently)
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertEqual(input.view.frame, CGRect(surface.presentedFrame(of: input.handle)))
        XCTAssertLessThan(input.view.frame.width, 80)
        try settle(fixture)
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertEqual(input.view.frame.width, 80, accuracy: 1e-3)
        XCTAssertEqual(input.text, "note")
    }

    func testNonOwnedFocusedEditorIsHiddenOnlyWhileItsRevealGroupIsHidden() throws {
        let clock = Clock()
        let body = Self.body.replacingOccurrences(of: "text='note'", with: "multiline=true,text='note'")
        let fixture = try Fixture(body, animations: true) { clock.now }
        open(fixture)
        let surface = fixture.surface
        let input = try XCTUnwrap(surface.textInputs.values.first)
        let window = Window()
        window.acceptsDeclaredFocus = true
        window.contentView = surface.view
        defer { surface.blurDeclaredFocus()
            window.contentView = nil
        }
        surface.focusDeclared(input.handle)
        input.editor?.string = "unsaved note"
        input.editor?.setSelectedRange(NSRange(location: 2, length: 4))
        input.beganEditing()
        XCTAssertNil(surface.manipulationOwner(of: input.handle))
        XCTAssertTrue(window.selectedResponder === input.responder)
        let frozen = input.view.frame
        for (step, hidden) in [(0.005, true), (0.055, false), (0.14, false)] {
            clock.now += step
            surface.layoutTextInputs()
            XCTAssertEqual(surface.editorPresentsTransiently(input.handle, in: surface.presentation), hidden)
            XCTAssertEqual(input.view.alphaValue, hidden ? 0 : 1)
            XCTAssertFalse(input.view.isHidden)
            if hidden { XCTAssertEqual(input.view.frame, frozen) }
            else { XCTAssertEqual(input.view.frame, CGRect(surface.presentedFrame(of: input.handle))) }
            XCTAssertEqual(input.text, "unsaved note")
            XCTAssertEqual(input.editor?.selectedRange(), NSRange(location: 2, length: 4))
            XCTAssertTrue(input.editing)
            XCTAssertTrue(window.selectedResponder === input.responder)
        }
        try settle(fixture)
        XCTAssertFalse(input.presentsTransiently)
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertEqual(input.view.frame, CGRect(surface.presentedFrame(of: input.handle)))
        XCTAssertEqual(input.view.frame.width, 80, accuracy: 1e-3)
        XCTAssertEqual(input.text, "unsaved note")
        XCTAssertEqual(input.editor?.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertTrue(input.editing)
        XCTAssertTrue(window.selectedResponder === input.responder)
    }

    func testAFocusRequestInsideAHiddenRevealIsTakenWhenTheInputIsInserted() throws {
        let clock = Clock()
        let body = Self.body.replacingOccurrences(of: "text='note'", with: "text='note',focus=true")
        let fixture = try Fixture(body, animations: true) { clock.now }
        let surface = fixture.surface
        let window = Window()
        window.acceptsDeclaredFocus = true
        window.contentView = surface.view
        defer { surface.blurDeclaredFocus()
            window.contentView = nil
        }
        open(fixture)
        let input = try XCTUnwrap(surface.textInputs.values.first)
        XCTAssertTrue(input.presentsTransiently)
        XCTAssertEqual(surface.focused, input.handle)
    }

    func testReducedMotionNonOwnedEditorAppearsAtItsLayoutFrame() throws {
        let fixture = try Fixture(Self.body, animations: false)
        open(fixture)
        let input = try XCTUnwrap(fixture.surface.textInputs.values.first)
        XCTAssertNil(fixture.surface.presentation)
        XCTAssertFalse(input.presentsTransiently)
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertEqual(input.view.frame.width, 80, accuracy: 1e-3)
    }
}
