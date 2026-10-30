// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellGlassWireTests: XCTestCase {
    func testConstructorsEncodeOneBoundedBodyRecipeAndShapeVariants() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.glass{key='glass',w=180,h=180,blend=34,light={x=0,y=-1},
                shadowOffset={x=-2,y=7},fill='#3F47685C',shadow='#0B0E113D',shadowRadius=20,
                ui.shape{key='frame',shape='frame',w=200,h=200,dx=-10,dy=-10,radius=40,thickness=10},
                ui.shape{key='rect',w=80,h=60,radius=12},
                ui.shape{key='ellipse',shape='ellipse',w=20,h=12,dx=50}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (nodes, strings) = try decoded(script)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 448)
        XCTAssertEqual(nodes.map(\.kind), [11, 12, 12, 12])
        XCTAssertEqual(nodes.map(\.behavior_flags), [1, 5, 1, 3])
        XCTAssertEqual(nodes.map(\.subtree_end), [4, 2, 3, 4])
        XCTAssertEqual(nodes[0].axis, 2)
        XCTAssertEqual(strings.string(nodes[0].text), "glass:34:0:-1:-2:7")
        XCTAssertEqual(nodes[0].blur_radius, 6)
        XCTAssertEqual(nodes[0].saturation, 1)
        XCTAssertEqual(nodes[0].shadow_radius, 20)
        XCTAssertEqual(nodes[0].fill, 0x3F47_685C)
        XCTAssertEqual(nodes[0].shadow, 0x0B0E_113D)
        XCTAssertEqual(nodes[1].params.0, 10)
        XCTAssertEqual(nodes[1].corner_radius, 40)
        XCTAssertEqual(nodes[1].dx, -10)
        XCTAssertEqual(nodes[3].width, 20)
        XCTAssertEqual(nodes[3].height, 12)
    }

    func testDefaultsPreserveExplicitZeroAndReuseInternedRecipe() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{ui.glass{ui.shape{shape='frame'}},
                ui.glass{blend=0,blurRadius=0,saturation=0,shadowRadius=0,fill='#00000000',shadow='#00000000',
                    light={x=1,y=1},shadowOffset={x=0,y=0},ui.shape{}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (nodes, strings) = try decoded(script)
        XCTAssertEqual(strings.string(nodes[1].text), "glass:26:-1:0:0:1")
        XCTAssertEqual(nodes[1].fill, 0x3F47_685C)
        XCTAssertEqual(nodes[1].shadow, 0x0B0E_1114)
        XCTAssertEqual(nodes[1].shadow_radius, 6)
        XCTAssertEqual(nodes[2].params.0, 8)
        XCTAssertEqual(strings.string(nodes[3].text), "glass:0:1:1:0:0")
        XCTAssertEqual(nodes[3].blur_radius, 0)
        XCTAssertEqual(nodes[3].saturation, 0)
        XCTAssertEqual(nodes[3].shadow_radius, 0)
        XCTAssertEqual(nodes[3].fill, 0)
        XCTAssertEqual(nodes[3].shadow, 0)
        XCTAssertEqual(nodes[3].fill_role, 0)
        XCTAssertEqual(nodes[3].shadow_role, 0)
        let rerender = script.render()
        XCTAssertEqual(rerender.status, OMNI_OK, script.message)
        XCTAssertEqual(rerender.stats.new_strings, 0)
    }

    func testGlassBodyKeepsBasicPresenceAndOpacityWithoutDuplicatingOnShapes() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.glass{opacity=0.75,appear={opacity=0},exit={scale=0.8},
                ui.shape{w=80,h=60,radius=12}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let (nodes, _) = try decoded(script)
        XCTAssertEqual(nodes[0].opacity, 0.75)
        XCTAssertNotEqual(nodes[0].appear, 0)
        XCTAssertNotEqual(nodes[0].exit, 0)
        XCTAssertEqual(nodes[1].opacity, 1)
        XCTAssertEqual(nodes[1].appear, 0)
        XCTAssertEqual(nodes[1].exit, 0)
    }

    func testGlassRejectsInvalidRecipesAndUnboundedNumbers() throws {
        for fields in [
            "decorative=false", "blend=-1", "blend=257", "blend=math.huge", "blend=0/0", "blend='26'",
            "light={x=0,y=0}", "light={x=1.1,y=0}", "light={x=-1}", "light={}",
            "light={x=-1,y=0,z=1}", "light={-1,0}", "light={x=-1,y=0/0}", "light=1",
            "shadowOffset={x=0,y=257}", "shadowOffset={}", "shadowOffset={x=math.huge,y=0}",
            "blurRadius=-1", "blurRadius=65", "saturation=4", "shadowRadius=-1", "shadowRadius=65",
            "text='glass:26:-1:0:0:1'", "source='wave.metal'", "material='regular'",
            "effect={source='wave.metal'}", "onClick=function() end", "border='#FFFFFF'"
        ] {
            let script = try ShellScriptHostTests
                .Script("function render(ctx) return ui.glass{\(fields),ui.shape{}} end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, fields)
            XCTAssertFalse(script.message.isEmpty, fields)
        }
    }

    func testShapesRejectUnsupportedPaintAnimationInputAndGeometry() throws {
        for fields in [
            "decorative=false", "shape='triangle'", "shape=1", "thickness=3", "shape='frame',thickness=0",
            "shape='frame',thickness=257", "shape='frame',thickness=math.huge",
            "w=0/0", "h=-1", "dx=math.huge", "radius=-1",
            "fill='#FFFFFF'", "material='regular'", "opacity=0.5", "blurRadius=3",
            "shadow='#000000'", "animate={response=3}", "appear=true", "rotate=math.huge", "scale=2",
            "onClick=function() end", "gesture={axis='x'}", "effect={source='wave.metal'}",
            "ui.shape{}"
        ] {
            let script = try ShellScriptHostTests
                .Script("function render(ctx) return ui.glass{ui.shape{\(fields)}} end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, fields)
            XCTAssertFalse(script.message.isEmpty, fields)
        }
    }

    func testFrameRejectsRotationWhileRectanglesAndEllipsesKeepIt() throws {
        for rotation in ["0", "30", "-45"] {
            let script = try ShellScriptHostTests.Script("""
            function render(ctx)
                return ui.glass{ui.shape{shape='frame',rotate=\(rotation)}}
            end
            """)
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, rotation)
            XCTAssertTrue(script.message.contains("rotate is not supported on frame shapes"), script.message)
        }
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.glass{ui.shape{rotate=30},ui.shape{shape='ellipse',rotate=-45}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertEqual(try decoded(script).0.map(\.rotate), [0, 30, -45])
    }

    func testExpandedTreeRejectsOrphansNestedContentEffectsAndShapeOverflow() throws {
        for tree in [
            "ui.shape{}", "ui.stack{ui.shape{}}", "ui.glass{ui.box{}}",
            "ui.glass{ui.stack{ui.shape{}}}", "ui.glass{ui.glass{ui.shape{}}}",
            "ui.glass{ui.shape{},ui.shape{shape='frame'}}",
            "ui.glass{ui.shape{shape='frame'},ui.shape{shape='frame'}}",
            "ui.stack{effect={source='wave.metal'},ui.glass{ui.shape{}}}",
            "ui.glass{false,ui.shape{}}", "ui.glass{[2]=ui.shape{}}"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return \(tree) end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, tree)
            XCTAssertFalse(script.message.isEmpty, tree)
        }
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            local props = {}
            for index=1,65 do props[index] = ui.shape{key=tostring(index)} end
            return ui.glass(props)
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("64 shapes"), script.message)
    }

    func testRejectedGlassPublicationPreservesPriorOutputAndHandler() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{onClick=function(next) next.state.invalid=not next.state.invalid end,
                ui.glass{ui.shape{},ctx.state.invalid and ui.box{} or ui.shape{}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let accepted = script.output
        let action = try XCTUnwrap(try decoded(script).0.first).action
        XCTAssertNotEqual(action, 0)
        XCTAssertEqual(script.invoke(action), OMNI_OK, script.message)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertEqual(script.output, accepted)
        XCTAssertEqual(script.invoke(action), OMNI_OK, script.message)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertEqual(try decoded(script).0.map(\.kind), [0, 11, 12, 12])
    }

    func testRejectedFollowBindingKeepsThePublishedTreeAndItsHandler() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{onClick=function(next) next.state.bad=not next.state.bad end,
                ui.glass{ui.shape{follow=if ctx.state.bad then 'missing' else 'target'}},
                ui.stack{key='target',manipulationFollow={response=0.3},
                    ui.box{gesture={track={mode='move',target='target',bounds={w=500,h=400},
                        min={w=100,h=50},max={w=400,h=300}}}}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let accepted = script.output
        let action = try XCTUnwrap(try decoded(script).0.first).action
        XCTAssertEqual(script.invoke(action), OMNI_OK)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertEqual(script.output, accepted)
        XCTAssertEqual(script.invoke(action), OMNI_OK)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertEqual(try decoded(script).0.count, 5)
    }

    private func decoded(_ script: ShellScriptHostTests.Script) throws -> ([omni_wire_node], ShellTextStore) {
        let output = script.output
        guard output.count >= MemoryLayout<omni_wire_header>.stride else {
            XCTFail("Rendered output has no header")
            throw NSError(domain: "ShellGlassWireTests", code: 1)
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
