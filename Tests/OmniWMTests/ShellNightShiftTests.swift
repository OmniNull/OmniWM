// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class ShellNightShiftTests: XCTestCase {
    @MainActor
    private final class Device {
        var enabled: Bool? = false
        var reads = 0
        var writes: [Bool] = []
        var acceptsWrites = true

        var access: ShellNightShiftAccess {
            ShellNightShiftAccess(
                read: { [self] in
                    reads += 1
                    return enabled
                },
                setEnabled: { [self] requested in
                    writes.append(requested)
                    if acceptsWrites { enabled = requested }
                    return acceptsWrites
                }
            )
        }
    }

    func testAcceptsOnlyExplicitOnAndOffCommands() {
        XCTAssertEqual(ShellAction("night-shift on"), .nightShift(.on))
        XCTAssertEqual(ShellAction("night-shift off"), .nightShift(.off))
        for command in ["night-shift", "night-shift toggle", "night-shift on off", "night-shift settings"] {
            XCTAssertNil(ShellAction(command), command)
        }
    }

    func testWritesUseReadbackAndSkipUnsupportedOrAlreadyMatchingStates() {
        let device = Device()
        let monitor = ShellNightShiftMonitor(access: device.access)
        monitor.setListening(true)
        XCTAssertEqual(monitor.value, ShellNightShift(available: true, enabled: false))
        XCTAssertTrue(monitor.perform(.off))
        XCTAssertTrue(device.writes.isEmpty)
        XCTAssertTrue(monitor.perform(.on))
        XCTAssertEqual(monitor.value, ShellNightShift(available: true, enabled: true))
        device.acceptsWrites = false
        XCTAssertFalse(monitor.perform(.off))
        XCTAssertEqual(monitor.value, ShellNightShift(available: true, enabled: true))
        device.enabled = nil
        XCTAssertFalse(monitor.perform(.off))
        XCTAssertEqual(monitor.value, ShellNightShift())
        XCTAssertEqual(device.writes, [true, false])
    }

    func testFeedStartsReadsOnDemandAndRefreshesOnResume() {
        let device = Device()
        let monitor = ShellNightShiftMonitor(access: device.access)
        let feed = ShellDataFeed(devices: ShellDevices(nightShift: monitor), deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertEqual(device.reads, 0)
        XCTAssertNil(feed.current.nightShift)
        let demand = ShellDataKey.nightShift.bit
        feed.setDemand(demand, cadence: .of([(demand, nil)]))
        XCTAssertEqual(feed.current.nightShift, ShellNightShift(available: true, enabled: false))
        XCTAssertEqual(device.reads, 1)
        XCTAssertTrue(monitor.perform(.on))
        XCTAssertEqual(feed.current.nightShift, ShellNightShift(available: true, enabled: true))
        feed.setPaused(true)
        XCTAssertNil(feed.current.nightShift)
        device.enabled = false
        feed.setPaused(false)
        XCTAssertEqual(feed.current.nightShift, ShellNightShift(available: true, enabled: false))
        feed.setDemand(0, cadence: .init())
        XCTAssertNil(feed.current.nightShift)
        feed.setDemand(demand, cadence: .of([(demand, nil)]))
        feed.stop()
        XCTAssertNil(feed.current.nightShift)
        XCTAssertNil(monitor.value)
    }

    func testPackagePublishesNightShiftBooleansAndTracksDemand() async {
        let package = ShellWidgetPackage(name: "night-shift", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx)
            local status = ctx.data.nightShift
            if not status then return ui.box{w=10,h=10} end
            assert(type(status.available) == 'boolean' and type(status.enabled) == 'boolean')
            return ui.box{w=status.available and (status.enabled and 40 or 30) or 20,h=10}
        end
        """)
        XCTAssertNil(failure)
        let key = ShellBarKey(monitor: .init(displayId: 96602))
        await package.receive(.bars([key: ShellBarData()]))
        let demand = ShellDataKey.nightShift.bit
        XCTAssertEqual(demand, 1 << 52)
        var data = ShellWidgetData()
        for (value, width): (ShellNightShift?, Float) in [
            (ShellNightShift(available: true, enabled: true), 40),
            (ShellNightShift(available: true, enabled: false), 30),
            (ShellNightShift(), 20),
            (nil, 10)
        ] {
            let previous = data
            data.nightShift = value
            XCTAssertEqual(data.changedKeys(from: previous), demand)
            await package.receive(.update(data))
            let output = await package.systemControlOutput(key)
            XCTAssertEqual(output?.width, width)
            XCTAssertEqual(output?.demand, demand)
        }
        await package.close()
    }
}
