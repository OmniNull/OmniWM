// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

private struct ShellLatestDataOutput: Sendable {
    let width: Float
    let demand: UInt64
    let action: UInt32
    let sequence: Int
}

private extension ShellWidgetPackage {
    func latestDataOutput(_ key: ShellBarKey, view: ShellWidgetView = .bar) -> ShellLatestDataOutput? {
        guard let script, let instance = script.instances[key], let state = states[key] else { return nil }
        var count = 0
        guard let pointer = omni_instance_output(instance, view.wire, &count),
              count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride else { return nil }
        let node = UnsafeRawPointer(pointer).loadUnaligned(
            fromByteOffset: MemoryLayout<omni_wire_header>.stride,
            as: omni_wire_node.self
        )
        let header = UnsafeRawPointer(pointer).loadUnaligned(as: omni_wire_header.self)
        return ShellLatestDataOutput(
            width: node.width,
            demand: header.deps,
            action: node.action,
            sequence: state.sequences[view.rawValue]
        )
    }
}

@MainActor
final class ShellLatestWidgetDataTests: XCTestCase {
    private let key = ShellBarKey(monitor: .init(displayId: 95201))

    func testSnapshotRevisionChangesOnlyForNewValuesAndReadKeepsCapturedValue() throws {
        let latest = ShellLatestWidgetData()
        XCTAssertNil(latest.read(after: 0))
        var data = ShellWidgetData()
        data.seconds = 10
        XCTAssertEqual(latest.publish(data), ShellDataKey.seconds.bit)
        let first = try XCTUnwrap(latest.read(after: 0))
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(latest.publish(data), 0)
        XCTAssertNil(latest.read(after: first.revision))
        data.seconds = 11
        data.vars = ["value": "current"]
        XCTAssertEqual(latest.publish(data), ShellDataKey.seconds.bit | ShellDataKey.vars.bit)
        let next = try XCTUnwrap(latest.read(after: first.revision))
        XCTAssertEqual(next.revision, 2)
        XCTAssertEqual(first.data.seconds, 10)
        XCTAssertTrue(first.data.vars.isEmpty)
        XCTAssertEqual(next.data.seconds, 11)
        XCTAssertEqual(next.data.vars["value"], "current")
    }

    func testStaticPackageReceivesZeroFeedMessagesWhileClockPackageIsActive() async {
        let host = host()
        let (fixed, fixedMessages) = attach("fixed", deps: 0, to: host)
        let (clock, clockMessages) = attach("clock", deps: ShellDataKey.seconds.bit, to: host)
        for value in 1 ... 8 {
            var data = ShellWidgetData()
            data.seconds = Double(value)
            host.broadcast(data)
        }
        fixed.mailbox?.finish()
        clock.mailbox?.finish()
        let fixedCount = await countDataMessages(fixedMessages)
        let clockCount = await countDataMessages(clockMessages)
        XCTAssertEqual(fixedCount, 0)
        XCTAssertEqual(clockCount, 8)
        XCTAssertEqual(host.latestData.read(after: 0)?.data.seconds, 8)
        await fixed.package?.close()
        await clock.package?.close()
    }

    func testNewDemandGetsCatchUpWithoutChangingTheGlobalDemand() async {
        let host = host()
        let (fixed, messages) = attach("fixed", deps: 0, to: host)
        let (clock, clockMessages) = attach("clock", deps: ShellDataKey.seconds.bit, to: host)
        var data = ShellWidgetData()
        data.seconds = 42
        host.broadcast(data)
        let previousGlobal = host.dataDemand
        var delivery = ShellWidgetDelivery(generation: fixed.generation)
        delivery.backgroundDemand = ShellDataKey.seconds.bit
        host.receive([fixed.name: delivery])
        XCTAssertEqual(host.dataDemand, previousGlobal)
        host.receive([fixed.name: delivery])
        fixed.mailbox?.finish()
        clock.mailbox?.finish()
        let count = await countDataMessages(messages)
        XCTAssertEqual(count, 1)
        _ = await countDataMessages(clockMessages)
        await fixed.package?.close()
        await clock.package?.close()
    }

