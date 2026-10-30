// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellRevealComponentWireTests: XCTestCase {
    private final class Fixture {
        let vm: OpaquePointer
        let instance: OpaquePointer
        var error = [CChar](repeating: 0, count: 512)

        init(_ root: String) throws {
            let created = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            let path = "profile/widgets/shape/component.luau"
            let component = """
            return {views={compact=function(ctx)
                return ui.shape{w=200,h=100,morph={stops={{at=0,scale=0.05},{at=1}}}}
            end}}
            """
            XCTAssertEqual(omni_vm_add_module(created, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
            var errors = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(omni_vm_load(
                created, "@profile/widgets/root/init.luau", root, root.utf8.count,
                100_000_000, &errors, errors.count
            ), OMNI_OK, errors.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            var writer = ShellValueWriter()
            writer.array(1)
            writer.map(4)
            writer.key("id")
            writer.string("shape")
            writer.key("widget")
            writer.string("shape")
            writer.key("enabled")
            writer.bool(true)
            writer.key("options")
            writer.map(0)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(created, $0.baseAddress, $0.count, 100_000_000, &errors, errors.count)
            }, OMNI_OK, errors.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            instance = try XCTUnwrap(omni_instance_create(created))
            vm = created
        }

        deinit {
            omni_instance_destroy(instance)
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        var output: [UInt8] {
            var length = 0
            guard let bytes = omni_instance_output(instance, OMNI_VIEW_BAR, &length) else { return [] }
            return Array(UnsafeBufferPointer(start: bytes, count: length))
        }

        func nodes() -> [omni_wire_node] {
            output.withUnsafeBytes { buffer in
                let headerSize = MemoryLayout<omni_wire_header>.stride
                let nodeSize = MemoryLayout<omni_wire_node>.stride
                guard buffer.count >= headerSize else { return [] }
                let count = Int(buffer.loadUnaligned(as: omni_wire_header.self).node_count)
                guard count <= (buffer.count - headerSize) / nodeSize else { return [] }
                return (0 ..< count).map {
                    buffer.loadUnaligned(fromByteOffset: headerSize + $0 * nodeSize, as: omni_wire_node.self)
                }
            }
        }

        func mode(_ value: Double) {
            XCTAssertEqual(omni_instance_set_number(instance, ShellDataKey.cpu.rawValue, value), OMNI_OK)
        }

        func update(_ changed: UInt64 = .max) -> (status: omni_status, steps: [omni_render_step_stats]) {
            let begun = omni_instance_begin_update(instance, OMNI_VIEW_BAR, changed, true)
            guard begun == OMNI_OK else { return (begun, []) }
            var steps: [omni_render_step_stats] = []
            for _ in 0 ..< 160 {
                var step = omni_render_step_stats()
                let status = omni_instance_step_update(
                    instance, OMNI_VIEW_BAR, 100_000_000, &step, &error, error.count
                )
                steps.append(step)
                if status != OMNI_OK || step.done { return (status, steps) }
            }
            XCTFail("retained reveal update did not reach its completion state")
            return (OMNI_ERR_RUNTIME, steps)
        }
    }

    private func assertMorphingShape(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let shape = try XCTUnwrap(fixture.nodes().first { $0.kind == 12 }, file: file, line: line)
        XCTAssertNotEqual(shape.morph, 0, file: file, line: line)
    }

    func testInheritedMountPresenceRejectsMorphingShapeAndPreservesPublication() throws {
        for presence in ["appear", "exit"] {
            let fixture = try Fixture("""
            function render(ctx)
                local component=ui.component{id='shape'}
                local mount=rawget(component,1)
                if ctx.data.cpu>0 then rawset(mount,'\(presence)',{}) end
                return ui.stack{reveal={response=0.3},ui.glass{w=200,h=100,mount}}
            end
            """)
            fixture.mode(0)
            let initial = fixture.update()
            XCTAssertEqual(initial.status, OMNI_OK, fixture.message)
            XCTAssertEqual(initial.steps.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
            try assertMorphingShape(fixture)
            let accepted = fixture.output
            XCTAssertFalse(accepted.isEmpty)
            fixture.mode(1)
            let rejected = fixture.update(ShellDataKey.cpu.bit)
            XCTAssertEqual(rejected.status, OMNI_ERR_RUNTIME, presence)
            XCTAssertTrue(fixture.message.contains("morph cannot be combined with appear or exit"), fixture.message)
            XCTAssertFalse(rejected.steps.contains { $0.kind == OMNI_RENDER_COMPONENT_VIEW })
            XCTAssertEqual(fixture.output, accepted)
        }
    }

    func testCachedMorphingShapeRejectsRemovalOfItsRevealAncestor() throws {
        let fixture = try Fixture("""
        function render(ctx)
            local component=ui.component{id='shape'}
            local mount=rawget(component,1)
            return ui.stack{reveal=if ctx.data.cpu==0 then {response=0.3} else nil,
                ui.glass{w=200,h=100,mount}}
        end
        """)
        fixture.mode(0)
        let initial = fixture.update()
        XCTAssertEqual(initial.status, OMNI_OK, fixture.message)
        XCTAssertEqual(initial.steps.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
        try assertMorphingShape(fixture)
        let accepted = fixture.output
        XCTAssertFalse(accepted.isEmpty)
        fixture.mode(1)
        let rejected = fixture.update(ShellDataKey.cpu.bit)
        XCTAssertEqual(rejected.status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(fixture.message.contains("morph requires a reveal ancestor"), fixture.message)
        XCTAssertFalse(rejected.steps.contains { $0.kind == OMNI_RENDER_COMPONENT_VIEW })
        XCTAssertEqual(fixture.output, accepted)
    }

    func testMotionPropertiesOnTaggedMountRequireTheRenderedRoot() throws {
        for (property, value) in [
            ("manipulationFollow", "{response=0.3}"),
            ("reveal", "{response=0.3}"),
            ("morph", "{stops={{at=0},{at=1}}}")
        ] {
            let fixture = try Fixture("""
            function render(ctx)
                local component=ui.component{id='shape'}
                local mount=rawget(component,1)
                if ctx.data.cpu>0 then rawset(mount,'\(property)',\(value)) end
                return ui.stack{reveal={response=0.3},ui.glass{w=200,h=100,mount}}
            end
            """)
            fixture.mode(0)
            let initial = fixture.update()
            XCTAssertEqual(initial.status, OMNI_OK, fixture.message)
            try assertMorphingShape(fixture)
            let accepted = fixture.output
            fixture.mode(1)
            let rejected = fixture.update(ShellDataKey.cpu.bit)
            XCTAssertEqual(rejected.status, OMNI_ERR_RUNTIME, property)
            let diagnostic = "\(property) must be declared on the component's rendered root"
            XCTAssertTrue(fixture.message.contains(diagnostic), fixture.message)
            XCTAssertEqual(fixture.output, accepted)
        }
    }
}
