// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellServiceVMTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let revision: UInt64
        let cancelled: Bool
        let bytes: [UInt8]
    }

    private final class Fixture {
        let vm: OpaquePointer
        var displays: [OpaquePointer] = []
        var error = [CChar](repeating: 0, count: 512)

        init(generation: UInt64 = 41) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            XCTAssertEqual(omni_vm_set_service_generation(vm, generation), OMNI_OK)
        }

        deinit {
            for display in displays { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func load(_ source: String) {
            XCTAssertEqual(
                omni_vm_load(
                    vm,
                    "@profile/widgets/root/init.luau",
                    source,
                    source.utf8.count,
                    200_000_000,
                    &error,
                    error.count
                ),
                OMNI_OK,
                message
            )
        }

        func module(_ name: String, _ source: String) {
            let path = "profile/widgets/\(name)/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
        }

        func configure(_ ids: [String], widget: String = "timer") {
            var writer = ShellValueWriter()
            writer.array(ids.count)
            for id in ids {
                writer.map(4)
                writer.key("id")
                writer.string(id)
                writer.key("widget")
                writer.string(widget)
                writer.key("enabled")
                writer.bool(true)
                writer.key("options")
                writer.map(0)
            }
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func seed(_ bytes: [UInt8], owner: String = "", failure: String = "") {
            XCTAssertEqual(bytes.withUnsafeBufferPointer {
                omni_vm_seed_store(
                    vm,
                    owner,
                    owner.utf8.count,
                    $0.baseAddress,
                    $0.count,
                    failure,
                    failure.utf8.count,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
        }

        func drain() -> [Request] {
            var requests: [Request] = []
            var request = omni_service_request()
            while omni_vm_next_service(vm, &request) {
                requests.append(Request(
                    kind: request.kind,
                    owner: request.owner,
                    id: request.id,
                    revision: request.revision,
                    cancelled: request.cancelled,
                    bytes: request.value.map { Array(UnsafeBufferPointer(
                        start: $0,
                        count: request.value_length
                    )) } ?? []
                ))
            }
            return requests
        }

        @discardableResult
        func complete(_ request: Request, ok: Bool = true, expected: omni_status = OMNI_OK) -> Bool {
            var writer = ShellValueWriter()
            writer.map(ok ? 1 : 2)
            writer.key("ok")
            writer.bool(ok)
            if !ok {
                writer.key("error")
                writer.string("disk unavailable")
            }
            var handled = false
            let status = writer.bytes.withUnsafeBufferPointer {
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
            }
            XCTAssertEqual(status, expected, message)
            return handled
        }

        func display() throws -> OpaquePointer {
            let value = try XCTUnwrap(omni_instance_create(vm))
            displays.append(value)
            return value
        }

        func destroy(_ display: OpaquePointer) {
            displays.removeAll { $0 == display }
            omni_instance_destroy(display)
        }

        func number(_ name: String) -> Double {
            var result = 0.0
            XCTAssertEqual(omni_vm_global_number(vm, name, &result), OMNI_OK)
            return result
        }

        func trigger(_ display: OpaquePointer) {
            let event: [UInt8] = [6, 0, 0, 0, 0]
            XCTAssertEqual(event.withUnsafeBufferPointer {
                omni_instance_trigger(display, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func render(_ display: OpaquePointer) {
            var stats = omni_render_stats()
            XCTAssertEqual(
                omni_instance_render(display, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count),
                OMNI_OK,
                message
            )
        }
    }

    func testTimerAdmissionCancellationAndReleaseBeforeCallback() throws {
        let fixture = try Fixture()
        fixture.load("""
        fired = 0
        handles = {}
        local rejected, invalid = omniwm.after(0.001, function() error("invalid") end)
        assert(rejected == nil and invalid)
        for i = 1, 32 do
            handles[i] = assert(omniwm.after(0.01, function()
                fired += 1
                assert(omniwm.after(0.01, function() end))
            end))
        end
        local handle, err = omniwm.after(0.01, function() error("overloaded") end)
        assert(handle == nil and err == "overloaded")
        """)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 32)
        XCTAssertEqual(requests.map(\.id), Array(1 ... 32).map(UInt64.init))
        XCTAssertTrue(fixture.complete(requests[0]))
        XCTAssertFalse(fixture.complete(requests[0]))
        let replacement = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(replacement.id, 33)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 32)
        fixture.load("handles[2]:cancel(); handles[2]:cancel(); assert(fired == 1)")
        let cancellations = fixture.drain()
        XCTAssertEqual(cancellations.count, 1)
        XCTAssertTrue(cancellations[0].cancelled)
        XCTAssertFalse(fixture.complete(requests[1]))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 31)
    }

    func testPendingCancellationNeverDispatchesAndCloseRejectsStaleCompletion() throws {
        let fixture = try Fixture()
        fixture.load("""
        local timer = assert(omniwm.after(0.01, function() error("cancelled") end))
        timer:cancel()
        assert(omniwm.after(0.01, function() error("closed") end))
        """)
        let request = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(request.id, 2)
        XCTAssertEqual(omni_vm_close_services(fixture.vm), OMNI_OK)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        XCTAssertFalse(fixture.complete(request))
        XCTAssertEqual(fixture.drain().filter(\.cancelled).count, 1)
    }

    func testPackageAndOwnerCapsAndOwnerEpochRetirement() throws {
        let fixture = try Fixture()
        fixture.module("timer", """
        return { views = {}, init = function(instance)
            local accepted = 0
            for i = 1, 32 do
                local handle, err = omniwm.after(0.01, function() error("old owner") end)
                if handle then accepted += 1 else assert(err == "overloaded") end
            end
            assert(accepted == (instance.id == "ninth" and 0 or 32))
            local handle, err = omniwm.after(0.01, function() end)
            assert(handle == nil and err == "overloaded")
        end }
        """)
        fixture.load("function render(ctx) return ui.box{} end")
        fixture.configure((1 ... 8).map { "owner\($0)" } + ["ninth"])
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 256)
        let old = fixture.drain()
        XCTAssertEqual(old.count, 256)
        fixture.configure([])
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        XCTAssertEqual(fixture.drain().count, 256)
        fixture.configure(["owner1"])
        let next = fixture.drain()
        XCTAssertEqual(next.count, 32)
        XCTAssertNotEqual(next[0].owner.epoch, old[0].owner.epoch)
        XCTAssertFalse(fixture.complete(old[0]))
    }

    func testStorePreservesJSONSnapshotCoalescesAndRetriesTerminalFailure() throws {
        let fixture = try Fixture()
        var writer = ShellValueWriter()
        writer.map(1)
        writer.key("seed")
        writer.number(7)
        fixture.seed(writer.bytes, failure: "prior failure")
        fixture.load("""
        assert(omniwm.store.get("seed") == 7)
        assert(omniwm.store.status.state == "failed")
        assert(omniwm.store.set("value", assert(json.decode('[null,[],{}]'))))
        local value = omniwm.store.get("value")
        assert(table.isfrozen(value) and table.isfrozen(value[2]))
        assert(json.encode(value) == '[null,[],{}]')
        local ok, err = omniwm.store.set("invalid", function() end)
        assert(ok == nil and err and omniwm.store.get("invalid") == nil)
        ok, err = omniwm.store.set("large", string.rep("x", 256 * 1024))
        assert(ok == nil and err and omniwm.store.get("large") == nil)
        assert(omniwm.store.set("count", 1))
        """)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 1)
        let first = try XCTUnwrap(fixture.drain().first)
        fixture.load("assert(omniwm.store.set('count', 2))")
        XCTAssertTrue(fixture.complete(first))
        let second = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(second.id, first.id)
        XCTAssertGreaterThan(second.revision, first.revision)
        fixture.complete(second, ok: false)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        fixture.load("""
        assert(omniwm.store.status.state == "failed")
        assert(omniwm.store.get("count") == 2)
        assert(omniwm.store.set("count", 2))
        assert(omniwm.store.status.state == "pending")
        """)
        let retry = try XCTUnwrap(fixture.drain().first)
        XCTAssertNotEqual(retry.id, first.id)
        fixture.complete(retry)
        fixture.load("assert(omniwm.store.status.state == 'ready'); assert(omniwm.store.set('count', 2))")
        XCTAssertTrue(fixture.drain().isEmpty)
        let reloaded = try Fixture(generation: 42)
        reloaded.seed(retry.bytes)
        reloaded.load("""
        assert(omniwm.store.get("count") == 2)
        assert(json.encode(omniwm.store.get("value")) == '[null,[],{}]')
        """)
        XCTAssertFalse(reloaded.complete(retry))
    }

    func testFirstLoadedRenderObservesPendingFailedAndReadyStoreStatus() throws {
        let fixture = try Fixture()
        fixture.load("""
        function render(ctx)
            local status = omniwm.store.status.state
            observed = status == "ready" and 0 or status == "pending" and 1 or 2
            return ui.box{}
        end
        function trigger(ctx, event)
            assert(omniwm.store.set("value", (omniwm.store.get("value") or 0) + 1))
        end
        """)
        let display = try fixture.display()
        fixture.render(display)
        XCTAssertEqual(fixture.number("observed"), 0)
        fixture.trigger(display)
        fixture.render(display)
        XCTAssertEqual(fixture.number("observed"), 1)
        fixture.complete(try XCTUnwrap(fixture.drain().first), ok: false)
        fixture.render(display)
        XCTAssertEqual(fixture.number("observed"), 2)
        fixture.trigger(display)
        fixture.complete(try XCTUnwrap(fixture.drain().first))
        fixture.render(display)
        XCTAssertEqual(fixture.number("observed"), 0)
    }

    func testSharedModuleResolvesStoreStatusForEachCurrentOwner() throws {
        let fixture = try Fixture()
        fixture.module("status", """
        local component = { views = {}, observed = {} }
        function component.init(instance)
            if instance.id == "a" then assert(omniwm.store.set("value", 1)) end
        end
        function component.views.compact(ctx)
            local status = omniwm.store.status.state
            component.observed[ctx.instance.id] = status == "ready" and 0 or status == "pending" and 1 or 2
            return ui.box{}
        end
        return component
        """)
        fixture.load("""
        local component = require("@component/status")
        function render(ctx)
            local first = ui.component{id="a", view="compact"}
            local second = ui.component{id="b", view="compact"}
            rootReady = omniwm.store.status.state == "ready" and 1 or 0
            return ui.stack{first,second}
        end
        function trigger(ctx, event)
            aStatus = component.observed.a
            bStatus = component.observed.b
        end
        """)
        fixture.seed([], owner: "b", failure: "prior commit failed")
        fixture.configure(["a", "b"], widget: "status")
        let display = try fixture.display()
        fixture.render(display)
        fixture.trigger(display)
        XCTAssertEqual(fixture.number("aStatus"), 1)
        XCTAssertEqual(fixture.number("bStatus"), 2)
        XCTAssertEqual(fixture.number("rootReady"), 1)
        fixture.complete(try XCTUnwrap(fixture.drain().first))
        fixture.render(display)
        fixture.trigger(display)
        XCTAssertEqual(fixture.number("aStatus"), 0)
        XCTAssertEqual(fixture.number("bStatus"), 2)
        XCTAssertEqual(fixture.number("rootReady"), 1)
    }

    func testFailedOlderCommitFlushesLatestSnapshotOnlyAtTeardown() throws {
        let fixture = try Fixture()
        fixture.load("assert(omniwm.store.set('value', 1))")
        let first = try XCTUnwrap(fixture.drain().first)
        fixture.load("assert(omniwm.store.set('value', 2))")
        fixture.complete(first, ok: false)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.load("assert(omniwm.store.status.state == 'failed'); assert(omniwm.store.get('value') == 2)")
        XCTAssertEqual(omni_vm_close_services(fixture.vm), OMNI_OK)
        let flush = try XCTUnwrap(fixture.drain().first)
        XCTAssertTrue(flush.cancelled)
        XCTAssertEqual(flush.id, 0)
        let reloaded = try Fixture()
        reloaded.seed(flush.bytes)
        reloaded.load("assert(omniwm.store.get('value') == 2)")
        XCTAssertEqual(omni_vm_close_services(fixture.vm), OMNI_OK)
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testReplacingComponentKeepsFinalDeinitSnapshotBeforeNewInit() throws {
        let fixture = try Fixture()
        fixture.module("first", """
        return { views = {}, init = function(instance)
            assert(omniwm.store.set("value", 3))
        end, deinit = function(instance)
            assert(omniwm.store.set("value", 9))
        end }
        """)
        fixture.module("second", """
        return { views = {}, init = function(instance)
            assert(omniwm.store.get("value") == 9)
            assert(omniwm.store.set("value", 10))
        end }
        """)
        fixture.load("function render(ctx) return ui.box{} end")
        fixture.configure(["shared"], widget: "first")
        let old = try XCTUnwrap(fixture.drain().first)
        fixture.seed([], owner: "shared")
        fixture.configure(["shared"], widget: "second")
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].cancelled)
        XCTAssertFalse(requests[1].cancelled)
        XCTAssertFalse(fixture.complete(old))
        let snapshot = try Fixture()
        snapshot.seed(requests[0].bytes)
        snapshot.load("assert(omniwm.store.get('value') == 9)")
    }

    func testComponentCallbackErrorIsContainedAndRootMessageOriginsRemainCorrect() throws {
        let fixture = try Fixture()
        fixture.module("timer", """
        return { views = {}, init = function(instance)
            assert(omniwm.after(0.01, function() error("component failed") end))
        end }
        """)
        fixture.load("""
        function render(ctx)
            if not ctx.state.started then
                ctx.state.started = true
                assert(omniwm.after(0.01, function()
                    omniwm.log("root callback")
                    omniwm.run("workspace next")
                    assert(omniwm.store.set("root", true))
                end))
            end
            return ui.box{}
        end
        """)
        fixture.configure(["child"])
        let child = try XCTUnwrap(fixture.drain().first)
        let display = try fixture.display()
        fixture.render(display)
        let root = try XCTUnwrap(fixture.drain().first)
        XCTAssertTrue(fixture.complete(child, expected: OMNI_ERR_COMPONENT))
        XCTAssertTrue(fixture.complete(root))
        XCTAssertEqual(omni_vm_message_count(fixture.vm, OMNI_MESSAGE_LOG), 1)
        XCTAssertEqual(omni_vm_message_count(fixture.vm, OMNI_MESSAGE_REQUEST), 1)
        var owner = omni_owner_token()
        var origin: UInt32 = .max
        XCTAssertTrue(omni_vm_message_origin(fixture.vm, OMNI_MESSAGE_REQUEST, 0, &owner, &origin))
        XCTAssertEqual(owner.owner, 0)
        XCTAssertEqual(owner.generation, 41)
        XCTAssertEqual(origin, omni_instance_display_id(display))
        XCTAssertEqual(fixture.drain().first?.owner.owner, 0)
    }

    func testCoroutinesReadOwnDisplayAndRejectRemovedDisplayAndOwner() throws {
        let fixture = try Fixture()
        fixture.module("timer", """
        local component = { views = {} }
        function component.init(instance)
            component.thread = coroutine.create(function() coroutine.yield(); omniwm.store.set("stale", true) end)
            assert(coroutine.resume(component.thread))
        end
        return component
        """)
        fixture.load("""
        component = require("@component/timer")
        function render(ctx)
            saved = coroutine.create(function()
                assert(ctx.data.cpu == 12)
                assert(ctx.select("cpu") == 12)
                coroutine.yield()
                error("stale display executed")
            end)
            assert(coroutine.resume(saved))
            wrapped = coroutine.wrap(function() coroutine.yield(); error("stale wrapped executed") end)
            wrapped()
            return ui.box{}
        end
        """)
        fixture.configure(["child"])
        let display = try fixture.display()
        XCTAssertEqual(omni_instance_set_number(display, "cpu", 12), OMNI_OK)
        fixture.render(display)
        fixture.destroy(display)
        let next = try fixture.display()
        XCTAssertNotEqual(omni_instance_display_id(next), 0)
        fixture.configure([])
        fixture.load("""
        local ok, err = coroutine.resume(saved)
        assert(not ok and string.find(err, "no longer available"))
        ok, err = pcall(wrapped)
        assert(not ok and string.find(err, "no longer available"))
        ok, err = coroutine.resume(component.thread)
        assert(not ok and string.find(err, "no longer available"))
        """)
        omni_vm_collect(fixture.vm)
    }
}
