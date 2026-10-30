// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

enum ShellP3WireFixture {
    struct Encoded {
        let wire: [UInt8]
        let nodes: [omni_wire_node]
        let text: ShellTextStore
        let tree: [TreeNode]
    }

    static func render(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws -> Encoded {
        let script = try ShellScriptHostTests.Script("function render(ctx) return " + body + " end")
        XCTAssertEqual(script.render(budget: 100_000_000).status, OMNI_OK, script.message, file: file, line: line)
        let wire = script.output
        guard wire.count >= MemoryLayout<omni_wire_header>.stride else {
            throw NSError(domain: "ShellP3WireFixture", code: 1)
        }
        let nodes = wire.withUnsafeBytes { bytes in
            let header = bytes.loadUnaligned(as: omni_wire_header.self)
            return (0 ..< Int(header.node_count)).map {
                bytes.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                )
            }
        }
        let host = ShellScriptHostTests()
        return Encoded(wire: wire, nodes: nodes, text: host.strings(wire), tree: host.decode(wire, capacity: 128))
    }

    static func reject(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let script = try ShellScriptHostTests.Script("function render(ctx) return " + body + " end")
        XCTAssertEqual(script.render(budget: 100_000_000).status, OMNI_ERR_RUNTIME, body, file: file, line: line)
        XCTAssertFalse(script.message.isEmpty, body, file: file, line: line)
    }
}

