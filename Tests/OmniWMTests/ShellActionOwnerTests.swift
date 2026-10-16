// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellActionOwnerTests: XCTestCase {
    func testPublishedActionOwnerMatchesInvocationAndRejectsRetirement() throws {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
        defer { _ = omni_vm_destroy(vm) }
        let component = """
        return {views={compact=function(ctx)
            return ui.text{text=ctx.instance.id,onClick=function(next,event)
                assert(next.instance.id==event.expected)
            end}
        end}}
        """
        let path = "profile/widgets/child/component.luau"
        XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
        let root = "function render(ctx) return ui.row{onClick=function() end,ui.component{id='a'},ui.component{id='b'}} end"
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
        var writer = ShellValueWriter()
        writer.array(2)
        for id in ["a", "b"] {
            writer.map(4)
            writer.key("id")
            writer.string(id)
            writer.key("widget")
            writer.string("child")
            writer.key("enabled")
            writer.bool(true)
            writer.key("options")
            writer.map(0)
        }
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
        }, OMNI_OK)
        let display = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(display) }
        var stats = omni_render_stats()
        XCTAssertEqual(omni_instance_render(display, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count), OMNI_OK)
        var length = 0
        let pointer = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &length))
        let bytes = Array(UnsafeBufferPointer(start: pointer, count: length))
        let actions = bytes.withUnsafeBytes { buffer in
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            return (0 ..< Int(header.node_count)).map {
                buffer.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                ).action
            }.filter { $0 != 0 }
        }
        XCTAssertEqual(actions.count, 3)
        var rootOwner = omni_owner_token()
        XCTAssertTrue(omni_instance_action_owner(display, OMNI_VIEW_BAR, actions[0], &rootOwner))
        XCTAssertEqual(rootOwner.owner, 0)
        for (index, id) in ["a", "b"].enumerated() {
            var expected = omni_owner_token()
            var actual = omni_owner_token()
            XCTAssertTrue(omni_vm_component_owner(vm, id, id.utf8.count, &expected))
            XCTAssertTrue(omni_instance_action_owner(display, OMNI_VIEW_BAR, actions[index + 1], &actual))
            XCTAssertEqual(actual.generation, expected.generation)
            XCTAssertEqual(actual.owner, expected.owner)
            XCTAssertEqual(actual.epoch, expected.epoch)
            var event = ShellValueWriter()
            event.map(1)
            event.key("expected")
            event.string(id)
            XCTAssertEqual(event.bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    display,
                    OMNI_VIEW_BAR,
                    actions[index + 1],
                    0,
                    $0.baseAddress,
                    $0.count,
                    100_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK)
        }
        var empty = ShellValueWriter()
        empty.array(0)
        XCTAssertEqual(empty.bytes.withUnsafeBufferPointer {
            omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
        }, OMNI_OK)
        var stale = omni_owner_token()
        XCTAssertFalse(omni_instance_action_owner(display, OMNI_VIEW_BAR, actions[1], &stale))
        XCTAssertEqual(stale.generation, 0)
        XCTAssertTrue(omni_instance_action_owner(display, OMNI_VIEW_BAR, actions[0], &rootOwner))
    }
}
