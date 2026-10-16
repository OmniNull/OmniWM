// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellDesktopVMTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let cancelled: Bool
        let bytes: [UInt8]
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
            let root = source + "\nfunction render(ctx) return ui.box{w=10,h=10} end"
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
                        .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
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

        func number(_ name: String) -> Double {
            var number = 0.0
            XCTAssertEqual(omni_vm_global_number(vm, name, &number), OMNI_OK)
            return number
        }
    }

    func testArgumentBoundsAndOptionalCallbacksReserveOnlyValidOperations() throws {
        let fixture = try Fixture("""
        for _,options in {false,{}, {files=false}, {files=true,multiple='yes'}, {files=true,unknown=true}} do
            local handle,message=omniwm.pick(options)
            assert(handle==nil and message=='invalid_request')
        end
        for _,url in {'', 'not-a-url', '123:bad', 'https://a b', string.rep('a',4097)} do
            local handle,message=omniwm.open(url)
            assert(handle==nil and message=='invalid_url')
        end
        for _,url in {'file:///tmp/private','FiLe:/tmp/private'} do
            local handle,message=omniwm.open(url)
            assert(handle==nil and message=='file_url_requires_resource')
        end
        assert(omniwm.reveal('invented-id')==nil)
        assert(omniwm.open({id='invented-id'})==nil)
        assert(omniwm.pick({files=true},42)==nil)
        assert(omniwm.open('https://example.test',42)==nil)
        assert(omniwm.open('https://example.test/path'))
        assert(omniwm.pick({files=true,multiple=true}))
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.kind == OMNI_SERVICE_DESKTOP })
        XCTAssertEqual(
            try ShellServiceValue.decode(requests[0].bytes).fields?["url"]?.string,
            "https://example.test/path"
        )
        XCTAssertEqual(try ShellServiceValue.decode(requests[1].bytes).fields?["multiple"]?.boolean, true)
        fixture.complete(requests[0])
        let resource = fixture.admit(requests[1].owner)
        let result = fixture.picked(requests[1], ids: [resource])
        XCTAssertTrue(result.handled)
        XCTAssertFalse(result.transferred)
        fixture.release(requests[1].owner, id: resource)
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, requests[1].owner), 0)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testPickerBuildsImmutableProxiesReleasesBeforeCallbackAndRejectsCapturedReplay() throws {
        let fixture = try Fixture("""
        local wrapper, resource
        delivered=0
        local function replay()
            local ok,message=pcall(wrapper)
            assert(not ok and string.find(message,'native delivery has already been consumed',1,true))
        end
        for index=1,31 do assert(omniwm.after(1,function() end)) end
        assert(omniwm.pick({files=true},function(result)
            wrapper=debug.info(2,'f')
            replay()
            assert(result.ok and #result.items==1)
            resource=result.items[1]
            assert(resource.name=='Selected.txt' and resource.state=='ready')
            assert(not pcall(function() result.ok=false end))
            assert(not pcall(function() result.items[1]=nil end))
            assert(not pcall(function() resource.name='other' end))
            assert(omniwm.open(resource))
            local handle,message=omniwm.reveal(resource)
            assert(handle==nil and message=='overloaded')
            delivered+=1
        end))
        function trigger()
            replay()
            assert(omniwm.reveal(resource))
        end
        """)
        let requests = fixture.drain()
        let picker = try XCTUnwrap(requests.first { $0.kind == OMNI_SERVICE_DESKTOP })
        let resource = fixture.admit(picker.owner)
        let picked = fixture.picked(picker, ids: [resource])
        XCTAssertTrue(picked.handled)
        XCTAssertTrue(picked.transferred)
        XCTAssertEqual(fixture.number("delivered"), 1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        let opened = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(try ShellServiceValue.decode(opened.bytes).fields?["op"]?.string, "open")
        XCTAssertEqual(
            try ShellServiceValue.decode(opened.bytes).fields?["resource"],
            .bytes(withUnsafeBytes(of: resource) { Array($0) })
        )
        fixture.complete(opened)
        for timer in requests where timer.kind == OMNI_SERVICE_TIMER { fixture.complete(timer) }
        try fixture.trigger()
        let revealed = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(try ShellServiceValue.decode(revealed.bytes).fields?["op"]?.string, "reveal")
        fixture.complete(revealed)
        let duplicate = fixture.picked(picker, ids: [resource])
        XCTAssertFalse(duplicate.handled)
        XCTAssertFalse(duplicate.transferred)
        XCTAssertEqual(fixture.number("delivered"), 1)
    }

    func testMalformedTypedResultsDeliverOneErrorWithoutTransferringResourceOwnership() throws {
        let fixture = try Fixture("""
        failures=0
        for index=1,3 do
            assert(omniwm.pick({files=true},function(result)
                assert(not result.ok and result.error=='invalid_response' and result.items==nil)
                failures+=1
            end))
        end
        assert(omniwm.pick({files=true},function(result)
            assert(result.ok and #result.items==1)
            error('after resource transfer')
        end))
        """, component: "return {views={compact=function() return ui.box{w=1,h=1} end}}")
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 4)
        let resource = fixture.admit(requests[0].owner)
        let foreign = fixture.admit(fixture.owner("a"))
        for result in [
            fixture.picked(requests[0], ids: [resource], metadata: [0]),
            fixture.picked(requests[1], ids: [foreign]),
            fixture.picked(requests[2], ids: [resource, resource])
        ] {
            XCTAssertTrue(result.handled)
            XCTAssertFalse(result.transferred)
        }
        XCTAssertEqual(fixture.number("failures"), 3)
        let throwing = fixture.picked(requests[3], ids: [resource], expected: OMNI_ERR_RUNTIME)
        XCTAssertTrue(throwing.handled)
        XCTAssertTrue(throwing.transferred)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        fixture.release(requests[0].owner, id: resource)
        fixture.release(fixture.owner("a"), id: foreign)
    }

    func testCancellationImmediatelyReleasesPublicCapacityAndSuppressesQueuedTypedDelivery() throws {
        let fixture = try Fixture("""
        local handles={}
        called=0
        for index=1,32 do
            handles[index]=assert(omniwm.pick({files=true},function() called+=1 end))
        end
        assert(omniwm.open('https://example.test')==nil)
        function trigger()
            handles[1]:cancel()
            assert(omniwm.open('https://example.test'))
        end
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 32)
        let resource = fixture.admit(requests[0].owner)
        try fixture.trigger()
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        let next = fixture.drain()
        XCTAssertEqual(next.count, 2)
        XCTAssertTrue(next[0].cancelled)
        XCTAssertEqual(next[0].id, requests[0].id)
        XCTAssertFalse(next[1].cancelled)
        let result = fixture.picked(requests[0], ids: [resource])
        XCTAssertFalse(result.handled)
        XCTAssertFalse(result.transferred)
        XCTAssertEqual(fixture.number("called"), 0)
        fixture.release(requests[0].owner, id: resource)
        fixture.complete(next[1])
        for request in requests.dropFirst() { XCTAssertTrue(omni_vm_cancel_service(
            fixture.vm,
            request.owner,
            request.id
        )) }
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testResourcesRequireReadyCurrentOwnerAndCannotSurviveOwnerReuse() throws {
        let fixture = try Fixture("", component: """
        local saved
        return {
            init=function(instance)
                if instance.options.phase==3 then
                    local handle,message=omniwm.open(saved)
                    assert(handle==nil and message=='resource_denied')
                    print('switch-workspace 3')
                elseif instance.id=='a' then
                    assert(omniwm.pick({files=true},function(result)
                        assert(result.ok)
                        saved=result.items[1]
                        local handle,message=omniwm.open(saved)
                        assert(handle==nil and message=='resource_not_ready')
                    end))
                else
                    assert(omniwm.after(1,function()
                        local handle,message=omniwm.open(saved)
                        assert(handle==nil and message=='resource_denied')
                    end))
                end
            end,
            options=function(instance)
                if instance.id~='a' then return end
                if instance.options.phase==1 then
                    assert(omniwm.open(saved))
                    assert(omniwm.reveal(saved))
                    print('switch-workspace 1')
                elseif instance.options.phase==2 then
                    local handle,message=omniwm.reveal(saved)
                    assert(handle==nil and message=='resource_unavailable')
                    print('switch-workspace 2')
                end
            end,
            views={compact=function() return ui.box{w=1,h=1} end}
        }
        """)
        let requests = fixture.drain()
        let picker = try XCTUnwrap(requests.first { $0.kind == OMNI_SERVICE_DESKTOP })
        let timer = try XCTUnwrap(requests.first { $0.kind == OMNI_SERVICE_TIMER })
        let resource = fixture.admit(picker.owner, ready: false)
        XCTAssertTrue(fixture.picked(picker, ids: [resource]).transferred)
        fixture.complete(timer)
        fixture.update(picker.owner, id: resource)
        fixture.configure(["a", "b"], phase: 1)
        let actions = fixture.drain()
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions
            .allSatisfy { $0.owner.owner == picker.owner.owner && $0.owner.epoch == picker.owner.epoch })
        actions.forEach(fixture.complete)
        fixture.release(picker.owner, id: resource)
        fixture.configure(["a", "b"], phase: 2)
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.configure(["b"], phase: 2)
        fixture.configure(["a", "b"], phase: 3)
        XCTAssertNotEqual(fixture.owner("a").epoch, picker.owner.epoch)
        XCTAssertEqual(fixture.markers(), ["switch-workspace 1", "switch-workspace 2", "switch-workspace 3"])
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testClipboardTextBoundsAndFrozenPublicAPI() throws {
        let fixture = try Fixture("""
        assert(omniwm.clipboard.copy(false)==nil)
        assert(omniwm.clipboard.copy('ok',42)==nil)
        assert(omniwm.clipboard.read()==nil)
        assert(omniwm.clipboard.read(42)==nil)
        assert(omniwm.clipboard.copy(string.rep('x',1048577))==nil)
        assert(not pcall(function() omniwm.clipboard.copy=nil end))
        assert(omniwm.clipboard.copy(string.rep('x',1048576),function(result) assert(result.ok) end))
        assert(omniwm.clipboard.copy(''))
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try ShellServiceValue.decode(requests[0].bytes).fields?["text"]?.string?.utf8.count, 1 << 20)
        let decoded = try ShellDesktopRequest(
            id: ShellServiceID(owner: ShellServiceOwner(requests[0].owner), request: requests[0].id),
            bytes: requests[0].bytes
        )
        guard case let .clipboardText(text) = decoded.action else { return XCTFail("wrong clipboard request") }
        XCTAssertEqual(text.utf8.count, 1 << 20)
        requests.forEach(fixture.complete)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testClipboardReadUsesTypedResourceTransferThenResourceCopy() throws {
        let fixture = try Fixture("""
        assert(omniwm.clipboard.read(function(result)
            assert(result.ok and #result.items==1 and type(result.items[1])=='userdata')
            assert(omniwm.clipboard.copy(result.items[1],function(copy) assert(copy.ok) end))
        end))
        """)
        let read = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(try ShellServiceValue.decode(read.bytes).fields?["op"]?.string, "clipboardRead")
        let resource = fixture.admit(read.owner, kind: "image")
        let result = fixture.picked(read, ids: [resource])
        XCTAssertTrue(result.handled)
        XCTAssertTrue(result.transferred)
        let copy = try XCTUnwrap(fixture.drain().first)
        guard case let .bytes(id) = try ShellServiceValue.decode(copy.bytes).fields?["resource"] else {
            return XCTFail("missing opaque resource ID")
        }
        XCTAssertEqual(id.count, 16)
        fixture.complete(copy)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testClipboardCopyRejectsPendingResourceAndAcceptsItAfterReady() throws {
        let fixture = try Fixture("""
        assert(omniwm.clipboard.read(function(result)
            resource=result.items[1]
            local handle,message=omniwm.clipboard.copy(resource)
            assert(handle==nil and message=='resource_not_ready')
        end))
        function trigger() assert(omniwm.clipboard.copy(resource)) end
        """)
        let request = try XCTUnwrap(fixture.drain().first)
        let resource = fixture.admit(request.owner, ready: false)
        XCTAssertTrue(fixture.picked(request, ids: [resource]).transferred)
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.update(request.owner, id: resource)
        try fixture.trigger()
        XCTAssertEqual(fixture.drain().count, 1)
    }

    func testCancelledClipboardReadNeverTransfersHostResources() throws {
        let fixture = try Fixture("""
        local handle=omniwm.clipboard.read(function() error('cancelled clipboard callback ran') end)
        assert(handle)
        handle:cancel()
        """)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }
}
