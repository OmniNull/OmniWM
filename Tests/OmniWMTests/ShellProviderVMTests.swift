// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellProviderVMTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let cancelled: Bool
        let bytes: [UInt8]
    }

    private final class Fixture {
        let vm: OpaquePointer
        var displays: [OpaquePointer] = []
        let text = ShellTextStore()
        var error = [CChar](repeating: 0, count: 512)

        init(
            _ source: String,
            provider: Bool = true,
            root: String = "function render(ctx) return ui.component{ id='child' } end"
        ) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            let path = "profile/widgets/child/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            XCTAssertEqual(omni_vm_load(
                vm, "@profile/widgets/root/init.luau", root, root.utf8.count,
                200_000_000, &error, error.count
            ), OMNI_OK, message)
            configure(provider: provider)
        }

        deinit {
            for display in displays { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func configure(provider: Bool = true, enabled: Bool = true) {
            var writer = ShellValueWriter()
            writer.array(1)
            writer.map(5)
            writer.key("id")
            writer.string("child")
            writer.key("widget")
            writer.string("child")
            writer.key("enabled")
            writer.bool(enabled)
            writer.key("provider")
            writer.bool(provider)
            writer.key("options")
            writer.map(0)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func owner() throws -> omni_owner_token {
            var value = omni_owner_token()
            XCTAssertTrue(omni_vm_component_owner(vm, "child", 5, &value))
            return value
        }

        func display() throws -> OpaquePointer {
            let display = try XCTUnwrap(omni_instance_create(vm))
            displays.append(display)
            return display
        }

        func update(_ display: OpaquePointer, changed: UInt64 = 0) -> [omni_render_step_stats] {
            XCTAssertEqual(omni_instance_begin_update(display, OMNI_VIEW_BAR, changed, true), OMNI_OK)
            var steps: [omni_render_step_stats] = []
            for _ in 0 ..< 160 {
                var stats = omni_render_step_stats()
                XCTAssertEqual(omni_instance_step_update(
                    display, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count
                ), OMNI_OK, message)
                steps.append(stats)
                if stats.done { return steps }
            }
            XCTFail("retained provider update did not complete")
            return steps
        }

        func captions(_ display: OpaquePointer) throws -> [String] {
            var length = 0
            let output = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &length))
            let bytes = Array(UnsafeBufferPointer(start: output, count: length))
            text.ingest(wire: bytes)
            return bytes.withUnsafeBytes { buffer in
                let header = buffer.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).compactMap {
                    let node = buffer.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>
                            .stride,
                        as: omni_wire_node.self
                    )
                    return node.text == 0 ? nil : text.string(node.text)
                }
            }
        }

        @discardableResult
        func state(
            _ json: String? = nil, topic: String = "value", incarnation: UInt64 = 1,
            status: omni_provider_status = OMNI_PROVIDER_UNCHANGED, owner: omni_owner_token? = nil,
            expected: omni_status = OMNI_OK
        ) throws -> Bool {
            var applied = false
            let target = try owner ?? self.owner()
            let code = topic.withCString { name in
                (json ?? "").withCString { value in
                    var delta = omni_provider_topic(
                        name: name, name_length: topic.utf8.count, json: value,
                        json_length: json?.utf8.count ?? 0, removed: false
                    )
                    return withUnsafePointer(to: &delta) { pointer in
                        var snapshot = omni_provider_snapshot(
                            incarnation: incarnation, status: status, error: nil, error_length: 0,
                            exit_code: 0, topics: json == nil ? nil : pointer, topic_count: json == nil ? 0 : 1
                        )
                        return omni_vm_provider_update(
                            vm,
                            target,
                            &snapshot,
                            200_000_000,
                            &applied,
                            &error,
                            error.count
                        )
                    }
                }
            }
            XCTAssertEqual(code, expected, message)
            return applied
        }

        @discardableResult
        func receive(
            _ name: String, _ json: String = "null", incarnation: UInt64 = 1,
            expected: omni_status = OMNI_OK, budget: UInt64 = 200_000_000
        ) throws -> Bool {
            var handled = false
            XCTAssertEqual(omni_vm_provider_receive(
                vm, try owner(), incarnation, name, name.utf8.count, json, json.utf8.count,
                budget, &handled, &error, error.count
            ), expected, message)
            return handled
        }

        func drain() -> [Request] {
            var result: [Request] = []
            var request = omni_service_request()
            while omni_vm_next_service(vm, &request) {
                result.append(Request(
                    kind: request.kind, owner: request.owner, id: request.id, cancelled: request.cancelled,
                    bytes: request.value
                        .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
                ))
            }
            return result
        }

        @discardableResult
        func complete(_ request: Request, ok: Bool = true, json: String = "null") -> Bool {
            var handled = false
            XCTAssertEqual(omni_vm_complete_provider(
                vm, request.owner, request.id, ok, json, json.utf8.count, nil, 0, 200_000_000,
                &handled, nil, &error, error.count
            ), OMNI_OK, message)
            return handled
        }
    }

    func testProviderAuthorizationIsVisibleBeforeInitAndRootCannotSend() throws {
        let source = """
        return { init = function(instance)
            local handle, reason = omniwm.provider.send("start", { n = 1 })
            if instance.provider.status == "starting" then assert(handle and reason == nil)
            else assert(handle == nil and reason == "provider_denied") end
        end, views = { compact = function(ctx) return ui.text{ text = ctx.instance.provider.status } end } }
        """
        let root = """
        local id, reason = omniwm.provider.send("start", {})
        assert(id == nil and reason == "provider_denied")
        function render(ctx) return ui.component{ id = "child" } end
        """
        let authorized = try Fixture(source, root: root)
        let request = try XCTUnwrap(authorized.drain().first)
        XCTAssertEqual(request.kind, OMNI_SERVICE_PROVIDER)
        XCTAssertNotEqual(request.owner.owner, 0)
        let fields = try XCTUnwrap(ShellServiceValue.decode(request.bytes).fields)
        XCTAssertEqual(fields["name"]?.string, "start")
        XCTAssertEqual(fields["argsJSON"]?.string, "{\"n\":1}")
        XCTAssertNil(fields["files"])
        let denied = try Fixture(source, provider: false)
        XCTAssertTrue(denied.drain().isEmpty)
        let display = try denied.display()
        _ = denied.update(display)
        XCTAssertEqual(try denied.captions(display), ["stopped"])
    }

    func testJSONStateIsSharedImmutableAndDoesNotRerunRoot() throws {
        let fixture = try Fixture("""
        return { views = { compact = function(ctx)
            local value = ctx.instance.provider.state.value
            if value then
                assert(not pcall(function() value[1] = 2 end))
                assert(not pcall(function() value[3].x = 2 end))
            end
            return ui.text{ text = value and json.encode(value) or "empty" }
        end } }
        """)
        let first = try fixture.display()
        let second = try fixture.display()
        _ = fixture.update(first)
        _ = fixture.update(second)
        XCTAssertTrue(try fixture.state("[null,[],{\"x\":1}]", status: OMNI_PROVIDER_RUNNING))
        for display in [first, second] {
            let steps = fixture.update(display)
            XCTAssertEqual(steps.filter { $0.kind == OMNI_RENDER_ROOT }.count, 0)
            XCTAssertEqual(steps.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
            XCTAssertEqual(try fixture.captions(display), ["[null,[],{\"x\":1}]"])
        }
        XCTAssertEqual(fixture.update(first).map(\.kind), [OMNI_RENDER_IDLE])
    }

    func testMalformedTopicPreservesLastValueAndNewIncarnationClearsState() throws {
        let fixture = try Fixture("""
        return { views = { compact = function(ctx)
            local provider = ctx.instance.provider
            return ui.text{ text = tostring(provider.state.value) .. ":" .. tostring(provider.error ~= nil) }
        end } }
        """)
        let display = try fixture.display()
        _ = fixture.update(display)
        XCTAssertEqual(try fixture.captions(display), ["nil:false"])
        try fixture.state("7", status: OMNI_PROVIDER_RUNNING)
        try fixture.state("{")
        _ = fixture.update(display)
        XCTAssertEqual(try fixture.captions(display), ["7:true"])
        try fixture.state(incarnation: 2, status: OMNI_PROVIDER_STARTING)
        _ = fixture.update(display)
        XCTAssertEqual(try fixture.captions(display), ["nil:false"])
        XCTAssertFalse(try fixture.state("9", incarnation: 1))
        XCTAssertEqual(fixture.update(display).map(\.kind), [OMNI_RENDER_IDLE])
    }

    func testReceiveRunsOnceWithoutDisplayAndSeesInstalledState() throws {
        let fixture = try Fixture("""
        return { receive = function(instance, event)
            assert(event.kind == "event" and event.name == "next")
            assert(event.value == json.null and instance.provider.state.value == 7)
            instance.state.calls = (instance.state.calls or 0) + 1
            omniwm.run("media toggle")
            assert(omniwm.after(1, function() end))
        end, views = { compact = function(ctx) return ui.text{ text = tostring(ctx.instance.state.calls or 0) } end } }
        """)
        let first = try fixture.display()
        let second = try fixture.display()
        _ = fixture.update(first)
        _ = fixture.update(second)
        try fixture.state("7", status: OMNI_PROVIDER_RUNNING)
        XCTAssertTrue(try fixture.receive("next"))
        XCTAssertEqual(omni_vm_message_count(fixture.vm, OMNI_MESSAGE_REQUEST), 1)
        var owner = omni_owner_token()
        var display: UInt32 = 0
        XCTAssertTrue(omni_vm_message_origin(fixture.vm, OMNI_MESSAGE_REQUEST, 0, &owner, &display))
        XCTAssertEqual(owner.owner, try fixture.owner().owner)
        XCTAssertEqual(display, OMNI_NO_DISPLAY)
        XCTAssertEqual(fixture.drain().filter { $0.kind == OMNI_SERVICE_TIMER }.count, 1)
        for item in [first, second] {
            _ = fixture.update(item)
            XCTAssertEqual(try fixture.captions(item), ["1"])
        }
        XCTAssertFalse(try fixture.receive("next", incarnation: 2))
        XCTAssertEqual(omni_vm_message_count(fixture.vm, OMNI_MESSAGE_REQUEST), 1)
    }

    func testOldIncarnationResultSettlesOriginalIDAndMalformedResultSettlesOnce() throws {
        let fixture = try Fixture("""
        return { init = function(instance)
            assert(omniwm.provider.send("start", {}, nil, function(result)
                instance.state.value = result.ok and json.encode(result.value) or result.error
            end))
        end, receive = function(instance)
            assert(omniwm.provider.send("again", {}, nil, function(result)
                assert(not result.ok and result.error == "invalid_response")
                instance.state.value = result.error
            end))
        end, views = { compact = function(ctx) return ui.text{ text = ctx.instance.state.value or "waiting" } end } }
        """)
        let request = try XCTUnwrap(fixture.drain().first)
        try fixture.state(incarnation: 2, status: OMNI_PROVIDER_RUNNING)
        XCTAssertTrue(fixture.complete(request, json: "[null,[]]"))
        XCTAssertFalse(fixture.complete(request, json: "0"))
        let display = try fixture.display()
        _ = fixture.update(display)
        XCTAssertEqual(try fixture.captions(display), ["[null,[]]"])
        try fixture.receive("again", incarnation: 2)
        let second = try XCTUnwrap(fixture.drain().first)
        XCTAssertTrue(fixture.complete(second, ok: false, json: "{}"))
        _ = fixture.update(display)
        XCTAssertEqual(try fixture.captions(display), ["invalid_response"])
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testAdmissionAndCancellationAreBoundedBeforeDispatch() throws {
        let fixture = try Fixture("""
        return { init = function(instance)
            local args = string.rep("x", 65536)
            local handle, err = omniwm.provider.send("large", args)
            assert(handle == nil and type(err) == "string")
            assert(omniwm.provider.send("bad token", {}) == nil)
            assert(omniwm.provider.send("files", {}, { files = { 1 } }) == nil)
            local handles = {}
            for i = 1, 32 do handles[i] = assert(omniwm.provider.send("queued", {})) end
            local rejected, reason = omniwm.provider.send("over", {})
            assert(rejected == nil and reason == "overloaded")
            for _, item in handles do item:cancel() end
        end, views = { compact = function(ctx) return ui.text{ text = "ready" } end } }
        """)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testReceiveFailureAndTimeoutStayWithinComponentOwner() throws {
        let fixture = try Fixture("""
        return { receive = function(instance, event)
            if event.name == "runtime" then error("provider failure") end
            if event.name == "timeout" then while true do end end
            instance.state.calls = (instance.state.calls or 0) + 1
        end, views = { compact = function(ctx) return ui.text{ text = tostring(ctx.instance.state.calls or 0) } end } }
        """)
        try fixture.state(status: OMNI_PROVIDER_RUNNING)
        XCTAssertTrue(try fixture.receive("runtime", expected: OMNI_ERR_COMPONENT))
        XCTAssertTrue(try fixture.receive("timeout", expected: OMNI_ERR_COMPONENT, budget: 2_000_000))
        XCTAssertTrue(try fixture.receive("recover"))
        let display = try fixture.display()
        _ = fixture.update(display)
        XCTAssertEqual(try fixture.captions(display), ["1"])
    }

    func testRetiredOwnerRejectsStateAndLateResults() throws {
        let fixture = try Fixture("""
        return { init = function() assert(omniwm.provider.send("pending", {}, nil, function() error("retired") end)) end,
            views = { compact = function(ctx) return ui.text{ text = "ready" } end } }
        """)
        let owner = try fixture.owner()
        let request = try XCTUnwrap(fixture.drain().first)
        fixture.configure(enabled: false)
        XCTAssertFalse(try fixture.state("1", owner: owner))
        XCTAssertFalse(fixture.complete(request))
        var missing = omni_owner_token()
        XCTAssertFalse(omni_vm_component_owner(fixture.vm, "child", 5, &missing))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testExactFrameLimitAndReleasedCompletionSlot() throws {
        let fixture = try Fixture("""
        return { init = function(instance)
            local prefix = '["action","r1","exact",'
            local count = 65536 - #prefix - 4
            assert(omniwm.provider.send("exact", string.rep("a", count), nil, function(result)
                assert(result.ok and result.value == json.null)
                assert(omniwm.provider.send("replacement", {}))
            end))
            for i = 2, 32 do assert(omniwm.provider.send("queued", {})) end
        end, views = {} }
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 32)
        let first = try XCTUnwrap(requests.first)
        let fields = try XCTUnwrap(ShellServiceValue.decode(first.bytes).fields)
        let args = try XCTUnwrap(fields["argsJSON"]?.string)
        let frame = "[\"action\",\"r\(first.id)\",\"exact\",\(args)]\n"
        XCTAssertEqual(frame.utf8.count, 65_536)
        XCTAssertTrue(fixture.complete(first))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        XCTAssertEqual(fixture.drain().count, 1)
    }

    func testCapturedNativeDeliveryWrappersRejectRecursiveAndLaterReplay() throws {
        let fixture = try Fixture("""
        local receiveWrapper, resultWrapper
        local function replay(wrapper)
            local ok, message = pcall(wrapper)
            assert(not ok and string.find(tostring(message), 'native delivery has already been consumed', 1, true))
        end
        return { init = function(instance)
            assert(omniwm.provider.send('start', {}, nil, function(result)
                resultWrapper = debug.info(2, 'f')
                replay(resultWrapper)
                assert(result.ok and result.value.answer == 42)
                instance.state.result = true
            end))
        end, receive = function(instance, event)
            if receiveWrapper then replay(receiveWrapper) end
            if resultWrapper then replay(resultWrapper) end
            receiveWrapper = debug.info(2, 'f')
            replay(receiveWrapper)
            if event.name == 'failure' then error('after capture') end
            if event.name == 'timeout' then while true do end end
            instance.state.received = true
        end, views = { compact = function(ctx)
            if receiveWrapper then replay(receiveWrapper) end
            if resultWrapper then replay(resultWrapper) end
            return ui.text{ text = tostring(ctx.instance.state.result) .. ':' .. tostring(ctx.instance.state.received) }
        end } }
        """)
        let request = try XCTUnwrap(fixture.drain().first)
        try fixture.state(status: OMNI_PROVIDER_RUNNING)
        XCTAssertTrue(fixture.complete(request, json: "{\"answer\":42}"))
        XCTAssertTrue(try fixture.receive("failure", expected: OMNI_ERR_COMPONENT))
        XCTAssertTrue(try fixture.receive("timeout", expected: OMNI_ERR_COMPONENT, budget: 2_000_000))
        XCTAssertTrue(try fixture.receive("success"))
        let display = try fixture.display()
        _ = fixture.update(display)
        XCTAssertEqual(try fixture.captions(display), ["true:true"])
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }
}
