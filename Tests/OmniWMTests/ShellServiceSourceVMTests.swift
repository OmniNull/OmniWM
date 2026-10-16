// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellServiceSourceVMTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let display: UInt32
        let view: omni_view
        let surface: UInt64
    }

    private final class Fixture {
        let vm: OpaquePointer
        var instance: OpaquePointer?
        var error = [CChar](repeating: 0, count: 512)

        init(_ source: String, component: String? = nil) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            if let component {
                let path = "profile/widgets/child/component.luau"
                XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
            }
            XCTAssertEqual(omni_vm_load(
                vm,
                "@profile/widgets/root/init.luau",
                source,
                source.utf8.count,
                200_000_000,
                &error,
                error.count
            ), OMNI_OK, message)
            if component != nil {
                var value = ShellValueWriter()
                value.array(1)
                value.map(5)
                value.key("id")
                value.string("child")
                value.key("widget")
                value.string("child")
                value.key("enabled")
                value.bool(true)
                value.key("provider")
                value.bool(true)
                value.key("options")
                value.map(0)
                XCTAssertEqual(value.bytes.withUnsafeBufferPointer {
                    omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
                }, OMNI_OK, message)
            }
            instance = try XCTUnwrap(omni_instance_create(vm))
        }

        deinit {
            if let instance { omni_instance_destroy(instance) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func action(_ view: omni_view = OMNI_VIEW_BAR, drop: Bool = false) throws -> UInt32 {
            let instance = try XCTUnwrap(instance)
            var stats = omni_render_stats()
            XCTAssertEqual(
                omni_instance_render(instance, view, 200_000_000, &stats, &error, error.count),
                OMNI_OK,
                message
            )
            var length = 0
            let bytes = try XCTUnwrap(omni_instance_output(instance, view, &length))
            let buffer = UnsafeRawBufferPointer(start: bytes, count: length)
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            for index in 0 ..< Int(header.node_count) {
                let node = buffer.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + index * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                )
                let action = drop ? node.resource_drop_action : node.action
                if action & OMNI_ACTION_HANDLER != 0 { return action }
            }
            XCTFail("missing action")
            throw NSError(domain: "ShellServiceSourceVMTests", code: 1)
        }

        func invoke(_ view: omni_view = OMNI_VIEW_BAR, source: UInt64, expected: omni_status = OMNI_OK) throws {
            let action = try action(view)
            XCTAssertEqual(omni_instance_invoke(
                instance!,
                view,
                action,
                source,
                nil,
                0,
                200_000_000,
                &error,
                error.count
            ), expected, message)
        }

        func drain() -> [Request] {
            var requests: [Request] = []
            var request = omni_service_request()
            while omni_vm_next_service(vm, &request) {
                guard !request.cancelled else { continue }
                requests.append(Request(
                    kind: request.kind,
                    owner: request.owner,
                    id: request.id,
                    display: request.display,
                    view: request.view,
                    surface: request.surface
                ))
            }
            return requests
        }

        func complete(_ request: Request) {
            var value = ShellValueWriter()
            value.map(1)
            value.key("ok")
            value.bool(true)
            var handled = false
            XCTAssertEqual(value.bytes.withUnsafeBufferPointer {
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

        func picked(_ request: Request) {
            var value = ShellValueWriter()
            value.map(1)
            value.key("ok")
            value.bool(true)
            var handled = false
            var transferred = false
            XCTAssertEqual(value.bytes.withUnsafeBufferPointer {
                omni_vm_complete_desktop(
                    vm,
                    request.owner,
                    request.id,
                    $0.baseAddress,
                    $0.count,
                    nil,
                    0,
                    200_000_000,
                    &handled,
                    &transferred,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
            XCTAssertTrue(handled)
            XCTAssertTrue(transferred)
        }

        func trigger() {
            var value = ShellValueWriter()
            value.map(0)
            XCTAssertEqual(value.bytes.withUnsafeBufferPointer {
                omni_instance_trigger(
                    instance!,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
        }
    }

    private func assertOrigin(
        _ request: Request,
        display: UInt32,
        view: omni_view,
        source: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(request.display, display, file: file, line: line)
        XCTAssertEqual(request.view, view, file: file, line: line)
        XCTAssertEqual(request.surface, source, file: file, line: line)
    }

    func testTimerHTTPAndTypedPickerCallbacksRetainBarAndPopoutSource() throws {
        let fixture = try Fixture("""
        local function clicked()
            assert(omniwm.after(0.1, function()
                assert(omniwm.http({url='https://example.test/'}, function()
                    assert(omniwm.pick({files=true}, function()
                        assert(omniwm.after(0.1, function() end))
                    end))
                end))
            end))
        end
        function render() return ui.box{w=10,h=10,onClick=clicked} end
        function popout() return ui.box{w=10,h=10,onClick=clicked} end
        """)
        let display = omni_instance_display_id(fixture.instance)
        for (view, source) in [(OMNI_VIEW_BAR, UInt64(0x1_0000_0001)), (OMNI_VIEW_POPOUT, UInt64(0x2_0000_0002))] {
            try fixture.invoke(view, source: source)
            let timer = try XCTUnwrap(fixture.drain().first)
            assertOrigin(timer, display: display, view: view, source: source)
            fixture.complete(timer)
            let http = try XCTUnwrap(fixture.drain().first)
            XCTAssertEqual(http.kind, OMNI_SERVICE_HTTP)
            assertOrigin(http, display: display, view: view, source: source)
            fixture.complete(http)
            let picker = try XCTUnwrap(fixture.drain().first)
            XCTAssertEqual(picker.kind, OMNI_SERVICE_DESKTOP)
            assertOrigin(picker, display: display, view: view, source: source)
            fixture.picked(picker)
            let nested = try XCTUnwrap(fixture.drain().first)
            assertOrigin(nested, display: display, view: view, source: source)
            fixture.complete(nested)
        }
    }

    func testFailedInvokeDoesNotLeakSourceIntoRenderOrTrigger() throws {
        let fixture = try Fixture("""
        local function scheduled() assert(omniwm.after(0.1, function() end)) end
        function render()
            scheduled()
            return ui.box{w=10,h=10,onClick=function() scheduled(); error('handler failure') end}
        end
        function trigger() scheduled() end
        """)
        let display = omni_instance_display_id(fixture.instance)
        try fixture.invoke(source: 44, expected: OMNI_ERR_RUNTIME)
        let before = fixture.drain()
        XCTAssertEqual(before.count, 2)
        assertOrigin(before[0], display: display, view: OMNI_VIEW_NONE, source: 0)
        assertOrigin(before[1], display: display, view: OMNI_VIEW_BAR, source: 44)
        fixture.trigger()
        let trigger = try XCTUnwrap(fixture.drain().first)
        assertOrigin(trigger, display: display, view: OMNI_VIEW_NONE, source: 0)
        _ = try fixture.action()
        let render = try XCTUnwrap(fixture.drain().first)
        assertOrigin(render, display: display, view: OMNI_VIEW_NONE, source: 0)
    }

    func testCoroutineKeepsCreationSourceWhenResumedBySourceFreeTrigger() throws {
        let fixture = try Fixture("""
        local task
        function render()
            return ui.box{w=10,h=10,onClick=function()
                task=coroutine.create(function() assert(omniwm.after(0.1,function() end)) end)
            end}
        end
        function trigger()
            assert(coroutine.resume(task))
            assert(omniwm.after(0.1,function() end))
        end
        """)
        try fixture.invoke(source: 711)
        fixture.trigger()
        let requests = fixture.drain()
        XCTAssertEqual(requests.count, 2)
        let display = omni_instance_display_id(fixture.instance)
        assertOrigin(requests[0], display: display, view: OMNI_VIEW_BAR, source: 711)
        assertOrigin(requests[1], display: display, view: OMNI_VIEW_NONE, source: 0)
    }

    func testCompletionAfterDisplayRetirementClearsItsPresentationSource() throws {
        let fixture = try Fixture("""
        function render()
            return ui.box{w=10,h=10,onClick=function()
                assert(omniwm.after(0.1,function() assert(omniwm.pick({files=true})) end))
            end}
        end
        """)
        try fixture.invoke(source: 72)
        let timer = try XCTUnwrap(fixture.drain().first)
        omni_instance_destroy(fixture.instance!)
        fixture.instance = nil
        fixture.complete(timer)
        let picker = try XCTUnwrap(fixture.drain().first)
        assertOrigin(picker, display: OMNI_NO_DISPLAY, view: OMNI_VIEW_NONE, source: 0)
    }

    func testDropCallbackCarriesTheCapturedSourceIntoItsService() throws {
        let fixture = try Fixture("""
        function render()
            return ui.box{w=10,h=10,accepts={'text'},onDrop=function(ctx,event)
                assert(omniwm.after(0.1,function() end))
            end}
        end
        """)
        let action = try fixture.action(drop: true)
        var owner = omni_owner_token()
        var request: UInt64 = 0
        XCTAssertEqual(
            omni_instance_reserve_drop(
                fixture.instance!,
                OMNI_VIEW_BAR,
                action,
                999,
                &owner,
                &request,
                &fixture.error,
                fixture.error.count
            ),
            OMNI_OK,
            fixture.message
        )
        var resource = omni_resource_id()
        let name = "Text"
        let kind = "text"
        let uti = "public.utf8-plain-text"
        XCTAssertEqual(name.withCString { namePointer in
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
                    return omni_vm_admit_resources(
                        fixture.vm,
                        owner,
                        &descriptor,
                        1,
                        &resource,
                        &fixture.error,
                        fixture.error.count
                    )
                }
            }
        }, OMNI_OK, fixture.message)
        var handled = false
        XCTAssertEqual(
            omni_vm_deliver_drop(
                fixture.vm,
                owner,
                request,
                &resource,
                1,
                0,
                0,
                200_000_000,
                &handled,
                &fixture.error,
                fixture.error.count
            ),
            OMNI_OK,
            fixture.message
        )
        XCTAssertTrue(handled)
        let timer = try XCTUnwrap(fixture.drain().first)
        assertOrigin(timer, display: omni_instance_display_id(fixture.instance), view: OMNI_VIEW_BAR, source: 999)
        XCTAssertTrue(omni_vm_finish_drop(fixture.vm, owner, request))
    }

    func testProviderResultRetainsActionSourceWhileInitAndReceiveHaveNone() throws {
        let fixture = try Fixture("function render(ctx) return ui.component{id='child'} end", component: """
        return {
            init=function() assert(omniwm.after(0.1,function() end)) end,
            receive=function() assert(omniwm.after(0.1,function() end)) end,
            views={compact=function()
                return ui.box{w=10,h=10,onClick=function()
                    assert(omniwm.provider.send('go',{},nil,function()
                        assert(omniwm.after(0.1,function() end))
                    end))
                end}
            end}
        }
        """)
        let initialized = try XCTUnwrap(fixture.drain().first)
        assertOrigin(initialized, display: OMNI_NO_DISPLAY, view: OMNI_VIEW_NONE, source: 0)
        var owner = omni_owner_token()
        XCTAssertTrue(omni_vm_component_owner(fixture.vm, "child", 5, &owner))
        var snapshot = omni_provider_snapshot(
            incarnation: 1,
            status: OMNI_PROVIDER_RUNNING,
            error: nil,
            error_length: 0,
            exit_code: 0,
            topics: nil,
            topic_count: 0
        )
        var applied = false
        XCTAssertEqual(omni_vm_provider_update(
            fixture.vm,
            owner,
            &snapshot,
            200_000_000,
            &applied,
            &fixture.error,
            fixture.error.count
        ), OMNI_OK, fixture.message)
        XCTAssertTrue(applied)
        try fixture.invoke(source: 813)
        let provider = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(provider.kind, OMNI_SERVICE_PROVIDER)
        var handled = false
        var transferred = false
        XCTAssertEqual(omni_vm_complete_provider(
            fixture.vm,
            owner,
            provider.id,
            true,
            "{}",
            2,
            nil,
            0,
            200_000_000,
            &handled,
            &transferred,
            &fixture.error,
            fixture.error.count
        ), OMNI_OK, fixture.message)
        XCTAssertTrue(handled)
        let completed = try XCTUnwrap(fixture.drain().first)
        assertOrigin(completed, display: omni_instance_display_id(fixture.instance), view: OMNI_VIEW_BAR, source: 813)
        handled = false
        XCTAssertEqual(
            omni_vm_provider_receive(
                fixture.vm,
                owner,
                1,
                "update",
                6,
                "{}",
                2,
                200_000_000,
                &handled,
                &fixture.error,
                fixture.error.count
            ),
            OMNI_OK,
            fixture.message
        )
        XCTAssertTrue(handled)
        let received = try XCTUnwrap(fixture.drain().first)
        assertOrigin(received, display: OMNI_NO_DISPLAY, view: OMNI_VIEW_NONE, source: 0)
    }
}
