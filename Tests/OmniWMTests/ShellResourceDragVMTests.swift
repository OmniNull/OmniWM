// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellResourceDragVMTests: XCTestCase {
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

        func render(expected: omni_status = OMNI_OK) throws -> [omni_wire_node] {
            if display == nil { display = try XCTUnwrap(omni_instance_create(vm)) }
            var stats = omni_render_stats()
            let status = omni_instance_render(display!, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count)
            XCTAssertEqual(status, expected, message)
            if status != OMNI_OK { return [] }
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

        func provideResources() throws {
            for request in drain() where request.kind == OMNI_SERVICE_DESKTOP && !request.cancelled {
                let resource = admit(request.owner)
                XCTAssertTrue(picked(request, ids: [resource]).transferred)
            }
        }

        func reserve(
            _ node: omni_wire_node,
            expected: omni_status = OMNI_OK,
            source: UInt64 = 91
        ) -> (omni_owner_token, UInt64, [omni_resource_id]) {
            var owner = omni_owner_token()
            var id: UInt64 = 0
            var count = 0
            var items = [omni_resource_id](repeating: omni_resource_id(), count: 32)
            XCTAssertEqual(items.withUnsafeMutableBufferPointer {
                omni_instance_reserve_drag(
                    display!,
                    OMNI_VIEW_BAR,
                    node.resource_drag_ref,
                    node.resource_drag_action,
                    source,
                    &owner,
                    &id,
                    $0.baseAddress,
                    $0.count,
                    &count,
                    &error,
                    error.count
                )
            }, expected, message)
            return (owner, id, Array(items.prefix(count)))
        }

        @discardableResult
        func begin(_ request: (omni_owner_token, UInt64, [omni_resource_id]), expected: omni_status = OMNI_OK) -> Bool {
            var handled = false
            XCTAssertEqual(
                omni_vm_begin_drag(vm, request.0, request.1, 200_000_000, &handled, &error, error.count),
                expected,
                message
            )
            return handled
        }

        @discardableResult
        func finish(
            _ request: (omni_owner_token, UInt64, [omni_resource_id]),
            copied: Bool = true,
            deliver: Bool = true
        ) -> Bool {
            var handled = false
            XCTAssertEqual(omni_vm_finish_drag(
                vm,
                request.0,
                request.1,
                copied,
                deliver,
                200_000_000,
                &handled,
                &error,
                error.count
            ), OMNI_OK, message)
            return handled
        }

        func number(_ name: String) -> Double {
            var number = 0.0
            XCTAssertEqual(omni_vm_global_number(vm, name, &number), OMNI_OK)
            return number
        }
    }

    func testBeganAndEndAreOnceAndCapturedAfterSourceUIChanges() throws {
        let fixture = try Fixture("""
        resource=nil; calls=0; ended=0; hidden=false
        assert(omniwm.pick({files=true},function(r) resource=r.items[1] end))
        function render()
            if hidden then return ui.text{text='closed'} end
            return ui.box{w=30,h=20,dragItems={resource},onDragOut=function(ctx,e)
                calls+=1
                assert(table.isfrozen(e))
                if e.phase=='began' then assert(e.operation=='none'); hidden=true
                else assert(e.operation=='copy'); ended+=1 end
            end}
        end
        """)
        try fixture.provideResources()
        let node = try XCTUnwrap(fixture.render().first)
        XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 392)
        XCTAssertNotEqual(node.resource_drag_ref & OMNI_ACTION_HANDLER, 0)
        let request = fixture.reserve(node)
        XCTAssertEqual(request.2.count, 1)
        XCTAssertTrue(fixture.begin(request))
        XCTAssertFalse(fixture.begin(request))
        XCTAssertEqual(try fixture.render().first?.resource_drag_ref, 0)
        XCTAssertTrue(fixture.finish(request))
        XCTAssertFalse(fixture.finish(request))
        XCTAssertEqual(fixture.number("calls"), 2)
        XCTAssertEqual(fixture.number("ended"), 1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testTwoComponentDeclarationsAndCallbacksStayOwnerScoped() throws {
        let fixture = try Fixture(
            "function render() return ui.row{ui.component{id='a'},ui.component{id='b'}} end",
            component: """
            return {
                init=function(i) omniwm.pick({files=true},function(r) i.state.r=r.items[1] end) end,
                views={compact=function(ctx) return ui.box{w=20,h=20,dragItems={ctx.instance.state.r},
                    onDragOut=function(c,e) if e.phase=='ended' then omniwm.log(c.instance.id) end end} end}
            }
            """
        )
        try fixture.provideResources()
        let nodes = try fixture.render().filter { $0.resource_drag_ref != 0 }
        XCTAssertEqual(nodes.count, 2)
        var forged = nodes[0]
        forged.resource_drag_action = nodes[1].resource_drag_action
        XCTAssertEqual(fixture.reserve(forged, expected: OMNI_ERR_STALE_ACTION).1, 0)
        let a = fixture.reserve(nodes[0])
        let b = fixture.reserve(nodes[1])
        XCTAssertNotEqual(a.0.owner, b.0.owner)
        XCTAssertNotEqual(a.1, b.1)
        XCTAssertTrue(fixture.begin(a))
        XCTAssertTrue(fixture.begin(b))
        XCTAssertTrue(fixture.finish(b))
        XCTAssertTrue(fixture.finish(a))
        XCTAssertEqual(fixture.markers(), ["b", "a"])
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testNativeOnlyDeclarationAndStalePreflightNeverCallLua() throws {
        let fixture = try Fixture("""
        resource=nil; hidden=false
        omniwm.pick({files=true},function(r) resource=r.items[1] end)
        function trigger() hidden=true end
        function render() return hidden and ui.box{} or ui.box{dragItems={resource}} end
        """)
        try fixture.provideResources()
        let node = try XCTUnwrap(fixture.render().first)
        let ready = fixture.reserve(node)
        XCTAssertFalse(fixture.begin(ready))
        XCTAssertFalse(fixture.finish(ready))
        let abandoned = fixture.reserve(node)
        try fixture.trigger()
        _ = try fixture.render()
        XCTAssertFalse(fixture.finish(abandoned))
        XCTAssertEqual(fixture.reserve(node, expected: OMNI_ERR_STALE_ACTION).1, 0)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testActualBeginUsesAcceptedCaptureWhenVMTreeAdvancedBeforeCallbackDelivery() throws {
        let fixture = try Fixture("""
        resource=nil; hidden=false; calls=0
        omniwm.pick({files=true},function(r) resource=r.items[1] end)
        function trigger() hidden=true end
        function render()
            return hidden and ui.box{} or ui.box{dragItems={resource},onDragOut=function() calls+=1 end}
        end
        """)
        try fixture.provideResources()
        let node = try XCTUnwrap(fixture.render().first)
        let request = fixture.reserve(node)
        try fixture.trigger()
        _ = try fixture.render()
        XCTAssertTrue(fixture.begin(request))
        XCTAssertTrue(fixture.finish(request))
        XCTAssertEqual(fixture.number("calls"), 2)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testCancelAndOwnerSlotReuseKeepPhysicalCapacityUntilFinish() throws {
        let fixture = try Fixture(
            "function render() return ui.row{ui.component{id='a'},ui.component{id='b'},ui.component{id='c'}} end",
            component: """
            return {
                init=function(i) omniwm.pick({files=true},function(r) i.state.r=r.items[1] end) end,
                views={compact=function(ctx) return ui.box{dragItems={ctx.instance.state.r}} end}
            }
            """
        )
        try fixture.provideResources()
        let oldNode = try XCTUnwrap(fixture.render().first { $0.resource_drag_ref != 0 })
        let old = fixture.reserve(oldNode)
        fixture.configure(["b", "c"])
        try fixture.provideResources()
        let c = fixture.owner("c")
        XCTAssertEqual(old.0.owner, c.owner)
        XCTAssertNotEqual(old.0.epoch, c.epoch)
        let nodes = try fixture.render().filter { $0.resource_drag_ref != 0 }
        let current = try XCTUnwrap(nodes.last)
        let requests = (0 ..< 32).map { _ in fixture.reserve(current) }
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 33)
        XCTAssertFalse(fixture.finish(old))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        XCTAssertEqual(fixture.reserve(current, expected: OMNI_ERR_RUNTIME).1, 0)
        for request in requests { XCTAssertFalse(fixture.finish(request, deliver: false)) }
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testTerminalReleasesCapacityBeforeCallbackAndCapturedNativeWrapperIsInert() throws {
        let fixture = try Fixture("""
        resource=nil; calls=0; replay=nil
        omniwm.pick({files=true},function(r) resource=r.items[1] end)
        function trigger() assert(not pcall(replay)); assert(calls==2) end
        function render() return ui.box{dragItems={resource},onDragOut=function(ctx,e)
            calls+=1; replay=debug.info(2,'f')
            if e.phase=='ended' then assert(omniwm.after(0.1,function() end)) end
        end} end
        """)
        try fixture.provideResources()
        let node = try XCTUnwrap(fixture.render().first)
        let requests = (0 ..< 32).map { _ in fixture.reserve(node) }
        XCTAssertTrue(fixture.begin(requests[0]))
        XCTAssertTrue(fixture.finish(requests[0]))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        try fixture.trigger()
        let timer = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(timer.kind, OMNI_SERVICE_TIMER)
        XCTAssertEqual(timer.source, 91)
        for request in requests.dropFirst() { fixture.finish(request, deliver: false) }
        fixture.complete(timer)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testDragDeclarationsRejectInvalidResourcesAndConflictingInputPolicies() throws {
        for property in [
            "dragItems={}",
            "dragItems={'forged'}",
            "dragItems={resource,resource}",
            "dragItems={resource},drag=true",
            "dragItems={resource},target='x'",
            "dragItems={resource},mask=true",
            "dragItems={resource},gesture={axis='x'}",
            "onDragOut=function() end",
            "dragItems={resource},onDragOut='run'"
        ] {
            let fixture = try Fixture("""
            resource=nil; omniwm.pick({files=true},function(r) resource=r.items[1] end)
            function render() return ui.box{\(property)} end
            """)
            try fixture.provideResources()
            XCTAssertTrue(try fixture.render(expected: OMNI_ERR_RUNTIME).isEmpty, property)
            XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        }
    }
}
