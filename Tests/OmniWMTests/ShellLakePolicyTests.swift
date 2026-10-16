// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellLakePolicyTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let revision: UInt64
        let seconds: Double
        let cancelled: Bool
        let bytes: [UInt8]
    }

    @MainActor
    private final class Fixture {
        let vm: OpaquePointer
        var instance: OpaquePointer!
        let text = ShellTextStore()
        var nodes: [omni_wire_node] = []
        var error = [CChar](repeating: 0, count: 512)
        var deps: UInt64 = 0

        init(count: Int = 3, peek: Bool = true, note: Bool = false, blocked: Int = 0) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            XCTAssertEqual(omni_vm_set_module_limit(vm, 512), OMNI_OK)
            let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
            for path in [
                "motion",
                "view",
                "slots",
                "preferences",
                "policy",
                "attention",
                "intent",
                "settings",
                "services/note"
            ] {
                let file = "lib/lake/\(path).luau"
                let source = try String(contentsOf: profile.appendingPathComponent(file), encoding: .utf8)
                let virtual = "profile/" + file
                XCTAssertEqual(omni_vm_add_module(vm, virtual, virtual.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            let component: String
            let widget: String
            if note {
                widget = "quick-note"
                component = try String(
                    contentsOf: profile.appendingPathComponent("widgets/quick-note/component.luau"),
                    encoding: .utf8
                )
            } else {
                widget = "probe"
                component = """
                local function view(ctx) return ui.text{text=ctx.instance.id..':'..ctx.view.name} end
                return {
                    activity=function(ctx)
                        local values=ctx.data.vars or {}
                        local id=values[ctx.instance.id]
                        return {label='label-'..ctx.instance.id,priority=0,
                            alert=id and {id=id,seconds=0.25} or nil,
                            dropTypes=ctx.instance.id=='b' and {'file'} or nil}
                    end,
                    views={compact=view,peek=view,expanded=view}
                }
                """
            }
            let path = "profile/widgets/\(widget)/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
            let main = note ? "function render() return ui.component{id='note',view='expanded',w=500} end"
                : try String(contentsOf: profile.appendingPathComponent("widgets/lake/init.luau"), encoding: .utf8)
            let source = "for _=1,\(blocked) do assert(omniwm.after(3600,function() end)) end\n" + main
            XCTAssertEqual(omni_vm_load(
                vm,
                "@profile/widgets/lake/init.luau",
                source,
                source.utf8.count,
                200_000_000,
                &error,
                error.count
            ), OMNI_OK, message)
            if note {
                var seed = ShellValueWriter()
                seed.map(1)
                seed.key("note")
                seed.string("Saved note")
                XCTAssertEqual(seed.bytes.withUnsafeBufferPointer {
                    omni_vm_seed_store(vm, "note", 4, $0.baseAddress, $0.count, nil, 0, &error, error.count)
                }, OMNI_OK, message)
            }
            let names = note ? ["note"] : (0 ..< count).map { String(UnicodeScalar(97 + $0)!) }
            let config = ShellServiceValue.array(names.map {
                .object([
                    "id": .text($0),
                    "widget": .text(widget),
                    "title": .text("Item \($0)"),
                    "enabled": .bool(true),
                    "options": .object([:])
                ])
            })
            var writer = ShellValueWriter()
            config.write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
            instance = try XCTUnwrap(omni_instance_create(vm))
            set("catalog", .array([.object([
                "widget": .text(widget),
                "title": .text(widget),
                "views": .array((peek ? ["compact", "peek", "expanded"] : [
                    "compact",
                    "expanded"
                ]).map { .text($0) })
            ])]))
            set("vars", .object([:]))
            if !note { island() }
        }

        isolated deinit {
            if let instance { omni_instance_destroy(instance) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        var captions: [String] {
            nodes.filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func set(_ key: String, _ value: ShellServiceValue) {
            var writer = ShellValueWriter()
            value.write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_set_value(instance, key, $0.baseAddress, $0.count)
            }, OMNI_OK)
        }

        func island(drag: Bool = false, types: [String] = [], notch: Bool = true) {
            set("island", .object([
                "size": .object(["w": .number(760), "h": .number(360)]),
                "notch": notch ? .object(["w": .number(180), "h": .number(32)]) : .null,
                "drag": .object(["active": .bool(drag), "types": .array(types.map { .text($0) })]),
                "visible": .bool(true)
            ]))
        }

        func render() throws {
            var stats = omni_render_stats()
            let status = omni_instance_render(instance, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count)
            XCTAssertEqual(status, OMNI_OK, message)
            guard status == OMNI_OK else { throw ShellResourceFailure(message) }
            deps = stats.deps
            var length = 0
            let output = try XCTUnwrap(omni_instance_output(instance, OMNI_VIEW_BAR, &length))
            let bytes = Array(UnsafeBufferPointer(start: output, count: length))
            text.ingest(wire: bytes)
            nodes = bytes.withUnsafeBytes { buffer in
                let header = buffer.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map {
                    buffer.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>
                            .stride,
                        as: omni_wire_node.self
                    )
                }
            }
        }

        func invoke(_ action: UInt32, event: ShellEvent = ShellEvent()) {
            XCTAssertEqual(event.bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    instance,
                    OMNI_VIEW_BAR,
                    action,
                    41,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
        }

        func action(_ caption: String) throws -> UInt32 {
            let index = try XCTUnwrap(nodes.indices.first { text.string(nodes[$0].text) == caption })
            let node = try XCTUnwrap(nodes.enumerated().last { offset, node in
                node.action != 0 && offset <= index && index < Int(node.subtree_end)
            })
            return node.element.action
        }

        func drain() -> [Request] {
            var request = omni_service_request()
            var result: [Request] = []
            while omni_vm_next_service(vm, &request) {
                result.append(Request(
                    kind: request.kind,
                    owner: request.owner,
                    id: request.id,
                    revision: request.revision,
                    seconds: request.seconds,
                    cancelled: request.cancelled,
                    bytes: request.value
                        .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
                ))
            }
            return result
        }

        func complete(_ request: Request, error problem: String? = nil) {
            var writer = ShellValueWriter()
            ShellServiceValue.object(["ok": .bool(problem == nil), "error": problem.map { .text($0) } ?? .null])
                .write(to: &writer)
            var handled = false
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_complete_service(
                    vm,
                    request.owner,
                    request.id,
                    request.revision,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &handled,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
            XCTAssertTrue(handled)
        }
    }

    func testAlertQueueIsBoundedDeduplicatedAndHasNoSecondsDemand() throws {
        let fixture = try Fixture(count: 12)
        fixture.set(
            "vars",
            .object(Dictionary(uniqueKeysWithValues: (0 ..< 12)
                    .map { (String(UnicodeScalar(97 + $0)!), .text("done")) }))
        )
        var count = 0
        for _ in 0 ..< 12 {
            try fixture.render()
            XCTAssertEqual(fixture.deps & ShellDataKey.seconds.bit, 0)
            let timers = fixture.drain().filter { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled }
            XCTAssertLessThanOrEqual(timers.count, 1)
            guard let timer = timers.first else { break }
            XCTAssertEqual(timer.seconds, 0.25)
            XCTAssertTrue(fixture.captions.contains { $0.hasSuffix(":peek") })
            count += 1
            fixture.complete(timer)
        }
        XCTAssertEqual(count, 8)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        try fixture.render()
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertFalse(fixture.captions.contains { $0.hasSuffix(":peek") })
    }

    func testRealAdvertisedPeekAndFallbackCaptionFollowHover() throws {
        for peek in [false, true] {
            let fixture = try Fixture(peek: peek)
            try fixture.render()
            let primary = try XCTUnwrap(fixture.nodes.first { $0.hover_action != 0 })
            fixture.invoke(primary.hover_action, event: ShellEvent(phase: .began, kind: .hover))
            try fixture.render()
            XCTAssertEqual(fixture.captions.contains("a:peek"), peek)
            XCTAssertEqual(fixture.captions.contains("label-a"), !peek)
            fixture.invoke(
                try XCTUnwrap(fixture.nodes.first { $0.hover_action != 0 }).hover_action,
                event: ShellEvent(phase: .ended, kind: .hover)
            )
            try fixture.render()
            XCTAssertTrue(fixture.captions.contains("a:compact"))
            XCTAssertFalse(fixture.captions.contains("a:peek"))
        }
    }

    func testDragTemporarilyPromotesOnlyMatchingActivityThenRestoresSelection() throws {
        let fixture = try Fixture()
        try fixture.render()
        let primary = try XCTUnwrap(fixture.nodes.first { $0.hover_action != 0 })
        fixture.invoke(primary.action)
        try fixture.render()
        fixture.invoke(try fixture.action("Item c"))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("c:expanded"))
        fixture.island(drag: true, types: ["text"])
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("c:expanded"))
        fixture.island(drag: true, types: ["file"])
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("b:expanded"))
        fixture.island()
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("c:expanded"))
        XCTAssertEqual(fixture.deps & ShellDataKey.seconds.bit, 0)
    }

    func testEveryNavigationPageIsReachableAndSelectedTabStaysVisible() throws {
        let fixture = try Fixture(count: 7)
        try fixture.render()
        fixture.invoke(try XCTUnwrap(fixture.nodes.first { $0.hover_action != 0 }).action)
        try fixture.render()
        fixture.invoke(try fixture.action("chevron.right"))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Item f"))
        fixture.invoke(try fixture.action("chevron.right"))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Item g"))
        fixture.invoke(try fixture.action("Item g"))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("g:expanded"))
        XCTAssertTrue(fixture.captions.contains("Item g"))
        fixture.invoke(try fixture.action("chevron.right"))
        try fixture.render()
        fixture.invoke(
            try XCTUnwrap(fixture.nodes.first { $0.key_action != 0 }).key_action,
            event: ShellEvent(kind: .key, key: "right")
        )
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("a:expanded"))
        XCTAssertTrue(fixture.captions.contains("Item a"))
        fixture.invoke(try fixture.action("chevron.right"))
        try fixture.render()
        fixture.invoke(try XCTUnwrap(fixture.nodes.first { $0.secondary_action != 0 }).secondary_action)
        try fixture.render()
        fixture.invoke(try fixture.action("Show"))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("a:expanded"))
        XCTAssertTrue(fixture.captions.contains("Item a"))
    }

    func testRejectedAlertTimerIsVisibleInExistingSettingsNotice() throws {
        let fixture = try Fixture(blocked: 32)
        _ = fixture.drain()
        fixture.set("vars", .object(["a": .text("done")]))
        try fixture.render()
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.invoke(try XCTUnwrap(fixture.nodes.first { $0.secondary_action != 0 }).secondary_action)
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains { $0.contains("overloaded") })
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
    }

    func testQuickNoteCancelCommitAndClipboardFailureUsePublicNativeContracts() throws {
        let fixture = try Fixture(note: true)
        try fixture.render()
        let original = try XCTUnwrap(fixture.nodes.first { $0.kind == 10 })
        XCTAssertEqual(fixture.text.string(original.text), "Saved note")
        var change = ShellEvent(kind: .textChange)
        change.text = "Discarded draft"
        fixture.invoke(original.action, event: change)
        fixture.invoke(original.input_cancel_action, event: ShellEvent(kind: .textCancel))
        try fixture.render()
        let restored = try XCTUnwrap(fixture.nodes.first { $0.kind == 10 })
        XCTAssertNotEqual(restored.key, original.key)
        XCTAssertEqual(fixture.text.string(restored.text), "Saved note")
        XCTAssertTrue(fixture.drain().isEmpty)
        var commit = ShellEvent(kind: .textCommit)
        commit.text = "Durable note"
        fixture.invoke(restored.input_commit_action, event: commit)
        let store = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_STORE })
        XCTAssertEqual(try ShellServiceValue.decode(store.bytes).fields?["note"]?.string, "Durable note")
        fixture.complete(store)
        try fixture.render()
        fixture.invoke(try fixture.action("doc.on.doc"))
        let copy = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        XCTAssertEqual(try ShellServiceValue.decode(copy.bytes).fields?["op"]?.string, "clipboardCopy")
        XCTAssertEqual(try ShellServiceValue.decode(copy.bytes).fields?["text"]?.string, "Durable note")
        fixture.complete(copy, error: "clipboard_denied")
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("clipboard_denied"))
        XCTAssertEqual(fixture.deps & ShellDataKey.seconds.bit, 0)
    }
}
