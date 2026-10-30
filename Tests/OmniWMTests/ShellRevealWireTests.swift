// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellRevealWireTests: XCTestCase {
    private struct Encoded {
        let nodes: [omni_wire_node]
        let text: ShellTextStore
        let wire: [UInt8]
    }

    private func render(_ body: String) throws -> Encoded {
        let script = try ShellScriptHostTests.Script("function render(ctx) return " + body + " end")
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let wire = script.output
        let text = ShellTextStore()
        text.ingest(wire: wire)
        guard wire.count >= MemoryLayout<omni_wire_header>.stride else {
            throw NSError(domain: "ShellRevealWireTests", code: 1)
        }
        let nodes = wire.withUnsafeBytes { buffer -> [omni_wire_node] in
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            return (0 ..< Int(header.node_count)).map {
                buffer.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride
                        + $0 * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                )
            }
        }
        return Encoded(nodes: nodes, text: text, wire: wire)
    }

    private func reject(_ body: String, containing message: String) throws {
        let script = try ShellScriptHostTests.Script("function render(ctx) return " + body + " end")
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, body)
        XCTAssertTrue(script.message.contains(message), script.message)
    }

    func testRevealAndElementMorphDecodeAsPaintReferences() throws {
        let encoded = try render("""
        ui.stack{key='reveal',reveal={response=0.482,bounce=0.31},
            ui.text{key='caption',text='visible',morph={anchor={x=1,y=0.5},
                stops={{at=0,scale=0.05,opacity=0},{at=1}}}}}
        """)
        let root = try XCTUnwrap(encoded.nodes.first)
        let child = try XCTUnwrap(encoded.nodes.last)
        XCTAssertEqual(encoded.text.string(root.reveal), "reveal:0.482:0.31")
        let recipe = try XCTUnwrap(ShellMorphRecipe(encoded.text.string(child.morph)))
        XCTAssertEqual(recipe.anchor, CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(recipe.stops.map(\.scale), [0.05, 1])
        XCTAssertEqual(recipe.stops.map(\.opacity), [0, 1])
        let layout = ShellWidgetLayout()
        XCTAssertTrue(layout.apply(encoded.wire, text: encoded.text))
        XCTAssertEqual(layout.core.paint(of: layout.core.rootHandle).reveal, root.reveal)
        let handle = try XCTUnwrap(layout.core.elements { _ in true }.last)
        XCTAssertEqual(layout.core.paint(of: handle).morph, child.morph)
        XCTAssertEqual(layout.core.paint(of: handle).reveal, 0)
    }

    func testRectShapeMorphCarriesAdditiveStretchAndShapeStops() throws {
        let encoded = try render("""
        ui.stack{reveal={response=0.482},ui.glass{w=200,h=100,
            ui.shape{key='body',w=200,h=100,morph={anchor={x=1,y=0.5},
                stretch={gain=0.07,max=0.5,w=1,h=-0.5},
                stops={{at=-0.5,scale=0,w=0.9,h=0.8,round=0},{at=1.5}}}}}}
        """)
        let shape = try XCTUnwrap(encoded.nodes.last)
        XCTAssertEqual(shape.kind, 12)
        let recipe = try XCTUnwrap(ShellMorphRecipe(encoded.text.string(shape.morph)))
        XCTAssertEqual(recipe.stretch.gain, 0.07)
        XCTAssertEqual(recipe.stretch.max, 0.5)
        XCTAssertEqual(recipe.stretch.width, 1)
        XCTAssertEqual(recipe.stretch.height, -0.5)
        XCTAssertEqual(recipe.stops.map(\.at), [-0.5, 1.5])
        XCTAssertEqual(recipe.stops.first?.round, 0)
        XCTAssertEqual(recipe.stops.last?.width, 1)
        XCTAssertEqual(shape.appear, 0)
        XCTAssertEqual(shape.exit, 0)
    }

    func testMorphKindValidationDoesNotDependOnPropertyIterationOrder() throws {
        for shape in [
            "ui.shape{shape='rect',morph={stops={{at=0},{at=1}}}}",
            "ui.shape{morph={stops={{at=0},{at=1}}},shape='rect'}"
        ] {
            let encoded = try render("ui.stack{reveal={response=0.3},ui.glass{\(shape)}}")
            XCTAssertNotNil(ShellMorphRecipe(encoded.text.string(try XCTUnwrap(encoded.nodes.last).morph)))
        }
        for shape in ["ellipse", "frame"] {
            let encoded = try render(
                "ui.stack{reveal={response=0.3},ui.glass{ui.shape{shape='\(shape)',morph={stops={{at=0},{at=1}}}}}}"
            )
            XCTAssertNotNil(ShellMorphRecipe(encoded.text.string(try XCTUnwrap(encoded.nodes.last).morph)))
        }
    }

    func testMorphRejectsMissingAncestorConflictingPresenceAndWrongStopFields() throws {
        try reject("ui.box{morph={stops={{at=0},{at=1}}}}", containing: "reveal ancestor")
        try reject("ui.stack{reveal={response=0.3},morph={stops={{at=0},{at=1}}}}", containing: "reveal ancestor")
        for presence in ["appear", "exit"] {
            try reject(
                "ui.stack{reveal={response=0.3},ui.box{\(presence)={},morph={stops={{at=0},{at=1}}}}}",
                containing: "cannot be combined"
            )
        }
        try reject(
            "ui.stack{reveal={response=0.3},ui.box{morph={stretch={},stops={{at=0},{at=1}}}}}",
            containing: "stretch"
        )
        try reject(
            "ui.stack{reveal={response=0.3},ui.box{morph={stops={{at=0,w=1},{at=1}}}}}",
            containing: "unsupported field"
        )
        try reject(
            "ui.stack{reveal={response=0.3},ui.glass{ui.shape{morph={stops={{at=0,opacity=0},{at=1}}}}}}",
            containing: "unsupported field"
        )
    }

    func testMorphRejectsUnboundedSparseAndUnorderedStops() throws {
        for stops in [
            "{{at=0}}",
            "{{at=0},{at=0}}",
            "{{at=1},{at=0}}",
            "{{at=-0.6},{at=1}}",
            "{{at=0},{at=1.6}}",
            "{{at=0/0},{at=1}}",
            "{[1]={at=0},[3]={at=1}}",
            "{[1]={at=0},[2]={at=1},extra=true}"
        ] {
            try reject("ui.stack{reveal={response=0.3},ui.box{morph={stops=\(stops)}}}", containing: "morph")
        }
        for field in ["scale", "opacity"] {
            let value = field == "scale" ? "-1" : "2"
            try reject(
                "ui.stack{reveal={response=0.3},ui.box{morph={stops={{at=0,\(field)=\(value)},{at=1}}}}}",
                containing: field
            )
        }
        let stops = (0 ... 16).map { "{at=\(Double($0) / 16)}" }.joined(separator: ",")
        try reject("ui.stack{reveal={response=0.3},ui.box{morph={stops={\(stops)}}}}", containing: "2 to 16")
        try reject(
            "ui.stack{reveal={response=0.3},ui.box{morph={anchor={x=1.1,y=0},stops={{at=0},{at=1}}}}}",
            containing: "anchor"
        )
    }

    func testRevealRequiresAStackAndOnlyTheChosenSpringContract() throws {
        for spring in ["true", "{}", "{response=3}"] {
            try reject("ui.stack{reveal=\(spring)}", containing: "spring")
        }
        try reject("ui.stack{reveal={response=0.3,bounce=1}}", containing: "bounce")
        for spring in ["{response=0.3,exit=true}", "{response=0.3,curve='linear'}"] {
            try reject("ui.stack{reveal=\(spring)}", containing: "unsupported field")
        }
        try reject("ui.stack{reveal={response=0.3,delay=3}}", containing: "delay")
        let timed = try ShellScriptHostTests.Script(
            "function render(ctx) return ui.stack{reveal={response=0.3,delay=0.2,hold=0.1}} end"
        )
        XCTAssertEqual(timed.render().status, OMNI_OK, timed.message)
        try reject("ui.box{reveal={response=0.3}}", containing: "ui.stack")
        try reject("ui.stack{mask=true,reveal={response=0.3}}", containing: "unmasked ui.stack")
    }

    func testRejectedMorphPublicationKeepsThePriorTree() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{key='root',reveal={response=0.3},onClick=function(next) next.state.bad=true end,
                ui.box{morph={stops=if ctx.state.bad then {{at=1},{at=0}} else {{at=0},{at=1}}}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let accepted = script.output
        let action = accepted.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self).action
        }
        XCTAssertNotEqual(action, 0)
        XCTAssertEqual(script.invoke(action), OMNI_OK)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertEqual(script.output, accepted)
    }

    func testImpulsePhaseIsValidatedAndPreservedThroughTheWire() throws {
        let encoded = try render("""
        ui.glass{w=200,h=200,ui.shape{w=80,h=60,reveal={response=.482,bounce=.31},morph={stops={{at=0},{at=1}},impulses={
            {at=.08,rising=false,on='close',spring={response=.3,bounce=.5},velocity=90},
            {at=.97,on='open',spring={response=.3,bounce=.5},velocity=-260},
            {after=.1,spring={response=.3,bounce=.5},velocity=20}}}}}
        """)
        let shape = try XCTUnwrap(encoded.nodes.last)
        let recipe = try XCTUnwrap(ShellMorphRecipe(encoded.text.string(shape.morph)))
        XCTAssertEqual(recipe.impulses.map(\.phase), [.close, .open, .both])
        try reject("""
        ui.glass{ui.shape{reveal={response=.482,bounce=.31},morph={stops={{at=0},{at=1}},impulses={{at=.08,on='sideways',spring={response=.3,bounce=.5}}}}}}
        """, containing: "morph impulse on")
        let impulse = "morph:0.5:0.5:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1|impulses:0,0.08,0,0.3,0.5,90,1,1,1"
        XCTAssertNil(ShellMorphRecipe(impulse + "|impulsePhases:3"))
        XCTAssertNil(ShellMorphRecipe(impulse + "|impulsePhases:1,2"))
    }
}

