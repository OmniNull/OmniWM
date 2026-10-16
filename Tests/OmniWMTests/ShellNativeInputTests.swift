// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

private extension ShellWidgetPackage {
    func inputTestAuthority(_ key: ShellTreeKey) -> ShellDropAuthority? {
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
                    accepts: ShellDropTypes.file.rawValue,
                    sourceID: 71
                )
            }
        }
        return nil
    }

    func inputTestDragAuthority(_ key: ShellTreeKey) -> ShellDragOutAuthority? {
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
            if node.resource_drag_ref != 0 {
                return ShellDragOutAuthority(
                    handle: ElementHandle(slot: Int32(index), generation: 1),
                    sequence: sequence,
                    declaration: node.resource_drag_ref,
                    action: node.resource_drag_action,
                    sourceID: 71
                )
            }
        }
        return nil
    }

    func inputTestNumber(_ name: String) -> Double? {
        guard let script else { return nil }
        var result = 0.0
        return omni_vm_global_number(script.vm, name, &result) == OMNI_OK ? result : nil
    }

    func inputTestBeginPass(_ key: ShellTreeKey) -> Bool {
        guard let script, let instance = script.instances[key.bar] else { return false }
        return omni_instance_begin_update(instance, key.view.wire, .max, true) == OMNI_OK
    }

    func inputTestFinishPass(_ key: ShellTreeKey) -> Bool {
        guard let script, let instance = script.instances[key.bar] else { return false }
        defer { omni_instance_cancel_update(instance, key.view.wire) }
        for _ in 0 ..< 16 {
            var step = omni_render_step_stats()
            let status = omni_instance_step_update(
                instance,
                key.view.wire,
                Self.renderBudget,
                &step,
                &errorBuffer,
                errorBuffer.count
            )
            if status != OMNI_OK || step.kind == OMNI_RENDER_IDLE { return false }
            if step.done { return true }
        }
        return false
    }
}

