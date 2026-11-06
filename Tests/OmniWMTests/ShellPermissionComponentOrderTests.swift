// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

private extension ShellWidgetPackage {
    func componentOrderObservation(_ key: ShellBarKey) async -> (Double, Bool, Double)? {
        guard let script, let instance = script.instances[.bar(key)] else { return nil }
        await renderVisible(.bar(key), instance)
        var order = 0.0
        var disabled = false
        var target = 0.0
        guard omni_vm_global_number(script.vm, "observedOrder", &order) == OMNI_OK,
              omni_vm_global_boolean(script.vm, "observedDisabled", &disabled) == OMNI_OK,
              omni_vm_global_number(script.vm, "observedMoveTarget", &target) == OMNI_OK else { return nil }
        return (order, disabled, target)
    }

    func bindComponentForOrderRetirement(_ name: String) throws {
        let owner = try XCTUnwrap(providerOwner(name))
        try bindResources(owner, component: name)
    }
}

@MainActor
final class ShellPermissionComponentOrderTests: XCTestCase {
    private let bar = ShellBarKey(monitor: .init(displayId: 98117))

    private func source(width: Int = 10) -> ShellWidgetSource {
        ShellWidgetSource(
            chunk: "@look/widgets/root/init.luau",
            main: """
            function render(ctx)
                observedOrder = 0
                observedDisabled = false
                observedMoveTarget = 0
                for index, component in ctx.data.components do
                    observedOrder = observedOrder * 10 + tonumber(component.id)
                    if component.id == "1" then
                        observedDisabled = not component.enabled
                        observedMoveTarget = index + 1
                    end
                end
                return ui.box{ w = 1, h = 1 }
            end
            """,
            modules: [.init(
                path: "look/widgets/box/component.luau",
                source: "return { views = { compact = function() return ui.box{w=\(width),h=10} end } }"
            )],
            moduleLimit: 512,
            components: [
                ShellComponentInstance(id: "3", widget: "box"),
                ShellComponentInstance(id: "1", widget: "box", enabled: false),
                ShellComponentInstance(id: "2", widget: "box")
            ]
        )
    }

    func testPermissionChangesKeepTheCompleteVMListAndItsMoveIndices() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let permissions = ShellNetworkPermissions()
        let package = ShellWidgetPackage(
            name: "order", generation: 1, outbox: ShellWidgetOutbox { _ in },
            store: ShellStore(directoryURL: directory), permissions: permissions
        )
        let failure = await package.load(source())
        XCTAssertNil(failure)
        await package.receive(.bars([bar: ShellBarData()]))
        var decisions = ShellPermissionDecisions()
        for enabled in [false, true] {
            decisions.services.weather = enabled
            XCTAssertTrue(permissions.update(decisions: decisions))
            await package.receive(.permissions)
            let observation = await package.componentOrderObservation(bar)
            let (order, disabled, target) = try XCTUnwrap(observation)
            XCTAssertEqual(order, 312)
            XCTAssertTrue(disabled)
            XCTAssertEqual(target, 3)
            let instances = await package.configuredComponentInstances
            XCTAssertEqual(instances.map(\.id), ["3", "1", "2"])
        }
        await package.close()
    }

    func testPermissionWakeDuringReloadDoesNotRecreateRetiringOwners() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = expectation(description: "reload is retiring resource ownership")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let package = ShellWidgetPackage(
            name: "order", generation: 1, outbox: ShellWidgetOutbox { _ in },
            store: ShellStore(directoryURL: directory.appendingPathComponent("store")),
            resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("resources")),
            retireResourceImages: { _ in
                entered.fulfill()
                for await _ in release { break }
            }
        )
        let failure = await package.load(source())
        XCTAssertNil(failure)
        await package.receive(.bars([bar: ShellBarData()]))
        try await package.bindComponentForOrderRetirement("3")
        let next = source(width: 20)
        let reload = Task { await package.receive(.components(next)) }
        await fulfillment(of: [entered], timeout: failureBound)
        await package.receive(.permissions)
        let retiring = await package.configuredComponentInstances
        XCTAssertEqual(retiring.map(\.id), ["1"])
        let owner = await package.providerOwner("3")
        XCTAssertNil(owner)
        let during = await package.componentOrderObservation(bar)
        XCTAssertEqual(try XCTUnwrap(during).0, 1)
        continuation.yield(())
        await reload.value
        let after = await package.componentOrderObservation(bar)
        XCTAssertEqual(try XCTUnwrap(after).0, 312)
        await package.close()
    }
}