extension ShellRevealWireTests {
    func testPathTrackResolvesALaterRectShapeThroughTheExistingMorphReference() throws {
        let encoded = try render("""
        ui.stack{ui.stack{ui.box{key='pill'}},ui.path{key='outline',w=200,h=100,d='M 0 0 L 20 10',decorative=true,morph={track='pill'}},
            ui.glass{w=200,h=100,ui.shape{key='pill',w=40,h=20,radius=6,
                morph={edges={lead={response=.142},trail={response=.378},unit=40}}}}}
        """)
        let path = try XCTUnwrap(encoded.nodes.first { $0.kind == 9 })
        let shape = try XCTUnwrap(encoded.nodes.last)
        let recipe = try XCTUnwrap(ShellMorphRecipe(encoded.text.string(path.morph)))
        XCTAssertEqual(recipe.track, shape.key)
        XCTAssertEqual(recipe.stops.map(\.scale), [1, 1])
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 448)
        let prefix = "morph:0.5:0.5:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1|track:"
        XCTAssertNil(ShellMorphRecipe(prefix + "0"))
        XCTAssertNil(ShellMorphRecipe(prefix + "1:2"))
        XCTAssertNil(ShellMorphRecipe(prefix + "1|offsets:0,0,1;0,0,1"))
        XCTAssertNil(ShellMorphRecipe(prefix + "1|track:2"))
    }

    func testPathTrackRejectsAmbiguousMissingOrUnsupportedTargetsAndCompetingRecipes() throws {
        let target = "ui.glass{ui.shape{key='pill',w=40,h=20,radius=6,reveal={response=.3}}}"
        for (path, expected) in [
            ("ui.box{decorative=true,morph={track='pill'}}", "decorative unmasked ui.path"),
            ("ui.path{d='M 0 0',morph={track='pill'}}", "decorative unmasked ui.path"),
            ("ui.path{decorative=true,mask=true,d='M 0 0',morph={track='pill'}}", "decorative unmasked ui.path"),
            ("ui.path{decorative=true,d='M 0 0',morph={track='missing'}}", "unique ui.shape"),
            ("ui.path{decorative=true,d='M 0 0',morph={track='pill',stops={{at=0},{at=1}}}}", "path track morph")
        ] {
            try reject("ui.stack{" + path + "," + target + "}", containing: expected)
        }
        try reject("""
        ui.stack{ui.path{decorative=true,d='M 0 0',morph={track='pill'}},
            ui.glass{ui.shape{key='pill',reveal={response=.3}},ui.shape{key='pill',reveal={response=.3}}}}
        """, containing: "unique ui.shape")
        try reject("""
        ui.stack{ui.path{decorative=true,d='M 0 0',morph={track='pill'}},
            ui.glass{ui.shape{key='pill',shape='ellipse',reveal={response=.3}}}}
        """, containing: "rectangular")
        try reject("""
        ui.stack{ui.path{decorative=true,d='M 0 0',morph={track='pill'}},
            ui.glass{ui.shape{key='pill'}}}
        """, containing: "morph or reveal")
    }
}
