// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellInputPublicationTests: XCTestCase {
    func testTwoComponentInputsRouteEveryCallbackToItsPublishedOwner() throws {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
        defer { _ = omni_vm_destroy(vm) }
        let component = """
        local function handler(ctx, event)
            assert(ctx.instance.id == event.expected)
            ctx.instance.state.count = (ctx.instance.state.count or 0) + 1
        end
        return {views={compact=function(ctx)
            return ui.input{key='input',text=ctx.instance.id..':'..(ctx.instance.state.count or 0),
                onChange=handler,onCommit=handler,onCancel=handler,onFocus=handler}
        end}}
        """
        let path = "profile/widgets/input/component.luau"
        XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
        let root = "function render(ctx) return ui.row{ui.component{id='a'},ui.component{id='b'}} end"
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(
            omni_vm_load(
                vm,
                "@profile/widgets/root/init.luau",
                root,
                root.utf8.count,
                100_000_000,
                &error,
                error.count
            ),
            OMNI_OK
        )
        var config = ShellValueWriter()
        config.array(2)
        for id in ["a", "b"] {
            config.map(4)
            config.key("id")
            config.string(id)
            config.key("widget")
            config.string("input")
            config.key("enabled")
            config.bool(true)
            config.key("options")
            config.map(0)
        }
        XCTAssertEqual(config.bytes.withUnsafeBufferPointer {
            omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
        }, OMNI_OK)
        let display = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(display) }
        var stats = omni_render_stats()
        XCTAssertEqual(omni_instance_render(display, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count), OMNI_OK)
        var length = 0
        let output = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &length))
        let bytes = Array(UnsafeBufferPointer(start: output, count: length))
        let inputs = bytes.withUnsafeBytes { buffer in
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            return (0 ..< Int(header.node_count)).map {
                buffer.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                )
            }.filter { $0.kind == 10 }
        }
        XCTAssertEqual(inputs.count, 2)
        var handles = Set<UInt32>()
        for (index, node) in inputs.enumerated() {
            var event = ShellValueWriter()
            event.map(1)
            event.key("expected")
            event.string(index == 0 ? "a" : "b")
            for action in [node.action, node.input_commit_action, node.input_cancel_action, node.input_focus_action] {
                XCTAssertTrue(handles.insert(action).inserted)
                XCTAssertEqual(event.bytes.withUnsafeBufferPointer {
                    omni_instance_invoke(
                        display,
                        OMNI_VIEW_BAR,
                        action,
                        0,
                        $0.baseAddress,
                        $0.count,
                        100_000_000,
                        &error,
                        error.count
                    )
                }, OMNI_OK, error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
        }
    }
}
