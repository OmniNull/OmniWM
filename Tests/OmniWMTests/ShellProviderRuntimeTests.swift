// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellProviderRuntimeTests: XCTestCase {
    @MainActor
    private final class Harness {
        enum Wake: Sendable {
            case inbox
            case deadline(UInt64)
        }

        let directory: URL
        let owner = ShellServiceOwner(generation: 991, owner: 1, epoch: 1)
        let inbox = ShellProviderInbox()
        let services = ShellServiceLedger(generation: 991)
        let provider: ShellProvider
        let mailbox: AsyncStream<Wake>.Continuation
        private var consumer: Task<Void, Never>?
        private var timer: (any DispatchSourceTimer)?
        private var nextID: UInt64 = 1
        var deliveries: [ShellProviderInbox.Delivery] = []
        var states: [ShellProviderIdentity: [String: Data]] = [:]
        var statuses: [ShellProviderIdentity: ShellProviderInbox.Status] = [:]
        var onDelivery: ((ShellProviderInbox.Delivery) -> Void)?

        init(consuming: Bool, diagnostic: @escaping @Sendable (String) -> Void) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "OmniWMProviderRuntime-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ShellProvider/provider.pl")
            let executable = directory.appendingPathComponent("provider.pl")
            try FileManager.default.copyItem(at: fixture, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            provider = ShellProvider(owner: owner, inbox: inbox, diagnostics: { _, line in diagnostic(line.text) })
            let (messages, continuation) = AsyncStream.makeStream(of: Wake.self)
            mailbox = continuation
            inbox.attachWake { continuation.yield(.inbox) }
            if consuming {
                consumer = Task { [weak self] in
                    for await message in messages {
                        guard let self else { return }
                        switch message {
                        case .inbox: drain()
                        case let .deadline(expected): inbox.deadlineFired(
                                expected,
                                now: DispatchTime.now().uptimeNanoseconds
                            )
                        }
                    }
                }
            }
        }

        func configuration(tag: String = "A", mode: String = "echo") throws -> ShellProviderConfiguration {
            ShellProviderConfiguration(
                widget: "fixture", instance: "instance", folder: directory, command: ["provider.pl"],
                options: try JSONSerialization.data(withJSONObject: ["tag": tag, "mode": mode], options: .sortedKeys),
                authorized: true
            )
        }

        func send(_ name: String, arguments: Data = Data("{}".utf8)) throws -> ShellServiceID {
            let identity = try XCTUnwrap(inbox.identity(for: owner))
            let id = ShellServiceID(owner: owner, request: nextID)
            nextID += 1
            let frame = try ShellProviderProtocol.action(id: id.request, name: name, arguments: arguments)
            let provider = provider
            guard services.register(id, cancel: { provider.cancel(id, identity: identity) }) else {
                throw ShellProviderProtocol.Failure(message: "fixture ledger rejected action")
            }
            guard inbox.register(id, identity: identity) else {
                services.cancel(id)
                throw ShellProviderProtocol.Failure(message: "fixture provider rejected correlation")
            }
            provider.send(id, identity: identity, frame: frame)
            return id
        }

        func drain() {
            timer?.cancel()
            timer = nil
            let now = DispatchTime.now().uptimeNanoseconds
            for delivery in inbox.takeBatch(now: now) {
                if let snapshot = delivery.snapshot {
                    for topic in snapshot.topics { states[delivery.identity, default: [:]][topic.name] = topic.value }
                    if let status = snapshot.status { statuses[delivery.identity] = status }
                }
                if case let .result(id, _)? = delivery.control { XCTAssertTrue(services.takeRegistered(id)) }
                deliveries.append(delivery)
                onDelivery?(delivery)
            }
            if case let .deadline(deadline) = inbox.finishBatch(now: now) {
                let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                let mailbox = mailbox
                source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
                let fire: @Sendable () -> Void = { mailbox.yield(.deadline(deadline)) }
                source.setEventHandler(handler: fire)
                timer = source
                source.resume()
            }
        }

        func close() async {
            await provider.close()
            drain()
            timer?.cancel()
            timer = nil
            mailbox.finish()
            await consumer?.value
            onDelivery = nil
            services.close()
            inbox.close()
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }

        func marker(_ name: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
    }

    private func withHarness(
        consuming: Bool = true,
        diagnostic: @escaping @Sendable (String) -> Void = { _ in },
        _ body: (Harness) async throws -> Void
    ) async throws {
        let harness = try Harness(consuming: consuming, diagnostic: diagnostic)
        do {
            try await body(harness)
            await harness.close()
        } catch {
            await harness.close()
            throw error
        }
    }

    private func launch(
        _ harness: Harness,
        tag: String = "A",
        mode: String = "echo"
    ) async throws -> ShellProviderIdentity {
        let ready = expectation(description: "actual provider ready \(tag) \(mode)")
        harness.onDelivery = { delivery in
            if case let .event(name, value)? = delivery.control, name == "ready",
               (try? JSONSerialization.jsonObject(with: value) as? [String: Any])?["tag"] as? String == tag
            { ready.fulfill() }
        }
        await harness.provider.reconcile(try harness.configuration(tag: tag, mode: mode))
        await fulfillment(of: [ready], timeout: 10)
        harness.onDelivery = nil
        return try XCTUnwrap(harness.inbox.identity(for: harness.owner))
    }

    func testSubprocessInstallsLatestStateBeforeOrderedEventAndResult() async throws {
        try await withHarness { harness in
            let identity = try await launch(harness)
            let done = expectation(description: "echo result")
            let first = harness.deliveries.count
            harness.onDelivery = { delivery in
                if case let .event(name, value)? = delivery.control, name == "changed" {
                    XCTAssertEqual(harness.states[identity]?["latest"], value)
                }
                if case let .result(_, outcome)? = delivery.control {
                    guard case let .provider(ok, value, attachments) = outcome
                    else { return XCTFail("Unexpected failure") }
                    XCTAssertTrue(ok)
                    XCTAssertNil(attachments)
                    XCTAssertEqual(harness.states[identity]?["latest"], value)
                    done.fulfill()
                }
            }
            let id = try harness.send("echo", arguments: Data("{\"value\":42}".utf8))
            await fulfillment(of: [done], timeout: 10)
            let controls = harness.deliveries.dropFirst(first).compactMap(\.control)
            XCTAssertEqual(controls.count, 2)
            if case let .result(resultID, _)? = controls.last { XCTAssertEqual(resultID, id) }
            else { XCTFail("Expected final correlated result") }
            XCTAssertEqual(harness.services.activeCount, 0)
            XCTAssertEqual(harness.inbox.pendingActions, 0)
        }
    }

    func testReplacementStartsOnlyAfterOldProcessHasActuallyClosed() async throws {
        try await withHarness { harness in
            let first = try await launch(harness)
            let second = try await launch(harness, tag: "B")
            XCTAssertGreaterThan(second.incarnation, first.incarnation)
            let identity = try XCTUnwrap(harness.states[second]?["identity"])
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: identity) as? [String: Any])
            XCTAssertEqual(value["previousClosed"] as? String, "A")
            XCTAssertEqual(try harness.marker("launches"), "A\nB\n")
            await harness.provider.close()
            XCTAssertEqual(try harness.marker("closed"), "B")
            XCTAssertTrue(try XCTUnwrap(harness.inbox.binding(for: harness.owner)).terminal)
        }
    }

    func testCrashRetainsItsReplyAndDoesNotRestartOnUnchangedConfiguration() async throws {
        try await withHarness { harness in
            let identity = try await launch(harness)
            let exited = expectation(description: "actual process exit code seven")
            let reply = expectation(description: "pre-exit reply retained")
            harness.onDelivery = { delivery in
                if case .exited(7)? = delivery.snapshot?.status { exited.fulfill() }
                if case let .result(_, outcome)? = delivery.control {
                    guard case let .provider(ok, _, _) = outcome else { return XCTFail("Lost pre-exit reply") }
                    XCTAssertTrue(ok)
                    reply.fulfill()
                }
            }
            _ = try harness.send("crash")
            await fulfillment(of: [reply, exited], timeout: 10)
            harness.onDelivery = nil
            await harness.provider.reconcile(try harness.configuration())
            let binding = try XCTUnwrap(harness.inbox.binding(for: harness.owner))
            XCTAssertEqual(binding.identity, identity)
            XCTAssertTrue(binding.terminal)
            XCTAssertEqual(try harness.marker("launches"), "A\n")
            XCTAssertEqual(harness.services.activeCount, 0)
            await harness.provider.reconcile(nil)
            let next = try await launch(harness)
            XCTAssertGreaterThan(next.incarnation, identity.incarnation)
            XCTAssertEqual(try harness.marker("launches"), "A\nA\n")
        }
    }

    func testNonReadingAndStoppedProvidersFailOverloadWithoutBlockingAnotherProvider() async throws {
        for mode in ["stall", "stopped"] {
            try await withHarness { stalled in
                _ = try await launch(stalled, mode: mode)
                try await withHarness { responsive in
                    _ = try await launch(responsive)
                    let overloaded = expectation(description: "bounded writer reports overload \(mode)")
                    var sawOverload = false
                    stalled.onDelivery = { delivery in
                        if case let .result(_, .failure(error))? = delivery.control,
                           error.contains("backlog"), !sawOverload
                        { sawOverload = true
                            overloaded.fulfill()
                        }
                    }
                    let payload = Data(("{\"payload\":\"" + String(repeating: "x", count: 60_000) + "\"}").utf8)
                    for _ in 0 ..< 32 { _ = try stalled.send("echo", arguments: payload) }
                    let alive = expectation(description: "independent provider replied while peer stdin is blocked")
                    responsive.onDelivery = { delivery in
                        if case .result? = delivery.control { alive.fulfill() }
                    }
                    _ = try responsive.send("echo")
                    await fulfillment(of: [overloaded, alive], timeout: 10)
                    XCTAssertTrue(sawOverload)
                    XCTAssertEqual(responsive.services.activeCount, 0)
                    stalled.onDelivery = nil
                    await stalled.provider.close()
                    stalled.drain()
                    XCTAssertTrue(try XCTUnwrap(stalled.inbox.binding(for: stalled.owner)).terminal)
                }
            }
        }
    }

    func testStateFloodCoalescesAndEventFloodCannotDisplaceReservedReply() async throws {
        try await withHarness { harness in
            let identity = try await launch(harness)
            let done = expectation(description: "state flood final reply")
            harness.onDelivery = { delivery in
                if case .result? = delivery.control { done.fulfill() }
            }
            _ = try harness.send("flood_state")
            await fulfillment(of: [done], timeout: 10)
            let data = try XCTUnwrap(harness.states[identity]?["latest"])
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(value["index"] as? Int, 8192)
            XCTAssertGreaterThan(harness.inbox.counters.coalescedStates, 0)
            XCTAssertEqual(harness.services.activeCount, 0)
        }
        let ready = expectation(description: "flood fixture actual startup")
        let terminated = expectation(description: "supervisor terminated the overflowing provider")
        // the fixture reprints both lines if it is relaunched, and close() sends a second TERM
        ready.assertForOverFulfill = false
        terminated.assertForOverFulfill = false
        try await withHarness(consuming: false, diagnostic: { line in
            if line == "fixture:ready:A" { ready.fulfill() }
            if line == "fixture:closed:A" { terminated.fulfill() }
        }) { harness in
            await harness.provider.reconcile(try harness.configuration())
            await fulfillment(of: [ready], timeout: 10)
            let id = try harness.send("flood_events")
            await fulfillment(of: [terminated], timeout: 10)
            await harness.provider.close()
            harness.drain()
            let binding = try XCTUnwrap(harness.inbox.binding(for: harness.owner))
            XCTAssertTrue(binding.terminal)
            XCTAssertEqual(harness.inbox.pendingEvents, 0)
            let controls = harness.deliveries.compactMap(\.control)
            XCTAssertEqual(controls.count, 1)
            if case let .result(deliveredID, .provider(ok, _, _))? = controls.first {
                XCTAssertEqual(deliveredID, id)
                XCTAssertTrue(ok)
            } else { XCTFail("Event overload displaced the accepted reply") }
            if case let .failed(error)? = harness.statuses[binding.identity] { XCTAssertTrue(error.contains("256")) }
            else { XCTFail("Event flood must be explicit failure") }
            XCTAssertEqual(harness.services.activeCount, 0)
        }
    }
}
