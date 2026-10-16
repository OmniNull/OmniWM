// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellInputWireTests: XCTestCase {
    func testInputWireCarriesNativeFeedbackIntentAndDeclaredKeys() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            local function handle(next, event) end
            return ui.box{
                onHover = handle, onPress = handle, onGesture = handle, onKey = handle, onOutsidePress = handle,
                pressScale = 0.96, pressOpacity = 0.7, pressFill = 0,
                pressAnimate = { duration = 0.12, curve = { 0.2, 0, 0.8, 1 } },
                hoverDelay = 0.2, hoverGrace = 0.15,
                gesture = { axis = "y", source = "both", threshold = 6, lockDistance = 2, dominance = 1.5,
                    commit = { distance = 40, velocity = 250, direction = "up" } },
                gestureEvents = "all", scrollMomentum = "deliver", focusable = true,
                keys = { "return", "Escape", "escape", "a" },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let node = try first(script)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 392)
        XCTAssertEqual(node.press_scale, 0.96, accuracy: 0.0001)
        XCTAssertEqual(node.press_opacity, 0.7, accuracy: 0.0001)
        XCTAssertEqual(node.press_fill, 0)
        XCTAssertEqual(node.input_flags & UInt8(OMNI_INPUT_PRESS_FILL), UInt8(OMNI_INPUT_PRESS_FILL))
        XCTAssertGreaterThan(node.press_motion, 0)
        XCTAssertEqual(node.press_motion_curve, UInt8(OMNI_CURVE_CUSTOM))
        XCTAssertNotEqual(node.press_motion_curve_ref, 0)
        XCTAssertEqual(node.hover_delay, 0.2, accuracy: 0.0001)
        XCTAssertEqual(node.hover_grace, 0.15, accuracy: 0.0001)
        XCTAssertEqual(node.gesture_axis, 2)
        XCTAssertEqual(node.gesture_source, 2)
        XCTAssertEqual(node.gesture_direction, 3)
        XCTAssertEqual(node.gesture_threshold, 6)
        XCTAssertEqual(node.gesture_lock_distance, 2)
        XCTAssertEqual(node.gesture_dominance, 1.5)
        XCTAssertEqual(node.gesture_commit_distance, 40)
        XCTAssertEqual(node.gesture_commit_velocity, 250)
        XCTAssertEqual(node.input_flags, 31)
        let strings = ShellTextStore()
        strings.ingest(wire: script.output)
        XCTAssertEqual(strings.string(node.keys), "a\nescape\nreturn")
        for action in [
            node.hover_action,
            node.press_action,
            node.gesture_action,
            node.key_action,
            node.outside_press_action
        ] {
            XCTAssertNotEqual(action & OMNI_ACTION_HANDLER, 0)
        }
    }

    @MainActor
    func testFocusRingDefaultsOnAndUsesOnlyTheSpareNodeOption() throws {
        for (property, expected) in [("", true), ("focusRing=true,", true), ("focusRing=false,", false)] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx)
                return ui.box{\(property) w=40,h=20,focusable=true,keys={'left'},onKey=function() end}
            end
            """)
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            let node = try first(script)
            XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 392)
            XCTAssertEqual(node.input_flags, UInt8(OMNI_INPUT_FOCUSABLE))
            XCTAssertEqual(node.options, expected ? 0 : UInt8(OMNI_NODE_OPTION_NO_FOCUS_RING))
            XCTAssertEqual(node.texture_ref, 0)
            let text = ShellTextStore()
            text.ingest(wire: script.output)
            let layout = ShellWidgetLayout()
            XCTAssertTrue(layout.apply(script.output, text: text))
            let content = layout.core.content(of: layout.core.rootHandle)
            XCTAssertEqual(content.focusRing, expected)
            XCTAssertTrue(content.focusable)
            XCTAssertNotEqual(content.keyAction, 0)
        }
    }

    func testZeroPressScaleIsDistinguishedFromAnAbsentScale() throws {
        for specified in [false, true] {
            let properties = specified ? "pressScale = 0" : ""
            let script = try ShellScriptHostTests.Script("function render(ctx) return ui.box{ \(properties) } end")
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            let node = try first(script)
            XCTAssertEqual(node.press_scale, 0)
            XCTAssertEqual(
                node.input_flags & UInt8(OMNI_INPUT_PRESS_SCALE),
                specified ? UInt8(OMNI_INPUT_PRESS_SCALE) : 0
            )
        }
    }

    func testGestureDefaultsDoNotRequestChangedEventsOrImplicitCommit() throws {
        let script = try ShellScriptHostTests.Script("function render(ctx) return ui.box{ gesture = {} } end")
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let node = try first(script)
        XCTAssertEqual(node.gesture_axis, 4)
        XCTAssertEqual(node.gesture_source, 0)
        XCTAssertEqual(node.gesture_threshold, 4)
        XCTAssertEqual(node.gesture_lock_distance, 1)
        XCTAssertEqual(node.gesture_dominance, 1.25)
        XCTAssertEqual(node.gesture_commit_distance, 0)
        XCTAssertEqual(node.gesture_commit_velocity, 0)
        XCTAssertEqual(node.input_flags, 0)
        XCTAssertEqual(node.press_scale, 0)
        XCTAssertEqual(node.press_opacity, -1)
        XCTAssertEqual(node.hover_delay, 0)
        XCTAssertEqual(node.hover_grace, 0)
    }

    func testMalformedInputConfigurationIsRejectedExplicitly() throws {
        for properties in [
            "onHover = 'media toggle'", "onPress = 1", "onGesture = true", "onKey = {}",
            "onOutsidePress = 'shell menu'", "hoverDelay = -1", "hoverGrace = 61", "pressScale = 0/0",
            "pressOpacity = 2", "focusRing = 0", "focusRing = 'false'", "focusRing = {}",
            "gesture = true", "gesture = { axis = 'diagonal' }", "gesture = { source = 'wheel' }",
            "gesture = { threshold = -1 }", "gesture = { dominance = 0.5 }",
            "gesture = { commit = { velocity = math.huge } }",
            "gesture = { commit = { direction = 'inward' } }", "gestureEvents = 'everywhere'",
            "scrollMomentum = 'ignore'", "keys = true", "keys = { [2] = 'escape' }",
            "keys = { 'escape\\nreturn' }", "keys = { string.rep('a', 33) }"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return ui.box{ \(properties) } end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, properties)
            XCTAssertFalse(script.message.isEmpty)
        }
    }

    func testInputHandlersReceiveThePublishedContextAndEvent() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.box{ onPress = function(next, event)
                assert(next == ctx)
                assert(event.phase == "down" and event.x == 7 and event.y == 9)
                next.state.received = true
            end, onHover = function(next)
                assert(next.state.received)
            end }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let node = try first(script)
        var event = ShellValueWriter()
        event.map(3)
        event.key("phase")
        event.string("down")
        event.key("x")
        event.number(7)
        event.key("y")
        event.number(9)
        XCTAssertEqual(script.invoke(node.press_action, event: event.bytes), OMNI_OK, script.message)
        XCTAssertEqual(script.invoke(node.hover_action), OMNI_OK, script.message)
    }

    private func first(_ script: ShellScriptHostTests.Script) throws -> omni_wire_node {
        let output = script.output
        guard output.count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride else {
            XCTFail("Rendered output has no complete node")
            throw NSError(domain: "ShellInputWireTests", code: 1)
        }
        return output.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self)
        }
    }
}
