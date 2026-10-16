// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellProviderResourceVMTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let cancelled: Bool
        let bytes: [UInt8]
    }

    private final class Fixture {
        let vm: OpaquePointer
        var error = [CChar](repeating: 0, count: 512)

        init(_ source: String) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            let path = "profile/widgets/provider/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            let root = "function render(ctx) return ui.box{w=1,h=1} end"
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
            configure(["a", "b"])
        }

        deinit { _ = omni_vm_destroy(vm) }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func configure(_ ids: [String], phase: Int = 0) {
            var writer = ShellValueWriter()
            writer.array(ids.count)
            for id in ids {
                writer.map(5)
                writer.key("id")
                writer.string(id)
                writer.key("widget")
                writer.string("provider")
                writer.key("enabled")
                writer.bool(true)
                writer.key("provider")
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

        func owner(_ name: String = "a") -> omni_owner_token {
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

        func admit(_ owner: omni_owner_token, count: Int = 1, ready: Bool = true) -> [omni_resource_id] {
            var ids = [omni_resource_id](repeating: omni_resource_id(), count: count)
            let name = "Resource.png"
            let status = name.withCString { name in
                "image".withCString { kind in
                    "public.png".withCString { uti in
                        let descriptor = omni_resource_descriptor(
                            name: name,
                            name_length: 12,
                            kind: kind,
                            kind_length: 5,
                            uti: uti,
                            uti_length: 10
                        )
                        let descriptors = Array(repeating: descriptor, count: count)
                        return descriptors.withUnsafeBufferPointer {
                            omni_vm_admit_resources(vm, owner, $0.baseAddress, $0.count, &ids, &error, error.count)
                        }
                    }
                }
            }
            XCTAssertEqual(status, OMNI_OK, message)
            if ready { for id in ids { update(owner, id: id) } }
            return ids
        }

        func update(_ owner: omni_owner_token, id: omni_resource_id, state: omni_resource_state = OMNI_RESOURCE_READY) {
            var applied = false
            var value = omni_resource_update(
                id: id,
                revision: 1,
                state: state,
                size: 7,
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

        func release(_ owner: omni_owner_token, ids: [omni_resource_id]) {
            XCTAssertTrue(ids
                .withUnsafeBufferPointer { omni_vm_release_resources(vm, owner, $0.baseAddress, $0.count) })
        }

        func pick(_ request: Request, ids: [omni_resource_id]) {
            var writer = ShellValueWriter()
            writer.map(1)
            writer.key("ok")
            writer.bool(true)
            var handled = false
            var transferred = false
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer { metadata in
                ids.withUnsafeBufferPointer { ids in
                    omni_vm_complete_desktop(
                        vm,
                        request.owner,
                        request.id,
                        metadata.baseAddress,
                        metadata.count,
                        ids.baseAddress,
                        ids.count,
                        200_000_000,
                        &handled,
                        &transferred,
                        &error,
                        error.count
                    )
                }
            }, OMNI_OK, message)
            XCTAssertTrue(handled)
            XCTAssertTrue(transferred)
        }

        @discardableResult
        func complete(
            _ request: Request,
            ids: [omni_resource_id] = [],
            ok: Bool = true,
            json: String = "null",
            expected: omni_status = OMNI_OK
        ) -> (handled: Bool, transferred: Bool) {
            var handled = false
            var transferred = false
            XCTAssertEqual(ids.withUnsafeBufferPointer {
                omni_vm_complete_provider(
                    vm,
                    request.owner,
                    request.id,
                    ok,
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
            }, expected, message)
            return (handled, transferred)
        }

        func commands(_ kind: omni_message_kind = OMNI_MESSAGE_REQUEST) -> [String] {
            (0 ..< omni_vm_message_count(vm, kind)).map { index in
                var length = 0
                guard let bytes = omni_vm_message(vm, kind, index, &length) else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
            }
        }
    }

    func testInputEnvelopeDistinguishesDataOnlyEmptyAndThirtyTwoActualResources() throws {
        let fixture = try Fixture("""
        return {init=function(instance)
            if instance.id~='a' then return end
            assert(omniwm.pick({files=true},function(result)
                assert(#result.items==32 and result.items[1].state=='ready' and result.items[2].state=='pending')
                assert(omniwm.provider.send('plain',{n=1}))
                assert(omniwm.provider.send('empty',nil,{files={}}))
                assert(omniwm.provider.send('attached',string.rep('x',65000),{files=result.items}))
            end))
        end,views={}}
        """)
        let picker = try XCTUnwrap(fixture.drain().first)
        let ids = fixture.admit(picker.owner, count: 32, ready: false)
        fixture.update(picker.owner, id: ids[0])
        fixture.pick(picker, ids: ids)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.kind == OMNI_SERVICE_PROVIDER && $0.bytes.count <= 66_560 })
        let fields = try requests.map { try XCTUnwrap(ShellServiceValue.decode($0.bytes, byteLimit: 66_560).fields) }
        XCTAssertNil(fields[0]["files"])
        XCTAssertEqual(fields[0]["argsJSON"]?.string, "{\"n\":1}")
        XCTAssertEqual(fields[1]["files"], .array([]))
        XCTAssertEqual(fields[2]["files"], .array(ids.map { id in .bytes(withUnsafeBytes(of: id) { Array($0) }) }))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 3)
    }

    func testInputListsRejectForgedSparseDuplicateAndOversizedValuesBeforeAdmission() throws {
        let fixture = try Fixture("""
        return {init=function(instance)
            if instance.id~='a' then return end
            assert(omniwm.pick({files=true},function(result)
                local resource=result.items[1]
                local timer=assert(omniwm.after(1,function() end))
                local invalid={false,1,'path',{resource.id},{{id=resource.id}},
                    {timer},{[2]=resource},{[0]=resource},{resource,extra=resource},
                    {resource,resource},table.create(33,resource)}
                for _,files in invalid do
                    local handle,message=omniwm.provider.send('invalid',{}, {files=files})
                    assert(handle==nil and type(message)=='string')
                end
                assert(omniwm.provider.send('badcb',{}, {files={resource}},42)==nil)
                local cyclic={} cyclic.self=cyclic
                assert(omniwm.provider.send('badargs',cyclic,{files={resource}})==nil)
                timer:cancel()
                local empty=setmetatable({}, {__iter=function() error('must not iterate') end})
                for index=1,32 do assert(omniwm.provider.send('bounded',{}, {files=empty})) end
                local rejected,message=omniwm.provider.send('over',{}, {files={resource}})
                assert(rejected==nil and message=='overloaded')
                omniwm.run('switch-workspace 1')
            end))
        end,views={}}
        """)
        let picker = try XCTUnwrap(fixture.drain().first)
        fixture.pick(picker, ids: fixture.admit(picker.owner, ready: false))
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 32)
        XCTAssertTrue(requests.allSatisfy { $0.kind == OMNI_SERVICE_PROVIDER && !$0.cancelled })
        XCTAssertEqual(fixture.commands(), ["switch-workspace 1"])
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, picker.owner), 1)
    }

    func testInputProxyCannotCrossOwnersReleaseFailureOrOwnerRecreation() throws {
        let fixture = try Fixture("""
        local saved
        local function rejected(message)
            local handle,error=omniwm.provider.send('invalid',{}, {files={saved}})
            assert(handle==nil and error==message)
        end
        return {init=function(instance)
            if instance.id~='a' then return end
            if instance.options.phase==3 then
                rejected('resource_denied')
                print('switch-workspace 14')
            else
                assert(omniwm.pick({files=true},function(result) saved=result.items[1] end))
            end
        end,options=function(instance)
            if instance.options.phase==1 then
                if instance.id=='a' then rejected('resource_failed') print('switch-workspace 11')
                else rejected('resource_denied') print('switch-workspace 12') end
            elseif instance.id=='a' and instance.options.phase==2 then
                rejected('resource_unavailable') print('switch-workspace 13')
            end
        end,views={}}
        """)
        let picker = try XCTUnwrap(fixture.drain().first)
        let ids = fixture.admit(picker.owner, ready: false)
        fixture.pick(picker, ids: ids)
        fixture.update(picker.owner, id: ids[0], state: OMNI_RESOURCE_FAILED)
        fixture.configure(["a", "b"], phase: 1)
        fixture.release(picker.owner, ids: ids)
        fixture.configure(["a", "b"], phase: 2)
        fixture.configure(["b"], phase: 2)
        fixture.configure(["a", "b"], phase: 3)
        XCTAssertNotEqual(fixture.owner().epoch, picker.owner.epoch)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(
            fixture.commands(OMNI_MESSAGE_LOG),
            ["switch-workspace 11", "switch-workspace 12", "switch-workspace 13", "switch-workspace 14"]
        )
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testTypedResultIsImmutableConsumesBorrowedInputAndReleasesBeforeCallback() throws {
        let fixture = try Fixture("""
        local wrapper
        local function replay()
            local ok,message=pcall(wrapper)
            assert(not ok and string.find(message,'native delivery has already been consumed',1,true))
        end
        return {init=function(instance)
            if instance.id~='a' then return end
            assert(omniwm.provider.send('first',{}, {files={}},function(result)
                wrapper=debug.info(2,'f')
                replay()
                assert(result.ok and result.value==json.null and #result.files==1)
                local resource=result.files[1]
                assert(resource.name=='Resource.png' and resource.state=='ready')
                assert(not pcall(function() result.ok=false end))
                assert(not pcall(function() result.files[1]=nil end))
                assert(not pcall(function() resource.name='changed' end))
                assert(omniwm.provider.send('replacement',{}, {files={}}))
                local handle,message=omniwm.provider.send('over',{})
                assert(handle==nil and message=='overloaded')
                omniwm.run('switch-workspace 1')
            end))
            for index=2,32 do assert(omniwm.provider.send('held',{})) end
        end,options=function(instance)
            if instance.id=='a' then replay() print('replay-ok') end
        end,views={}}
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 32)
        let first = try XCTUnwrap(requests.first)
        let result = fixture.complete(first, ids: fixture.admit(first.owner))
        XCTAssertTrue(result.handled)
        XCTAssertTrue(result.transferred)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        XCTAssertEqual(fixture.drain().count, 1)
        let duplicate = fixture.complete(first)
        XCTAssertFalse(duplicate.handled)
        XCTAssertFalse(duplicate.transferred)
        fixture.configure(["a", "b"], phase: 1)
        XCTAssertEqual(fixture.commands(), ["switch-workspace 1"])
        XCTAssertEqual(fixture.commands(OMNI_MESSAGE_LOG), ["replay-ok"])
    }

    func testTypedResultRejectsWholeMalformedOrUnreadyBatchAndDataOnlyAttachments() throws {
        let fixture = try Fixture("""
        return {init=function(instance)
            if instance.id~='a' then return end
            for index=1,8 do
                local options={files={}}
                if index==7 then options=nil end
                assert(omniwm.provider.send('result',{},options,function(result)
                    assert(not result.ok and result.error=='invalid_response' and result.files==nil)
                    omniwm.run('switch-workspace 1')
                end))
            end
        end,views={}}
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 8)
        let owner = fixture.owner()
        let ready = fixture.admit(owner)
        let pending = fixture.admit(owner, ready: false)
        let failed = fixture.admit(owner, ready: false)
        fixture.update(owner, id: failed[0], state: OMNI_RESOURCE_FAILED)
        let foreign = fixture.admit(fixture.owner("b"))
        let results = [
            fixture.complete(requests[0], ids: ready, json: "{"),
            fixture.complete(requests[1], ids: ready + foreign),
            fixture.complete(requests[2], ids: ready + ready),
            fixture.complete(requests[3], ids: ready + pending),
            fixture.complete(requests[4], ids: ready + failed),
            fixture.complete(requests[5], ids: Array(repeating: ready[0], count: 33)),
            fixture.complete(requests[6], ids: ready),
            fixture.complete(requests[7], ids: ready, ok: false, json: "\"failed\"")
        ]
        XCTAssertTrue(results.allSatisfy { $0.handled && !$0.transferred })
        XCTAssertEqual(fixture.commands(), Array(repeating: "switch-workspace 1", count: 8))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testOptionalCallbackCancellationAndRetirementNeverTransferLateFiles() throws {
        let fixture = try Fixture("""
        return {init=function(instance)
            if instance.id~='a' then return end
            assert(omniwm.provider.send('noCallback',{}, {files={}}))
            for index=1,2 do
                assert(omniwm.provider.send('late',{}, {files={}},function() error('late result') end))
            end
        end,views={}}
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 3)
        let first = requests[0]
        let ids = fixture.admit(first.owner)
        let noCallback = fixture.complete(first, ids: ids)
        XCTAssertTrue(noCallback.handled)
        XCTAssertFalse(noCallback.transferred)
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, first.owner), 1)
        XCTAssertTrue(omni_vm_cancel_service(fixture.vm, requests[1].owner, requests[1].id))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 1)
        let cancelled = fixture.complete(requests[1], ids: ids)
        XCTAssertFalse(cancelled.handled)
        XCTAssertFalse(cancelled.transferred)
        fixture.release(first.owner, ids: ids)
        fixture.configure(["b"])
        let retired = fixture.complete(requests[2], ids: ids)
        XCTAssertFalse(retired.handled)
        XCTAssertFalse(retired.transferred)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testSuccessfulEmptyFilesAndErrorResultsKeepTheirDistinctTransferMeaning() throws {
        let fixture = try Fixture("""
        return {init=function(instance)
            if instance.id~='a' then return end
            assert(omniwm.provider.send('empty',{}, {files={}},function(result)
                assert(result.ok and #result.files==0 and result.value==json.null)
                omniwm.run('switch-workspace 1')
            end))
            assert(omniwm.provider.send('failure',{}, {files={}},function(result)
                assert(not result.ok and result.error=='provider stopped' and result.files==nil)
                omniwm.run('switch-workspace 2')
            end))
            assert(omniwm.provider.send('data',{},nil,function(result)
                assert(result.ok and result.files==nil and result.value==json.null)
                omniwm.run('switch-workspace 3')
            end))
        end,views={}}
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 3)
        let empty = fixture.complete(requests[0])
        XCTAssertTrue(empty.handled)
        XCTAssertTrue(empty.transferred)
        let failed = fixture.complete(requests[1], ok: false, json: "\"provider stopped\"")
        XCTAssertTrue(failed.handled)
        XCTAssertFalse(failed.transferred)
        let data = fixture.complete(requests[2])
        XCTAssertTrue(data.handled)
        XCTAssertFalse(data.transferred)
        XCTAssertEqual(fixture.commands(), ["switch-workspace 1", "switch-workspace 2", "switch-workspace 3"])
    }

    func testCallbackFailureRetainsTransferAndWrongServiceDoesNotConsumeReservation() throws {
        for failure in ["error('after transfer')", "debug.info(2,'f')()"] {
            let fixture = try Fixture("""
            return {init=function(instance)
                if instance.id~='a' then return end
                assert(omniwm.after(1,function() end))
                assert(omniwm.provider.send('throwing',{}, {files={}},function(result)
                    assert(result.ok and #result.files==1 and result.files[1].state=='ready')
                    \(failure)
                end))
            end,views={}}
            """)
            let requests = fixture.drain()
            let timer = try XCTUnwrap(requests.first { $0.kind == OMNI_SERVICE_TIMER })
            let provider = try XCTUnwrap(requests.first { $0.kind == OMNI_SERVICE_PROVIDER })
            let ids = fixture.admit(provider.owner)
            let wrong = fixture.complete(timer, ids: ids)
            XCTAssertFalse(wrong.handled)
            XCTAssertFalse(wrong.transferred)
            XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 2)
            let throwing = fixture.complete(provider, ids: ids, expected: OMNI_ERR_COMPONENT)
            XCTAssertTrue(throwing.handled)
            XCTAssertTrue(throwing.transferred)
            XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 1)
            XCTAssertEqual(omni_vm_resource_count(fixture.vm, provider.owner), 1)
        }
    }
}
