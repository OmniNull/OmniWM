// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellManipulationWireTests: XCTestCase {
    private let sizes = "bounds={x=0,y=0,w=800,h=600},min={w=80,h=60},max={w=700,h=500}"

    func testMoveRecipePreservesExactAncestorKeyAndIndependentCoordinates() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{key='widget',w=800,h=600,ui.box{gesture={axis='free',track={
                mode='move',target='widget',bounds={x=-12,y=4,w=800,h=600},
                min={w=80,h=60},max={w=700,h=500}}}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (nodes, strings) = try decoded(script)
        XCTAssertEqual(nodes.count, 2)
        let target = try XCTUnwrap(nodes.first)
        let source = try XCTUnwrap(nodes.last)
        XCTAssertGreaterThan(target.key, 1 << 24)
        XCTAssertEqual(
            strings.string(source.gesture_track),
            "manip:move:\(target.key):-12:4:800:600:80:60:700:500:0:0:0"
        )
        XCTAssertEqual(source.gesture_axis, 3)
        XCTAssertEqual(source.gesture_source, 0)
        XCTAssertEqual(source.gesture_commit_distance, 0)
        XCTAssertEqual(source.input_flags & UInt8(OMNI_INPUT_GESTURE_ALL), 0)
    }

    func testAllResizeAnchorsUseTheSameBoundedRecipeAndDefaults() throws {
        for (edge, mask) in [("w", 1), ("e", 2), ("n", 4), ("s", 8), ("nw", 5), ("ne", 6), ("sw", 9), ("se", 10)] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx)
                return ui.stack{key=7,ui.box{gesture={track={mode='resize',target=7,edge='\(edge)',\(sizes)}}}}
            end
            """)
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            let (nodes, strings) = try decoded(script)
            let target = try XCTUnwrap(nodes.first)
            let source = try XCTUnwrap(nodes.last)
            XCTAssertEqual(
                strings.string(source.gesture_track),
                "manip:resize:\(target.key):0:0:800:600:80:60:700:500:\(mask):0:0"
            )
            XCTAssertEqual(source.gesture_axis, 3)
        }
    }

    func testManipulationRejectsInvalidBoundsModesAndReferences() throws {
        for fields in [
            "mode='unknown',target='widget',\(sizes)",
            "mode='move',target='',\(sizes)",
            "mode='move',target={},\(sizes)",
            "mode='move',target=0/0,\(sizes)",
            "mode='move',target=1.5,\(sizes)",
            "mode='move',target='missing',\(sizes)",
            "mode='move',target='widget',bounds={w=0,h=600},min={w=1,h=1},max={w=1,h=1}",
            "mode='move',target='widget',bounds={x=math.huge,w=800,h=600},min={w=1,h=1},max={w=1,h=1}",
            "mode='move',target='widget',bounds={w=800,h=600},min={w=90,h=60},max={w=80,h=500}",
            "mode='move',target='widget',bounds={w=800,h=600},min={w=1,h=1},max={w=801,h=500}",
            "mode='move',target='widget',\(sizes),edge='nw'",
            "mode='resize',target='widget',\(sizes)",
            "mode='resize',target='widget',\(sizes),edge='ns'"
        ] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx) return ui.stack{key='widget',ui.box{gesture={track={\(fields)}}}} end
            """)
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, fields)
            XCTAssertFalse(script.message.isEmpty)
        }
        for gesture in ["axis='x',", "source='scroll',", "source='both',"] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx)
                return ui.stack{key='widget',ui.box{gesture={\(gesture)track={mode='move',target='widget',\(sizes)}}}}
            end
            """)
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, gesture)
        }
        let selfTarget = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.box{key='self',gesture={track={mode='move',target='self',\(sizes)}}}
        end
        """)
        XCTAssertEqual(selfTarget.render().status, OMNI_ERR_RUNTIME)
    }

    @MainActor
    func testMetadataDecodesAndDecorativeStatusIsInherited() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{key='widget',material='regular',manipulationCommit='tx:00000000000000000001',
                ui.stack{effect={source='wave.metal',values={-1,0.25,2,4},fps=48,bleed=12},
                    ui.box{decorative=true,ui.text{text='ornament'}}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (nodes, strings) = try decoded(script)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 448)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.manipulation_commit), 392)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.effect_ref), 396)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.behavior_flags), 400)
        XCTAssertEqual(strings.string(nodes[0].manipulation_commit), "tx:00000000000000000001")
        XCTAssertEqual(strings.string(nodes[1].effect_ref), "effect:48:12:-1:0.25:2:4:wave.metal")
        XCTAssertEqual(nodes.map(\.behavior_flags), [0, 0, 1, 1])
        let layout = ShellWidgetLayout()
        XCTAssertTrue(layout.apply(script.output, text: strings))
        XCTAssertEqual(layout.core.content(of: layout.core.rootHandle).manipulationCommit, nodes[0].manipulation_commit)
        let effected = layout.core.elements { $0.effect != 0 }
        XCTAssertEqual(effected.count, 1)
        XCTAssertEqual(layout.core.content(of: try XCTUnwrap(effected.first)).effect, nodes[1].effect_ref)
        XCTAssertEqual(layout.core.elements { $0.decorative }.count, 2)
        XCTAssertTrue(layout.core.elements { $0.decorative && $0.acceptsPointer }.isEmpty)
    }

    func testRejectedPublicationKeepsPriorOutputAndHandlersUsable() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{key='widget',onClick=function(next) next.state.invalid=not next.state.invalid end,
                ui.box{decorative=ctx.state.invalid,ui.box{onClick=function() end}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let accepted = script.output
        let (nodes, _) = try decoded(script)
        let action = try XCTUnwrap(nodes.first).action
        XCTAssertEqual(script.invoke(action), OMNI_OK, script.message)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertEqual(script.output, accepted)
        XCTAssertEqual(script.invoke(action), OMNI_OK, script.message)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertEqual(try decoded(script).0.count, 3)
    }

    func testEffectsPreserveAssetReferencesAndAllowMaterialsOutsideTheGroup() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{material='regular',ui.stack{effect={source='@omni-asset:clock/shaders/wave.metal'}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (nodes, strings) = try decoded(script)
        XCTAssertEqual(strings.string(nodes[1].effect_ref), "effect:30:0:0:0:0:0:@omni-asset:clock/shaders/wave.metal")
    }

    func testPresentationMetadataRejectsUnsupportedOrInteractiveTrees() throws {
        for tree in [
            "ui.stack{manipulationCommit='tx'}",
            "ui.stack{key='x',manipulationCommit=1}",
            "ui.stack{key='x',manipulationCommit=''}",
            "ui.stack{key='x',manipulationCommit=string.rep('x',97)}",
            "ui.box{decorative=1}",
            "ui.stack{decorative=true,ui.box{onClick=function() end}}",
            "ui.stack{decorative=true,ui.input{key='input'}}",
            "ui.stack{decorative=true,ui.slider{value=0.5}}",
            "ui.box{decorative=true,hoverScale=1.1}",
            "ui.box{effect={source='wave.metal'}}",
            "ui.row{effect={source='wave.metal'}}",
            "ui.stack{mask=true,effect={source='wave.metal'}}",
            "ui.stack{material='regular',effect={source='wave.metal'}}",
            "ui.stack{effect={source='wave.metal'},ui.box{material='regular'}}",
            "ui.stack{effect={source='wave.metal'},ui.stack{effect={source='pixel.metal'}}}",
            "ui.stack{effect={source='../wave.metal'}}",
            "ui.stack{effect={source=''}}",
            "ui.stack{effect={source='wave.metal',fps=30.00000001}}",
            "ui.stack{effect={source='wave.metal',fps=121}}",
            "ui.stack{effect={source='wave.metal',bleed=129}}",
            "ui.stack{effect={source='wave.metal',values={math.huge}}}",
            "ui.stack{effect={source='wave.metal',values={1,2,3,4,5}}}",
            "ui.stack{effect={source='wave.metal',values={[2]=1}}}"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return \(tree) end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, tree)
            XCTAssertFalse(script.message.isEmpty)
        }
    }

    func testScaleCornersAndContentInsetRoundTripTogether() throws {
        for (edge, mask) in [("nw", 5), ("ne", 6), ("sw", 9), ("se", 10)] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx)
                return ui.stack{key='widget',ui.box{gesture={axis='free',track={
                    mode='scale',target='widget',edge='\(edge)',inset={x=6.5/353,y=0},\(sizes)}}}}
            end
            """)
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            let (nodes, strings) = try decoded(script)
            let source = try XCTUnwrap(nodes.last)
            let wire = strings.string(source.gesture_track)
            XCTAssertEqual(wire.split(separator: ":").count, 14)
            let recipe = try XCTUnwrap(ShellManipulationRecipe(wire))
            XCTAssertEqual(recipe.mode, .scale)
            XCTAssertEqual(recipe.resizeMask, UInt8(mask))
            XCTAssertEqual(recipe.target, nodes[0].key)
            XCTAssertEqual(recipe.inset.width, 6.5 / 353, accuracy: 0.000001)
            XCTAssertEqual(recipe.inset.height, 0)
            XCTAssertEqual(source.input_flags & UInt8(OMNI_INPUT_GESTURE_ALL), 0)
        }
    }

    func testScaleAndInsetRejectInvalidContractsAtTheEmitter() throws {
        for fields in [
            "mode='scale',target='widget',edge='n',\(sizes)",
            "mode='scale',target='widget',\(sizes)",
            "mode='resize',target='widget',edge='nw',inset={x=0,y=0},\(sizes)",
            "mode='move',target='widget',inset={x=0.5,y=0},\(sizes)",
            "mode='move',target='widget',inset={x=-0.1,y=0},\(sizes)",
            "mode='move',target='widget',inset={x=0/0,y=0},\(sizes)",
            "mode='move',target='widget',inset={x=0},\(sizes)",
            "mode='move',target='widget',inset={x=0,y=0,z=0},\(sizes)"
        ] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx) return ui.stack{key='widget',ui.box{gesture={track={\(fields)}}}} end
            """)
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, fields)
            XCTAssertFalse(script.message.isEmpty)
        }
    }

    @MainActor
    func testFollowSpringDecodesAsContentAndKeepsExistingOffsets() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx) return ui.stack{key='desk',manipulationFollow={response=0.363,bounce=0.42}} end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (nodes, strings) = try decoded(script)
        let node = try XCTUnwrap(nodes.first)
        XCTAssertEqual(strings.string(node.manipulation_follow), "spring:0.363:0.42")
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.behavior_flags), 400)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.manipulation_follow), 404)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.reveal), 408)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.morph), 412)
        let layout = ShellWidgetLayout()
        XCTAssertTrue(layout.apply(script.output, text: strings))
        XCTAssertEqual(layout.core.content(of: layout.core.rootHandle).manipulationFollow, node.manipulation_follow)
        XCTAssertEqual(layout.core.paint(of: layout.core.rootHandle).reveal, 0)
    }

    func testFollowRequiresOneKeyedInteractiveTargetAndAValidSpring() throws {
        for body in [
            "ui.stack{manipulationFollow={response=0.3}}",
            "ui.stack{key='a',manipulationFollow={response=3}}",
            "ui.stack{key='a',manipulationFollow={response=0.3,bounce=1}}",
            "ui.stack{key='a',manipulationFollow={response=0.3,delay=1}}",
            "ui.stack{key='a',decorative=true,manipulationFollow={response=0.3}}"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return " + body + " end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, body)
            XCTAssertFalse(script.message.isEmpty)
        }
    }

    private func decoded(_ script: ShellScriptHostTests.Script) throws -> ([omni_wire_node], ShellTextStore) {
        let output = script.output
        guard output.count >= MemoryLayout<omni_wire_header>.stride else {
            XCTFail("Rendered output has no header")
            throw NSError(domain: "ShellManipulationWireTests", code: 1)
        }
        let nodes = output.withUnsafeBytes { bytes in
            let header = bytes.loadUnaligned(as: omni_wire_header.self)
            return (0 ..< Int(header.node_count)).map {
                bytes.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                )
            }
        }
        let strings = ShellTextStore()
        strings.ingest(wire: output)
        return (nodes, strings)
    }
}
