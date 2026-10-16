// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

private extension ShellWidgetPackage {
    func testDropAuthority(_ key: ShellTreeKey) -> ShellDropAuthority? {
        guard let script, let instance = script.instances[key.bar],
              let sequence = states[key.bar]?.sequences[key.view.rawValue] else { return nil }
        var count = 0
        guard let pointer = omni_instance_output(instance, key.view.wire, &count) else { return nil }
        let header = UnsafeRawPointer(pointer).loadUnaligned(as: omni_wire_header.self)
        for index in 0 ..< Int(header.node_count) {
            let node = UnsafeRawPointer(pointer).loadUnaligned(
                fromByteOffset: MemoryLayout<omni_wire_header>.stride + index * MemoryLayout<omni_wire_node>.stride,
                as: omni_wire_node.self
            )
            if node.resource_drop_action != 0 {
                return ShellDropAuthority(
                    handle: ElementHandle(slot: Int32(index), generation: 1),
                    sequence: sequence,
                    action: node.resource_drop_action,
                    accepts: ShellDropTypes.text.rawValue,
                    sourceID: 70
                )
            }
        }
        return nil
    }

    func testDropResourceCount(_ owner: ShellServiceOwner) -> Int {
        guard let script else { return 0 }
        return omni_vm_resource_count(script.vm, owner.wire)
    }
}

@MainActor
final class ShellDropPackageTests: XCTestCase {
    private let key = ShellTreeKey(bar: ShellBarKey(monitor: .init(displayId: 99501)), view: .bar)

    func testNativeDropTransfersExactlyOnceAndKeepsReservationUntilPhysicalFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = ShellResourceStore(directory: root)
        let package = ShellWidgetPackage(
            name: "drop",
            generation: 1,
            outbox: ShellWidgetOutbox { _ in },
            resourceStore: resources
        )
        let failure = await package.load(source: """
        function render(ctx)
            return ui.box{w=100,h=20,accepts={'text'},onDrop=function(next,event)
                assert(#event.items==1 and event.items[1].state=='pending')
                assert(event.x==12 and event.y==34)
                next.state.resource=event.items[1]
            end}
        end
        """)
        XCTAssertNil(failure)
        await package.receive(.bars([key.bar: ShellBarData()]))
        let mailbox = ShellWidgetHost.connect(package)
        defer { mailbox.finish() }
        let authority = await package.testDropAuthority(key)
        let reservation = try await package.reserveDrop(XCTUnwrap(authority), key: key).get()
        XCTAssertEqual(reservation.authority.sourceID, 70)
        XCTAssertNil(reservation.component)
        XCTAssertEqual(package.services.activeCount, 1)
        let ids = try await package.admitDrop(
            reservation,
            values: [ShellPickedResource(name: "text", kind: "text", uti: "public.utf8-plain-text")]
        )
        let transferred = await package.deliverDrop(reservation, resources: ids, point: CGPoint(x: 12, y: 34))
        XCTAssertTrue(transferred)
        XCTAssertEqual(package.services.activeCount, 1)
        let replay = await package.deliverDrop(reservation, resources: ids, point: .zero)
        XCTAssertFalse(replay)
        await package.finishDrop(reservation)
        await package.finishDrop(reservation)
        XCTAssertEqual(package.services.activeCount, 0)
        await resources.release(ids, owner: reservation.id.owner)
        await package.retireResourceIDs(ids, owner: reservation.id.owner)
        let remaining = await package.testDropResourceCount(reservation.id.owner)
        XCTAssertEqual(remaining, 0)
        await package.close()
    }

    func testComponentFileCapabilityIsCheckedBeforeReturningPreflightReservation() async throws {
        for allowed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let resources = ShellResourceStore(directory: root)
            let package = ShellWidgetPackage(
                name: "drop",
                generation: 1,
                outbox: ShellWidgetOutbox { _ in },
                resourceStore: resources
            )
            let descriptor = ShellComponentDescriptor(
                widget: "child",
                title: "Child",
                icon: "",
                views: ["compact"],
                uses: [],
                options: [:],
                capabilities: ShellComponentCapabilities(files: allowed),
                providerCommand: nil,
                folder: root.appendingPathComponent("child")
            )
            let source = ShellWidgetSource(
                chunk: "@look/widgets/drop/init.luau",
                main: "function render(ctx) return ui.component{id='child'} end",
                modules: [.init(
                    path: "look/widgets/child/component.luau",
                    source: "return {views={compact=function(ctx) return ui.box{w=30,h=20,accepts={'text'},onDrop=function() end} end}}"
                )],
                moduleLimit: 512,
                components: [ShellComponentInstance(id: "child", widget: "child")],
                componentDescriptors: [descriptor]
            )
            let failure = await package.load(source)
            XCTAssertNil(failure)
            await package.receive(.bars([key.bar: ShellBarData()]))
            let mailbox = ShellWidgetHost.connect(package)
            defer { mailbox.finish() }
            let authority = await package.testDropAuthority(key)
            let result = await package.reserveDrop(try XCTUnwrap(authority), key: key)
            if allowed {
                let reservation = try result.get()
                XCTAssertEqual(reservation.component, "child")
                XCTAssertNotEqual(reservation.id.owner.owner, 0)
                await package.finishDrop(reservation)
            } else {
                guard case let .failure(problem) = result else { return XCTFail("files capability was ignored") }
                XCTAssertEqual(problem.description, "files_denied")
            }
            XCTAssertEqual(package.services.activeCount, 0)
            await package.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
