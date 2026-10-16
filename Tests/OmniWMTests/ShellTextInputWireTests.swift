// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellTextInputWireTests: XCTestCase {
    func testNativeInputWireCarriesFieldsAndBounds() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            local function handler() end
            return ui.input{key='search',text='hello',placeholder='Search',multiline=true,maxLength=42,
                focus=true,onChange=handler,onCommit=handler,onCancel=handler,onFocus=handler}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let node = try first(script)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 392)
        XCTAssertEqual(node.kind, 10)
        XCTAssertNotEqual(node.key, 0)
        XCTAssertEqual(node.input_max_length, 42)
        XCTAssertEqual(
            node.input_flags,
            UInt8(OMNI_INPUT_FOCUSABLE | OMNI_INPUT_MULTILINE | OMNI_INPUT_FOCUS_PRESENT | OMNI_INPUT_FOCUS_VALUE)
        )
        for action in [node.action, node.input_commit_action, node.input_cancel_action, node.input_focus_action] {
            XCTAssertNotEqual(action & OMNI_ACTION_HANDLER, 0)
        }
        let text = ShellTextStore()
        text.ingest(wire: script.output)
        XCTAssertEqual(text.string(node.text), "hello")
        XCTAssertEqual(text.string(node.placeholder), "Search")
    }

    func testAbsentAndFalseFocusRemainDistinct() throws {
        for explicit in [false, true] {
            let script = try ShellScriptHostTests
                .Script("function render(ctx) return ui.input{key='field', \(explicit ? "focus=false" : "")} end")
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            let node = try first(script)
            XCTAssertEqual(node.input_max_length, 65536)
            XCTAssertEqual(
                node.input_flags & UInt8(OMNI_INPUT_FOCUS_PRESENT),
                explicit ? UInt8(OMNI_INPUT_FOCUS_PRESENT) : 0
            )
            XCTAssertEqual(node.input_flags & UInt8(OMNI_INPUT_FOCUS_VALUE), 0)
        }
    }

    func testInvalidNativeInputDeclarationsFailExplicitly() throws {
        for properties in [
            "text='no key'",
            "key='x',maxLength=-1",
            "key='x',maxLength=65537",
            "key='x',maxLength=1.5",
            "key='x',maxLength=1.00000001",
            "key='x',maxLength=math.huge",
            "key='x',multiline=1",
            "key='x',focus='yes'",
            "key='x',onChange='focus left'",
            "key='x',onCommit=1",
            "key='x',onCancel=true",
            "key='x',onFocus={}",
            "key='x',mask=true",
            "key='x',ui.text{text='child'}"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return ui.input{\(properties)} end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, properties)
        }
    }

    func testTextEventsDecodeAtThePublicHandlerBoundary() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.input{key='field',onChange=function(next,event)
                assert(event.text=='edited')
                next.state.changed=true
            end,onFocus=function(next,event)
                assert(next.state.changed and event.focused==false)
            end}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let node = try first(script)
        var change = ShellEvent(button: .none)
        change.kind = .textChange
        change.text = "edited"
        XCTAssertEqual(script.invoke(node.action, event: change.bytes), OMNI_OK, script.message)
        var focus = ShellEvent(button: .none)
        focus.kind = .textFocus
        focus.focused = false
        XCTAssertEqual(script.invoke(node.input_focus_action, event: focus.bytes), OMNI_OK, script.message)
    }

    private func first(_ script: ShellScriptHostTests.Script) throws -> omni_wire_node {
        let offset = MemoryLayout<omni_wire_header>.stride
        guard script.output.count >= offset + MemoryLayout<omni_wire_node>.stride else {
            throw NSError(domain: "ShellTextInputWireTests", code: 1)
        }
        return script.output.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: omni_wire_node.self) }
    }
}
