// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

private extension ShellWidgetPackage {
    func checkExtractedProviderReplacement() throws {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: Self.memoryLimit))
        let script = ShellScript(vm: vm)
        self.script = script
        XCTAssertEqual(omni_vm_set_service_generation(vm, services.generation), OMNI_OK)
        let source = """
        return {
            init = function(instance)
                assert(omniwm.provider.send("reply", {}, nil, function(result)
                    assert(result.ok and result.value == 42)
                    instance.state.results = (instance.state.results or 0) + 1
                    instance.state.resultState = instance.provider.state.value
                end))
            end,
            receive = function(instance, event)
                if event.name == "verify" then
                    assert((instance.state.events or 0) == 0, "stale event was delivered")
                    assert(instance.state.results == 1, "old result was not delivered exactly once")
                    assert(instance.state.resultState == 0, "stale snapshot was installed")
                    assert(instance.provider.state.value == event.value, "unexpected provider state")
                else
                    instance.state.events = (instance.state.events or 0) + 1
                end
            end,
            views = { compact = function() return ui.box{} end },
        }
        """
        let path = "profile/widgets/child/component.luau"
        XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
        let root = "function render() return ui.component{id='child'} end"
        XCTAssertEqual(omni_vm_load(
            vm, "@profile/widgets/root/init.luau", root, root.utf8.count,
            Self.loadBudget, &errorBuffer, errorBuffer.count
        ), OMNI_OK, lastError())
        var configuration = ShellValueWriter()
        configuration.array(1)
        configuration.map(5)
        configuration.key("id")
        configuration.string("child")
        configuration.key("widget")
        configuration.string("child")
        configuration.key("enabled")
        configuration.bool(true)
        configuration.key("provider")
        configuration.bool(true)
        configuration.key("options")
        configuration.map(0)
        XCTAssertEqual(configuration.bytes.withUnsafeBufferPointer {
            omni_vm_configure_components(vm, $0.baseAddress, $0.count, Self.loadBudget, &errorBuffer, errorBuffer.count)
        }, OMNI_OK, lastError())
        let owner = try XCTUnwrap(providerOwner("child"))
        let first = ShellProviderIdentity(owner: owner, incarnation: 1)
        let second = ShellProviderIdentity(owner: owner, incarnation: 2)
        var request = omni_service_request()
        XCTAssertTrue(omni_vm_next_service(vm, &request))
        XCTAssertEqual(request.kind, OMNI_SERVICE_PROVIDER)
        let id = ShellServiceID(owner: ShellServiceOwner(request.owner), request: request.id)
        XCTAssertEqual(id.owner, owner)
        XCTAssertTrue(services.register(id))
        XCTAssertTrue(providerInbox.activate(first))
        XCTAssertTrue(providerInbox.register(id, identity: first))
        XCTAssertEqual(providerInbox.post(.state(topic: "value", value: Data("0".utf8)), from: first), .accepted)
        XCTAssertTrue(applyProviderSnapshot(
            try XCTUnwrap(providerInbox.takeState(first, now: 0)), identity: first, in: script
        ))
        XCTAssertEqual(providerInbox.post(.state(topic: "value", value: Data("1".utf8)), from: first), .accepted)
        XCTAssertEqual(providerInbox.post(.event(name: "stale", value: Data("null".utf8)), from: first), .accepted)
        XCTAssertEqual(providerInbox.post(
            .result(id: "r\(id.request)", ok: true, value: Data("42".utf8), attachments: nil), from: first
        ), .accepted)
        let extracted = providerInbox.takeBatch(now: 1)
        XCTAssertEqual(extracted.count, 2)
        XCTAssertNotNil(extracted.first?.snapshot)

        providerInbox.end(first, status: .exited(0))
        XCTAssertTrue(providerInbox.activate(second))
        XCTAssertEqual(providerInbox.post(.state(topic: "value", value: Data("9".utf8)), from: second), .accepted)
        XCTAssertFalse(deliverProvider(extracted[0], in: script))
        XCTAssertTrue(deliverProvider(extracted[1], in: script))
        XCTAssertFalse(deliverProvider(extracted[1], in: script))
        XCTAssertEqual(services.activeCount, 0)
        XCTAssertEqual(omni_vm_service_stats(vm).reserved, 0)
        try verifyProviderDeliveryState(owner, incarnation: 1, expected: "0", in: script)

        for delivery in providerInbox.takeBatch(now: 2) {
            XCTAssertTrue(deliverProvider(delivery, in: script))
        }
        try verifyProviderDeliveryState(owner, incarnation: 2, expected: "9", in: script)
    }

    func verifyProviderDeliveryState(
        _ owner: ShellServiceOwner, incarnation: UInt64, expected: String, in script: ShellScript
    ) throws {
        var handled = false
        XCTAssertEqual(omni_vm_provider_receive(
            script.vm, owner.wire, incarnation, "verify", 6, expected, expected.utf8.count,
            Self.handlerBudget, &handled, &errorBuffer, errorBuffer.count
        ), OMNI_OK, lastError())
        XCTAssertTrue(handled)
    }
}

@MainActor
final class ShellProviderIncarnationDeliveryTests: XCTestCase {
    func testExtractedOldStateAndEventAreDroppedButTheirAcceptedResultSettles() async throws {
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: ShellWidgetOutbox { _ in })
        do {
            try await package.checkExtractedProviderReplacement()
        } catch {
            await package.close()
            throw error
        }
        await package.close()
    }
}
