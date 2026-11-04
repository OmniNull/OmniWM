// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellWindowServiceVMTests: XCTestCase {
    func testWindowActionsCarryCheckedOwnerRootAndStructuredCompletion() throws {
        let child = "confirm"
        let source: UInt64 = 73
        let fixture = try ShellWindowServiceFixture("""
        completed = 0
        assert(table.isfrozen(omniwm.windows))
        function window()
            return ui.box{w=10,h=10,onClick=function()
                assert(omniwm.windows.open('\(child)', function(result)
                    assert(not result.ok and result.error == 'sheet_busy')
                    local handle, reason = omniwm.windows.open('\(child)')
                    assert(handle == nil and reason == 'window_request_denied')
                    completed += 1
                end))
                assert(omniwm.windows.close('\(child)'))
            end}
        end
        """)
        let instance = try fixture.instance()
        try fixture.invoke(instance, source: source)
        let requests = fixture.drain()
        let operations: [ShellWindowRequest.Operation] = [.open, .close]
        XCTAssertEqual(requests.count, operations.count)
        let rootID = UUID()
        let origin = ShellDesktopOrigin(
            widget: "root", generation: 1,
            key: ShellTreeKey(instance: .window(rootID), view: .window), sourceID: source
        )
        for (record, operation) in zip(requests, operations) {
            XCTAssertEqual(record.kind, OMNI_SERVICE_WINDOW)
            XCTAssertEqual(record.display, omni_instance_display_id(instance))
            XCTAssertEqual(record.view, OMNI_VIEW_WINDOW)
            XCTAssertEqual(record.source, source)
            let request = try ShellWindowRequest(id: record.serviceID, origin: origin, bytes: record.bytes)
            XCTAssertEqual(request.id, record.serviceID)
            XCTAssertEqual(request.rootID, rootID)
            XCTAssertEqual(request.sourceID, source)
            XCTAssertEqual(request.operation, operation)
            XCTAssertEqual(request.childID, child)
            XCTAssertTrue(fixture.complete(record, error: operation == .open ? "sheet_busy" : nil))
        }
        XCTAssertEqual(fixture.number("completed"), Double(operations.filter { $0 == .open }.count))
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testTypedRequestRejectsMissingWindowOriginAndMalformedOperation() throws {
        let owner = ShellServiceOwner(generation: 1, owner: 0, epoch: 1)
        let id = ShellServiceID(owner: owner, request: 1)
        var writer = ShellValueWriter()
        writer.map(2)
        writer.key("op")
        writer.string(ShellWindowRequest.Operation.open.rawValue)
        writer.key("id")
        writer.string("confirm")
        let rootID = UUID()
        let source: UInt64 = 73
        let valid = ShellDesktopOrigin(
            widget: "root", generation: 1,
            key: ShellTreeKey(instance: .window(rootID), view: .window), sourceID: source
        )
        XCTAssertNoThrow(try ShellWindowRequest(id: id, origin: valid, bytes: writer.bytes))
        XCTAssertThrowsError(try ShellWindowRequest(id: id, origin: nil, bytes: writer.bytes))
        for (view, sourceID) in [(ShellWidgetView.popout, source), (.window, UInt64(0))] {
            let origin = ShellDesktopOrigin(
                widget: valid.widget, generation: valid.generation,
                key: ShellTreeKey(instance: valid.key.instance, view: view), sourceID: sourceID
            )
            XCTAssertThrowsError(try ShellWindowRequest(id: id, origin: origin, bytes: writer.bytes))
        }
        var malformed = ShellValueWriter()
        malformed.map(2)
        malformed.key("op")
        malformed.string("unrecognized")
        malformed.key("id")
        malformed.string("confirm")
        XCTAssertThrowsError(try ShellWindowRequest(id: id, origin: valid, bytes: malformed.bytes))
    }

    func testInitializationRenderTriggerBarPopoutAndMissingSurfaceAreRefused() throws {
        let fixture = try ShellWindowServiceFixture("""
        local function denied()
            for _, action in {omniwm.windows.open, omniwm.windows.close} do
                local handle, reason = action('confirm')
                assert(handle == nil and reason == 'window_request_denied')
            end
        end
        denied()
        local function root()
            denied()
            return ui.box{w=10,h=10,onClick=denied}
        end
        render = root
        popout = root
        window = root
        trigger = denied
        """)
        let instance = try fixture.instance()
        for view in [OMNI_VIEW_BAR, OMNI_VIEW_POPOUT] {
            try fixture.invoke(instance, view: view, source: UInt64(omni_instance_display_id(instance)) + 1)
        }
        try fixture.invoke(instance, source: 0)
        fixture.trigger(instance)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testCoroutineSourceDoesNotAuthorizeARequestFromALaterTrigger() throws {
        let fixture = try ShellWindowServiceFixture("""
        local saved
        function window()
            return ui.box{w=10,h=10,onClick=function()
                saved = coroutine.create(function()
                    local handle, reason = omniwm.windows.open('confirm')
                    assert(handle == nil and reason == 'window_request_denied')
                end)
            end}
        end
        function trigger() assert(coroutine.resume(saved)) end
        """)
        let instance = try fixture.instance()
        try fixture.invoke(instance, source: UInt64(omni_instance_display_id(instance)) + 1)
        fixture.trigger(instance)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testMalformedArgumentsAndCancelledHandlesDoNotLeaveReservations() throws {
        let fixture = try ShellWindowServiceFixture("""
        function window()
            return ui.box{w=10,h=10,onClick=function()
                for _, action in {
                    function() return omniwm.windows.open('') end,
                    function() return omniwm.windows.open({id='confirm'}) end,
                    function() return omniwm.windows.close('confirm', {}) end,
                    function() return omniwm.windows.open('a' .. string.char(0) .. 'b') end,
                } do
                    local handle, reason = action()
                    assert(handle == nil and reason == 'invalid window arguments')
                end
                local handle = assert(omniwm.windows.open('confirm'))
                handle:cancel()
            end}
        end
        """)
        let instance = try fixture.instance()
        try fixture.invoke(instance, source: UInt64(omni_instance_display_id(instance)) + 1)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testRetiringOneRootCancelsItsWindowsRequestsAndKeepsSharedOwnerServices() throws {
        let fixture = try ShellWindowServiceFixture("""
        completed = 0
        function window()
            return ui.box{w=10,h=10,onClick=function()
                assert(omniwm.windows.open('confirm', function(result)
                    assert(result.ok)
                    completed += 1
                end))
                assert(omniwm.http({url='https://example.test/'}, function(result) assert(result.ok) end))
            end}
        end
        """)
        let first = try fixture.instance()
        let second = try fixture.instance()
        try fixture.invoke(first, source: UInt64(omni_instance_display_id(first)) + 1)
        let firstRequests = fixture.drain()
        try fixture.invoke(second, source: UInt64(omni_instance_display_id(second)) + 1)
        let secondRequests = fixture.drain()
        let expectedKinds = [OMNI_SERVICE_WINDOW, OMNI_SERVICE_HTTP]
        XCTAssertEqual(firstRequests.map(\.kind), expectedKinds)
        XCTAssertEqual(secondRequests.map(\.kind), expectedKinds)
        let retired = try XCTUnwrap(firstRequests.first { $0.kind == OMNI_SERVICE_WINDOW })
        fixture.destroy(first)
        let cancellations = fixture.drain()
        XCTAssertEqual(cancellations.map(\.id), [retired.id])
        XCTAssertTrue(cancellations.allSatisfy(\.cancelled))
        XCTAssertFalse(fixture.complete(retired))
        for request in firstRequests where request.kind == OMNI_SERVICE_HTTP {
            XCTAssertTrue(fixture.complete(request))
        }
        for request in secondRequests { XCTAssertTrue(fixture.complete(request)) }
        XCTAssertEqual(
            fixture.number("completed"),
            Double(secondRequests.filter { $0.kind == OMNI_SERVICE_WINDOW }.count)
        )
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testComponentWindowActionUsesLiveComponentOwnerAndRetiresItsRequest() throws {
        let fixture = try ShellWindowServiceFixture("""
        function window() return ui.component{id='child'} end
        """, component: """
        return {
            init = function()
                local handle, reason = omniwm.windows.open('confirm')
                assert(handle == nil and reason == 'window_request_denied')
            end,
            views = {compact=function()
                return ui.box{w=10,h=10,onClick=function()
                    assert(omniwm.windows.open('confirm', function() error('retired owner callback') end))
                end}
            end},
        }
        """)
        let instance = try fixture.instance()
        try fixture.invoke(instance, source: UInt64(omni_instance_display_id(instance)) + 1)
        let request = try XCTUnwrap(fixture.drain().first)
        XCTAssertEqual(request.kind, OMNI_SERVICE_WINDOW)
        XCTAssertNotEqual(request.owner.owner, 0)
        fixture.configureComponent(enabled: false)
        let cancellations = fixture.drain()
        XCTAssertEqual(cancellations.map(\.id), [request.id])
        XCTAssertTrue(cancellations.allSatisfy(\.cancelled))
        XCTAssertFalse(fixture.complete(request))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }
}