    func testMenuAppChangesWakeOnlySubscribedPackages() async {
        let host = host()
        let (menu, menuMessages) = attach("app-menu", deps: ShellDataKey.menuApp.bit, to: host)
        let (active, activeMessages) = attach(
            "active-window", deps: ShellDataKey.app.bit | ShellDataKey.bundle.bit, to: host
        )
        var data = ShellWidgetData()
        data.world.menuApp = ShellMenuApp(pid: 42, name: "Editor", bundle: "com.example.editor")
        host.broadcast(data)
        data.world.menuApp = ShellMenuApp(pid: 43, name: "Terminal", bundle: "com.example.terminal")
        host.broadcast(data)
        host.broadcast(data)
        menu.mailbox?.finish()
        active.mailbox?.finish()
        let menuCount = await countDataMessages(menuMessages)
        let activeCount = await countDataMessages(activeMessages)
        XCTAssertEqual(menuCount, 2)
        XCTAssertEqual(activeCount, 0)
        XCTAssertEqual(host.latestData.read(after: 0)?.data.world.menuApp, data.world.menuApp)
        await menu.package?.close()
        await active.package?.close()
    }

    func testMenuAppMapHydratesAndDemandsOnlyItsOwnKey() async throws {
        let package = ShellWidgetPackage(name: "menu-map", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx)
            local app = ctx.data.menuApp
            if app then
                assert(app.name == "Editor" and app.bundle == "com.example.editor")
            end
            return ui.box{w=app and app.pid or 1,h=10}
        end
        """)
        XCTAssertNil(failure)
        await package.receive(.bars([key: ShellBarData()]))
        let empty = await package.latestDataOutput(key)
        XCTAssertEqual(empty?.width, 1)
        XCTAssertEqual(empty?.demand, ShellDataKey.menuApp.bit)
        var data = ShellWidgetData()
        data.world.menuApp = ShellMenuApp(pid: 42, name: "Editor", bundle: "com.example.editor")
        await package.receive(.update(data))
        let app = await package.latestDataOutput(key)
        XCTAssertEqual(app?.width, 42)
        XCTAssertEqual(app?.demand, ShellDataKey.menuApp.bit)
        data.world.menuApp = nil
        await package.receive(.update(data))
        let cleared = await package.latestDataOutput(key)
        XCTAssertEqual(cleared?.width, 1)
        XCTAssertEqual(cleared?.demand, ShellDataKey.menuApp.bit)
        await package.close()
    }

    func testClickHandlerReadsLatestMenuAppBeforeItsFirstSubscription() async throws {
        let latest = ShellLatestWidgetData()
        let package = ShellWidgetPackage(
            name: "latest-menu", generation: 1, outbox: ShellWidgetOutbox { _ in }, latestData: latest
        )
        let failure = await package.load(source: """
        function render(ctx)
            return ui.box{w=ctx.state.seen or 1,h=10,onClick=function(next)
                local app = next.data.menuApp
                assert(app.name == "Terminal" and app.bundle == "com.example.terminal")
                next.state.seen = app.pid
            end}
        end
        """)
        XCTAssertNil(failure)
        await package.receive(.bars([key: ShellBarData()]))
        let beforeValue = await package.latestDataOutput(key)
        let before = try XCTUnwrap(beforeValue)
        var data = ShellWidgetData()
        data.world.menuApp = ShellMenuApp(pid: 42, name: "Editor", bundle: "com.example.editor")
        latest.publish(data)
        data.world.menuApp = ShellMenuApp(pid: 43, name: "Terminal", bundle: "com.example.terminal")
        latest.publish(data)
        await package.receive(.invoke(key, .bar, action: before.action, sequence: before.sequence, event: ShellEvent()))
        let after = await package.latestDataOutput(key)
        XCTAssertEqual(after?.width, 43)
        await package.close()
    }

    func testLaterHandlerReadsLatestUnobservedDataBeforeTheFirstNewSubscription() async throws {
        let latest = ShellLatestWidgetData()
        let package = ShellWidgetPackage(
            name: "latest",
            generation: 1,
            outbox: ShellWidgetOutbox { _ in },
            latestData: latest
        )
        let failure = await package.load(source: """
        function render(ctx)
            return ui.box{w=ctx.state.seen or 1,h=10,onClick=function(next)
                next.state.seen=tonumber(next.data.vars.value)
            end}
        end
        """)
        XCTAssertNil(failure)
        await package.receive(.bars([key: ShellBarData()]))
        let beforeValue = await package.latestDataOutput(key)
        let before = try XCTUnwrap(beforeValue)
        var data = ShellWidgetData()
        data.vars = ["value": "73"]
        latest.publish(data)
        await package.receive(.invoke(key, .bar, action: before.action, sequence: before.sequence, event: ShellEvent()))
        let afterValue = await package.latestDataOutput(key)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.width, 73)
        await package.close()
    }

    func testTriggerAndPopoutUseTheLatestSnapshotWithoutADataWake() async throws {
        let latest = ShellLatestWidgetData()
        let package = ShellWidgetPackage(
            name: "latest",
            generation: 1,
            outbox: ShellWidgetOutbox { _ in },
            latestData: latest
        )
        let failure = await package.load(source: """
        function render(ctx) return ui.box{w=ctx.state.seen or 1,h=10} end
        function trigger(ctx,event) ctx.state.seen=ctx.data.seconds end
        function popout(ctx) return ui.box{w=ctx.data.seconds,h=10} end
        """)
        XCTAssertNil(failure)
        await package.receive(.bars([key: ShellBarData()]))
        var data = ShellWidgetData()
        data.seconds = 19
        latest.publish(data)
        await package.receive(.trigger(name: "read", value: nil))
        let triggered = await package.latestDataOutput(key)
        XCTAssertEqual(triggered?.width, 19)
        data.seconds = 23
        latest.publish(data)
        await package.receive(.popout(key, true))
        let popout = await package.latestDataOutput(key, view: .popout)
        XCTAssertEqual(popout?.width, 23)
        await package.receive(.popout(key, false))
        data.seconds = 31
        latest.publish(data)
        await package.receive(.dataChanged)
        await package.receive(.popout(key, true))
        let reopened = await package.latestDataOutput(key, view: .popout)
        XCTAssertEqual(reopened?.width, 31)
        XCTAssertEqual(reopened?.sequence, (popout?.sequence ?? 0) + 1)
        await package.close()
    }

    func testQueuedDataHintsConsumeLatestAndExplicitUpdateRetainsItsPayloadSemantics() async throws {
        let latest = ShellLatestWidgetData()
        var shared = ShellWidgetData()
        shared.seconds = 7
        latest.publish(shared)
        let package = ShellWidgetPackage(
            name: "latest",
            generation: 1,
            outbox: ShellWidgetOutbox { _ in },
            latestData: latest
        )
        let failure = await package.load(source: "function render(ctx) return ui.box{w=ctx.data.seconds,h=10} end")
        XCTAssertNil(failure)
        var explicit = ShellWidgetData()
        explicit.seconds = 99
        await package.receive(.update(explicit))
        await package.receive(.bars([key: ShellBarData()]))
        let direct = await package.latestDataOutput(key)
        XCTAssertEqual(direct?.width, 99)
        shared.seconds = 8
        latest.publish(shared)
        shared.seconds = 9
        latest.publish(shared)
        await package.receive(.dataChanged)
        let first = await package.latestDataOutput(key)
        XCTAssertEqual(first?.width, 9)
        await package.receive(.dataChanged)
        let redundant = await package.latestDataOutput(key)
        XCTAssertEqual(redundant?.sequence, first?.sequence)
        await package.close()
    }

    func testHostStopResetsTheSnapshotWithoutReusingAnOldRevision() throws {
        let host = host()
        var data = ShellWidgetData()
        data.vars = ["private": "previous session"]
        host.broadcast(data)
        let old = try XCTUnwrap(host.latestData.read(after: 0))
        host.stop()
        let reset = try XCTUnwrap(host.latestData.read(after: old.revision))
        XCTAssertTrue(reset.data.vars.isEmpty)
        XCTAssertGreaterThan(reset.revision, old.revision)
    }

    func testStateOnlyOneShotCallbackWhileHiddenRendersOnReveal() async throws {
        let package = ShellWidgetPackage(name: "hidden-state", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx) return ui.box{w=ctx.state.seen or 1,h=10} end
        function trigger(ctx,event)
            if event.name == "arm" then
                omniwm.after(0.01, function() ctx.state.seen=77 end)
            end
        end
        """)
        XCTAssertNil(failure)
        let monitor = Monitor(
            id: key.monitor,
            displayId: key.monitor.displayId,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 868),
            hasNotch: false,
            name: "Snapshot test"
        )
        func bar(_ visible: Bool) -> ShellBarData {
            ShellBarData(surface: ShellIslandData(
                monitor: monitor,
                geometry: ShellIslandGeometry(
                    monitor: monitor,
                    size: CGSize(width: 300, height: 150)
                ),
                visible: visible,
                fullscreen: !visible
            ))
        }
        await package.receive(.bars([key: bar(true)]))
        let before = await package.latestDataOutput(key)
        XCTAssertEqual(before?.width, 1)
        await package.receive(.bars([key: bar(false)]))
        let ready = expectation(description: "one-shot callback completion admitted")
        package.services.attachWake { ready.fulfill() }
        await package.receive(.trigger(name: "arm", value: nil))
        await fulfillment(of: [ready], timeout: 5)
        await package.receive(.services)
        let hidden = await package.latestDataOutput(key)
        XCTAssertEqual(hidden?.sequence, before?.sequence)
        await package.receive(.bars([key: bar(true)]))
        let shown = await package.latestDataOutput(key)
        XCTAssertEqual(shown?.width, 77)
        XCTAssertEqual(shown?.sequence, (before?.sequence ?? 0) + 1)
        await package.close()
    }

    func testReplacementGenerationClearsPreviousBackgroundDemand() async {
        let host = host()
        let (state, messages) = attach("fixed", deps: 0, to: host)
        state.backgroundDemand = ShellDataKey.seconds.bit
        let previous = state.package
        await previous?.close()
        state.package = nil
        let replacement = ShellWidgetPackage(
            name: state.name,
            generation: 2,
            outbox: ShellWidgetOutbox { _ in },
            latestData: host.latestData
        )
        let source = ShellWidgetSource(
            chunk: "=fixed",
            main: "function render(ctx) return ui.box{w=10,h=10} end",
            modules: []
        )
        let failure = await replacement.load(source)
        XCTAssertNil(failure)
        state.loadingGeneration = 2
        let declaration = await replacement.declaration
        host.finishLoad(state: state, package: replacement, source: source, failure: failure, declaration: declaration)
        XCTAssertEqual(state.generation, 2)
        XCTAssertEqual(state.backgroundDemand, 0)
        XCTAssertEqual(host.dataDemand & ShellDataKey.seconds.bit, 0)
        _ = await countDataMessages(messages)
        host.stop()
        await replacement.close()
    }

    private func attach(
        _ name: String,
        deps: UInt64,
        to host: ShellWidgetHost
    ) -> (ShellWidgetHost.WidgetState, AsyncStream<ShellWidgetMessage>) {
        let state = ShellWidgetHost.WidgetState(name: name, sourceURL: URL(fileURLWithPath: "/unused/\(name)"))
        state.package = ShellWidgetPackage(
            name: name,
            generation: 1,
            outbox: ShellWidgetOutbox { _ in },
            latestData: host.latestData
        )
        state.generation = 1
        let instance = ShellWidgetHost.InstanceState()
        instance.deps = deps
        state.instances[key] = instance
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        state.mailbox = mailbox
        host.widgets[name] = state
        return (state, messages)
    }

    private func countDataMessages(_ messages: AsyncStream<ShellWidgetMessage>) async -> Int {
        var count = 0
        for await message in messages {
            if case .dataChanged = message { count += 1 } else { XCTFail("Unexpected feed message") }
        }
        return count
    }

    private func host() -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() },
            vars: { [:] },
            bars: { [:] },
            onLayoutChange: {},
            onCommand: { _, _ in },
            onMenu: { _ in },
            onPreview: { _ in },
            onDrag: { _ in },
            onPopoutChange: {},
            onTitleDemandChange: { _ in }
        )
    }
}
