// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellDesktopPresentationVMTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let cancelled: Bool
        let bytes: [UInt8]
        let source: UInt64
    }

    private final class Fixture {
        let vm: OpaquePointer
        var display: OpaquePointer?
        var error = [CChar](repeating: 0, count: 512)

        init(_ source: String, component: String? = nil) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            if let component {
                let path = "profile/widgets/desktop/component.luau"
                XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
            }
            let root = source
            XCTAssertEqual(omni_vm_load(
                vm,
                "@profile/widgets/root/init.luau",
                root,
                root.utf8.count,
                200_000_000,
                &error,
                error.count
            ), OMNI_OK, message)
            if component != nil { configure(["a", "b"]) }
        }

        deinit {
            if let display { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func configure(_ ids: [String], phase: Int = 0) {
            var writer = ShellValueWriter()
            writer.array(ids.count)
            for id in ids {
                writer.map(4)
                writer.key("id")
                writer.string(id)
                writer.key("widget")
                writer.string("desktop")
                writer.key("enabled")
                writer.bool(true)
                writer.key("options")
                writer.map(1)
                writer.key("phase")
                writer.number(Double(phase))
            }
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func owner(_ name: String) -> omni_owner_token {
            var owner = omni_owner_token()
            XCTAssertTrue(omni_vm_component_owner(vm, name, name.utf8.count, &owner))
            return owner
        }

        func drain() -> [Request] {
            var result: [Request] = []
            var request = omni_service_request()
            while omni_vm_next_service(vm, &request) {
                result.append(Request(
                    kind: request.kind,
                    owner: request.owner,
                    id: request.id,
                    cancelled: request.cancelled,
                    bytes: request.value
                        .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? [],
                    source: request.surface
                ))
            }
            return result
        }

        func admit(_ owner: omni_owner_token, kind: String = "file", ready: Bool = true) -> omni_resource_id {
            var id = omni_resource_id()
            let name = "Selected.txt"
            let uti = "public.text"
            let status = name.withCString { namePointer in
                kind.withCString { kindPointer in
                    uti.withCString { utiPointer in
                        var descriptor = omni_resource_descriptor(
                            name: namePointer,
                            name_length: name.utf8.count,
                            kind: kindPointer,
                            kind_length: kind.utf8.count,
                            uti: utiPointer,
                            uti_length: uti.utf8.count
                        )
                        return omni_vm_admit_resources(vm, owner, &descriptor, 1, &id, &error, error.count)
                    }
                }
            }
            XCTAssertEqual(status, OMNI_OK, message)
            if ready { update(owner, id: id) }
            return id
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

        func release(_ owner: omni_owner_token, id: omni_resource_id) {
            var value = id
            XCTAssertTrue(omni_vm_release_resources(vm, owner, &value, 1))
        }

        func complete(_ request: Request) {
            var writer = ShellValueWriter()
            writer.map(1)
            writer.key("ok")
            writer.bool(true)
            var handled = false
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_complete_service(
                    vm,
                    request.owner,
                    request.id,
                    0,
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

        func picked(
            _ request: Request,
            ids: [omni_resource_id],
            metadata: [UInt8]? = nil,
            expected: omni_status = OMNI_OK
        ) -> (handled: Bool, transferred: Bool) {
            var writer = ShellValueWriter()
            writer.map(1)
            writer.key("ok")
            writer.bool(true)
            var handled = false
            var transferred = false
            XCTAssertEqual((metadata ?? writer.bytes).withUnsafeBufferPointer { payload in
                ids.withUnsafeBufferPointer { ids in
                    omni_vm_complete_desktop(
                        vm,
                        request.owner,
                        request.id,
                        payload.baseAddress,
                        payload.count,
                        ids.baseAddress,
                        ids.count,
                        200_000_000,
                        &handled,
                        &transferred,
                        &error,
                        error.count
                    )
                }
            }, expected, message)
            return (handled, transferred)
        }

        func trigger() throws {
            if display == nil { display = try XCTUnwrap(omni_instance_create(vm)) }
            var writer = ShellValueWriter()
            writer.map(0)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_trigger(display!, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func markers() -> [String] {
            (0 ..< omni_vm_message_count(vm, OMNI_MESSAGE_LOG)).map { index in
                var length = 0
                guard let bytes = omni_vm_message(vm, OMNI_MESSAGE_LOG, index, &length) else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
            }
        }

        func render() throws -> [omni_wire_node] {
            if display == nil { display = try XCTUnwrap(omni_instance_create(vm)) }
            var stats = omni_render_stats()
            XCTAssertEqual(
                omni_instance_render(display!, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count),
                OMNI_OK,
                message
            )
            var count = 0
            let bytes = try XCTUnwrap(omni_instance_output(display!, OMNI_VIEW_BAR, &count))
            let buffer = UnsafeRawBufferPointer(start: bytes, count: count)
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            return (0 ..< Int(header.node_count)).map {
                buffer.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                )
            }
        }

        func invoke(_ action: UInt32, source: UInt64 = 0x1_0000_0001) {
            XCTAssertEqual(
                omni_instance_invoke(display!, OMNI_VIEW_BAR, action, source, nil, 0, 200_000_000, &error, error.count),
                OMNI_OK,
                message
            )
        }

        func locator(_ request: Request) throws -> omni_desktop_anchor {
            let value = try ShellServiceValue.decode(request.bytes)
            guard case let .bytes(bytes) = value.fields?["anchor"] else { throw ShellResourceFailure("missing_anchor") }
            return try ShellDesktopAnchorLocator(bytes: bytes).wire
        }

        func resolve(_ request: Request, expected: omni_status = OMNI_OK) throws -> [omni_anchor_step] {
            let locator = try locator(request)
            var count = 0
            var steps = [omni_anchor_step](repeating: omni_anchor_step(), count: 65)
            XCTAssertEqual(steps.withUnsafeMutableBufferPointer {
                omni_instance_resolve_anchor(
                    display!,
                    OMNI_VIEW_BAR,
                    request.owner,
                    locator,
                    $0.baseAddress,
                    $0.count,
                    &count,
                    &error,
                    error.count
                )
            }, expected, message)
            return Array(steps.prefix(count))
        }

        func provideResources() throws {
            for request in drain() {
                let resource = admit(request.owner)
                XCTAssertTrue(picked(request, ids: [resource]).transferred)
            }
        }

        func number(_ name: String) -> Double {
            var number = 0.0
            XCTAssertEqual(omni_vm_global_number(vm, name, &number), OMNI_OK)
            return number
        }
    }

    private let component = """
    return {
        init = function(instance)
            omniwm.pick({files=true}, function(result) instance.state.resource=result.items[1] end)
        end,
        views = {compact=function(ctx)
            return ui.box{w=50,h=20,ui.text{key='share',text=ctx.instance.id,onClick=function(next)
                assert(omniwm.share({next.instance.state.resource},'share',function(result) assert(result.ok) end))
            end}}
        end}
    }
    """

    func testSameKeyInTwoComponentsResolvesTheirOwnMountAncestry() throws {
        let fixture = try Fixture("""
        function render() return ui.row{ui.component{id='a'},ui.component{id='b'}} end
        """, component: component)
        try fixture.provideResources()
        let actions = try fixture.render().map(\.action).filter { $0 != 0 }
        XCTAssertEqual(actions.count, 2)
        for action in actions { fixture.invoke(action) }
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first)
        let second = try XCTUnwrap(requests.last)
        XCTAssertNotEqual(first.owner.owner, second.owner.owner)
        XCTAssertEqual(first.source, 0x1_0000_0001)
        let a = try fixture.resolve(first)
        let b = try fixture.resolve(second)
        XCTAssertEqual(a.count, 4)
        XCTAssertEqual(b.count, 4)
        XCTAssertEqual(a[1].child, 0)
        XCTAssertEqual(b[1].child, 1)
        XCTAssertNotEqual(a[1].key, b[1].key)
        XCTAssertEqual(a.last?.key, b.last?.key)
        fixture.complete(first)
        fixture.complete(second)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testLocatorResolvesCurrentPublicationAfterSiblingInsertionAndRejectsRetiredOwner() throws {
        let fixture = try Fixture("""
        phase=0
        function trigger() phase+=1 end
        function render()
            local result=ui.row{}
            if phase>0 then table.insert(result,ui.text{key='new',text='new'}) end
            table.insert(result,ui.component{id='a'})
            table.insert(result,ui.component{id='b'})
            return result
        end
        """, component: component)
        try fixture.provideResources()
        fixture.invoke(try XCTUnwrap(fixture.render().first { $0.action != 0 }).action)
        let request = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(try fixture.resolve(request)[1].child, 0)
        try fixture.trigger()
        _ = try fixture.render()
        XCTAssertEqual(try fixture.resolve(request)[1].child, 1)
        fixture.configure(["b"])
        _ = try fixture.render()
        XCTAssertTrue(try fixture.resolve(request, expected: OMNI_ERR_STALE_ACTION).isEmpty)
    }

    func testAmbiguousRepeatedMountCannotReserveShareAndStringResetInvalidatesLocator() throws {
        let checking = component.replacingOccurrences(
            of: "assert(omniwm.share({next.instance.state.resource},'share',function(result) assert(result.ok) end))",
            with: "local h,e=omniwm.share({next.instance.state.resource},'share'); assert(h==nil and e=='anchor_ambiguous')"
        )
        let repeated = try Fixture("""
        function render() return ui.row{ui.component{id='a'},ui.component{id='a'}} end
        """, component: checking)
        try repeated.provideResources()
        repeated.invoke(try XCTUnwrap(repeated.render().first { $0.action != 0 }).action)
        XCTAssertTrue(repeated.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(repeated.vm).reserved, 0)

        let single = try Fixture("function render() return ui.component{id='a'} end", component: component)
        try single.provideResources()
        single.invoke(try XCTUnwrap(single.render().first { $0.action != 0 }).action)
        let request = try XCTUnwrap(single.drain().first)
        omni_vm_reset_strings(single.vm)
        _ = try single.render()
        XCTAssertTrue(try single.resolve(request, expected: OMNI_ERR_STALE_ACTION).isEmpty)
    }

    func testStrictResourceListsIndicesAndCallbacksOnlyReserveValidPreviewAndShare() throws {
        let fixture = try Fixture("""
        omniwm.pick({files=true},function(result) resource=result.items[1] end)
        function render()
            return ui.box{key='share',w=20,h=20,onClick=function()
                for _,items in {{},{'fake'},{resource,resource},{[1]=resource,extra=resource}} do
                    assert(omniwm.quicklook(items)==nil)
                end
                assert(omniwm.quicklook({resource},0)==nil)
                assert(omniwm.quicklook({resource},2)==nil)
                assert(omniwm.quicklook({resource},1.5)==nil)
                assert(omniwm.quicklook({resource},1,false)==nil)
                assert(omniwm.share({resource},'missing')==nil)
                assert(omniwm.share({resource},'share','other')==nil)
                assert(omniwm.share({resource},'share',nil,false)==nil)
                assert(omniwm.quicklook({resource},function(r) assert(r.ok) end))
                assert(omniwm.share({resource},'share','airdrop',function(r) assert(r.ok) end))
            end}
        end
        """)
        try fixture.provideResources()
        fixture.invoke(try XCTUnwrap(fixture.render().first).action)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        let preview = try XCTUnwrap(requests.first)
        let sharing = try XCTUnwrap(requests.last)
        XCTAssertEqual(try ShellServiceValue.decode(preview.bytes).fields?["index"]?.number, 1)
        XCTAssertEqual(try ShellServiceValue.decode(sharing.bytes).fields?["service"]?.string, "airdrop")
        XCTAssertEqual(try fixture.resolve(sharing).count, 1)
        fixture.complete(preview)
        fixture.complete(sharing)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testShareWithoutPhysicalSourceRejectsBeforeReservation() throws {
        let fixture = try Fixture("""
        omniwm.pick({files=true},function(result) resource=result.items[1] end)
        function render() return ui.box{key='share',w=20,h=20,onClick=function()
            local h,e=omniwm.share({resource},'share'); assert(h==nil and e=='source_surface_unavailable')
        end} end
        """)
        try fixture.provideResources()
        fixture.invoke(try XCTUnwrap(fixture.render().first).action, source: 0)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(MemoryLayout<omni_desktop_anchor>.stride, 24)
        XCTAssertEqual(MemoryLayout<omni_anchor_step>.stride, 16)
    }

    func testImageBackingIsAcceptedForPreviewAndShare() throws {
        let fixture = try Fixture("""
        omniwm.pick({files=true},function(result) resource=result.items[1] end)
        function render() return ui.box{key='image',w=20,h=20,onClick=function()
            assert(omniwm.quicklook({resource}))
            assert(omniwm.share({resource},'image'))
        end} end
        """)
        let pick = try XCTUnwrap(fixture.drain().first)
        XCTAssertTrue(fixture.picked(pick, ids: [fixture.admit(pick.owner, kind: "image")]).transferred)
        fixture.invoke(try XCTUnwrap(fixture.render().first).action)
        XCTAssertEqual(fixture.drain().count, 2)
    }
}
