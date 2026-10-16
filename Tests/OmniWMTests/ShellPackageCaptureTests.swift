// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

private struct PackageCaptureProbe: Equatable, Sendable {
    var hasScript: Bool
    var revision: UInt64
    var seconds: Double
    var renders: Double
    var strings: UInt32
    var active: Bool
    var encodes: UInt64
}

private extension ShellWidgetPackage {
    func captureProbe(_ id: UInt64) -> PackageCaptureProbe {
        var stats = omni_capture_stats()
        var renders = 0.0
        if let script { _ = omni_vm_global_number(script.vm, "renders", &renders) }
        return PackageCaptureProbe(
            hasScript: script != nil,
            revision: dataRevision,
            seconds: current.seconds,
            renders: renders,
            strings: script.map { omni_vm_string_count($0.vm) } ?? 0,
            active: script.map { omni_vm_capture_snapshot($0.vm, id, &stats) } ?? false,
            encodes: stats.tree_encodes
        )
    }
}

@MainActor
final class ShellPackageCaptureTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let package: ShellWidgetPackage
        let latest = ShellLatestWidgetData()
        let stream: AsyncStream<ShellWidgetMessage>
        let mailbox: AsyncStream<ShellWidgetMessage>.Continuation
        let key = ShellBarKey(monitor: .init(displayId: 99314))

        init() {
            package = ShellWidgetPackage(
                name: "capture-widget", generation: 8, outbox: ShellWidgetOutbox { _ in }, latestData: latest
            )
            (stream, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
            package.capture.attach(mailbox)
        }

        func load() async {
            let error = await package.load(source: """
            renders=0
            function render(ctx)
                renders+=1
                return ui.text{text='captured',size=12}
            end
            """)
            XCTAssertNil(error)
            await package.receive(.bars([key: ShellBarData()]))
        }

        func context() throws -> ShellFrameTraceContext {
            var context = try XCTUnwrap(ShellFrameTrace.shared.makeContext())
            context.widget = package.name
            context.generation = package.generation
            return context
        }
    }

    func testControlWaitsForMailboxAndDoesNotRefreshRenderOrDrain() async throws {
        let fixture = Fixture()
        await fixture.load()
        ShellFrameTrace.shared.beginCapture()
        defer { ShellFrameTrace.shared.endCapture() }
        let context = try fixture.context()
        let before = await fixture.package.captureProbe(context.capture)
        var next = ShellWidgetData()
        next.seconds = 917
        fixture.latest.publish(next)
        let id = ShellServiceID(
            owner: ShellServiceOwner(generation: fixture.package.services.generation, owner: 0, epoch: 0), request: 99
        )
        XCTAssertTrue(fixture.package.services.register(id))
        XCTAssertTrue(fixture.package.services.complete(ShellServiceCompletion(id: id, payload: [])))
        let begin = fixture.package.capture.request(context, .begin(joined: false))
        XCTAssertNil(begin.result)
        var messages = fixture.stream.makeAsyncIterator()
        await fixture.package.receive(try await nextCapture(&messages))
        let started = await begin.wait()
        XCTAssertTrue(started)
        let during = await fixture.package.captureProbe(context.capture)
        XCTAssertTrue(during.active)
        XCTAssertEqual(during.encodes, 0)
        XCTAssertEqual(during.revision, before.revision)
        XCTAssertEqual(during.seconds, before.seconds)
        XCTAssertEqual(during.renders, before.renders)
        XCTAssertEqual(during.strings, before.strings)
        XCTAssertEqual(fixture.package.services.pendingCount, 1)
        let end = fixture.package.capture.request(context, .end(retired: false))
        XCTAssertNil(end.result)
        await fixture.package.receive(try await nextCapture(&messages))
        let ended = await end.wait()
        XCTAssertTrue(ended)
        let after = await fixture.package.captureProbe(context.capture)
        XCTAssertFalse(after.active)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.renders, before.renders)
        XCTAssertEqual(after.strings, before.strings)
        XCTAssertEqual(fixture.package.services.pendingCount, 1)
        let dump = ShellFrameTrace.shared.dump()
        XCTAssertFalse(dump.contains("event=packageWake"))
        XCTAssertTrue(dump.contains("scope=native available=true incomplete=false"))
        XCTAssertTrue(dump.contains("tree_encodes=0"))
        XCTAssertTrue(dump.contains("completion_begin=1 completion_end=1"))
        fixture.mailbox.finish()
        await fixture.package.close()
    }

    func testCloseAcknowledgesQueuedBeginAndEndAsUnavailable() async throws {
        let fixture = Fixture()
        await fixture.load()
        ShellFrameTrace.shared.beginCapture()
        defer { ShellFrameTrace.shared.endCapture() }
        let context = try fixture.context()
        let begin = fixture.package.capture.request(context, .begin(joined: true))
        let end = fixture.package.capture.request(context, .end(retired: true))
        await fixture.package.close()
        let started = await begin.wait()
        let ended = await end.wait()
        XCTAssertFalse(started)
        XCTAssertFalse(ended)
        let before = ShellFrameTrace.shared.dump()
        XCTAssertEqual(before.components(separatedBy: "available=false incomplete=true").count - 1, 2)
        var messages = fixture.stream.makeAsyncIterator()
        await fixture.package.receive(try await nextCapture(&messages))
        await fixture.package.receive(try await nextCapture(&messages))
        XCTAssertEqual(ShellFrameTrace.shared.dump(), before)
        fixture.mailbox.finish()
    }

    func testCloseEndsActiveCaptureBeforeDestroyingVMAndResolvesQueuedEndOnce() async throws {
        let fixture = Fixture()
        await fixture.load()
        ShellFrameTrace.shared.beginCapture()
        defer { ShellFrameTrace.shared.endCapture() }
        let context = try fixture.context()
        var messages = fixture.stream.makeAsyncIterator()
        let begin = fixture.package.capture.request(context, .begin(joined: false))
        await fixture.package.receive(try await nextCapture(&messages))
        XCTAssertEqual(begin.result, true)
        let end = fixture.package.capture.request(context, .end(retired: false))
        let repeated = fixture.package.capture.request(context, .end(retired: true))
        XCTAssertTrue(end === repeated)
        await fixture.package.close()
        let ended = await end.wait()
        XCTAssertTrue(ended)
        let probe = await fixture.package.captureProbe(context.capture)
        XCTAssertFalse(probe.hasScript)
        let dump = ShellFrameTrace.shared.dump()
        XCTAssertEqual(dump.components(separatedBy: "scope=native ").count - 1, 1)
        XCTAssertTrue(dump.contains("boundary=retire"))
        XCTAssertTrue(dump.contains("service_generation=\(fixture.package.services.generation)"))
        XCTAssertFalse(dump.contains("available=false"))
        await fixture.package.receive(try await nextCapture(&messages))
        await fixture.package.close()
        XCTAssertEqual(ShellFrameTrace.shared.dump(), dump)
        fixture.mailbox.finish()
    }

    func testRetirementFenceWaitsForSnapshotWithoutWaitingForPackageClose() async throws {
        let fixture = Fixture()
        await fixture.load()
        ShellFrameTrace.shared.beginCapture()
        defer { ShellFrameTrace.shared.endCapture() }
        let context = try fixture.context()
        var messages = fixture.stream.makeAsyncIterator()
        _ = fixture.package.capture.request(context, .begin(joined: false))
        await fixture.package.receive(try await nextCapture(&messages))
        ShellWidgetHost.retireTraceCapture(fixture.package)
        let id = ObjectIdentifier(fixture.package)
        XCTAssertNotNil(ShellWidgetHost.traceRetiringTasks[id])
        ShellWidgetHost.sealTraceCapture()
        let late = Fixture()
        ShellWidgetHost.joinTraceCapture(late.package)
        XCTAssertNil(late.package.capture.context)
        let fence = Task { await ShellWidgetHost.finishTraceRetirements() }
        let message = try await nextCapture(&messages)
        guard case let .capture(end) = message else { return XCTFail("Expected capture end") }
        XCTAssertNil(end.result)
        await fixture.package.receive(message)
        await fence.value
        XCTAssertNil(ShellWidgetHost.traceRetiringTasks[id])
        let probe = await fixture.package.captureProbe(context.capture)
        XCTAssertTrue(probe.hasScript)
        XCTAssertFalse(probe.active)
        XCTAssertTrue(ShellFrameTrace.shared.dump().contains("boundary=retire"))
        fixture.mailbox.finish()
        late.mailbox.finish()
        await fixture.package.close()
        await late.package.close()
    }

    func testConnectedPackageJoinsBeforeNormalMessages() async throws {
        let fixture = Fixture()
        await fixture.load()
        ShellFrameTrace.shared.beginCapture()
        defer { ShellFrameTrace.shared.endCapture() }
        ShellWidgetHost.joinTraceCapture(fixture.package)
        fixture.mailbox.yield(.interval(15))
        var messages = fixture.stream.makeAsyncIterator()
        let message = try await nextCapture(&messages)
        guard case let .capture(begin) = message else { return XCTFail("Capture must be first") }
        XCTAssertEqual(begin.action, .begin(joined: true))
        await fixture.package.receive(message)
        let joined = await begin.wait()
        XCTAssertTrue(joined)
        let next = await messages.next(isolation: #isolation)
        guard case .interval(15)? = next else { return XCTFail("Normal message ordering changed") }
        XCTAssertTrue(ShellFrameTrace.shared.dump().contains("joined=true"))
        fixture.mailbox.finish()
        await fixture.package.close()
    }

    private func nextCapture(
        _ messages: inout AsyncStream<ShellWidgetMessage>.Iterator
    ) async throws -> ShellWidgetMessage {
        let value = await messages.next(isolation: #isolation)
        return try XCTUnwrap(value)
    }
}
