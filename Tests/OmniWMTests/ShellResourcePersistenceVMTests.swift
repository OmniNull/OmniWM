// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellResourcePersistenceVMTests: XCTestCase {
    private static let saved = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private struct Request {
        let owner: omni_owner_token
        let id: UInt64
        let kind: omni_service_kind
        let cancelled: Bool
        let bytes: [UInt8]

        var operation: String? {
            try? ShellServiceValue.decode(bytes).fields?["op"]?.string
        }
    }

    private final class Fixture {
        let vm: OpaquePointer
        var display: OpaquePointer?
        var error = [CChar](repeating: 0, count: 512)

        init(_ source: String, component: String? = nil, rootError: String = "") throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            if rootError.isEmpty { seed("") }
            else { seed("", count: 0, problem: rootError) }
            if let component {
                let path = "profile/widgets/shelf/component.luau"
                XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
            }
            let root = source + "\nfunction render(ctx) return ui.box{w=1,h=1} end"
            XCTAssertEqual(omni_vm_load(
                vm,
                "@profile/widgets/root/init.luau",
                root,
                root.utf8.count,
                200_000_000,
                &error,
                error.count
            ), OMNI_OK, message)
        }

        deinit {
            if let display { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        @discardableResult
        func seed(
            _ name: String,
            count: Int = 1,
            duplicate: Bool = false,
            problem: String = "",
            expected: omni_status = OMNI_OK
        ) -> omni_status {
            let title = "Saved.txt"
            let kind = "file"
            let uti = "public.data"
            let status = title.withCString { titlePointer in
                kind.withCString { kindPointer in
                    uti.withCString { utiPointer in
                        let descriptor = omni_resource_descriptor(
                            name: titlePointer,
                            name_length: title.utf8.count,
                            kind: kindPointer,
                            kind_length: kind.utf8.count,
                            uti: utiPointer,
                            uti_length: uti.utf8.count
                        )
                        let values = (0 ..< count).map { index -> omni_resource_token_descriptor in
                            var id = omni_resource_id()
                            var uuid =
                                (index == 0 || duplicate ? UUID(uuidString: ShellResourcePersistenceVMTests.saved)! :
                                    UUID()).uuid
                            withUnsafeMutableBytes(of: &id) { destination in
                                withUnsafeBytes(of: &uuid) { destination.copyBytes(from: $0) }
                            }
                            return omni_resource_token_descriptor(token: id, descriptor: descriptor)
                        }
                        return values.withUnsafeBufferPointer {
                            omni_vm_seed_resource_tokens(
                                vm,
                                name,
                                name.utf8.count,
                                $0.baseAddress,
                                $0.count,
                                problem,
                                problem.utf8.count,
                                &error,
                                error.count
                            )
                        }
                    }
                }
            }
            XCTAssertEqual(status, expected, message)
            return status
        }

        func configure(_ ids: [String]) {
            var writer = ShellValueWriter()
            writer.array(ids.count)
            for id in ids {
                writer.map(3)
                writer.key("id")
                writer.string(id)
                writer.key("widget")
                writer.string("shelf")
                writer.key("enabled")
                writer.bool(true)
            }
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func drain() -> [Request] {
            var result: [Request] = []
            var request = omni_service_request()
            while omni_vm_next_service(vm, &request) {
                result.append(Request(
                    owner: request.owner,
                    id: request.id,
                    kind: request.kind,
                    cancelled: request.cancelled,
                    bytes: request.value
                        .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
                ))
            }
            return result
        }

        @discardableResult
        func complete(
            _ request: Request,
            ok: Bool = true,
            revision: UInt64 = 1,
            failure: String = "",
            expected: omni_status = OMNI_OK
        ) -> Bool {
            var handled = false
            XCTAssertEqual(omni_vm_complete_resource(
                vm,
                request.owner,
                request.id,
                ok,
                revision,
                12,
                true,
                failure,
                failure.utf8.count,
                200_000_000,
                &handled,
                &error,
                error.count
            ), expected, message)
            return handled
        }

        func trigger() throws {
            if display == nil { display = try XCTUnwrap(omni_instance_create(vm)) }
            var writer = ShellValueWriter()
            writer.map(0)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_trigger(display!, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func number(_ name: String) -> Double {
            var value = 0.0
            XCTAssertEqual(omni_vm_global_number(vm, name, &value), OMNI_OK)
            return value
        }

        func markers() -> [String] {
            (0 ..< omni_vm_message_count(vm, OMNI_MESSAGE_LOG)).map { index in
                var length = 0
                guard let text = omni_vm_message(vm, OMNI_MESSAGE_LOG, index, &length) else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)
            }
        }
    }

    func testRestoreUsesSeededAuthorityAndBothAdmissionsRemainBounded() throws {
        let fixture = try Fixture("""
        local saved='\(Self.saved)'
        assert(omniwm.resources.restore('11111111-2222-3333-4444-555555555555')==nil)
        assert(omniwm.resources.persist({id=saved})==nil)
        assert(omniwm.resources.persist(saved)==nil)
        local resource=assert(omniwm.resources.restore(saved))
        assert(resource.state=='pending' and resource.name=='Saved.txt')
        assert(not pcall(function() resource.state='ready' end))
        for index=1,31 do assert(omniwm.after(1,function() end)) end
        attempts=0
        function trigger()
            attempts+=1
            local token,message=omniwm.resources.persist(resource)
            if attempts==1 then assert(token==nil and message=='overloaded')
            else
                assert(token and resource.state=='ready' and resource.persistence.state=='pending')
                local restored,problem=omniwm.resources.restore(token)
                assert(restored==nil and problem=='persistence_pending')
            end
        end
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 32)
        let restore = try XCTUnwrap(requests.first { $0.operation == "restore" })
        try fixture.trigger()
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        XCTAssertTrue(fixture.complete(restore))
        try fixture.trigger()
        let persist = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(persist.operation, "persist")
        XCTAssertEqual(persist.bytes.count < 256, true)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        XCTAssertEqual(omni_vm_resource_count(fixture.vm, restore.owner), 1)
    }

    func testPersistencePublishesReadonlyDurabilityBeforeReentrantCallbackAndConsumesWrapper() throws {
        let fixture = try Fixture("""
        local resource=assert(omniwm.resources.restore('\(Self.saved)'))
        local wrapper,token
        delivered=0
        for index=1,31 do assert(omniwm.after(1,function() end)) end
        local function replay()
            local ok,message=pcall(wrapper)
            assert(not ok and string.find(message,'native delivery has already been consumed',1,true))
        end
        function trigger()
            if delivered>0 then replay() return end
            token=assert(omniwm.resources.persist(resource,function(result)
                wrapper=debug.info(2,'f')
                replay()
                assert(result.ok and result.token==token)
                assert(resource.persistence.state=='durable' and resource.persistence.token==token)
                assert(not pcall(function() resource.persistence.state='failed' end))
                assert(not pcall(function() result.ok=false end))
                assert(omniwm.after(1,function() end))
                delivered+=1
            end))
        end
        """)
        let requests = fixture.drain()
        XCTAssertTrue(fixture.complete(try XCTUnwrap(requests.first { $0.operation == "restore" })))
        try fixture.trigger()
        let persist = try XCTUnwrap(fixture.drain().first)
        XCTAssertTrue(fixture.complete(persist))
        XCTAssertEqual(fixture.number("delivered"), 1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        try fixture.trigger()
        XCTAssertFalse(fixture.complete(persist))
        XCTAssertEqual(fixture.number("delivered"), 1)
    }

    func testFailedAndMalformedPersistenceStayVisibleWithoutGrantingRestoreAuthority() throws {
        let fixture = try Fixture("""
        local resource=assert(omniwm.resources.restore('\(Self.saved)'))
        local token=assert(omniwm.resources.persist(resource))
        stage=0
        function trigger()
            stage+=1
            if stage==1 then
                assert(resource.persistence.state=='failed' and resource.persistence.error=='disk_failure')
                local restored,message=omniwm.resources.restore(token)
                assert(restored==nil and message=='unknown_resource_token')
                token=assert(omniwm.resources.persist(resource,function(result)
                    assert(not result.ok and result.error=='invalid_response')
                    assert(resource.persistence.state=='failed' and resource.persistence.error=='invalid_response')
                    stage+=1
                end))
            end
        end
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first { $0.operation == "persist" })
        XCTAssertTrue(fixture.complete(first, ok: false, failure: "disk_failure"))
        try fixture.trigger()
        let retry = try XCTUnwrap(fixture.drain().first)
        XCTAssertTrue(fixture.complete(retry, ok: false))
        XCTAssertEqual(fixture.number("stage"), 2)
        XCTAssertTrue(fixture.complete(try XCTUnwrap(requests.first { $0.operation == "restore" })))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testDeinitPreservesOnlyUndrainedPersistPayloadAndDoesNotReviveOldCallback() throws {
        let fixture = try Fixture("", component: """
        return {
            init=function(instance)
                instance.state.resource=assert(omniwm.resources.restore('\(Self.saved)'))
                print('switch-workspace 1')
            end,
            deinit=function(instance)
                local token=assert(omniwm.resources.persist(instance.state.resource,function()
                    print('switch-workspace 99')
                end))
                assert(omniwm.store.set('resource',token))
                print('switch-workspace 2')
            end,
            views={compact=function() return ui.box{w=1,h=1} end}
        }
        """)
        fixture.seed("a")
        fixture.configure(["a"])
        let restore = try XCTUnwrap(fixture.drain().first { $0.operation == "restore" })
        XCTAssertTrue(fixture.complete(restore))
        fixture.configure([])
        let cancelled = fixture.drain()
        let detached = try XCTUnwrap(cancelled.first { $0.operation == "persist" })
        XCTAssertTrue(detached.cancelled)
        XCTAssertTrue(cancelled.contains { $0.kind == OMNI_SERVICE_STORE && $0.cancelled })
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        XCTAssertFalse(fixture.complete(detached))
        XCTAssertEqual(fixture.markers(), ["switch-workspace 1", "switch-workspace 2"])

        let dispatched = try Fixture("""
        local resource=assert(omniwm.resources.restore('\(Self.saved)'))
        local token=assert(omniwm.resources.persist(resource))
        """)
        let live = dispatched.drain()
        let persist = try XCTUnwrap(live.first { $0.operation == "persist" })
        XCTAssertTrue(omni_vm_cancel_service(dispatched.vm, persist.owner, persist.id))
        let cancelledPersist = try XCTUnwrap(dispatched.drain().first)
        XCTAssertTrue(cancelledPersist.cancelled)
        XCTAssertEqual(cancelledPersist.id, persist.id)
        XCTAssertTrue(cancelledPersist.bytes.isEmpty)
    }

    func testSeedReplacementIsAtomicBoundedAndIsolatedByConfiguredOwnerName() throws {
        let fixture = try Fixture("", component: """
        return {
            init=function(instance)
                local resource,message=omniwm.resources.restore('\(Self.saved)')
                if instance.id=='a' then
                    assert(resource and resource.name=='Saved.txt')
                    local token,problem=omniwm.resources.persist(resource)
                    assert(token==nil and problem=='resource_token_limit')
                    print('switch-workspace 1')
                else
                    assert(resource==nil and message=='unknown_resource_token')
                    print('switch-workspace 2')
                end
            end,
            views={compact=function() return ui.box{w=1,h=1} end}
        }
        """)
        fixture.seed("a", count: 4096)
        fixture.seed("a", count: 4097, expected: OMNI_ERR_RUNTIME)
        fixture.seed("a", count: 2, duplicate: true, expected: OMNI_ERR_RUNTIME)
        fixture.configure(["a", "b"])
        XCTAssertEqual(fixture.markers(), ["switch-workspace 1", "switch-workspace 2"])
        XCTAssertEqual(fixture.drain().filter { $0.operation == "restore" }.count, 1)
        let failed = try Fixture("""
        local resource,message=omniwm.resources.restore('\(Self.saved)')
        assert(resource==nil and message=='manifest_unavailable')
        """, rootError: "manifest_unavailable")
        XCTAssertEqual(omni_vm_service_stats(failed.vm).reserved, 0)
    }
}
