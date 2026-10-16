// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellMotionWireTests: XCTestCase {
    func testSpringUsesExistingMotionAndCustomCurveSlots() throws {
        for (properties, expected) in [
            ("response = 0.31, bounce = 0.22", "spring:0.31:0.22"),
            ("response = 0.05", "spring:0.05:0"),
            ("response = 2.5, bounce = 0.95", "spring:2.5:0.95")
        ] {
            let script = try ShellScriptHostTests
                .Script("function render(ctx) return ui.box{ animate = { \(properties) } } end")
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            let (node, strings) = try first(script)
            XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 392)
            XCTAssertNotEqual(node.motion, 0)
            XCTAssertEqual(node.motion_curve, UInt8(OMNI_CURVE_CUSTOM))
            XCTAssertEqual(strings.string(node.motion_curve_ref), expected)
        }
    }

    func testLifecycleRecipesCarryIndependentRelativeTargetsAndAnimation() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.box{
                enter = { opacity = 0.2 },
                appear = { opacity = 0, scale = 0.88, dy = -8, animate = { response = 0.31, bounce = 0.22 } },
                exit = { opacity = 0, animate = "none" },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (node, strings) = try first(script)
        XCTAssertEqual(node.enter_opacity, 0.2, accuracy: 0.0001)
        XCTAssertEqual(strings.string(node.appear), "life:0:0.88:0:-8:1:255:spring:0.31:0.22")
        XCTAssertEqual(strings.string(node.exit), "life:0:1:0:0:0:0:")
        let inherited = try ShellScriptHostTests.Script("function render(ctx) return ui.box{ appear = {} } end")
        XCTAssertEqual(inherited.render().status, OMNI_OK, inherited.message)
        let (inheritedNode, inheritedStrings) = try first(inherited)
        XCTAssertEqual(inheritedStrings.string(inheritedNode.appear), "life:1:1:0:0:inherit")
        XCTAssertEqual(inheritedNode.exit, 0)
    }

    func testTrackRecipeHasBoundedChannelsAndDoesNotEnableLuaSamples() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.box{ gesture = { axis = "y", commit = { distance = 50, velocity = 300, direction = "up" },
                track = { dy = { 0, -40, rubber = 0.4 }, scale = { 1, 0.94 }, opacity = { 1, 0.8 } } } }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (node, strings) = try first(script)
        XCTAssertEqual(strings.string(node.gesture_track), "track:14:0:0:0:0:-40:0.4:1:0.94:0:1:0.8:0")
        XCTAssertEqual(node.input_flags & UInt8(OMNI_INPUT_GESTURE_ALL), 0)
        XCTAssertEqual(node.gesture_action, 0)
    }

    func testMaskMotionRequiresAnEnclosingVisibleContainer() throws {
        for recipe in ["appear = {}", "exit = {}", "gesture = { commit = {distance=50}, track = {dy={0,-40}} }"] {
            for properties in ["mask = true, \(recipe)", "\(recipe), mask = true"] {
                let script = try ShellScriptHostTests.Script("function render(ctx) return ui.box{ \(properties) } end")
                XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, properties)
                XCTAssertTrue(script.message.contains("enclosing visible container"), script.message)
            }
        }
        let enclosing = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.box{w=50,h=20,appear={opacity=0},exit={opacity=0},
                gesture={commit={distance=50},track={dy={0,-40}}},
                ui.box{w=50,h=20,mask=true}}
        end
        """)
        XCTAssertEqual(enclosing.render().status, OMNI_OK, enclosing.message)
    }

    func testMotionRecipesRejectInvalidNumbersAndUndefinedProgress() throws {
        for properties in [
            "animate = { response = 0.049 }", "animate = { response = 2.51 }", "animate = { bounce = 0.2 }",
            "animate = { response = 0.3, bounce = -0.1 }", "animate = { response = 0.3, bounce = 0.96 }",
            "animate = { response = math.huge }", "animate = { response = 0.3, duration = 0.2 }",
            "appear = true", "appear = { opacity = -0.1 }", "exit = { scale = -1 }", "exit = { dx = 0/0 }",
            "gesture = { track = { dy = {0,-40} } }",
            "gesture = { commit = {distance=0}, track = {dy={0,-40}} }",
            "gesture = { commit = {distance=50}, track = {} }",
            "gesture = { commit = {distance=50}, track = {dy={0}} }",
            "gesture = { commit = {distance=50}, track = {dy={0,-40,rubber=1.1}} }",
            "gesture = { commit = {distance=50}, track = {opacity={1,2}} }",
            "mask = true, gesture = { commit = {distance=50}, track = {dy={0,-40}} }"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return ui.box{ \(properties) } end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, properties)
            XCTAssertFalse(script.message.isEmpty)
        }
    }

    private func first(_ script: ShellScriptHostTests.Script) throws -> (omni_wire_node, ShellTextStore) {
        let output = script.output
        guard output.count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride else {
            XCTFail("Rendered output has no complete node")
            throw NSError(domain: "ShellMotionWireTests", code: 1)
        }
        let node = output.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self)
        }
        let strings = ShellTextStore()
        strings.ingest(wire: output)
        return (node, strings)
    }
}
