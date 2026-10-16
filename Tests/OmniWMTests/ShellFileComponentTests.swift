// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellFileComponentTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let revision: UInt64
        let cancelled: Bool
        let bytes: [UInt8]
    }

    @MainActor
    private final class Fixture {
        let vm: OpaquePointer
        let widget: String
        var displays: [OpaquePointer] = []
        let text = ShellTextStore()
        var error = [CChar](repeating: 0, count: 512)
        var nodes: [omni_wire_node] = []

        init(widget: String = "shelf", seed: ShellServiceValue? = nil, token: String? = nil) throws {
            self.widget = widget
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
            func module(_ path: String, _ source: String) {
                let name = "profile/" + path
                XCTAssertEqual(omni_vm_add_module(vm, name, name.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            for path in [
                "lib/lake/view.luau",
                "lib/lake/motion.luau",
                "lib/lake/services/shelf.luau",
                "lib/lake/services/convert.luau",
                "lib/lake/shelf-view.luau"
            ] {
                module(path, try String(contentsOf: profile.appendingPathComponent(path), encoding: .utf8))
            }
            let source = try String(
                contentsOf: profile.appendingPathComponent("widgets/\(widget)/component.luau"),
                encoding: .utf8
            )
            module("widgets/\(widget)/component.luau", """
            local component=(function()
            \(source)
            end)()
            local shelf=require('../lib/lake/services/shelf')
            local convert=require('../lib/lake/services/convert')
            component.views.fixture=function(ctx)
                local items=shelf.items(ctx.instance)
                return ui.column{component.views.expanded(ctx),
                    ui.text{text='count:'..tostring(#items)},
                    ui.text{text='failure:'..tostring(shelf.error(ctx.instance))},
                    ui.text{text='item-error:'..tostring(items[1] and items[1].error)},
                    ui.box{onClick=function(next,event)
                        local first=shelf.items(next.instance)[1]
                        if event.key=='pick' then shelf.pick(next.instance)
                        elseif event.key=='paste' then shelf.paste(next.instance)
                        elseif event.key=='retry' then shelf.retry(next.instance)
                        elseif event.key=='remove' and first then shelf.remove(next.instance,first.id)
                        elseif event.key=='clear' then shelf.clear(next.instance)
                        elseif event.key=='share' and first then shelf.action(next.instance,first,'share','shelf:fixture:'..tostring(first.id))
                        elseif event.key=='convert' then
                            assert(omniwm.pick({files=true,multiple=true},function(result) if result.ok then convert.accept(next.instance,result.items) end end))
                        elseif event.key=='retry-convert' then convert.retry(next.instance) end
                    end,ui.text{text='fixture-control'}}}
            end
            return component
            """)
            let root = """
            function render(ctx)
                local activity=omniwm.components.activity('files')
                return ui.column{ui.text{text=activity and activity.alert and 'alert:'..activity.alert.id or 'no-alert'},
                    ui.component{id='files',view='fixture',w=380,h=300}}
            end
            """
            XCTAssertEqual(
                omni_vm_load(
                    vm,
                    "@profile/widgets/root/init.luau",
                    root,
                    root.utf8.count,
                    200_000_000,
                    &error,
                    error.count
                ),
                OMNI_OK,
                message
            )
            if let seed {
                var writer = ShellValueWriter()
                ShellServiceValue.object(["shelf": seed]).write(to: &writer)
                XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                    omni_vm_seed_store(vm, "files", 5, $0.baseAddress, $0.count, nil, 0, &error, error.count)
                }, OMNI_OK, message)
            }
            if let token {
                let value = try XCTUnwrap(UUID(uuidString: token))
                let status = "Picture.png"
                    .withCString { name in "file".withCString { kind in "public.png".withCString { uti in
                        let descriptor = omni_resource_descriptor(
                            name: name,
                            name_length: 11,
                            kind: kind,
                            kind_length: 4,
                            uti: uti,
                            uti_length: 10
                        )
                        var saved = omni_resource_token_descriptor(
                            token: omni_resource_id(bytes: value.uuid),
                            descriptor: descriptor
                        )
                        return omni_vm_seed_resource_tokens(vm, "files", 5, &saved, 1, nil, 0, &error, error.count)
                    } } }
                XCTAssertEqual(status, OMNI_OK, message)
            }
            configure()
            displays.append(try XCTUnwrap(omni_instance_create(vm)))
        }

        isolated deinit {
            for display in displays { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        var captions: [String] {
            nodes.filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func configure(format: String = "png", enabled: Bool = true) {
            let value = ShellServiceValue.array([.object([
                "id": .text("files"),
                "widget": .text(widget),
                "enabled": .bool(enabled),
                "provider": .bool(true),
                "options": .object(["format": .text(format)])
            ])])
            var writer = ShellValueWriter()
            value.write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func render(_ display: OpaquePointer? = nil) throws {
            let display = try XCTUnwrap(display ?? displays.first)
            var stats = omni_render_stats()
            XCTAssertEqual(
                omni_instance_render(display, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count),
                OMNI_OK,
                message
            )
            var count = 0
            let output = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &count))
            let bytes = Array(UnsafeBufferPointer(start: output, count: count))
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

        func action(_ command: String) throws {
            try render()
            let action = try XCTUnwrap(nodes.last { $0.action != 0 }).action
            var event = ShellEvent()
            event.key = command
            XCTAssertEqual(event.bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    displays[0],
                    OMNI_VIEW_BAR,
                    action,
                    0x1_0000_0001,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
        }

        func commit(_ node: omni_wire_node, text: String) {
            var writer = ShellValueWriter()
            ShellServiceValue.object(["text": .text(text)]).write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    displays[0],
                    OMNI_VIEW_BAR,
                    node.input_commit_action,
                    0x1_0000_0001,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
        }

        func cancel(_ node: omni_wire_node) {
            XCTAssertEqual(omni_instance_invoke(
                displays[0],
                OMNI_VIEW_BAR,
                node.input_cancel_action,
                0x1_0000_0001,
                nil,
                0,
                200_000_000,
                &error,
                error.count
            ), OMNI_OK, message)
        }

        func click(_ caption: String) throws {
            let index = try XCTUnwrap(nodes.firstIndex { $0.text != 0 && text.string($0.text) == caption })
            let action = try XCTUnwrap(nodes[..<index].last { $0.action != 0 && Int($0.subtree_end) > index }).action
            XCTAssertEqual(omni_instance_invoke(
                displays[0],
                OMNI_VIEW_BAR,
                action,
                0x1_0000_0001,
                nil,
                0,
                200_000_000,
                &error,
                error.count
            ), OMNI_OK, message)
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
                    cancelled: request.cancelled,
                    bytes: request.value
                        .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
                ))
            }
            return result
        }

        func admit(
            _ owner: omni_owner_token,
            count: Int = 1,
            ready: Bool = true,
            name: String = "Picture.png",
            kind: String = "file",
            uti: String = "public.png"
        ) -> [omni_resource_id] {
            var ids = [omni_resource_id](repeating: omni_resource_id(), count: count)
            let status = name
                .withCString { namePointer in kind.withCString { kindPointer in uti.withCString { utiPointer in
                    let descriptor = omni_resource_descriptor(
                        name: namePointer,
                        name_length: name.utf8.count,
                        kind: kindPointer,
                        kind_length: kind.utf8.count,
                        uti: utiPointer,
                        uti_length: uti.utf8.count
                    )
                    return Array(repeating: descriptor, count: count).withUnsafeBufferPointer {
                        omni_vm_admit_resources(vm, owner, $0.baseAddress, $0.count, &ids, &error, error.count)
                    }
                } } }
            XCTAssertEqual(status, OMNI_OK, message)
            if ready { for id in ids { update(owner, id: id) } }
            return ids
        }

        func update(_ owner: omni_owner_token, id: omni_resource_id) {
            var applied = false
            var value = omni_resource_update(
                id: id,
                revision: 1,
                state: OMNI_RESOURCE_READY,
                size: 12,
                has_size: true,
                error: nil,
                error_length: 0
            )
            XCTAssertEqual(
                omni_vm_update_resources(vm, owner, &value, 1, &applied, &error, error.count),
                OMNI_OK,
                message
            )
            XCTAssertTrue(applied)
        }

        func picked(_ request: Request, ids: [omni_resource_id]) {
            var writer = ShellValueWriter()
            ShellServiceValue.object(["ok": .bool(true)]).write(to: &writer)
            var handled = false
            var transferred = false
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer { bytes in ids.withUnsafeBufferPointer { ids in
                omni_vm_complete_desktop(
                    vm,
                    request.owner,
                    request.id,
                    bytes.baseAddress,
                    bytes.count,
                    ids.baseAddress,
                    ids.count,
                    200_000_000,
                    &handled,
                    &transferred,
                    &error,
                    error.count
                )
            } }, OMNI_OK, message)
            XCTAssertTrue(handled)
            XCTAssertTrue(transferred)
        }

        func persisted(_ request: Request, failure: String? = nil) {
            var handled = false
            let status = failure.map { failure in failure.withCString {
                omni_vm_complete_resource(
                    vm,
                    request.owner,
                    request.id,
                    false,
                    1,
                    0,
                    false,
                    $0,
                    failure.utf8.count,
                    200_000_000,
                    &handled,
                    &error,
                    error.count
                )
            } } ?? omni_vm_complete_resource(
                vm,
                request.owner,
                request.id,
                true,
                1,
                12,
                true,
                nil,
                0,
                200_000_000,
                &handled,
                &error,
                error.count
            )
            XCTAssertEqual(status, OMNI_OK, message)
            XCTAssertTrue(handled)
        }

        func storeComplete(_ request: Request, failure: String? = nil) {
            var writer = ShellValueWriter()
            ShellServiceValue.object(failure.map { ["ok": .bool(false), "error": .text($0)] } ?? ["ok": .bool(true)])
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
        }

        func converted(_ request: Request, ids: [omni_resource_id], failure: String? = nil) {
            var handled = false
            var transferred = false
            let json = failure.map { "\"" + $0 + "\"" } ?? "{\"converted\":\(ids.count)}"
            XCTAssertEqual(ids.withUnsafeBufferPointer {
                omni_vm_complete_provider(
                    vm,
                    request.owner,
                    request.id,
                    failure == nil,
                    json,
                    json.utf8.count,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &handled,
                    &transferred,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
            XCTAssertTrue(handled)
            XCTAssertEqual(transferred, !ids.isEmpty)
        }
    }

    func testPendingPromisesPersistOneAtATimeAndDisplaysDoNotDuplicateWork() throws {
        let fixture = try Fixture()
        try fixture.action("pick")
        let pick = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        try fixture.action("paste")
        XCTAssertTrue(fixture.drain().isEmpty)
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("failure:Another file action is pending"))
        let ids = fixture.admit(pick.owner, count: 2, ready: false)
        fixture.picked(pick, ids: ids)
        let started = fixture.drain()
        let first = try XCTUnwrap(started.first { $0.kind == OMNI_SERVICE_RESOURCE })
        XCTAssertEqual(started.filter { $0.kind == OMNI_SERVICE_RESOURCE }.count, 1)
        let store = try XCTUnwrap(started.first { $0.kind == OMNI_SERVICE_STORE })
        let items = try XCTUnwrap(ShellServiceValue.decode(store.bytes).fields?["shelf"]?.fields?["items"]?.values)
        XCTAssertEqual(items.count, 2)
        XCTAssertNotNil(items[0].fields?["token"]?.string)
        XCTAssertNil(items[1].fields?["token"])
        try fixture.render()
        let secondDisplay = try XCTUnwrap(omni_instance_create(fixture.vm))
        fixture.displays.append(secondDisplay)
        try fixture.render(secondDisplay)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertTrue(fixture.captions.contains("Preparing…"))
        fixture.update(pick.owner, id: ids[0])
        fixture.persisted(first)
        let second = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_RESOURCE })
        XCTAssertNotEqual(first.id, second.id)
        fixture.update(pick.owner, id: ids[1])
        fixture.persisted(second)
        XCTAssertFalse(fixture.drain().contains { $0.kind == OMNI_SERVICE_RESOURCE })
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("count:2"))
    }

    func testPersistenceAndStoreFailureAreVisibleAndRetryIsExplicit() throws {
        let fixture = try Fixture()
        try fixture.action("pick")
        let pick = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        fixture.picked(pick, ids: fixture.admit(pick.owner))
        let requests = fixture.drain()
        let persist = try XCTUnwrap(requests.first { $0.kind == OMNI_SERVICE_RESOURCE })
        let store = try XCTUnwrap(requests.first { $0.kind == OMNI_SERVICE_STORE })
        fixture.persisted(persist, failure: "pin failed")
        fixture.storeComplete(store, failure: "disk full")
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("item-error:pin failed"))
        XCTAssertTrue(fixture.captions.contains("failure:disk full"))
        XCTAssertFalse(fixture.drain().contains { $0.kind == OMNI_SERVICE_RESOURCE })
        try fixture.action("retry")
        let retry = fixture.drain()
        XCTAssertEqual(retry.filter { $0.kind == OMNI_SERVICE_RESOURCE }.count, 1)
        XCTAssertEqual(retry.filter { $0.kind == OMNI_SERVICE_STORE }.count, 1)
        let next = try XCTUnwrap(retry.first { $0.kind == OMNI_SERVICE_RESOURCE })
        XCTAssertNotEqual(
            try ShellServiceValue.decode(persist.bytes).fields?["token"],
            try ShellServiceValue.decode(next.bytes).fields?["token"]
        )
    }

    func testShelfLimitRenameAndReadyAnchorRemainBounded() throws {
        let fixture = try Fixture()
        try fixture.action("pick")
        let pick = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        fixture.picked(pick, ids: fixture.admit(pick.owner, count: 32))
        let pending = fixture.drain()
        XCTAssertEqual(pending.filter { $0.kind == OMNI_SERVICE_RESOURCE }.count, 1)
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("count:32"))
        let input = try XCTUnwrap(fixture.nodes.first { $0.kind == 10 })
        XCTAssertEqual(input.height, 28)
        fixture.commit(input, text: "My screenshot")
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("My screenshot"))
        try fixture.action("share")
        let share = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        XCTAssertEqual(try ShellServiceValue.decode(share.bytes).fields?["op"]?.string, "share")
        fixture.storeComplete(share)
        try fixture.action("pick")
        let extra = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        fixture.picked(extra, ids: fixture.admit(extra.owner))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("count:32"))
        XCTAssertTrue(fixture.captions.contains("failure:Shelf is full (32 items)"))
        try fixture.action("remove")
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("count:31"))
    }

    func testCancelAlwaysReplacesTheVisibleInputAcrossPages() throws {
        let fixture = try Fixture()
        try fixture.action("pick")
        let pick = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        fixture.picked(pick, ids: fixture.admit(pick.owner, count: 5))
        _ = fixture.drain()
        try fixture.render()
        let first = try XCTUnwrap(fixture.nodes.first { $0.kind == 10 })
        fixture.cancel(first)
        try fixture.render()
        XCTAssertNotEqual(fixture.nodes.first { $0.kind == 10 }?.key, first.key)
        try fixture.click("Next")
        try fixture.render()
        let next = try XCTUnwrap(fixture.nodes.first { $0.kind == 10 })
        XCTAssertEqual(fixture.nodes.filter { $0.kind == 10 }.count, 1)
        fixture.cancel(next)
        try fixture.render()
        XCTAssertNotEqual(fixture.nodes.first { $0.kind == 10 }?.key, next.key)
        XCTAssertEqual(fixture.text.string(try XCTUnwrap(fixture.nodes.first { $0.kind == 10 }).text), "Picture.png")
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testSavedTokenRestoresWithoutRepersistingAndRetainsRenamedLabel() throws {
        let initial = try Fixture()
        try initial.action("pick")
        let pick = try XCTUnwrap(initial.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        initial.picked(pick, ids: initial.admit(pick.owner))
        let admitted = initial.drain()
        let persist = try XCTUnwrap(admitted.first { $0.kind == OMNI_SERVICE_RESOURCE })
        let store = try XCTUnwrap(admitted.first { $0.kind == OMNI_SERVICE_STORE })
        initial.persisted(persist)
        initial.storeComplete(store)
        _ = initial.drain()
        let saved = try XCTUnwrap(ShellServiceValue.decode(store.bytes).fields?["shelf"])
        let token = try XCTUnwrap(saved.fields?["items"]?.values?.first?.fields?["token"]?.string)
        var entry = try XCTUnwrap(saved.fields?["items"]?.values?.first?.fields)
        entry["name"] = .text("My saved image")
        let snapshot = ShellServiceValue.object(["next": .number(1), "items": .array([.object(entry)])])
        let restored = try Fixture(seed: snapshot, token: token)
        let restore = try XCTUnwrap(restored.drain().first { $0.kind == OMNI_SERVICE_RESOURCE })
        XCTAssertEqual(try ShellServiceValue.decode(restore.bytes).fields?["op"]?.string, "restore")
        try restored.render()
        XCTAssertTrue(restored.captions.contains("My saved image"))
        XCTAssertTrue(restored.captions.contains("Preparing…"))
        restored.persisted(restore)
        try restored.render()
        XCTAssertTrue(restored.captions.contains("count:1"))
        XCTAssertTrue(restored.captions.contains("My saved image"))
        XCTAssertTrue(restored.drain().isEmpty)
    }

    func testMalformedSavedShelfDoesNotOverwriteUntilExplicitClear() throws {
        let fixture = try Fixture(seed: .object(["next": .number(1), "items": .object(["unexpected": .bool(true)])]))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("failure:Saved shelf is invalid"))
        XCTAssertTrue(fixture.drain().isEmpty)
        try fixture.action("clear")
        XCTAssertEqual(fixture.drain().filter { $0.kind == OMNI_SERVICE_STORE }.count, 1)
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("count:0"))
    }

    func testConverterUsesTypedInputsPreservesOutputsOnFailureAndCancelsOnOptions() throws {
        let fixture = try Fixture(widget: "converter")
        try fixture.action("convert")
        let pick = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        fixture.picked(pick, ids: fixture.admit(pick.owner, ready: false))
        let request = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_PROVIDER })
        let payload = try ShellServiceValue.decode(request.bytes).fields
        XCTAssertEqual(payload?["name"]?.string, "convert")
        XCTAssertEqual(payload?["files"]?.values?.count, 1)
        XCTAssertTrue(payload?["argsJSON"]?.string?.contains("png") == true)
        try fixture.action("retry-convert")
        XCTAssertTrue(fixture.drain().isEmpty)
        let outputs = fixture.admit(request.owner)
        fixture.converted(request, ids: outputs)
        let persisted = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_RESOURCE })
        fixture.persisted(persisted)
        _ = fixture.drain()
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("count:1"))
        XCTAssertTrue(fixture.captions.contains("alert:converted:1"))
        try fixture.action("retry-convert")
        let retry = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_PROVIDER })
        fixture.converted(retry, ids: [], failure: "conversion_failed")
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("count:1"))
        XCTAssertTrue(fixture.captions.contains("conversion_failed"))
        try fixture.action("retry-convert")
        let active = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_PROVIDER })
        fixture.configure(format: "jpeg")
        XCTAssertTrue(fixture.drain().contains { $0.id == active.id && $0.cancelled })
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Options changed; retry conversion"))
    }

    func testUnsupportedConverterInputsNeverReachProvider() throws {
        let fixture = try Fixture(widget: "converter")
        try fixture.action("convert")
        let pick = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_DESKTOP })
        fixture.picked(
            pick,
            ids: fixture.admit(pick.owner, name: "note.txt", kind: "text", uti: "public.utf8-plain-text")
        )
        XCTAssertFalse(fixture.drain().contains { $0.kind == OMNI_SERVICE_PROVIDER })
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Only supported image files can be converted"))
        let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
        let descriptor = try ShellComponentCatalog.load("converter", directories: [profile])
        XCTAssertEqual(descriptor.providerCommand, ["provider.pl"])
        XCTAssertTrue(descriptor.capabilities.files)
        XCTAssertTrue(descriptor.capabilities.provider)
        XCTAssertFalse(ShellComponentInstance(id: "convert", widget: "converter").provider)
        let format = try XCTUnwrap(descriptor.options["format"])
        XCTAssertTrue(format.accepts(.string("png")))
        XCTAssertFalse(format.accepts(.string("shell-command")))
    }
}