@MainActor
final class ShellP3WireTests: XCTestCase {
    func testExtendedWireOffsetsAndGlassGradientDecodeWithoutChangingEarlierOffsets() throws {
        let result = try ShellP3WireFixture.render("""
        ui.glass{key='body',backdrop=false,rim=0.55,gradient={from='#FF0000',to='accent',angle=0},
            shadowOffset={x=-2,y=7},ui.shape{key='shape',w=40,h=30}}
        """)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 448)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.behavior_flags), 400)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.shape_follow), 416)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.pulse), 424)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.gradient_from), 428)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.offset(of: \.shadow_offset_x), 440)
        let body = try XCTUnwrap(result.nodes.first)
        let paint = try XCTUnwrap(result.tree.first).paint
        XCTAssertTrue(result.text.string(body.text).contains("|optics:0.55:1:0"))
        XCTAssertEqual(body.gradient_from, 0xFF00_00FF)
        XCTAssertNotEqual(body.gradient_to_role, 0)
        XCTAssertTrue(paint.gradientSpecified)
        XCTAssertEqual(paint.gradientFrom, Color(packed: body.gradient_from, role: body.gradient_from_role))
        XCTAssertEqual(paint.gradientTo, Color(packed: body.gradient_to, role: body.gradient_to_role))
        XCTAssertEqual(paint.shadowOffsetX, -2)
        XCTAssertEqual(paint.shadowOffsetY, 7)
    }

    func testFollowShapeAnimationRevealAndFixedRadiusResolveALaterTarget() throws {
        let result = try ShellP3WireFixture.render("""
        ui.stack{ui.glass{ui.shape{key='shape',follow='target',followRadius='fixed',hit=false,
            animate={response=0.3,bounce=0.2},rotate=30,reveal={response=0.4,bounce=0.2,delay=0.1,hold=0.2,exit=false},
            morph={stops={{at=0,dx=-12,dy=4},{at=1}}}}},
            ui.stack{key='target',w=200,h=100,manipulationFollow={response=0.363,bounce=0.42},
                ui.box{gesture={track={mode='move',target='target',bounds={w=500,h=400},
                    min={w=100,h=50},max={w=400,h=300}}}}}}
        """)
        let shape = result.nodes[2]
        let target = try XCTUnwrap(result.nodes.first { $0.manipulation_follow != 0 })
        XCTAssertEqual(shape.shape_follow, target.key)
        XCTAssertEqual(shape.rotate, 30)
        XCTAssertNotEqual(shape.motion, 0)
        XCTAssertTrue(result.text.string(shape.reveal).contains("|shape:0.1:0.2:0"))
        XCTAssertTrue(result.text.string(shape.morph).contains("|offsets:-12,4,1;0,0,1"))
        XCTAssertEqual(result.tree[2].content.glassFollow, target.key)
        XCTAssertFalse(result.tree[2].content.glassHit)
        XCTAssertTrue(result.tree[2].content.glassFollowFixedRadius)
        XCTAssertNotEqual(result.tree[2].paint.reveal, 0)
    }

    func testFrameEllipseAndExtendedMorphReferencesSurviveTheFinalTree() throws {
        let result = try ShellP3WireFixture.render("""
        ui.stack{ui.glass{
            ui.shape{key='frame',shape='frame',w=500,h=400,thickness=12,reveal={response=0.4},
                morph={stops={{at=0,thickness=0.5},{at=1}},
                    impulses={{after=0.25,spring={response=0.3},velocity=-200,w=1,h=-0.5,pivot='centre'},
                              {at=0.7,rising=false,spring={response=0.4,bounce=0.2},velocity=80}},
                    source={target='target',edge='right',from=14,span=50,pads={left=2,bottom=-3}}}},
            ui.shape{key='orb',shape='ellipse',reveal={response=0.4},
                morph={stops={{at=0,w=0.5,dx=2},{at=1,h=1.5}},
                    trigger={shape='frame',at=0.8,rising=false}}}},
            ui.stack{key='target',w=200,h=100,manipulationFollow={response=0.363},
                ui.box{gesture={track={mode='move',target='target',bounds={w=500,h=400},
                    min={w=100,h=50},max={w=400,h=300}}}}}}
        """)
        let frame = result.nodes[2]
        let orb = result.nodes[3]
        let target = result.nodes[4]
        let recipe = result.text.string(frame.morph)
        XCTAssertTrue(recipe.contains("|offsets:0,0,0.5;0,0,1"), recipe)
        XCTAssertTrue(recipe.contains("|impulses:1,0.25,1,0.3,0,-200,1,-0.5,1;0,0.7,0,0.4,0.2,80,0,0,0"), recipe)
        XCTAssertTrue(recipe.contains("|source:\(target.key):2:14:50:1:2:0:0:-3"), recipe)
        let orbRecipe = result.text.string(orb.morph)
        XCTAssertTrue(orbRecipe.contains("|trigger:\(frame.key):0.8:0"), orbRecipe)
        XCTAssertFalse(recipe.contains("|trigger:"))
        XCTAssertNotEqual(orb.morph, 0)
        XCTAssertEqual(result.tree.count, result.nodes.count)
    }

    func testEdgeTracksReplaceStopsAndOrdinaryMorphOffsetsAreEncoded() throws {
        let result = try ShellP3WireFixture.render("""
        ui.stack{reveal={response=0.4},ui.glass{ui.shape{key='pill',
            morph={edges={lead={response=0.142},trail={response=0.378},thin=0.18,unit=40}}}},
            ui.text{text='caption',morph={stops={{at=0,dx=-10,dy=6,opacity=0},{at=1}}}}}
        """)
        let shapeRecipe = result.text.string(result.nodes[2].morph)
        XCTAssertTrue(shapeRecipe.contains("|edges:0.142:0:0.378:0:0.18:40"), shapeRecipe)
        XCTAssertTrue(result.text.string(result.nodes[3].morph).contains("|offsets:-10,6,1;0,0,1"))
    }

    func testTwentyFourFollowTargetsAreAcceptedAndATwentyFifthIsRejected() throws {
        func body(_ count: Int) -> String {
            let targets = (1 ... count).map {
                "ui.stack{key='target-\($0)',w=100,h=80,manipulationFollow={response=0.3}}"
            }.joined(separator: ",")
            return "ui.stack{\(targets)}"
        }
        let result = try ShellP3WireFixture.render(body(24))
        XCTAssertEqual(result.nodes.filter { $0.manipulation_follow != 0 }.count, 24)
        try ShellP3WireFixture.reject(body(25))
    }

    func testNewShapeLiteralsAndReferencesRejectBeforePublication() throws {
        for fields in [
            "follow='missing'", "follow='plain'", "follow={}", "follow=string.rep('x',257)",
            "followRadius='other'", "hit=1", "rotate=math.huge",
            "reveal={response=0.3,delay=-1}", "reveal={response=0.3,hold=3}",
            "reveal={response=0.3,exit=1}",
            "morph={stops={{at=0},{at=1}},impulses={{spring={response=0.3}}}}",
            "morph={stops={{at=0},{at=1}},impulses={{at=0.5,after=0.1,spring={response=0.3}}}}",
            "morph={stops={{at=0},{at=1}},impulses={{at=0.5,spring={response=0.3},pivot='other'}}}",
            "morph={stops={{at=0},{at=1}},source={edge='left',span=40}}",
            "morph={stops={{at=0},{at=1}},source={target='missing',edge='left',span=40}}",
            "morph={stops={{at=0},{at=1}},trigger={shape='plain',at=0.5}}",
            "morph={edges={lead={response=0.3},trail={response=0.4},unit=0}}",
            "morph={stops={{at=0},{at=1}},edges={lead={response=0.3},trail={response=0.4},unit=40}}"
        ] {
            let reveal = fields.hasPrefix("reveal=") ? "" : "reveal={response=0.3},"
            try ShellP3WireFixture.reject("""
            ui.stack{ui.glass{ui.shape{\(reveal)\(fields)}},ui.box{key='plain'}}
            """)
        }
        let impulses = Array(repeating: "{at=0.5,spring={response=0.3}}", count: 9).joined(separator: ",")
        try ShellP3WireFixture.reject("""
        ui.glass{ui.shape{reveal={response=0.3},morph={stops={{at=0},{at=1}},impulses={\(impulses)}}}}
        """)
    }

    func testFrameLandingAndTravelImpulsesFitTheEightChannelBudget() throws {
        for count in [5, 8] {
            let impulses = Array(repeating: "{after=0.25,spring={response=0.3},velocity=80,h=1}", count: count)
                .joined(separator: ",")
            let result = try ShellP3WireFixture.render("""
            ui.glass{ui.shape{reveal={response=0.3},morph={stops={{at=0},{at=1}},impulses={\(impulses)}}}}
            """)
            let recipe = try XCTUnwrap(ShellMorphRecipe(result.text.string(result.nodes[1].morph)))
            XCTAssertEqual(recipe.impulses.count, count)
        }
    }

    func testPublishedShapeTriggerSurvivesItsSourceLeavingTheTree() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            local shapes = {}
            if ctx.data.cpu < 1 then
                table.insert(shapes, ui.shape{key='source',reveal={response=0.3}})
            end
            if ctx.data.cpu == 2 then
                table.insert(shapes, ui.shape{key='source'})
                table.insert(shapes, ui.shape{key='source'})
            end
            local target = ctx.data.cpu == 3 and 'missing' or 'source'
            table.insert(shapes, ui.shape{key='crest',reveal={response=0.3},
                morph={stops={{at=0},{at=1}},trigger={shape=target,at=0.5}}})
            return ui.glass(shapes)
        end
        """)
        for value in [0, 1, 1] {
            XCTAssertEqual(omni_instance_set_number(script.instance, "cpu", Double(value)), OMNI_OK)
            XCTAssertEqual(script.render(budget: 100_000_000).status, OMNI_OK, script.message)
        }
        for value in [2, 3] {
            XCTAssertEqual(omni_instance_set_number(script.instance, "cpu", Double(value)), OMNI_OK)
            XCTAssertEqual(script.render(budget: 100_000_000).status, OMNI_ERR_RUNTIME)
            XCTAssertTrue(script.message.contains("morph.trigger"), script.message)
        }
        try ShellP3WireFixture.reject("""
        ui.glass{ui.shape{key='crest',reveal={response=0.3},
            morph={stops={{at=0},{at=1}},trigger={shape='missing',at=0.5}}}}
        """)
        try ShellP3WireFixture.reject("""
        ui.glass{ui.shape{key='crest',reveal={response=0.3},
            morph={stops={{at=0},{at=1}},trigger={shape='crest',at=0.5}}}}
        """)
    }

    func testFlatGlassOutlineAndGroupRevealRejectConflictingProperties() throws {
        for fields in [
            "backdrop=false,blurRadius=0", "backdrop=false,saturation=1", "rim=-0.1", "rim=1.1",
            "gradient={from='#FFFFFF'}", "gradient={from='#FFFFFF',to='#000000',angle=math.huge}"
        ] {
            try ShellP3WireFixture.reject("ui.glass{\(fields),ui.shape{}}")
        }
        try ShellP3WireFixture.reject("ui.stack{reveal={response=0.3,hold=2.1}}")
        try ShellP3WireFixture.reject("ui.box{gesture={track={dx={0,10},outline=false}}}")
        let result = try ShellP3WireFixture.render("""
        ui.stack{key='target',w=400,h=300,ui.box{gesture={track={mode='move',target='target',outline=false,
            bounds={x=0,y=0,w=800,h=600},min={w=40,h=30},max={w=700,h=500}}}}}
        """)
        XCTAssertTrue(result.text.string(result.nodes[1].gesture_track).contains("|outline:0:0:0"))
    }
}
