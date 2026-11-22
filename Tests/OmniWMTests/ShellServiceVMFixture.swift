// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellServiceVMFixture {
    struct DrainedServiceRequest {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let cancelled: Bool
        let bytes: [UInt8]
    }

    let vm: OpaquePointer
    private var display: OpaquePointer?
    private var error = [CChar](repeating: 0, count: 512)

    init(enabled: Bool = true) throws {
        vm = try XCTUnwrap(ShellVM.make(memoryLimit: ShellWidgetPackage.memoryLimit))
        XCTAssertEqual(omni_vm_set_configuration_enabled(vm, enabled), OMNI_OK)
    }

    deinit {
        if let display { omni_instance_destroy(display) }
        _ = omni_vm_destroy(vm)
    }

    private var message: String {
        error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    func load(_ source: String) {
        XCTAssertEqual(omni_vm_load(
            vm, "@profile/widgets/root/init.luau", source, source.utf8.count,
            ShellWidgetPackage.loadBudget, &error, error.count
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
            omni_vm_configure_components(
                vm, $0.baseAddress, $0.count, ShellWidgetPackage.loadBudget, &error, error.count
            )
        }, OMNI_OK, message)
    }

    func drain() -> [DrainedServiceRequest] {
        var requests: [DrainedServiceRequest] = []
        var request = omni_service_request()
        while omni_vm_next_service(vm, &request) {
            requests.append(DrainedServiceRequest(
                kind: request.kind, owner: request.owner, id: request.id, cancelled: request.cancelled,
                bytes: request.value
                    .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
            ))
        }
        return requests
    }

    @discardableResult
    func complete(_ request: DrainedServiceRequest, _ bytes: [UInt8]? = nil) -> Bool {
        var writer = ShellValueWriter()
        writer.map(1)
        writer.key("ok")
        writer.bool(true)
        var handled = false
        XCTAssertEqual((bytes ?? writer.bytes).withUnsafeBufferPointer {
            omni_vm_complete_service(
                vm, request.owner, request.id, 0, $0.baseAddress, $0.count, ShellWidgetPackage.handlerBudget,
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

    private func instance() throws -> OpaquePointer {
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
            omni_instance_trigger(
                instance, $0.baseAddress, $0.count, ShellWidgetPackage.handlerBudget, &error, error.count
            )
        }, OMNI_OK, message)
    }

    func render() throws {
        var stats = omni_render_stats()
        XCTAssertEqual(omni_instance_render(
            try instance(), OMNI_VIEW_BAR, ShellWidgetPackage.renderBudget, &stats, &error, error.count
        ), OMNI_OK, message)
    }
}
