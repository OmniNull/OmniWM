// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellManipulationSurfaceTests {
    private static let editorBody = followBody.replacingOccurrences(
        of: "w=80,h=25,text='stateful note'", with: "w=80,h=25,multiline=true,text='stateful note'"
    )

    private func prepareEditor(_ fixture: Fixture, in window: Window) throws -> ShellTextInput {
        window.acceptsDeclaredFocus = true
        window.contentView = fixture.surface.view
        let input = try XCTUnwrap(fixture.surface.textInputs.values.first)
        fixture.surface.focusDeclared(input.handle)
        input.editor?.string = "edited note"
        input.editor?.setSelectedRange(NSRange(location: 2, length: 4))
        input.beganEditing()
        fixture.surface.refreshOwnedInputs()
        XCTAssertTrue(window.selectedResponder === input.responder)
        return input
    }

    private func rasterTexts(_ commands: [ShellLayerCommand], for input: ShellTextInput) -> [String] {
        commands.compactMap {
            if case let .text(slot, text, _, _, _, _, _) = $0, slot == input.handle.slot { return text }
            return nil
        }
    }

    private func applyEditorFixture(_ fixture: Fixture, acknowledgement: UInt64 = 0) {
        XCTAssertEqual(fixture.script.render().status, OMNI_OK, fixture.script.message)
        fixture.text.ingest(wire: fixture.script.output)
        fixture.surface.sequence += 1
        XCTAssertTrue(fixture.surface.apply(
            fixture.script.output, text: fixture.text, gestureAcknowledgement: acknowledgement
        ))
        ShellLayerScene.engineQueue.sync {}
    }

    func testHiddenOwnedInputKeepsItsFocusRequestUntilItIsVisible() throws {
        let body = Self.followBody
            .replacingOccurrences(
                of: "local rect=vars.x and {x=vars.x,y=70,w=100,h=80} or ctx.state.rect or home",
                with: "local rect={x=vars.x or -1000,y=70,w=100,h=80}"
            )
            .replacingOccurrences(
                of: "w=80,h=25,text='stateful note'",
                with: "w=80,h=25,text='stateful note',focus=true"
            )
        let fixture = try follow(body, clock: Clock())
        let surface = fixture.surface
        let window = Window()
        window.acceptsDeclaredFocus = true
        window.contentView = surface.view
        defer {
            surface.blurDeclaredFocus()
            window.contentView = nil
        }
        surface.layoutTextInputs()
        let input = try XCTUnwrap(surface.textInputs.values.first)
        XCTAssertTrue(input.view.isHidden)
        XCTAssertTrue(input.pendingFocus)
        surface.realizeTextInputFocus()
        XCTAssertEqual(surface.focused, .none)
        XCTAssertEqual(surface.selectedManipulation, .none)
        setValues(fixture, numbers: ["x": 80])
        fixture.render()
        surface.finishSettle()
        surface.layoutTextInputs()
        surface.realizeTextInputFocus()
        XCTAssertFalse(input.view.isHidden)
        XCTAssertEqual(surface.focused, input.handle)
    }

    func testTabSkipsAnOwnedInputThatIsOffScreen() throws {
        func card(_ key: String, x: Int) -> String {
            """
            ui.stack{key='\(key)',align='topLeading',dx=\(x),dy=70,w=100,h=80,
                manipulationFollow={response=0.363,bounce=0.42},fill='surface',
                ui.box{align='topLeading',w=100,h=20,onGesture=function() end,
                    gesture={axis='free',track={mode='move',target='\(key)',bounds={w=600,h=400},
                        min={w=50,h=40},max={w=300,h=240}}}},
                ui.input{key='\(key)-note',align='topLeading',dy=30,w=80,h=25,text='\(key)'}}
            """
        }
        let fixture = try follow(
            "return ui.stack{w=600,h=400,\(card("shown", x: 80)),\(card("hidden", x: -1000))}", clock: Clock()
        )
        let surface = fixture.surface
        let window = Window()
        window.acceptsDeclaredFocus = true
        window.contentView = surface.view
        defer {
            surface.blurDeclaredFocus()
            window.contentView = nil
        }
        surface.layoutTextInputs()
        let shown = try XCTUnwrap(surface.textInputs.values.first { $0.onScreen })
        XCTAssertEqual(surface.textInputs.count, 2)
        surface.focusTextInput(shown)
        XCTAssertEqual(surface.focused, shown.handle)
        for backwards in [false, true] {
            surface.moveTextInputFocus(from: shown.handle, backwards: backwards)
            XCTAssertEqual(surface.focused, shown.handle)
        }
    }

    func testFocusedEditorIsAlphaSuppressedDuringDragHoldAndSettleAndRestoredOnCompletion() throws {
        let clock = Clock()
        let fixture = try follow(Self.editorBody, clock: clock)
        let surface = fixture.surface
        let window = Window()
        let input = try prepareEditor(fixture, in: window)
        defer { surface.blurDeclaredFocus()
            window.contentView = nil
        }
        let initialFrame = input.view.frame
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        XCTAssertEqual(input.view.alphaValue, 0)
        XCTAssertFalse(input.view.isHidden)
        XCTAssertEqual(surface.inputAppearances[input.handle]?.text, "edited note")
        XCTAssertTrue(window.selectedResponder === input.responder)
        for sample in 1 ... 4 {
            clock.now += 0.016
            surface.drag(to: CGPoint(x: 185 + sample, y: 75), screen: .zero, timestamp: Double(sample))
            surface.layoutTextInputs()
            XCTAssertEqual(input.view.frame, initialFrame)
            XCTAssertTrue(surface.ownedInputCommands().isEmpty)
        }
        let invocation = try fixture.releaseMove(at: CGPoint(x: 189, y: 75))
        XCTAssertTrue(surface.manipulation?.holding == true)
        XCTAssertEqual(input.view.alphaValue, 0)
        try fixture.invokeRelease()
        fixture.render(acknowledgement: invocation)
        XCTAssertNil(surface.manipulation)
        XCTAssertNotNil(try record(fixture)?.motion)
        XCTAssertEqual(input.view.alphaValue, 0)
        XCTAssertFalse(input.view.isHidden)
        let token = try XCTUnwrap(record(fixture)?.token)
        surface.manipulationSettled(try fixture.target().slot, token: token)
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertEqual(input.view.frame, CGRect(surface.presentedFrame(of: input.handle)))
        XCTAssertEqual(input.text, "edited note")
        XCTAssertEqual(input.editor?.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertTrue(input.editing)
        XCTAssertTrue(window.selectedResponder === input.responder)
        XCTAssertEqual(surface.inputAppearances[input.handle]?.text, "")
    }

    func testEditorRasterIsCollectedOnceAtEachPresentationTransition() throws {
        let clock = Clock()
        let fixture = try follow(Self.editorBody, clock: clock)
        let surface = fixture.surface
        let window = Window()
        let input = try prepareEditor(fixture, in: window)
        defer { surface.blurDeclaredFocus()
            window.contentView = nil
        }
        let target = try fixture.target()
        surface.follows[target]?.motion = try XCTUnwrap(ShellManipulationMotion(
            from: Self.home, to: Self.home.offsetBy(dx: 100, dy: 0), begin: clock.now, spring: desk
        ))
        var commands: [ShellLayerCommand] = []
        surface.layoutTextInputs(into: &commands)
        XCTAssertEqual(rasterTexts(commands, for: input), ["edited note"])
        commands.removeAll()
        for _ in 0 ..< 10 {
            clock.now += 0.016
            surface.layoutTextInputs(into: &commands)
        }
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(surface.editorPresentsTransiently(input.handle, in: surface.presentation))
        surface.follows[target]?.motion = nil
        surface.layoutTextInputs(into: &commands)
        XCTAssertEqual(rasterTexts(commands, for: input), [""])
        commands.removeAll()
        surface.layoutTextInputs(into: &commands)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertTrue(surface.layout.core.contains(target))
    }

    func testFinishSettleAndImmediateCancelRestoreTheEditorSynchronously() throws {
        for finishing in [true, false] {
            let clock = Clock()
            let fixture = try follow(Self.editorBody, clock: clock)
            let surface = fixture.surface
            let window = Window()
            let input = try prepareEditor(fixture, in: window)
            defer { surface.blurDeclaredFocus()
                window.contentView = nil
            }
            if finishing {
                try commitMove(fixture, to: CGPoint(x: 185, y: 75), clock: clock)
                clock.now += 0.03
                surface.finishSettle()
            } else {
                fixture.beginMove(to: CGPoint(x: 185, y: 75))
                clock.now += 0.03
                surface.cancelManipulation(reason: "test", immediate: true)
            }
            XCTAssertEqual(input.view.alphaValue, 1)
            XCTAssertFalse(input.view.isHidden)
            XCTAssertEqual(input.view.frame, CGRect(surface.presentedFrame(of: input.handle)))
            XCTAssertEqual(input.text, "edited note")
            XCTAssertEqual(input.editor?.selectedRange(), NSRange(location: 2, length: 4))
            XCTAssertTrue(window.selectedResponder === input.responder)
        }
    }

    func testScaleCommitKeepsEditorSuppressedUntilTheNewLayoutSettles() throws {
        let clock = Clock()
        let fixture = try follow(Self.editorBody, clock: clock)
        let surface = fixture.surface
        let window = Window()
        let input = try prepareEditor(fixture, in: window)
        defer { surface.blurDeclaredFocus()
            window.contentView = nil
        }
        surface.press(at: CGPoint(x: 175, y: 145), timestamp: 0)
        surface.drag(to: CGPoint(x: 125, y: 105), screen: .zero, timestamp: 0.01)
        clock.now += 0.05
        XCTAssertTrue(surface.editorPresentsTransiently(input.handle, in: surface.presentation))
        XCTAssertEqual(input.view.alphaValue, 0)
        surface.release(at: CGPoint(x: 125, y: 105), timestamp: 0.02)
        let invocation = try XCTUnwrap(fixture.lastInvocation)
        try fixture.invokeRelease()
        applyEditorFixture(fixture, acknowledgement: invocation)
        XCTAssertNil(surface.manipulation)
        XCTAssertEqual(input.view.alphaValue, 0)
        surface.finishSettle()
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertEqual(input.view.frame, CGRect(surface.layout.core.absoluteFrame(of: input.handle)))
        XCTAssertEqual(input.text, "edited note")
        XCTAssertEqual(input.editor?.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertEqual(surface.inputAppearances[input.handle]?.text, "")
    }

    func testFollowRecipeAndAspectClearsRestoreEditorBeforeAnotherLayoutPass() throws {
        for recipeChange in [true, false] {
            let clock = Clock()
            let body = Self.editorBody.replacingOccurrences(
                of: "response=0.363", with: "response=vars.response or 0.363"
            ).replacingOccurrences(
                of: "return ui.stack{w=600",
                with: "if vars.h then rect={x=rect.x,y=rect.y,w=rect.w,h=vars.h} end return ui.stack{w=600"
            )
            let fixture = try follow(body, clock: clock)
            let surface = fixture.surface
            let window = Window()
            let input = try prepareEditor(fixture, in: window)
            defer { surface.blurDeclaredFocus()
                window.contentView = nil
            }
            try commitMove(fixture, to: CGPoint(x: 185, y: 75), clock: clock)
            clock.now += 0.03
            XCTAssertEqual(input.view.alphaValue, 0)
            setVars(fixture, recipeChange ? "response" : "h", recipeChange ? 0.6 : 100, commit: "next")
            applyEditorFixture(fixture)
            XCTAssertNil(try record(fixture)?.motion)
            XCTAssertEqual(input.view.alphaValue, 1)
            XCTAssertFalse(input.view.isHidden)
            XCTAssertEqual(input.view.frame, CGRect(surface.presentedFrame(of: input.handle)))
            XCTAssertEqual(input.text, "edited note")
            XCTAssertEqual(surface.inputAppearances[input.handle]?.text, "")
        }
    }

    func testUnfocusedOwnedEditorKeepsItsExistingHiddenNativeViewAndRaster() throws {
        let clock = Clock()
        let fixture = try follow(Self.editorBody, clock: clock)
        let surface = fixture.surface
        let input = try XCTUnwrap(surface.textInputs.values.first)
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        XCTAssertFalse(input.presentsTransiently)
        XCTAssertTrue(input.view.isHidden)
        XCTAssertEqual(surface.inputAppearances[input.handle]?.text, "stateful note")
        surface.cancelManipulation(reason: "test", immediate: true)
    }

    func testEditorLayoutSamplesPresentationOncePerPass() throws {
        let clock = Clock()
        let fixture = try follow(Self.editorBody.replacingOccurrences(
            of: "ui.input{key='note'", with: "ui.input{key='extra',w=20,h=20},ui.input{key='note'"
        ), clock: clock)
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        var samples = 0
        fixture.surface.clock = { samples += 1
            return clock.now
        }
        fixture.surface.layoutTextInputs()
        XCTAssertEqual(samples, 1)
        fixture.surface.cancelManipulation(reason: "test", immediate: true)
    }

    func testSingleLineNativeFieldEditorKeepsFirstResponderAndSelectionWhileAlphaSuppressed() throws {
        _ = NSApplication.shared
        let clock = Clock()
        let fixture = try follow(clock: clock)
        let surface = fixture.surface
        let panel = ShellFocusPanel(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.acceptsDeclaredFocus = true
        panel.contentView = surface.view
        defer { surface.blurDeclaredFocus()
            panel.contentView = nil
        }
        surface.layoutTextInputs()
        let input = try XCTUnwrap(surface.textInputs.values.first)
        surface.recordDeclaredFocus(input.handle)
        XCTAssertTrue(panel.makeFirstResponder(input.responder))
        let editor = try XCTUnwrap(input.textEditor)
        editor.string = "edited note"
        editor.setSelectedRange(NSRange(location: 2, length: 4))
        XCTAssertTrue(panel.firstResponder === editor)
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        XCTAssertEqual(input.view.alphaValue, 0)
        XCTAssertFalse(input.view.isHidden)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 4))
        surface.cancelManipulation(reason: "test", immediate: true)
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertEqual(editor.string, "edited note")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 4))
    }

    func testImmediateResizeCommitLeavesOnlyTheNativeEditorAfterTheOutgoingBatch() throws {
        let body = Self.editorBody.replacingOccurrences(
            of: "manipulationFollow={response=0.363,bounce=0.42},",
            with: ""
        )
        .replacingOccurrences(of: "mode='scale'", with: "mode='resize'")
        .replacingOccurrences(of: "w=80,h=25,multiline=true", with: "w=rect.w-20,h=25,multiline=true")
        let fixture = try Fixture(body)
        let surface = fixture.surface
        let window = Window()
        let input = try prepareEditor(fixture, in: window)
        defer { surface.blurDeclaredFocus()
            window.contentView = nil
        }
        surface.press(at: CGPoint(x: 175, y: 145), timestamp: 0)
        surface.drag(to: CGPoint(x: 125, y: 105), screen: .zero, timestamp: 0.01)
        XCTAssertEqual(input.view.alphaValue, 0)
        surface.release(at: CGPoint(x: 125, y: 105), timestamp: 0.02)
        let invocation = try XCTUnwrap(fixture.lastInvocation)
        try fixture.invokeRelease()
        applyEditorFixture(fixture, acknowledgement: invocation)
        XCTAssertNil(surface.manipulation)
        XCTAssertEqual(input.view.alphaValue, 1)
        XCTAssertEqual(surface.inputAppearances[input.handle]?.text, "")
        let contents = ShellLayerScene.engineQueue.sync { surface.scene.layers[input.handle.slot]?.contents }
        XCTAssertNil(contents)
    }

    func testOwnerCommitStartingASettleSuppressesTheFocusedEditorBeforeAnotherLayoutPass() throws {
        let clock = Clock()
        let fixture = try follow(Self.editorBody, clock: clock)
        let surface = fixture.surface
        let window = Window()
        let input = try prepareEditor(fixture, in: window)
        defer { surface.blurDeclaredFocus()
            window.contentView = nil
        }
        setVars(fixture, "x", 200, commit: "external-placement")
        applyEditorFixture(fixture)
        XCTAssertNotNil(try record(fixture)?.motion)
        XCTAssertEqual(input.view.alphaValue, 0)
        XCTAssertFalse(input.view.isHidden)
        XCTAssertEqual(surface.inputAppearances[input.handle]?.text, "edited note")
        surface.finishSettle()
    }
}
