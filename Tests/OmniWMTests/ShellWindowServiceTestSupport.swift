// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

struct ShellWindowServiceRecord {
    let kind: omni_service_kind
    let owner: omni_owner_token
    let id: UInt64
    let cancelled: Bool
    let display: UInt32
    let view: omni_view
    let source: UInt64
    let bytes: [UInt8]

    var serviceID: ShellServiceID {
        ShellServiceID(owner: ShellServiceOwner(owner), request: id)
    }
}

final class ShellWindowServiceFixture {
    let vm: OpaquePointer
    private var instances: [OpaquePointer] = []
    private var error = [CChar](repeating: 0, count: 512)

    init(_ source: String, component: String? = nil) throws {
        vm = try XCTUnwrap(ShellVM.make(memoryLimit: ShellWidgetPackage.memoryLimit))
        if let component {
            let path = "profile/widgets/child/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, component, component.utf8.count), OMNI_OK)
        }
        XCTAssertEqual(omni_vm_load(
            vm, "@profile/widgets/root/init.luau", source, source.utf8.count,
            ShellWidgetPackage.loadBudget, &error, error.count
        ), OMNI_OK, message)
        if component != nil { configureComponent(enabled: true) }
    }

    deinit {
        for instance in instances { omni_instance_destroy(instance) }
        _ = omni_vm_destroy(vm)
    }

    private var message: String {
        error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    func instance() throws -> OpaquePointer {
        let instance = try XCTUnwrap(omni_instance_create(vm))
        instances.append(instance)
        return instance
    }

    func destroy(_ instance: OpaquePointer) {
        instances.removeAll { $0 == instance }
        omni_instance_destroy(instance)
    }

    func configureComponent(enabled: Bool) {
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
        writer.map(0)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_vm_configure_components(
                vm,
                $0.baseAddress,
                $0.count,
                ShellWidgetPackage.loadBudget,
                &error,
                error.count
            )
        }, OMNI_OK, message)
    }

    func invoke(_ instance: OpaquePointer, view: omni_view = OMNI_VIEW_WINDOW, source: UInt64) throws {
        var stats = omni_render_stats()
        XCTAssertEqual(omni_instance_render(
            instance,
            view,
            ShellWidgetPackage.renderBudget,
            &stats,
            &error,
            error.count
        ), OMNI_OK, message)
        var length = 0
        let pointer = try XCTUnwrap(omni_instance_output(instance, view, &length))
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        let header = bytes.loadUnaligned(as: omni_wire_header.self)
        let actions = (0 ..< Int(header.node_count)).map { index in
            bytes.loadUnaligned(
                fromByteOffset: MemoryLayout<omni_wire_header>.stride + index * MemoryLayout<omni_wire_node>.stride,
                as: omni_wire_node.self
            ).action
        }
        let action = try XCTUnwrap(actions.first { $0 & OMNI_ACTION_HANDLER != 0 })
        XCTAssertEqual(omni_instance_invoke(
            instance,
            view,
            action,
            source,
            nil,
            0,
            ShellWidgetPackage.handlerBudget,
            &error,
            error.count
        ), OMNI_OK, message)
    }

    func trigger(_ instance: OpaquePointer) {
        var writer = ShellValueWriter()
        writer.map(0)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_trigger(
                instance,
                $0.baseAddress,
                $0.count,
                ShellWidgetPackage.handlerBudget,
                &error,
                error.count
            )
        }, OMNI_OK, message)
    }

    func drain() -> [ShellWindowServiceRecord] {
        var records: [ShellWindowServiceRecord] = []
        var request = omni_service_request()
        while omni_vm_next_service(vm, &request) {
            records.append(ShellWindowServiceRecord(
                kind: request.kind, owner: request.owner, id: request.id, cancelled: request.cancelled,
                display: request.display, view: request.view, source: request.surface,
                bytes: request.value.map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
            ))
        }
        return records
    }

    func complete(_ request: ShellWindowServiceRecord, error failure: String? = nil) -> Bool {
        let result = ShellWindowRequest.completion(id: request.serviceID, error: failure)
        var handled = false
        XCTAssertEqual(result.payload.withUnsafeBufferPointer {
            omni_vm_complete_service(
                vm,
                request.owner,
                request.id,
                0,
                $0.baseAddress,
                $0.count,
                ShellWidgetPackage.handlerBudget,
                &handled,
                &error,
                error.count
            )
        }, OMNI_OK, message)
        return handled
    }

    func number(_ name: String) -> Double {
        var value = 0.0
        XCTAssertEqual(omni_vm_global_number(vm, name, &value), OMNI_OK)
        return value
    }
}
