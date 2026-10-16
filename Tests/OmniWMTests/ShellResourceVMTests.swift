// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellResourceVMTests: XCTestCase {
    private final class Fixture {
        let vm: OpaquePointer
        let display: OpaquePointer
        let text = ShellTextStore()
        var error = [CChar](repeating: 0, count: 512)

        init(_ component: String = """
        return {views={compact=function(ctx)
            local resource=ctx.instance.state.resource
            local content=resource and resource.state or 'empty'
            return ui.stack{accepts={'file','image'},onDrop=function(next,event)
                assert(#event.items==1 and event.x==12 and event.y==34)
                local value=event.items[1]
                assert(not pcall(function() value.name='changed' end))
                assert(not pcall(function() event.items[1]=nil end))
                next.instance.state.resource=value
            end,onDropHover=function() end,
                ui.text{text=ctx.instance.id..':'..content},
                resource and ui.image{image=resource,thumbnail=128} or nil}
        end}}
        """, root: String = "function render(ctx) return ui.row{ui.component{id='a'},ui.component{id='b'}} end") throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            let path = "profile/widgets/resource/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
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
            display = try XCTUnwrap(omni_instance_create(vm))
            let writer = Self.configuration(["a", "b"])
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
            }, OMNI_OK)
        }

        deinit {
            omni_instance_destroy(display)
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        static func configuration(_ ids: [String]) -> ShellValueWriter {
            var writer = ShellValueWriter()
            writer.array(ids.count)
            for id in ids {
                writer.map(4)
                writer.key("id")
                writer.string(id)
                writer.key("widget")
                writer.string("resource")
                writer.key("enabled")
                writer.bool(true)
                writer.key("options")
                writer.map(0)
            }
            return writer
        }

        func configure(_ ids: [String]) {
            let writer = Self.configuration(ids)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func owner(_ id: String) throws -> omni_owner_token {
            var owner = omni_owner_token()
            XCTAssertTrue(omni_vm_component_owner(vm, id, id.utf8.count, &owner))
            return owner
        }

        @discardableResult
        func update(_ changed: UInt64 = 0) -> [omni_render_step_stats] {
            XCTAssertEqual(omni_instance_begin_update(display, OMNI_VIEW_BAR, changed, true), OMNI_OK)
            var result: [omni_render_step_stats] = []
            for _ in 0 ..< 160 {
                var step = omni_render_step_stats()
                XCTAssertEqual(
                    omni_instance_step_update(display, OMNI_VIEW_BAR, 100_000_000, &step, &error, error.count),
                    OMNI_OK,
                    message
                )
                result.append(step)
                if step.done { return result }
            }
            XCTFail("resource update did not terminate")
            return result
        }

        func nodes() throws -> [omni_wire_node] {
            var length = 0
            let output = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &length))
            let bytes = Array(UnsafeBufferPointer(start: output, count: length))
            text.ingest(wire: bytes)
            return bytes.withUnsafeBytes { buffer in
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

        func actions() throws -> [UInt32] {
            try nodes().map(\.resource_drop_action).filter { $0 != 0 }
        }

        func captions() throws -> [String] {
            try nodes().filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func admit(
            _ owner: omni_owner_token,
            count: Int = 1,
            expected: omni_status = OMNI_OK,
            name: String = "File.txt"
        ) -> [omni_resource_id] {
            var ids = [omni_resource_id](repeating: omni_resource_id(), count: max(count, 1))
            let status = name.withCString { namePointer in
                "file".withCString { kind in
                    "public.text".withCString { uti in
                        let descriptor = omni_resource_descriptor(
                            name: namePointer,
                            name_length: name.utf8.count,
                            kind: kind,
                            kind_length: 4,
                            uti: uti,
                            uti_length: 11
                        )
                        let descriptors = Array(repeating: descriptor, count: count)
                        return descriptors.withUnsafeBufferPointer {
                            omni_vm_admit_resources(vm, owner, $0.baseAddress, $0.count, &ids, &error, error.count)
                        }
                    }
                }
            }
            XCTAssertEqual(status, expected, message)
            return ids
        }

        func reserve(_ action: UInt32, expected: omni_status = OMNI_OK) -> (omni_owner_token, UInt64) {
            var owner = omni_owner_token()
            var id: UInt64 = 0
            XCTAssertEqual(
                omni_instance_reserve_drop(display, OMNI_VIEW_BAR, action, 0, &owner, &id, &error, error.count),
                expected,
                message
            )
            if expected != OMNI_OK { XCTAssertEqual(id, 0) }
            return (owner, id)
        }

        @discardableResult
        func deliver(
            _ request: (omni_owner_token, UInt64),
            ids: [omni_resource_id],
            x: Double = 12,
            y: Double = 34,
            expected: omni_status = OMNI_OK
        ) -> Bool {
            var handled = false
            XCTAssertEqual(ids.withUnsafeBufferPointer {
                omni_vm_deliver_drop(
                    vm,
                    request.0,
                    request.1,
                    $0.baseAddress,
                    $0.count,
                    x,
                    y,
                    100_000_000,
                    &handled,
                    &error,
                    error.count
                )
            }, expected, message)
            return handled
        }

        @discardableResult
        func metadata(
            _ owner: omni_owner_token,
            id: omni_resource_id,
            revision: UInt64 = 1,
            state: omni_resource_state = OMNI_RESOURCE_READY
        ) -> Bool {
            var applied = false
            var update = omni_resource_update(
                id: id,
                revision: revision,
                state: state,
                size: 42,
                has_size: true,
                error: nil,
                error_length: 0
            )
            XCTAssertEqual(
                omni_vm_update_resources(vm, owner, &update, 1, &applied, &error, error.count),
                OMNI_OK,
                message
            )
            return applied
        }

        func drainCancellations() -> Int {
            var request = omni_service_request()
            var count = 0
            while omni_vm_next_service(vm, &request) {
                XCTAssertEqual(request.kind, OMNI_SERVICE_DROP)
                XCTAssertTrue(request.cancelled)
                count += 1
            }
            return count
        }
    }

    func testResourceWireIsDistinctFromWindowManagerDropBits() throws {
        let fixture = try Fixture()
        fixture.update()
        let targets = try fixture.nodes().filter { $0.resource_accepts != 0 }
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 392)
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(Set(targets.map(\.resource_drop_action)).count, 2)
        for target in targets {
            XCTAssertEqual(target.resource_accepts, OMNI_RESOURCE_ACCEPT_FILE | OMNI_RESOURCE_ACCEPT_IMAGE)
            XCTAssertEqual(target.flags & UInt16(OMNI_NODE_DROP), 0)
            XCTAssertNotEqual(target.resource_drop_action & OMNI_ACTION_HANDLER, 0)
            XCTAssertNotEqual(target.resource_hover_action & OMNI_ACTION_HANDLER, 0)
        }
    }

    func testHTTPBodyUsesOpaqueReadyOwnerResourceWithoutPaths() throws {
        let fixture = try Fixture("""
        local shared
        return {views={compact=function(ctx)
            return ui.box{accepts={'file'},onDrop=function(next,event)
                shared=event.items[1]
                local handle,err=omniwm.http({url='https://upload.example',body=shared},function() end)
                assert(handle==nil and err=='resource_not_ready')
            end,onClick=function(next)
                local handle,err=omniwm.http({url='https://upload.example',method='POST',body=shared},function() end)
                if next.instance.id=='a' then assert(handle and err==nil)
                else assert(handle==nil and err=='resource_denied') end
            end}
        end}}
        """)
        fixture.update()
        let drop = fixture.reserve(try fixture.actions()[0])
        let resources = fixture.admit(drop.0)
        XCTAssertTrue(fixture.deliver(drop, ids: resources))
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, drop.0, drop.1))
        XCTAssertTrue(fixture.metadata(drop.0, id: resources[0]))
        fixture.update()
        for node in try fixture.nodes() where node.action != 0 {
            XCTAssertEqual(omni_instance_invoke(
                fixture.display,
                OMNI_VIEW_BAR,
                node.action,
                0,
                nil,
                0,
                100_000_000,
                &fixture.error,
                fixture.error.count
            ), OMNI_OK, fixture.message)
        }
        var request = omni_service_request()
        XCTAssertTrue(omni_vm_next_service(fixture.vm, &request))
        XCTAssertEqual(request.kind, OMNI_SERVICE_HTTP)
        let value = try XCTUnwrap(request.value)
        let decoded = try ShellHTTPRequest(bytes: Array(UnsafeBufferPointer(start: value, count: request.value_length)))
        XCTAssertEqual(decoded.bodyResource, ShellResourceID(UUID(uuid: resources[0].bytes)))
        XCTAssertNil(decoded.body)
        XCTAssertThrowsError(try decoded.request())
        XCTAssertFalse(omni_vm_next_service(fixture.vm, &request))
    }

    func testAdmissionIsAtomicAndOwnerBounded() throws {
        let fixture = try Fixture()
        let owner = try fixture.owner("a")
        _ = fixture.admit(owner, count: 2, expected: OMNI_ERR_RUNTIME, name: String(repeating: "x", count: 1025))
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, owner), 0)
        for _ in 0 ..< 16 { _ = fixture.admit(owner, count: 32) }
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, owner), 512)
        let rejected = fixture.admit(owner, expected: OMNI_ERR_RUNTIME)
        XCTAssertEqual(UUID(uuid: rejected[0].bytes), UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, owner), 512)
        XCTAssertEqual(fixture.admit(try fixture.owner("b")).count, 1)
    }

    func testDropProxyMetadataAndImagesInvalidateOnlyTheReadingComponent() throws {
        let fixture = try Fixture()
        fixture.update()
        let request = fixture.reserve(try fixture.actions()[0])
        let ids = fixture.admit(request.0)
        XCTAssertTrue(fixture.deliver(request, ids: ids))
        XCTAssertFalse(fixture.deliver(request, ids: ids))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 1)
        fixture.update()
        XCTAssertEqual(try fixture.captions(), ["a:pending", "b:empty"])
        let image = try XCTUnwrap(fixture.nodes().first { $0.resource_image_ref != 0 })
        XCTAssertEqual(image.thumbnail, 128)
        XCTAssertEqual(image.text, 0)
        XCTAssertTrue(fixture.text.string(image.resource_image_ref)
            .contains(UUID(uuid: ids[0].bytes).uuidString.lowercased()))
        XCTAssertTrue(fixture.metadata(request.0, id: ids[0]))
        let steps = fixture.update()
        XCTAssertEqual(steps.filter { $0.kind == OMNI_RENDER_ROOT }.count, 0)
        XCTAssertEqual(steps.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
        XCTAssertEqual(try fixture.captions(), ["a:ready", "b:empty"])
        XCTAssertFalse(fixture.metadata(request.0, id: ids[0]))
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, request.0, request.1))
        XCTAssertFalse(omni_vm_finish_drop(fixture.vm, request.0, request.1))
    }

    func testCancelledIngressKeepsCapacityUntilActualFinish() throws {
        let fixture = try Fixture()
        fixture.update()
        let action = try fixture.actions()[0]
        let requests = (0 ..< 32).map { _ in fixture.reserve(action) }
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).pending, 0)
        for request in requests { XCTAssertTrue(omni_vm_cancel_service(fixture.vm, request.0, request.1)) }
        XCTAssertEqual(fixture.drainCancellations(), 32)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        _ = fixture.reserve(action, expected: OMNI_ERR_RUNTIME)
        let first = requests[0]
        XCTAssertFalse(fixture.deliver(first, ids: []))
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, first.0, first.1))
        let replacement = fixture.reserve(action)
        XCTAssertNotEqual(replacement.1, first.1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
    }

    func testOldCancelledFinishDoesNotDecrementReusedOwnerCapacity() throws {
        let fixture = try Fixture()
        fixture.update()
        let old = fixture.reserve(try fixture.actions()[0])
        let ids = fixture.admit(old.0)
        XCTAssertTrue(omni_vm_cancel_service(fixture.vm, old.0, old.1))
        fixture.configure(["b"])
        fixture.configure(["a", "b"])
        fixture.update()
        let replacementOwner = try fixture.owner("a")
        XCTAssertEqual(replacementOwner.owner, old.0.owner)
        XCTAssertNotEqual(replacementOwner.epoch, old.0.epoch)
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, old.0), 0)
        XCTAssertFalse(fixture.metadata(old.0, id: ids[0]))
        XCTAssertFalse(fixture.deliver(old, ids: ids))
        _ = fixture.drainCancellations()
        let action = try fixture.actions()[0]
        for _ in 0 ..< 32 { _ = fixture.reserve(action) }
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 33)
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, old.0, old.1))
        _ = fixture.reserve(action, expected: OMNI_ERR_RUNTIME)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
    }

    func testForeignResourceCannotEnterADropAndStaleActionStillFinishes() throws {
        let fixture = try Fixture()
        fixture.update()
        let actions = try fixture.actions()
        let a = fixture.reserve(actions[0])
        let b = fixture.reserve(actions[1])
        let ids = fixture.admit(a.0)
        XCTAssertFalse(fixture.deliver(b, ids: ids, expected: OMNI_ERR_RUNTIME))
        let initial = fixture.reserve(try fixture.actions()[0])
        XCTAssertTrue(fixture.deliver(initial, ids: ids))
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, initial.0, initial.1))
        fixture.update()
        for revision in 1 ... 5 {
            XCTAssertTrue(fixture.metadata(a.0, id: ids[0], revision: UInt64(revision)))
            fixture.update()
        }
        XCTAssertFalse(fixture.deliver(a, ids: ids, expected: OMNI_ERR_STALE_ACTION))
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, a.0, a.1))
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, b.0, b.1))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testInventedResourceRecipeAndMalformedDropDeclarationsAreRejected() throws {
        for declaration in [
            "ui.image{image='@omni-resource:invented'}",
            "ui.stack{accepts={'arbitrary'}}",
            "ui.stack{accepts={file=true}}",
            "ui.stack{onDrop=function() end}",
            "ui.stack{accepts={'file'},onDrop='focus left'}",
            "ui.stack{accepts={'file'},mask=true}",
            "ui.image{image='ordinary.png',thumbnail=math.huge}"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return \(declaration) end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, declaration)
        }
    }

    func testDropWithoutCallbackCannotReserveOrTransferResources() throws {
        let fixture = try Fixture("""
        return {views={compact=function(ctx)
            return ui.stack{accepts={'file'},onDropHover=function() end,ui.text{text='hover'}}
        end}}
        """, root: "function render(ctx) return ui.component{id='a'} end")
        fixture.update()
        XCTAssertTrue(try fixture.actions().isEmpty)
        let rejected = fixture.reserve(0, expected: OMNI_ERR_STALE_ACTION)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        let owner = try fixture.owner("a")
        let ids = fixture.admit(owner)
        XCTAssertFalse(fixture.deliver((owner, rejected.1), ids: ids))
        XCTAssertFalse(omni_vm_finish_drop(fixture.vm, owner, rejected.1))
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, owner), 1)
    }

    func testMalformedDropDoesNotTransferOrConsumeTheAcceptedReservation() throws {
        let fixture = try Fixture()
        fixture.update()
        let request = fixture.reserve(try fixture.actions()[0])
        let ids = fixture.admit(request.0)
        XCTAssertFalse(fixture.deliver(request, ids: [], expected: OMNI_ERR_RUNTIME))
        XCTAssertFalse(fixture.deliver(request, ids: Array(repeating: ids[0], count: 33), expected: OMNI_ERR_RUNTIME))
        XCTAssertFalse(fixture.deliver(request, ids: ids, x: .nan, expected: OMNI_ERR_RUNTIME))
        XCTAssertFalse(fixture.deliver(request, ids: ids, y: .infinity, expected: OMNI_ERR_RUNTIME))
        var handled = true
        XCTAssertEqual(
            omni_vm_deliver_drop(
                fixture.vm,
                request.0,
                request.1,
                nil,
                1,
                12,
                34,
                100_000_000,
                &handled,
                &fixture.error,
                fixture.error.count
            ),
            OMNI_ERR_RUNTIME
        )
        XCTAssertFalse(handled)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 1)
        XCTAssertTrue(fixture.deliver(request, ids: ids))
        XCTAssertFalse(fixture.deliver(request, ids: ids))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 1)
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, request.0, request.1))
        XCTAssertFalse(omni_vm_finish_drop(fixture.vm, request.0, request.1))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testThrowingDropCallbacksTransferBeforeFailureAndHoldCleanupCapacity() throws {
        for (failure, message) in [
            ("error('after resource transfer')", "after resource transfer"),
            ("debug.info(2,'f')()", "native delivery has already been consumed")
        ] {
            let fixture = try Fixture("""
            return {views={compact=function(ctx)
                return ui.stack{accepts={'file'},onDrop=function(next,event)
                    assert(#event.items==1 and event.items[1].name=='File.txt')
                    next.instance.state.resource=event.items[1]
                    \(failure)
                end,ui.text{text='drop'}}
            end}}
            """, root: "function render(ctx) return ui.component{id='a'} end")
            fixture.update()
            let request = fixture.reserve(try fixture.actions()[0])
            let ids = fixture.admit(request.0)
            XCTAssertTrue(fixture.deliver(request, ids: ids, expected: OMNI_ERR_COMPONENT))
            XCTAssertTrue(fixture.message.contains(message), fixture.message)
            XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 1)
            XCTAssertFalse(fixture.deliver(request, ids: ids))
            XCTAssertTrue(omni_vm_finish_drop(fixture.vm, request.0, request.1))
            XCTAssertFalse(omni_vm_finish_drop(fixture.vm, request.0, request.1))
            XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        }
    }

    func testCapturedDropWrapperCannotReplayBorrowedResourceList() throws {
        let fixture = try Fixture("""
        local escaped
        local function replay()
            local ok, message = pcall(escaped)
            assert(not ok and string.find(tostring(message), 'native delivery has already been consumed', 1, true))
        end
        return {views={compact=function(ctx)
            if escaped then replay() end
            return ui.stack{accepts={'file'},onDrop=function(next,event)
                escaped=debug.info(2,'f')
                replay()
                assert(#event.items==1 and event.items[1].name=='File.txt')
                next.instance.state.received=true
            end,ui.text{text=tostring(ctx.instance.state.received)}}
        end}}
        """, root: "function render(ctx) return ui.component{id='a'} end")
        fixture.update()
        let request = fixture.reserve(try fixture.actions()[0])
        let ids = fixture.admit(request.0)
        XCTAssertTrue(fixture.deliver(request, ids: ids))
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, request.0, request.1))
        fixture.update()
        XCTAssertEqual(try fixture.captions(), ["true"])
        fixture.configure([])
        fixture.configure(["a"])
        fixture.update()
        XCTAssertEqual(try fixture.captions(), ["nil"])
    }
}
