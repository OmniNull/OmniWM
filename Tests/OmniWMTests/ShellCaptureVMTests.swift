// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellCaptureVMTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
    }

    private final class Fixture {
        let vm: OpaquePointer
        var displays: [OpaquePointer] = []
        var error = [CChar](repeating: 0, count: 512)

        init() throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
        }

        deinit {
            for display in displays { omni_instance_destroy(display) }
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

        func module(_ source: String) {
            let path = "profile/widgets/child/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
        }

        func configure(_ ids: [String], provider: Bool = false, count: (Int) -> Int = { _ in 0 }) {
            var value = ShellValueWriter()
            value.array(ids.count)
            for (index, id) in ids.enumerated() {
                value.map(5)
                value.key("id")
                value.string(id)
                value.key("widget")
                value.string("child")
                value.key("enabled")
                value.bool(true)
                value.key("provider")
                value.bool(provider)
                value.key("options")
                value.map(1)
                value.key("count")
                value.number(Double(count(index)))
            }
            XCTAssertEqual(value.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func display() throws -> OpaquePointer {
            let display = try XCTUnwrap(omni_instance_create(vm))
            displays.append(display)
            return display
        }

        func render(_ display: OpaquePointer, expected: omni_status = OMNI_OK) {
            var stats = omni_render_stats()
            XCTAssertEqual(omni_instance_render(
                display, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count
            ), expected, message)
        }

        func trigger(_ display: OpaquePointer) {
            var value = ShellValueWriter()
            value.map(0)
            XCTAssertEqual(value.bytes.withUnsafeBufferPointer {
                omni_instance_trigger(display, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func action(_ display: OpaquePointer) throws -> UInt32 {
            var length = 0
            let pointer = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &length))
            let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
            XCTAssertGreaterThanOrEqual(length, MemoryLayout<omni_wire_header>.stride)
            let header = bytes.loadUnaligned(as: omni_wire_header.self)
            for index in 0 ..< Int(header.node_count) {
                let node = bytes.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + index * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                )
                if node.action & OMNI_ACTION_HANDLER != 0 { return node.action }
            }
            throw NSError(domain: "ShellCaptureVMTests", code: 1)
        }

        func drain() -> [Request] {
            var result: [Request] = []
            var request = omni_service_request()
            while omni_vm_next_service(vm, &request) {
                if !request
                    .cancelled { result.append(Request(kind: request.kind, owner: request.owner, id: request.id)) }
            }
            return result
        }

        @discardableResult
        func complete(_ request: Request) -> Bool {
            var value = ShellValueWriter()
            value.map(1)
            value.key("ok")
            value.bool(true)
            var handled = false
            XCTAssertEqual(value.bytes.withUnsafeBufferPointer {
                omni_vm_complete_service(
                    vm, request.owner, request.id, 0, $0.baseAddress, $0.count,
                    200_000_000, &handled, &error, error.count
                )
            }, OMNI_OK, message)
            return handled
        }

        func reload(_ source: String) {
            var names = ShellValueWriter()
            names.array(1)
            names.string("child")
            let path = "profile/widgets/child/component.luau"
            let status = path.withCString { pathPointer in
                source.withCString { sourcePointer in
                    var change = omni_module_change(
                        path: pathPointer, path_length: path.utf8.count,
                        source: sourcePointer, source_length: source.utf8.count, remove: false
                    )
                    return names.bytes.withUnsafeBufferPointer {
                        omni_vm_reload_components(
                            vm, $0.baseAddress, $0.count, &change, 1, 200_000_000, &error, error.count
                        )
                    }
                }
            }
            XCTAssertEqual(status, OMNI_OK, message)
        }

        func owner() -> omni_owner_token {
            var owner = omni_owner_token()
            XCTAssertTrue(omni_vm_component_owner(vm, "child", 5, &owner))
            return owner
        }

        @discardableResult
        func state(_ json: String, incarnation: UInt64 = 1, removed: Bool = false) -> Bool {
            var applied = false
            let length = json.utf8.count
            let status = "value".withCString { name in
                json.withCString { json in
                    var topic = omni_provider_topic(
                        name: name, name_length: 5, json: json,
                        json_length: length, removed: removed
                    )
                    return withUnsafePointer(to: &topic) { topic in
                        var snapshot = omni_provider_snapshot(
                            incarnation: incarnation, status: OMNI_PROVIDER_RUNNING,
                            error: nil, error_length: 0, exit_code: 0, topics: topic, topic_count: 1
                        )
                        return omni_vm_provider_update(
                            vm, owner(), &snapshot, 200_000_000, &applied, &error, error.count
                        )
                    }
                }
            }
            XCTAssertEqual(status, OMNI_OK, message)
            return applied
        }

        @discardableResult
        func receive(_ json: String, expected: omni_status = OMNI_OK) -> Bool {
            var handled = false
            XCTAssertEqual(omni_vm_provider_receive(
                vm, owner(), 2, "event", 5, json, json.utf8.count,
                200_000_000, &handled, &error, error.count
            ), expected, message)
            return handled
        }

        @discardableResult
        func providerResult(_ request: Request, json: String) -> Bool {
            var handled = false
            XCTAssertEqual(omni_vm_complete_provider(
                vm, request.owner, request.id, true, json, json.utf8.count,
                nil, 0, 200_000_000, &handled, nil, &error, error.count
            ), OMNI_OK, message)
            return handled
        }

        func begin(_ id: UInt64 = 1) -> omni_capture_stats {
            var stats = omni_capture_stats()
            XCTAssertTrue(omni_vm_capture_begin(vm, id, &stats))
            return stats
        }

        func snapshot(_ id: UInt64 = 1) -> omni_capture_stats {
            var stats = omni_capture_stats()
            XCTAssertTrue(omni_vm_capture_snapshot(vm, id, &stats))
            return stats
        }

        func end(_ id: UInt64 = 1) -> omni_capture_stats {
            var stats = omni_capture_stats()
            XCTAssertTrue(omni_vm_capture_end(vm, id, &stats))
            return stats
        }
    }

    func testCaptureBoundariesDoNotRunScriptsCollectOrResetAndRejectWrongToken() throws {
        let fixture = try Fixture()
        fixture.load("""
        calls = 0
        function trigger()
            calls += 1
            assert(json.decode('[null,[]]'))
            local value, failure = json.decode('{')
            assert(value == nil and failure)
        end
        function render() return ui.box{w=10,h=10} end
        """)
        let display = try fixture.display()
        fixture.trigger(display)
        var untouched = omni_capture_stats()
        untouched.capture_id = 999
        XCTAssertFalse(omni_vm_capture_begin(fixture.vm, 0, &untouched))
        XCTAssertEqual(untouched.capture_id, 999)
        let bytes = omni_vm_bytes_in_use(fixture.vm)
        let begin = fixture.begin()
        XCTAssertEqual(begin.vm_bytes_begin, UInt64(bytes))
        XCTAssertEqual(begin.vm_bytes, UInt64(bytes))
        XCTAssertEqual(begin.json_decodes, 0)
        XCTAssertFalse(omni_vm_capture_begin(fixture.vm, 2, &untouched))
        XCTAssertFalse(omni_vm_capture_snapshot(fixture.vm, 2, &untouched))
        XCTAssertFalse(omni_vm_capture_end(fixture.vm, 2, &untouched))
        XCTAssertFalse(omni_vm_capture_end(fixture.vm, 1, nil))
        XCTAssertEqual(untouched.capture_id, 999)
        XCTAssertEqual(omni_vm_bytes_in_use(fixture.vm), bytes)
        fixture.trigger(display)
        let end = fixture.end()
        XCTAssertEqual(end.trigger_handlers, 1)
        XCTAssertEqual(end.json_decodes, 2)
        XCTAssertEqual(end.json_decode_successes, 1)
        XCTAssertEqual(end.vm_bytes, UInt64(omni_vm_bytes_in_use(fixture.vm)))
        XCTAssertFalse(omni_vm_capture_snapshot(fixture.vm, 1, &untouched))
        fixture.trigger(display)
        XCTAssertEqual(fixture.begin(2).trigger_handlers, 0)
        let second = fixture.end(2)
        XCTAssertEqual(second.json_decodes, 0)
        var calls = 0.0
        XCTAssertEqual(omni_vm_global_number(fixture.vm, "calls", &calls), OMNI_OK)
        XCTAssertEqual(calls, 3)
        XCTAssertLessThanOrEqual(MemoryLayout<omni_capture_stats>.size, 256)
    }

    func testInputAndEncodeAttemptsExcludeStaleActionsAndFailedScriptBeforeEncode() throws {
        let fixture = try Fixture()
        fixture.load("""
        function render(ctx)
            if ctx.state.clicked then error('before encode') end
            return ui.box{w=10,h=10,onClick=function(ctx) ctx.state.clicked=true end}
        end
        """)
        let display = try fixture.display()
        _ = fixture.begin()
        fixture.render(display)
        let action = try fixture.action(display)
        XCTAssertEqual(omni_instance_invoke(
            display, OMNI_VIEW_BAR, action, 1, nil, 0,
            200_000_000, &fixture.error, fixture.error.count
        ), OMNI_OK, fixture.message)
        fixture.render(display, expected: OMNI_ERR_RUNTIME)
        XCTAssertEqual(omni_instance_invoke(
            display, OMNI_VIEW_BAR, 0, 1, nil, 0,
            200_000_000, &fixture.error, fixture.error.count
        ), OMNI_ERR_STALE_ACTION)
        let end = fixture.end()
        XCTAssertEqual(end.tree_encodes, 1)
        XCTAssertEqual(end.input_handlers, 1)
        XCTAssertEqual(end.trigger_handlers, 0)
    }

    func testOwnerRejectionAndTransientPeakSurviveCancelBeforeSnapshot() throws {
        let fixture = try Fixture()
        fixture.load("""
        function trigger()
            local handles = {}
            for i=1,32 do handles[i] = assert(omniwm.after(1,function() end)) end
            local rejected, reason = omniwm.after(1,function() end)
            assert(rejected == nil and reason == 'overloaded')
            for _, handle in handles do handle:cancel() end
        end
        """)
        let display = try fixture.display()
        _ = fixture.begin()
        fixture.trigger(display)
        let stats = fixture.end()
        XCTAssertEqual(stats.reservations, 0)
        XCTAssertEqual(stats.reservation_peak, 32)
        XCTAssertEqual(stats.owner_reservation_peak, 32)
        XCTAssertEqual(stats.owner_rejections, 1)
        XCTAssertEqual(stats.package_rejections, 0)
        XCTAssertEqual(stats.service_handlers, 0)
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testCallbackIsCountedOnceAfterReleaseAndCanRefillFullOwner() throws {
        let fixture = try Fixture()
        fixture.load("""
        for i=1,32 do assert(omniwm.after(1,function()
            assert(omniwm.after(1,function() end))
        end)) end
        """)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 32)
        let baseline = fixture.begin()
        XCTAssertEqual(baseline.reservations, 32)
        XCTAssertEqual(baseline.reservation_peak, 32)
        XCTAssertTrue(fixture.complete(requests[0]))
        XCTAssertFalse(fixture.complete(requests[0]))
        let stats = fixture.snapshot()
        XCTAssertEqual(stats.service_handlers, 1)
        XCTAssertEqual(stats.reservations, 32)
        XCTAssertEqual(stats.reservation_peak, 32)
        XCTAssertEqual(stats.owner_rejections, 0)
        XCTAssertEqual(omni_vm_close_services(fixture.vm), OMNI_OK)
        XCTAssertEqual(fixture.end().reservations, 0)
    }

    func testPackageCapacityOwnerRetirementAndSlotReuseKeepOneCapture() throws {
        let fixture = try Fixture()
        fixture.module("""
        return {init=function(instance)
            for i=1,instance.options.count do omniwm.after(1,function() end) end
        end, views={compact=function() return ui.box{w=10,h=10} end}}
        """)
        fixture.load("""
        function render() return ui.box{w=10,h=10} end
        function trigger()
            local handle, reason = omniwm.after(1,function() end)
            assert(handle == nil and reason == 'overloaded')
        end
        """)
        let display = try fixture.display()
        _ = fixture.begin()
        fixture.configure((1 ... 9).map { "child\($0)" }, count: { $0 < 8 ? 32 : 1 })
        let old = try XCTUnwrap(fixture.drain().first)
        let full = fixture.snapshot()
        XCTAssertEqual(full.reservations, 256)
        XCTAssertEqual(full.reservation_peak, 256)
        XCTAssertEqual(full.owner_reservation_peak, 32)
        XCTAssertEqual(full.package_rejections, 1)
        XCTAssertEqual(full.owner_rejections, 0)
        fixture.configure([])
        XCTAssertEqual(fixture.snapshot().reservations, 0)
        fixture.trigger(display)
        XCTAssertEqual(fixture.snapshot().backlog_rejections, 1)
        _ = fixture.drain()
        fixture.configure(["child"], count: { _ in 1 })
        let replacement = try XCTUnwrap(fixture.drain().first)
        XCTAssertNotEqual(old.owner.epoch, replacement.owner.epoch)
        XCTAssertFalse(fixture.complete(old))
        XCTAssertTrue(fixture.complete(replacement))
        let end = fixture.end()
        XCTAssertEqual(end.capture_id, 1)
        XCTAssertEqual(end.service_handlers, 1)
        XCTAssertEqual(end.reservations, 0)
        XCTAssertEqual(end.reservation_peak, 256)
        let newVM = try Fixture()
        var rejected = omni_capture_stats()
        XCTAssertFalse(omni_vm_capture_end(newVM.vm, 1, &rejected))
        XCTAssertEqual(newVM.begin().reservation_peak, 0)
        XCTAssertEqual(newVM.end().service_handlers, 0)
    }

    func testHTTPHasSeparateSixFlightRejectionsAndPeaks() throws {
        let fixture = try Fixture()
        fixture.load("""
        function trigger()
            for i=1,6 do assert(omniwm.http({url='https://example.test/'},function()
                assert(omniwm.http({url='https://example.test/'},function() end))
            end)) end
            local rejected, reason = omniwm.http({url='https://example.test/'},function() end)
            assert(rejected == nil and reason == 'overloaded')
        end
        """)
        let display = try fixture.display()
        _ = fixture.begin()
        fixture.trigger(display)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(fixture.complete(requests[0]))
        let stats = fixture.snapshot()
        XCTAssertEqual(stats.http_reservations, 6)
        XCTAssertEqual(stats.http_reservation_peak, 6)
        XCTAssertEqual(stats.reservation_peak, 6)
        XCTAssertEqual(stats.owner_reservation_peak, 6)
        XCTAssertEqual(stats.http_rejections, 1)
        XCTAssertEqual(stats.owner_rejections, 0)
        XCTAssertEqual(stats.service_handlers, 1)
        XCTAssertEqual(omni_vm_close_services(fixture.vm), OMNI_OK)
        XCTAssertEqual(fixture.end().http_reservations, 0)
    }

    func testProviderDecodesOncePerConsumedTopicAcrossDisplaysAndRejectsStaleDeliveries() throws {
        let fixture = try Fixture()
        fixture.module("""
        return {init=function()
            for i=1,2 do assert(omniwm.provider.send('request',{},nil,function(result)
                assert(type(result.ok)=='boolean')
            end)) end
        end, receive=function(instance,event)
            instance.state.event=event.value
        end, views={compact=function(ctx)
            return ui.text{text=tostring(ctx.instance.provider.state.value)}
        end}}
        """)
        fixture.load("function render() return ui.component{id='child'} end")
        fixture.configure(["child"], provider: true)
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        let displays = try [fixture.display(), fixture.display()]
        for display in displays { fixture.render(display) }
        _ = fixture.begin()
        XCTAssertTrue(fixture.state("7"))
        for display in displays { fixture.render(display) }
        XCTAssertTrue(fixture.state("{"))
        XCTAssertTrue(fixture.state("", removed: true))
        XCTAssertTrue(fixture.state("9", incarnation: 2))
        XCTAssertFalse(fixture.state("11", incarnation: 1))
        XCTAssertTrue(fixture.receive("null"))
        XCTAssertFalse(fixture.receive("{", expected: OMNI_ERR_COMPONENT))
        XCTAssertTrue(fixture.providerResult(requests[0], json: "[null,[]]"))
        XCTAssertTrue(fixture.providerResult(requests[1], json: "{"))
        XCTAssertFalse(fixture.providerResult(requests[0], json: "malformed duplicate"))
        let end = fixture.end()
        XCTAssertEqual(end.provider_topic_inputs, 3)
        XCTAssertEqual(end.provider_topic_decodes, 3)
        XCTAssertEqual(end.provider_topic_decode_successes, 2)
        XCTAssertEqual(end.provider_event_decodes, 2)
        XCTAssertEqual(end.provider_event_decode_successes, 1)
        XCTAssertEqual(end.provider_result_decodes, 2)
        XCTAssertEqual(end.provider_result_decode_successes, 1)
        XCTAssertEqual(end.provider_handlers, 3)
        XCTAssertEqual(end.json_decodes, 0)
        XCTAssertEqual(end.reservations, 0)
    }

    func testSnapshotDoesNotRestartAnInProgressRetainedPass() throws {
        let fixture = try Fixture()
        fixture.module("return {views={compact=function() return ui.text{text='child'} end}}")
        fixture.load("""
        roots=0
        function render()
            roots+=1
            return ui.component{id='child'}
        end
        """)
        fixture.configure(["child"])
        let display = try fixture.display()
        XCTAssertEqual(omni_instance_begin_update(display, OMNI_VIEW_BAR, .max, true), OMNI_OK)
        var rootSeen = false
        for _ in 0 ..< 160 {
            var step = omni_render_step_stats()
            XCTAssertEqual(omni_instance_step_update(
                display, OMNI_VIEW_BAR, 200_000_000, &step, &fixture.error, fixture.error.count
            ), OMNI_OK, fixture.message)
            if step.kind == OMNI_RENDER_ROOT {
                rootSeen = true
                break
            }
            XCTAssertFalse(step.done)
        }
        XCTAssertTrue(rootSeen)
        _ = fixture.begin()
        XCTAssertEqual(fixture.snapshot().tree_encodes, 0)
        var child = omni_render_step_stats()
        XCTAssertEqual(omni_instance_step_update(
            display, OMNI_VIEW_BAR, 200_000_000, &child, &fixture.error, fixture.error.count
        ), OMNI_OK, fixture.message)
        XCTAssertEqual(child.kind, OMNI_RENDER_COMPONENT_VIEW)
        XCTAssertEqual(fixture.end().tree_encodes, 1)
        var assembly = omni_render_step_stats()
        XCTAssertEqual(omni_instance_step_update(
            display, OMNI_VIEW_BAR, 200_000_000, &assembly, &fixture.error, fixture.error.count
        ), OMNI_OK, fixture.message)
        XCTAssertEqual(assembly.kind, OMNI_RENDER_ASSEMBLE)
        XCTAssertTrue(assembly.done)
        var roots = 0.0
        XCTAssertEqual(omni_vm_global_number(fixture.vm, "roots", &roots), OMNI_OK)
        XCTAssertEqual(roots, 1)
    }

    func testComponentCodeReloadPreservesCaptureAndRejectsRetiredCallback() throws {
        let fixture = try Fixture()
        let first = "return {views={},init=function() assert(omniwm.after(1,function() end)) end}"
        let second = "return {views={},init=function() assert(omniwm.after(2,function() end)) end}"
        fixture.module(first)
        fixture.load("function render() return ui.box{w=10,h=10} end")
        fixture.configure(["child"])
        let old = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(fixture.begin().reservations, 1)
        fixture.reload(second)
        _ = fixture.drain()
        fixture.configure(["child"])
        let replacement = try XCTUnwrap(fixture.drain().first)
        XCTAssertNotEqual(replacement.owner.epoch, old.owner.epoch)
        XCTAssertFalse(fixture.complete(old))
        XCTAssertTrue(fixture.complete(replacement))
        let end = fixture.end()
        XCTAssertEqual(end.service_handlers, 1)
        XCTAssertEqual(end.reservation_peak, 1)
        XCTAssertEqual(end.reservations, 0)
    }
}
