// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellBetterDisplayTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let id = UUID()
        let other = UUID()
        let virtual = UUID()
        let center = NotificationCenter()
        var pid: pid_t?
        var pidReads = 0
        var applicationsChanged: (@MainActor @Sendable () -> Void)?
        var readIDs: [[UUID]] = []
        var level = 0.5
        var nightShift: Bool? = false
        var holdRead: XCTestExpectation?
        var resumeRead: CheckedContinuation<[UUID: ShellBetterDisplayClient.Level], Never>?
        var actions: [ShellBetterDisplayCommand] = []
        var targets: [pid_t] = []

        func monitor() -> ShellBetterDisplayMonitor {
            let client = ShellBetterDisplayClient(
                runningPID: { self.pidReads += 1
                    return self.pid
                },
                brightness: { await self.read($0) },
                nightShift: { await self.nightShift },
                setBrightness: { await self.record(.brightness(id: $1, percent: $2 * 100), pid: $0) },
                setNightShift: { await self.record(.nightShift($1 ? .on : .off), pid: $0) },
                openMenu: { await self.record(.menu, pid: $0) }
            )
            return ShellBetterDisplayMonitor(
                client: client, monitors: {
                    [self.display(self.id, number: 1), self.display(self.other, number: 2), self.display(self.virtual, number: 3)]
                }, center: center, observeApplications: { changed in
                    self.applicationsChanged = changed
                    return { self.applicationsChanged = nil }
                }
            )
        }

        private func display(_ id: UUID, number: CGDirectDisplayID) -> Monitor {
            Monitor(
                id: .init(displayId: number),
                displayId: number,
                frame: .zero,
                visibleFrame: .zero,
                hasNotch: false,
                name: "Screen \(number)",
                displayUUID: id.uuidString,
                isMain: number == 1
            )
        }

        private func read(_ ids: [UUID]) async -> [UUID: ShellBetterDisplayClient.Level] {
            readIDs.append(ids)
            guard let holdRead else { return [id: .init(value: level), other: .init(value: nil)] }
            self.holdRead = nil
            return await withCheckedContinuation { continuation in
                resumeRead = continuation
                holdRead.fulfill()
            }
        }

        private func record(_ action: ShellBetterDisplayCommand, pid: pid_t) -> Bool {
            targets.append(pid)
            actions.append(action)
            return true
        }
    }

    func testParsesOnlyExactScopedCommands() {
        let id = UUID()
        XCTAssertEqual(
            ShellAction("betterdisplay brightness \(id) set 42.5"),
            .betterDisplay(.brightness(id: id, percent: 42.5))
        )
        XCTAssertEqual(ShellAction("betterdisplay night-shift on"), .betterDisplay(.nightShift(.on)))
        XCTAssertEqual(ShellAction("betterdisplay night-shift off"), .betterDisplay(.nightShift(.off)))
        XCTAssertEqual(ShellAction("betterdisplay menu"), .betterDisplay(.menu))
        for words in [
            "",
            "menu extra",
            "night-shift toggle",
            "brightness 1 set 40",
            "brightness \(id) set -1",
            "brightness \(id) set 101",
            "brightness \(id) set nan",
            "brightness \(id) set inf",
            "brightness \(id) set"
        ] {
            XCTAssertNil(ShellAction("betterdisplay \(words)"))
        }
    }

    func testFeedWatchesRunningApplicationsOnlyWhileDemandedAndDropsPreviousInstanceReads() async throws {
        let fixture = Fixture()
        let source = fixture.monitor()
        let published = expectation(description: "replacement app read")
        let feed = ShellDataFeed(devices: ShellDevices(betterDisplay: source)) { data in
            if data.betterDisplay?.displays.first?.value == 75 { published.fulfill() }
        }
        defer { feed.stop() }
        feed.start()
        XCTAssertEqual(fixture.pidReads, 0)
        XCTAssertNil(fixture.applicationsChanged)
        XCTAssertNil(feed.current.betterDisplay)
        let demand = ShellDataKey.betterDisplay.bit
        feed.setDemand(demand, cadence: .of([(demand, nil)]))
        XCTAssertNotNil(fixture.applicationsChanged)
        XCTAssertEqual(feed.current.betterDisplay, .init())
        XCTAssertTrue(fixture.readIDs.isEmpty)
        let started = expectation(description: "first app read")
        fixture.holdRead = started
        fixture.pid = 100
        fixture.applicationsChanged?()
        XCTAssertEqual(feed.current.betterDisplay, .init(running: true))
        let first = try XCTUnwrap(source.sample)
        await fulfillment(of: [started], timeout: failureBound)
        fixture.applicationsChanged?()
        XCTAssertFalse(first.isCancelled)
        fixture.pid = 101
        fixture.level = 0.75
        fixture.applicationsChanged?()
        XCTAssertTrue(first.isCancelled)
        await fulfillment(of: [published], timeout: failureBound)
        fixture.resumeRead?.resume(returning: [fixture.id: .init(value: 0.1)])
        await first.value
        XCTAssertEqual(feed.current.betterDisplay?.displays.map(\.value), [75, 0])
        XCTAssertEqual(feed.current.betterDisplay?.displays.map(\.available), [true, false])
        XCTAssertEqual(fixture.readIDs, Array(repeating: [fixture.id, fixture.other, fixture.virtual], count: 2))
        fixture.pid = nil
        fixture.applicationsChanged?()
        XCTAssertEqual(feed.current.betterDisplay, .init())
        feed.setPaused(true)
        XCTAssertNil(feed.current.betterDisplay)
        XCTAssertNil(fixture.applicationsChanged)
        feed.setPaused(false)
        XCTAssertEqual(feed.current.betterDisplay, .init())
        feed.setDemand(0, cadence: .init())
        XCTAssertNil(fixture.applicationsChanged)
        XCTAssertNil(feed.current.betterDisplay)
    }

    func testScreenChangesAndWritesReadBackInsteadOfInventingSuccess() async {
        let fixture = Fixture()
        fixture.pid = 42
        let source = fixture.monitor()
        defer { source.setListening(false) }
        let initial = expectation(description: "initial capabilities")
        source.onChange = { if $0?.available == true { initial.fulfill() } }
        source.setListening(true)
        await fulfillment(of: [initial], timeout: failureBound)
        XCTAssertNil(source.perform(.brightness(id: fixture.other, percent: 10)))
        XCTAssertNil(source.perform(.brightness(id: fixture.id, percent: .nan)))
        XCTAssertNil(source.perform(.brightness(id: UUID(), percent: 80)))
        let changed = expectation(description: "screen change")
        source.onChange = { if $0?.displays.first?.value == 25 { changed.fulfill() } }
        fixture.level = 0.25
        fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await fulfillment(of: [changed], timeout: failureBound)
        let readback = expectation(description: "actual settings returned after the commands")
        fixture.level = 0.2
        fixture.nightShift = true
        source.onChange = { if $0?.displays.first?.value == 20 { readback.fulfill() } }
        source.perform(.brightness(id: fixture.id, percent: 80))
        source.perform(.nightShift(.on))
        await fulfillment(of: [readback], timeout: failureBound)
        XCTAssertEqual(fixture.actions, [.brightness(id: fixture.id, percent: 80), .nightShift(.on)])
        XCTAssertEqual(fixture.targets, [42, 42])
        XCTAssertEqual(source.value?.nightShift, .init(available: true, enabled: true))
    }

    func testDismissalCompletesAcceptedActionAndRelaunchRejectsQueuedAction() async throws {
        let fixture = Fixture()
        fixture.pid = 42
        let source = fixture.monitor()
        let initial = expectation(description: "initial capabilities")
        source.onChange = { if $0?.available == true { initial.fulfill() } }
        source.setListening(true)
        await fulfillment(of: [initial], timeout: failureBound)
        let release = try XCTUnwrap(source.perform(.brightness(id: fixture.id, percent: 75)))
        source.setListening(false)
        await release.value
        XCTAssertNil(source.value)
        XCTAssertNil(source.sample)
        XCTAssertEqual(fixture.actions, [.brightness(id: fixture.id, percent: 75)])
        let menu = try XCTUnwrap(source.perform(.menu))
        fixture.pid = 43
        let replacement = try XCTUnwrap(source.perform(.menu))
        await menu.value
        await replacement.value
        XCTAssertEqual(fixture.actions, [.brightness(id: fixture.id, percent: 75), .menu])
        XCTAssertEqual(fixture.targets, [42, 43])
        fixture.pid = nil
        XCTAssertNil(source.perform(.menu))
    }

    func testWidgetReceivesOnlyTheAppendedDependencyAndProviderCapabilities() async {
        let package = ShellWidgetPackage(name: "betterdisplay", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx)
            local b = ctx.data.betterDisplay
            if not b or not b.running then return ui.box{w=b and 2 or 1,h=10} end
            if not b.available then return ui.box{w=3,h=10} end
            assert(b.nightShift.enabled and b.nightShift.available)
            local d = b.displays[1]
            assert(d.id == "97CD864A-7BC1-406A-8495-BDF9CC5250E4" and d.name == "Test" and d.available)
            return ui.box{w=d.value,h=10}
        end
        """)
        XCTAssertNil(failure)
        let key = ShellBarKey(monitor: .init(displayId: 96701))
        await package.receive(.bars([key: ShellBarData()]))
        let demand = ShellDataKey.betterDisplay.bit
        XCTAssertEqual(demand, 1 << 53)
        var data = ShellWidgetData()
        let display = ShellBrightness.Display(
            id: "97CD864A-7BC1-406A-8495-BDF9CC5250E4",
            name: "Test",
            value: 63,
            available: true
        )
        for (value, width): (ShellBetterDisplay?, Float) in [
            (.init(), 2), (.init(running: true), 3),
            (.init(running: true, displays: [display], nightShift: .init(available: true, enabled: true)), 63), (nil, 1)
        ] {
            let previous = data
            data.betterDisplay = value
            XCTAssertEqual(data.changedKeys(from: previous), demand)
            await package.receive(.update(data))
            let output = await package.systemControlOutput(key)
            XCTAssertEqual(output?.width, width)
            XCTAssertEqual(output?.demand, demand)
        }
        await package.close()
    }
}
