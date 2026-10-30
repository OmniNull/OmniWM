// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellBoundTrackWireTests: XCTestCase {
    private func body(
        mode: String = "move", source: String = "", morph: String = "", extraGrip: String = ""
    ) -> String {
        let edge = mode == "move" ? "" : "edge='se',"
        return """
        ui.stack{ui.stack{key='target',w=200,h=100,
            ui.box{gesture={track={mode='\(mode)',\(edge)target='target',
                bounds={w=600,h=400},min={w=50,h=25},max={w=400,h=200}}}},\(extraGrip)},
            ui.glass{ui.shape{key='bound',w=200,h=100,morph={
                stops={{at=0},{at=1}},source={target='target',edge='right',from=20,span=50,\(source)},\(morph)}}}}
        """
    }

    private func reject(_ body: String, containing message: String) throws {
        let script = try ShellScriptHostTests.Script("function render(ctx) return " + body + " end")
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains(message), script.message)
    }

    func testAdhesionRoundTripsEachExtraSidesOwnOriginAndPreservesSourceProgress() throws {
        let result = try ShellP3WireFixture.render(body(
            source: "pads={left=-13,right=13,top=-13,bottom=13},adhere={top=62,left=22,bottom=31}"
        ))
        let shape = try XCTUnwrap(result.nodes.last)
        let raw = result.text.string(shape.morph)
        let recipe = try XCTUnwrap(ShellMorphRecipe(raw))
        let source = try XCTUnwrap(recipe.source)
        XCTAssertEqual(source.edge, .right)
        XCTAssertEqual(source.from, 20)
        XCTAssertEqual(source.span, 50)
        XCTAssertEqual(source.adhere.top, 62)
        XCTAssertEqual(source.adhere.left, 22)
        XCTAssertEqual(source.adhere.bottom, 31)
        XCTAssertNil(source.adhere.right)
        XCTAssertEqual(source.pads?.right, 13)
        XCTAssertEqual(source.pads?.left, -13)
        XCTAssertTrue(raw.contains("|adhere:1:62:1:22:0:0:1:31"), raw)
    }

    func testSourceAndTriggerAreRejectedAsCompetingGeometryOwners() throws {
        try reject(
            body(morph: "trigger={shape='bound',at=0.7}"),
            containing: "source cannot be combined with morph.trigger"
        )
        XCTAssertNil(ShellMorphRecipe(
            "morph:0.5:0.5:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1|source:7:2:20:50:0:0:0:0:0|trigger:8:0.7:1"
        ))
    }

    func testSourceCannotBindResizeTargetsEvenWhenTheyAlsoHaveAMoveGrip() throws {
        try reject(body(mode: "resize"), containing: "source cannot bind a resize target")
        let resize = """
        ui.box{gesture={track={mode='resize',edge='se',target='target',
            bounds={w=600,h=400},min={w=50,h=25},max={w=400,h=200}}}}
        """
        try reject(body(extraGrip: resize), containing: "source cannot bind a resize target")
        for mode in ["move", "scale"] {
            let result = try ShellP3WireFixture.render(body(mode: mode))
            XCTAssertNotEqual(result.nodes.last?.morph, 0)
        }
    }

    func testAdhesionRejectsUnknownSidesNonNumbersAndASecondSourceOrigin() throws {
        for field in [
            "adhere=1",
            "adhere={other=1}",
            "adhere={left='far'}",
            "adhere={top=math.huge}",
            "adhere={right=20}"
        ] {
            try ShellP3WireFixture.reject(body(source: field))
        }
        let base = "morph:0.5:0.5:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1"
        XCTAssertNil(ShellMorphRecipe(base + "|adhere:1:20:0:0:0:0:0:0"))
        XCTAssertNil(ShellMorphRecipe(base + "|source:7:2:20:50:0:0:0:0:0|adhere:0:0:0:0:1:20:0:0"))
        XCTAssertNil(ShellMorphRecipe(base + "|source:7:2:20:50:0:0:0:0:0|adhere:2:0:0:0:0:0:0:0"))
    }

    func testContactRoundTripsAndRejectsPadsAndNonContactTriggerSources() throws {
        let result = try ShellP3WireFixture.render(body(source: "contact=true"))
        let shape = try XCTUnwrap(result.nodes.last)
        XCTAssertEqual(ShellMorphRecipe(result.text.string(shape.morph))?.source?.contact, true)
        try reject(body(source: "contact=true,pads={left=0}"), containing: "contact cannot be combined with pads")
        let base = "morph:0.5:0.5:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1"
        XCTAssertNil(ShellMorphRecipe(base + "|source:7:2:20:50:1:0:0:0:0|sourceContact:1"))
        XCTAssertNil(ShellMorphRecipe(base + "|triggerContact:1"))
        for contact in [false, true] {
            let tree = body(source: "contact=\(contact)")
            let source = tree.dropLast(2) + ",ui.shape{key='pulse',w=10,h=10,morph={trigger={shape='bound',at=0.7,contact=true},stops={{at=0},{at=1}}}}}}"
            if contact {
                let output = try ShellP3WireFixture.render(String(source))
                let pulse = try XCTUnwrap(output.nodes.last)
                XCTAssertEqual(ShellMorphRecipe(output.text.string(pulse.morph))?.trigger?.contact, true)
            } else {
                try reject(
                    String(source),
                    containing: "trigger.contact requires a source shape with morph.source.contact"
                )
            }
        }
    }

    func testPublishedContactTriggerKeepsItsBindingAfterTheSourceLeaves() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            local shapes = {}
            if not ctx.data.hidden then
                shapes[#shapes+1] = ui.shape{key='bound',w=10,h=10,morph={
                    source={target='target',edge='right',span=50,contact=true},stops={{at=0},{at=1}}}}
            end
            shapes[#shapes+1] = ui.shape{key='pulse',w=10,h=10,morph={
                trigger={shape='bound',at=0.7,contact=true},stops={{at=0},{at=1}}}}
            return ui.stack{ui.stack{key='target',w=200,h=100,
                ui.box{gesture={track={mode='move',target='target',bounds={w=600,h=400},
                    min={w=200,h=100},max={w=200,h=100}}}}},ui.glass(shapes)}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        var writer = ShellValueWriter()
        writer.bool(true)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(script.instance, "hidden", $0.baseAddress, $0.count)
        }, OMNI_OK)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
    }
}
