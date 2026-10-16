// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellHTTPVMTests: XCTestCase {
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

    func testDefaultAndExplicitRequestPayloadsPreserveBinaryBody() throws {
        let fixture = try Fixture()
        fixture.load("""
        assert(omniwm.http({ url = "https://example.test/a" }, function() end))
        assert(omniwm.http({ url = "https://example.test/b", method = "POST", response = "bytes",
            body = "a" .. string.char(0, 255) .. "b", headers = { ["X-Token"] = "value" },
            maxBytes = 4194304, timeout = 120 }, function() end))
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(ShellServiceValue.decode(requests[0].bytes).fields)
        XCTAssertEqual(first["url"]?.string, "https://example.test/a")
        XCTAssertEqual(first["method"]?.string, "GET")
        XCTAssertEqual(first["response"]?.string, "text")
        XCTAssertEqual(first["maxBytes"]?.number, 1_048_576)
        XCTAssertEqual(first["timeout"]?.number, 30)
        XCTAssertEqual(first["headers"]?.fields, [:])
        XCTAssertNil(first["body"])
        let second = try XCTUnwrap(ShellServiceValue.decode(requests[1].bytes).fields)
        XCTAssertEqual(second["body"], .bytes([97, 0, 255, 98]))
        XCTAssertEqual(second["headers"]?.fields?["X-Token"]?.string, "value")
        XCTAssertEqual(second["method"]?.string, "POST")
        XCTAssertEqual(second["response"]?.string, "bytes")
        XCTAssertEqual(second["maxBytes"]?.number, 4_194_304)
        XCTAssertEqual(second["timeout"]?.number, 120)
        XCTAssertTrue(requests.allSatisfy { $0.kind == OMNI_SERVICE_HTTP })
    }

    func testInvalidRequestAndBodyResourceAdmissionIsExplicitAndBounded() throws {
        let fixture = try Fixture()
        fixture.load("""
        local callback = function() error("not admitted") end
        local invalid = {
            {}, { url = 9 }, { url = "x", method = 5 }, { url = "x", response = "xml" },
            { url = "x", maxBytes = 0 }, { url = "x", maxBytes = 4194305 }, { url = "x", maxBytes = 1.5 },
            { url = "x", timeout = 0 }, { url = "x", timeout = 121 },
            { url = "x", headers = { 1 } }, { url = "x", headers = { A = string.rep("x", 65536) } },
            { url = "x", body = string.rep("x", 4194305) },
        }
        local headers = {}; for i = 1, 129 do headers["h" .. i] = "x" end
        table.insert(invalid, { url = "x", headers = headers })
        for _, request in invalid do
            local handle, err = omniwm.http(request, callback)
            assert(handle == nil and type(err) == "string")
        end
        local missing, err = omniwm.http({ url = "x" })
        assert(missing == nil and err == "invalid_request")
        local timer = assert(omniwm.after(10, callback))
        local handle, reason = omniwm.http({ url = "x", body = timer }, callback)
        assert(handle == nil and reason == "invalid_resource")
        timer:cancel()
        """)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testFullBodyRequestFitsItsSeparateEnvelopeLimit() throws {
        let fixture = try Fixture()
        fixture.load("""
        assert(omniwm.http({ url = "https://example.test/body", body = string.rep("a", 4194304),
            headers = { X = string.rep("h", 65535) } }, function() end))
        """)
        let request = try XCTUnwrap(fixture.drain().first)
        let fields = try XCTUnwrap(ShellServiceValue.decode(
            request.bytes, byteLimit: (4 << 20) + (128 << 10)
        ).fields)
        guard case let .bytes(body) = fields["body"] else { return XCTFail("Missing binary body") }
        XCTAssertEqual(body.count, 4 << 20)
        XCTAssertEqual(fields["headers"]?.fields?["X"]?.string?.utf8.count, 65535)
    }

    func testSixReservationsPersistThroughFlightAndReleaseBeforeCallbackOrCancel() throws {
        let fixture = try Fixture()
        fixture.load("""
        completed = 0
        local handles = {}
        for index = 1, 6 do
            handles[index] = assert(omniwm.http({ url = "https://example.test/" }, function(result)
                assert(result.ok)
                completed += 1
                assert(omniwm.http({ url = "https://example.test/followup" }, function() end))
            end))
        end
        local overflow, err = omniwm.http({ url = "https://example.test/overflow" }, function() end)
        assert(overflow == nil and err == "overloaded")
        function trigger()
            handles[2]:cancel()
            assert(omniwm.http({ url = "https://example.test/after-cancel" }, function() end))
        end
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 6)
        XCTAssertTrue(fixture.complete(requests[0]))
        let followup = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(followup.id, requests.last!.id + 1)
        try fixture.trigger()
        let afterCancel = fixture.drain()
        XCTAssertEqual(afterCancel.count, 2)
        XCTAssertTrue(afterCancel[0].cancelled)
        XCTAssertEqual(afterCancel[0].id, requests[1].id)
        XCTAssertEqual(afterCancel[1].id, followup.id + 1)
        XCTAssertFalse(fixture.complete(requests[1]))
        XCTAssertEqual(fixture.number("completed"), 1)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 6)
    }

    func testOwnerRemovalReleasesSharedHTTPPoolAndRejectsLateCompletions() throws {
        let fixture = try Fixture()
        fixture.component("""
        return { views = {}, init = function()
            for index = 1, 6 do
                assert(omniwm.http({ url = "https://example.test/component" }, function() error("retired") end))
            end
        end }
        """)
        fixture.load("""
        function trigger()
            for index = 1, 6 do assert(omniwm.http({ url = "https://example.test/root" }, function() end)) end
        end
        """)
        fixture.configure()
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy { $0.owner.owner != 0 })
        fixture.configure(enabled: false)
        let cancellations = fixture.drain()
        XCTAssertEqual(cancellations.count, 6)
        XCTAssertTrue(cancellations.allSatisfy(\.cancelled))
        for request in requests { XCTAssertFalse(fixture.complete(request)) }
        try fixture.trigger()
        XCTAssertEqual(fixture.drain().count, 6)
    }

    func testMaximumHTTPBodyAndEncodedHeadersFitCompletionEnvelope() throws {
        let fixture = try Fixture()
        fixture.load("""
        completed = 0
        assert(omniwm.http({ url = "https://example.test/", response = "bytes" }, function(result)
            assert(result.ok and #result.bytes == 4194304 and #result.headers.h == 65521)
            completed += 1
        end))
        """)
        var writer = ShellValueWriter()
        writer.map(4)
        writer.key("ok")
        writer.bool(true)
        writer.key("status")
        writer.number(200)
        writer.key("headers")
        writer.map(1)
        writer.key("h")
        writer.string(String(repeating: "h", count: (64 << 10) - 15))
        writer.key("bytes")
        writer.string(String(repeating: "a", count: 4 << 20))
        XCTAssertLessThanOrEqual(writer.bytes.count, 4_261_888)
        XCTAssertTrue(fixture.complete(try XCTUnwrap(fixture.drain().first), writer.bytes))
        XCTAssertEqual(fixture.number("completed"), 1)
    }

    func testJSONBodyDepth64FitsEnvelopeButPublicJSONAndDeeperBodyStayBounded() throws {
        for depth in [64, 65] {
            let fixture = try Fixture()
            fixture.load("""
            completed = 0
            local public, failure = json.decode(string.rep("[", 65) .. "null" .. string.rep("]", 65))
            assert(public == nil and failure)
            assert(omniwm.http({ url = "https://example.test/", response = "json" }, function(result)
                if \(depth) == 64 then
                    assert(json.encode(result.json) == string.rep("[", 64) .. "null" .. string.rep("]", 64))
                else
                    assert(result.ok == false and result.error == "invalid_response")
                end
                completed += 1
            end))
            """)
            var writer = ShellValueWriter()
            writer.map(1)
            writer.key("json")
            for _ in 0 ..< depth { writer.array(1) }
            writer.null()
            XCTAssertTrue(fixture.complete(try XCTUnwrap(fixture.drain().first), writer.bytes))
            XCTAssertEqual(fixture.number("completed"), 1)
        }
    }

    func testConfigurationCompletionDoesNotInheritLargerHTTPLimit() throws {
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
    }
}
