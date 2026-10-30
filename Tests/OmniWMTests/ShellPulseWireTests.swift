// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellPulseWireTests: XCTestCase {
    func testPulseChannelsDecodeOnOrdinaryAndBodyElementsWithShapeShadowOffsetsPreserved() throws {
        let result = try ShellP3WireFixture.render("""
        ui.stack{key='root',pulse={key='arrival',duration=0.4,rotate={0,-12,0},scale={0,0.1,0},dx={0,4,0},dy={0,-6,0}},
            shadowOffset={x=2,y=-3},ui.glass{pulse={key=42,duration=1,dy={0,7,0}},
                ui.shape{shadowOffset={x=-4,y=5}}}}
        """)
        XCTAssertEqual(result.nodes.count, 3)
        for (wire, native) in zip(result.nodes.prefix(2), result.tree.prefix(2)) {
            XCTAssertNotEqual(wire.pulse, 0)
            XCTAssertEqual(native.paint.pulse, wire.pulse)
            XCTAssertTrue(result.text.string(wire.pulse).hasPrefix("pulse:"))
        }
        let rootRecipe = result.text.string(result.nodes[0].pulse)
        XCTAssertTrue(rootRecipe.hasSuffix(":0.4:0,-12,0:0,0.1,0:0,4,0:0,-6,0"), rootRecipe)
        let bodyPulse = try XCTUnwrap(ShellPulseRecipe(result.text.string(result.nodes[1].pulse)))
        XCTAssertEqual(bodyPulse.key, UInt64(42) | (1 << 62))
        XCTAssertEqual(bodyPulse.duration, 1)
        XCTAssertEqual(result.nodes[2].pulse, 0)
        XCTAssertEqual(result.tree[2].paint.pulse, 0)
        XCTAssertEqual(result.tree[0].paint.shadowOffsetX, 2)
        XCTAssertEqual(result.tree[0].paint.shadowOffsetY, -3)
        XCTAssertEqual(result.tree[2].paint.shadowOffsetX, -4)
        XCTAssertEqual(result.tree[2].paint.shadowOffsetY, 5)
    }

    func testSampleBoundsAcceptTwoAnd256AndRejectOneOr257() throws {
        for count in [2, 256] {
            let samples = Array(repeating: "0", count: count).joined(separator: ",")
            let result = try ShellP3WireFixture.render("ui.box{pulse={key='pulse',duration=1,dx={\(samples)}}}")
            let recipe = result.text.string(result.nodes[0].pulse)
            XCTAssertEqual(
                recipe.split(separator: ":", omittingEmptySubsequences: false)[5]
                    .split(separator: ",").count,
                count
            )
        }
        for count in [1, 257] {
            let samples = Array(repeating: "0", count: count).joined(separator: ",")
            try ShellP3WireFixture.reject("ui.box{pulse={key='pulse',duration=1,dx={\(samples)}}}")
        }
    }

    func testPulseRejectsUnknownSparseUnboundedOrMissingFields() throws {
        for pulse in [
            "true", "{}", "{key='x',duration=1}", "{duration=1,dx={0,1}}",
            "{key={},duration=1,dx={0,1}}", "{key=1.5,duration=1,dx={0,1}}",
            "{key='x',duration=0,dx={0,1}}", "{key='x',duration=31,dx={0,1}}",
            "{key='x',duration=math.huge,dx={0,1}}", "{key='x',duration=1,dx={0,math.huge}}",
            "{key='x',duration=1,dx={0,1000001}}", "{key='x',duration=1,dx={0,'1'}}",
            "{key='x',duration=1,dx={[1]=0,[3]=1}}", "{key='x',duration=1,dx={0,1,extra=true}}",
            "{key='x',duration=1,angle={0,1}}"
        ] {
            try ShellP3WireFixture.reject("ui.box{pulse=\(pulse)}")
        }
        for offset in ["{}", "{x=0}", "{x=0,y=257}", "{x=0/0,y=0}", "{x=0,y=0,z=1}"] {
            try ShellP3WireFixture.reject("ui.text{text='offset',shadowOffset=\(offset)}")
        }
    }

    func testEveryPulseChannelMustEndAtZero() throws {
        for channel in ["rotate", "scale", "dx", "dy"] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx)
                return ui.box{pulse={key='pulse',duration=1,\(channel)={0,1}}}
            end
            """)
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, channel)
            XCTAssertTrue(script.message.contains("pulse.\(channel) must end at zero"), script.message)
            _ = try ShellP3WireFixture.render("ui.box{pulse={key='pulse',duration=1,\(channel)={2,-1,0}}}")
        }
    }

    func testShapesRejectPulseInsteadOfAcceptingAnInvisibleAnimation() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.glass{ui.shape{pulse={key='shape',duration=1,dx={0,10,0}}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("pulse is not supported on ui.shape"), script.message)
    }

    func testRotationSamplesNeedIntermediateAnglesToPreserveTheirDirection() throws {
        for samples in ["0,360,0", "0,180,0", "0,-180,0", "0,179,-1,0"] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx)
                return ui.box{pulse={key='pulse',duration=1,rotate={\(samples)}}}
            end
            """)
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, samples)
            XCTAssertTrue(
                script.message.contains("adjacent pulse.rotate samples must differ by less than 180 degrees"),
                script.message
            )
        }
        _ = try ShellP3WireFixture.render("ui.box{pulse={key='pulse',duration=1,rotate={0,90,179,0}}}")
    }

    func testStablePulseRecipesAreInternedAndRejectedPublicationPreservesTheAcceptedTree() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.box{key='root',onClick=function(next) next.state.bad=not next.state.bad end,
                pulse={key='once',duration=0.4,rotate=if ctx.state.bad then {0} else {0,-12,0}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let accepted = script.output
        let action = accepted.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self).action
        }
        let rerender = script.render()
        XCTAssertEqual(rerender.status, OMNI_OK, script.message)
        XCTAssertEqual(rerender.stats.new_strings, 0)
        XCTAssertEqual(script.invoke(action), OMNI_OK, script.message)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertEqual(script.output, accepted)
        XCTAssertEqual(script.invoke(action), OMNI_OK, script.message)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
    }
}
