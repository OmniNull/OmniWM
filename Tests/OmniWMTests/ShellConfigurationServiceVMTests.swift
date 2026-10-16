// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellConfigurationServiceVMTests: XCTestCase {
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

        init(enabled: Bool = true) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            XCTAssertEqual(omni_vm_set_configuration_enabled(vm, enabled), OMNI_OK)
        }

        deinit {
            if let display { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func load(_ source: String) {
            XCTAssertEqual(omni_vm_load(
                vm, "@profile/widgets/root/init.luau", source, source.utf8.count,
                200_000_000, &error, error.count
            ), OMNI_OK, message)
        }

        func component(_ source: String) {
            let path = "profile/widgets/child/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
        }

        func configure(enabled: Bool = true, amount: Int = 7) {
            var writer = ShellValueWriter()
            writer.array(1)
            writer.map(4)
            writer.key("id")
            writer.string("child")
            writer.key("widget")
            writer.string("child")
            writer.key("enabled")
            writer.bool(enabled)
            writer.key("options")
            writer.map(1)
            writer.key("amount")
            writer.number(Double(amount))
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func drain() -> [Request] {
            var requests: [Request] = []
            var request = omni_service_request()
            while omni_vm_next_service(vm, &request) {
                requests.append(Request(
                    kind: request.kind, owner: request.owner, id: request.id, cancelled: request.cancelled,
                    bytes: request.value
                        .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
                ))
            }
            return requests
        }

        @discardableResult
        func complete(_ request: Request, _ bytes: [UInt8]? = nil) -> Bool {
            var writer = ShellValueWriter()
            writer.map(1)
            writer.key("ok")
            writer.bool(true)
            var handled = false
            XCTAssertEqual((bytes ?? writer.bytes).withUnsafeBufferPointer {
                omni_vm_complete_service(
                    vm, request.owner, request.id, 0, $0.baseAddress, $0.count, 200_000_000,
                    &handled, &error, error.count
                )
            }, OMNI_OK, message)
            return handled
        }

        func number(_ name: String) -> Double {
            var value = 0.0
            XCTAssertEqual(omni_vm_global_number(vm, name, &value), OMNI_OK)
            return value
        }

        func instance() throws -> OpaquePointer {
            if let display { return display }
            let result = try XCTUnwrap(omni_instance_create(vm))
            display = result
            return result
        }

        func trigger() throws {
            let instance = try instance()
            var writer = ShellValueWriter()
            writer.map(0)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_trigger(instance, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func render() throws {
            var stats = omni_render_stats()
            XCTAssertEqual(omni_instance_render(
                try instance(), OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count
            ), OMNI_OK, message)
        }
    }

    func testAllOperationPayloadsAndOptionalCallbacks() throws {
        let fixture = try Fixture()
        fixture.load("""
        completed = 0
        assert(omniwm.components.add("clock", { label = "Tokyo" }))
        assert(omniwm.components.remove("clock-a"))
        assert(omniwm.components.move("clock-b", 2))
        assert(omniwm.components.enable("clock-c", false))
        assert(omniwm.components.set("clock-d", "zones", { "UTC", "Asia/Tokyo" }))
        assert(omniwm.config.set("width", 512))
        assert(omniwm.components.add("empty"))
        assert(omniwm.components.add("shorthand", function(result) assert(result.ok); completed += 1 end))
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 8)
        let fields = try requests.map { try XCTUnwrap(ShellServiceValue.decode($0.bytes).fields) }
        XCTAssertEqual(
            fields.map { $0["op"]?.string },
            ["add", "remove", "move", "enable", "set", "rootSetting", "add", "add"]
        )
        XCTAssertEqual(fields[0]["widget"]?.string, "clock")
        XCTAssertEqual(fields[0]["options"]?.fields?["label"]?.string, "Tokyo")
        XCTAssertEqual(fields[1]["id"]?.string, "clock-a")
        XCTAssertEqual(fields[2]["index"]?.number, 2)
        XCTAssertEqual(fields[3]["enabled"]?.boolean, false)
        XCTAssertEqual(fields[4]["value"]?.values?.compactMap(\.string), ["UTC", "Asia/Tokyo"])
        XCTAssertEqual(fields[5]["key"]?.string, "width")
        XCTAssertEqual(fields[5]["value"]?.number, 512)
        XCTAssertEqual(fields[6]["options"]?.fields, [:])
        for request in requests {
            XCTAssertEqual(request.kind, OMNI_SERVICE_CONFIG)
            XCTAssertEqual(request.owner.owner, 0)
            XCTAssertTrue(fixture.complete(request))
        }
        XCTAssertEqual(fixture.number("completed"), 1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testEmptyLuauTablesClearStringOptionsThroughRequestBridge() throws {
        let fixture = try Fixture()
        fixture.load("""
        assert(omniwm.components.add("clock", { zones = {} }))
        assert(omniwm.components.set("clock-a", "zones", {}))
        assert(omniwm.config.set("zones", {}))
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 3)
        let decoded = try requests.map { request in
            try ShellConfigurationRequest(
                id: ShellServiceID(owner: ShellServiceOwner(request.owner), request: request.id),
                bytes: request.bytes
            ).operation
        }
        XCTAssertEqual(decoded, [
            .add(widget: "clock", options: ["zones": .strings([])]),
            .set(id: "clock-a", key: "zones", value: .strings([])),
            .rootSetting(key: "zones", value: .strings([]))
        ])
        let setRequest = try XCTUnwrap(requests.dropFirst().first)
        let fields = try XCTUnwrap(ShellServiceValue.decode(setRequest.bytes).fields)
        XCTAssertEqual(fields["value"], .object([:]))
        for request in requests { XCTAssertTrue(fixture.complete(request)) }
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testOnlyEnabledRootOwnerCanAdmitConfigurationRequests() throws {
        let denied = try Fixture(enabled: false)
        denied.load("""
        local handle, err = omniwm.components.add("clock")
        assert(handle == nil and err == "configuration_denied")
        """)
        XCTAssertTrue(denied.drain().isEmpty)
        let fixture = try Fixture()
        fixture.component("""
        return { views = {}, init = function()
            local handle, err = omniwm.components.add("clock")
            assert(handle == nil and err == "configuration_denied")
            local task = coroutine.create(function()
                local nested, reason = omniwm.config.set("width", 640)
                assert(nested == nil and reason == "configuration_denied")
            end)
            assert(coroutine.resume(task))
        end }
        """)
        fixture.load("""
        function render(ctx)
            assert(ctx.data.components[1].status == "ready")
            return ui.text{ text = "ready" }
        end
        """)
        fixture.configure()
        try fixture.render()
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testMalformedOrOversizedCallsDoNotReserveSlots() throws {
        let fixture = try Fixture()
        fixture.load("""
        local bad = {
            function() return omniwm.components.add(7) end,
            function() return omniwm.components.add("clock", 5) end,
            function() return omniwm.components.move("clock", 1.5) end,
            function() return omniwm.components.enable("clock", 1) end,
            function() return omniwm.components.set("clock", "x", function() end) end,
            function() return omniwm.config.set("x", nil) end,
            function() return omniwm.components.remove("clock", {}) end,
            function() return omniwm.components.add("clock", { x = string.rep("x", 65536) }) end,
        }
        for _, call in bad do local handle, err = call(); assert(handle == nil and type(err) == "string") end
        local cycle = {}; cycle.self = cycle
        local handle, err = omniwm.components.add("clock", cycle)
        assert(handle == nil and err)
        """)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testSlotRemainsReservedUntilDeliveryAndReleasesBeforeCallback() throws {
        let fixture = try Fixture()
        fixture.load("""
        completed = 0
        for index = 1, 32 do
            assert(omniwm.components.move("clock", 1, function(result)
                assert(result.ok)
                completed += 1
                assert(omniwm.components.add("followup"))
            end))
        end
        local handle, err = omniwm.components.add("overload")
        assert(handle == nil and err == "overloaded")
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 32)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        XCTAssertTrue(fixture.complete(try XCTUnwrap(requests.first)))
        XCTAssertEqual(fixture.number("completed"), 1)
        let followup = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(followup.id, requests.last!.id + 1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
    }

    func testCancellationBeforeDispatchDropsRequestAndAfterDispatchDropsCallback() throws {
        let fixture = try Fixture()
        fixture.load("""
        completed = 0
        local early = assert(omniwm.components.add("early"))
        early:cancel()
        local later = assert(omniwm.components.add("later", nil, function() completed += 1 end))
        function trigger() later:cancel() end
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        try fixture.trigger()
        let cancellation = try XCTUnwrap(fixture.drain().first)
        XCTAssertTrue(cancellation.cancelled)
        XCTAssertEqual(cancellation.id, request.id)
        XCTAssertFalse(fixture.complete(request))
        XCTAssertEqual(fixture.number("completed"), 0)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testStructuredCompletionPreservesJSONNullArraysAndBinaryStrings() throws {
        let fixture = try Fixture()
        fixture.load("""
        completed = 0
        assert(omniwm.components.add("clock", nil, function(result)
            assert(result.ok and result.json[1] == json.null)
            assert(json.encode(result.json) == '[null,[],{}]')
            assert(result.bytes == "a" .. string.char(0) .. "b")
            completed += 1
        end))
        """)
        let request = try XCTUnwrap(fixture.drain().first)
        var result = ShellValueWriter()
        result.map(3)
        result.key("ok")
        result.bool(true)
        result.key("json")
        result.array(3)
        result.null()
        result.array(0)
        result.map(0)
        result.key("bytes")
        result.string("a\0b")
        XCTAssertTrue(fixture.complete(request, result.bytes))
        XCTAssertEqual(fixture.number("completed"), 1)
    }

    func testMalformedCompletionIsExplicitAndDoesNotLeakReservation() throws {
        let fixture = try Fixture()
        fixture.load("""
        completed = 0
        assert(omniwm.components.add("clock", nil, function(result)
            assert(result.ok == false and result.error == "invalid_response")
            completed += 1
        end))
        """)
        XCTAssertTrue(fixture.complete(try XCTUnwrap(fixture.drain().first), [255]))
        XCTAssertEqual(fixture.number("completed"), 1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testMetadataIncludesReadonlyEffectiveOptionsForDisabledInstances() throws {
        let fixture = try Fixture()
        fixture.component("return { views = {} }")
        fixture.load("""
        amount = 0
        function render(ctx)
            local component = ctx.data.components[1]
            assert(component.enabled == false and component.status == "disabled")
            assert(not pcall(function() component.options.amount = 0 end))
            amount = component.options.amount
            return ui.text{ text = tostring(amount) }
        end
        """)
        fixture.configure(enabled: false, amount: 7)
        try fixture.render()
        XCTAssertEqual(fixture.number("amount"), 7)
        fixture.configure(enabled: false, amount: 9)
        try fixture.render()
        XCTAssertEqual(fixture.number("amount"), 9)
    }

    func testConfigurationCompletionRemainsBoundedTo64KiB() throws {
        let fixture = try Fixture()
        fixture.load("""
        completed = 0
        assert(omniwm.components.add("clock", nil, function(result)
            assert(result.ok == false and result.error == "invalid_response")
            completed += 1
        end))
        """)
        var writer = ShellValueWriter()
        writer.map(1)
        writer.key("error")
        writer.string(String(repeating: "x", count: 64 << 10))
        XCTAssertTrue(fixture.complete(try XCTUnwrap(fixture.drain().first), writer.bytes))
        XCTAssertEqual(fixture.number("completed"), 1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }
}