@MainActor
final class ShellNativeInputTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let directory: URL
        let resources: ShellResourceStore
        let package: ShellWidgetPackage
        let stream: AsyncStream<ShellWidgetMessage>
        let mailbox: AsyncStream<ShellWidgetMessage>.Continuation
        let key = ShellTreeKey(bar: ShellBarKey(monitor: .init(displayId: 99133)), view: .bar)

        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            resources = ShellResourceStore(directory: directory)
            package = ShellWidgetPackage(
                name: "native-input",
                generation: 1,
                outbox: ShellWidgetOutbox { _ in },
                resourceStore: resources
            )
            (stream, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
            package.nativeInput.attach(mailbox)
        }

        func load() async throws {
            let error = await package.load(source: """
            drops=0
            begins=0
            ends=0
            function render(ctx)
                local resource=ctx.state.item
                local ready=resource and resource.state=='ready'
                return ui.box{w=80,h=20,accepts={'file'},onDrop=function(next,event)
                    drops+=1
                    next.state.item=event.items[1]
                end,dragItems=if ready then {resource} else nil,onDragOut=if ready then function(next,event)
                    if event.phase=='began' then begins+=1 else ends+=1 end
                end else nil}
            end
            """)
            XCTAssertNil(error)
            await package.receive(.bars([key.bar: ShellBarData()]))
        }

        func reserve() async throws -> (ShellDropReservation, [ShellResourceID]) {
            let authority = await package.inputTestAuthority(key)
            let reservation = try await package.reserveDrop(XCTUnwrap(authority), key: key).get()
            let ids = try await package.admitDrop(
                reservation,
                values: [ShellPickedResource(name: "drag.txt", kind: "file", uti: "public.plain-text")]
            )
            return (reservation, ids)
        }

        func close() async {
            await package.close()
            mailbox.finish()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func next(_ messages: inout AsyncStream<ShellWidgetMessage>.Iterator) async throws -> ShellWidgetMessage {
        let value = await messages.next(isolation: #isolation)
        return try XCTUnwrap(value)
    }

    func testDropDeliveryWaitsForMailboxAndDoesNotMutateOpenRetainedPass() async throws {
        let fixture = Fixture()
        try await fixture.load()
        let (reservation, ids) = try await fixture.reserve()
        var messages = fixture.stream.makeAsyncIterator()
        let open = await fixture.package.inputTestBeginPass(fixture.key)
        XCTAssertTrue(open)
        let delivery = Task { await fixture.package.deliverDrop(reservation, resources: ids, point: .zero) }
        let queued = try await next(&messages)
        let before = await fixture.package.inputTestNumber("drops")
        XCTAssertEqual(before, 0)
        let intact = await fixture.package.inputTestFinishPass(fixture.key)
        XCTAssertTrue(intact)
        await fixture.package.receive(queued)
        let transferred = await delivery.value
        XCTAssertTrue(transferred)
        let after = await fixture.package.inputTestNumber("drops")
        XCTAssertEqual(after, 1)
        let finish = Task { await fixture.package.finishDrop(reservation) }
        let cleanup = try await next(&messages)
        await fixture.package.receive(cleanup)
        await finish.value
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        await fixture.close()
    }

    func testClosingQueuedDropRejectsTransferAndCompletesItsWaiter() async throws {
        let fixture = Fixture()
        try await fixture.load()
        let (reservation, ids) = try await fixture.reserve()
        var messages = fixture.stream.makeAsyncIterator()
        let delivery = Task { await fixture.package.deliverDrop(reservation, resources: ids, point: .zero) }
        let queued = try await next(&messages)
        await fixture.package.close()
        await fixture.package.receive(queued)
        let transferred = await delivery.value
        XCTAssertFalse(transferred)
        await fixture.package.finishDrop(reservation)
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        await fixture.close()
    }

    func testDragCallbacksWaitForMailboxAndRetirementStillReleasesPhysicalPin() async throws {
        let fixture = Fixture()
        try await fixture.load()
        let (reservation, ids) = try await fixture.reserve()
        var messages = fixture.stream.makeAsyncIterator()
        let delivery = Task { await fixture.package.deliverDrop(reservation, resources: ids, point: .zero) }
        await fixture.package.receive(try await next(&messages))
        let transferred = await delivery.value
        XCTAssertTrue(transferred)
        let finishDrop = Task { await fixture.package.finishDrop(reservation) }
        await fixture.package.receive(try await next(&messages))
        await finishDrop.value
        try await fixture.resources.materialize([.bytes(Data("retained".utf8))], ids: ids, owner: reservation.id.owner)
        await fixture.package.receive(.resources)
        let authority = await fixture.package.inputTestDragAuthority(fixture.key)
        let prepared = try await fixture.package.prepareDragOut(XCTUnwrap(authority), key: fixture.key)
        guard case let .file(file) = try XCTUnwrap(prepared.pin.values.first) else { return XCTFail("missing file") }
        let open = await fixture.package.inputTestBeginPass(fixture.key)
        XCTAssertTrue(open)
        let begin = Task { await prepared.begin() }
        let queued = try await next(&messages)
        let before = await fixture.package.inputTestNumber("begins")
        XCTAssertEqual(before, 0)
        let intact = await fixture.package.inputTestFinishPass(fixture.key)
        XCTAssertTrue(intact)
        await fixture.package.receive(queued)
        await begin.value
        let after = await fixture.package.inputTestNumber("begins")
        XCTAssertEqual(after, 1)
        await fixture.package.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await prepared.finish(true, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        await fixture.close()
    }

    func testClosingQueuedEndCompletesWithoutLeavingItsPhysicalPin() async throws {
        let fixture = Fixture()
        try await fixture.load()
        let (reservation, ids) = try await fixture.reserve()
        var messages = fixture.stream.makeAsyncIterator()
        let delivery = Task { await fixture.package.deliverDrop(reservation, resources: ids, point: .zero) }
        await fixture.package.receive(try await next(&messages))
        _ = await delivery.value
        let finishDrop = Task { await fixture.package.finishDrop(reservation) }
        await fixture.package.receive(try await next(&messages))
        await finishDrop.value
        try await fixture.resources.materialize([.bytes(Data("retained".utf8))], ids: ids, owner: reservation.id.owner)
        await fixture.package.receive(.resources)
        let authority = await fixture.package.inputTestDragAuthority(fixture.key)
        let prepared = try await fixture.package.prepareDragOut(XCTUnwrap(authority), key: fixture.key)
        guard case let .file(file) = try XCTUnwrap(prepared.pin.values.first) else { return XCTFail("missing file") }
        let begin = Task { await prepared.begin() }
        await fixture.package.receive(try await next(&messages))
        await begin.value
        let finish = Task { await prepared.finish(false, true) }
        let queued = try await next(&messages)
        await fixture.package.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await fixture.package.receive(queued)
        await finish.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await fixture.close()
    }
}
