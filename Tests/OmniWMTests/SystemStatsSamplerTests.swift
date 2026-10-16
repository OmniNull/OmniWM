// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SystemStatsSamplerTests: XCTestCase {
    @MainActor
    func testTheFeedDeliversDiskUsageSampledOffTheMainThread() async {
        final class Latest {
            var data: ShellWidgetData?
        }
        let latest = Latest()
        let feed = ShellDataFeed(deliver: { latest.data = $0 })
        defer { feed.stop() }
        feed.start()
        let keys = ShellDataKey.disk.bit | ShellDataKey.system.bit
        feed.setDemand(keys, cadence: .of([(keys, nil)]))
        await until { latest.data?.disk != nil && (latest.data?.system?.diskTotal ?? 0) > 0 }
        XCTAssertNotNil(latest.data?.disk)
        XCTAssertGreaterThan(latest.data?.system?.diskTotal ?? 0, 0)
    }

    @MainActor
    func testTheFeedKeepsANetworkHistoryOnlyWhileAWidgetReadsIt() async {
        final class Latest {
            var data: ShellWidgetData?
        }
        let latest = Latest()
        let feed = ShellDataFeed(deliver: { latest.data = $0 })
        defer { feed.stop() }
        feed.start()
        let keys = ShellDataKey.networkHistory.bit
        feed.setDemand(keys, cadence: .of([(keys, 0.1)]))
        await until { (latest.data?.networkHistory?.down.count ?? 0) >= 2 }
        XCTAssertGreaterThan(latest.data?.networkHistory?.received ?? 0, 0)
        XCTAssertEqual(latest.data?.networkHistory?.up.count, latest.data?.networkHistory?.down.count)
        XCTAssertNil(latest.data?.network)
        let clock = ShellDataKey.clock.bit
        feed.setDemand(clock, cadence: .of([(clock, nil)]))
        XCTAssertNil(feed.current.networkHistory)

        var history = ShellNetworkHistory()
        for value in 0 ..< 40 {
            history.append(ShellNetworkRate(down: Double(value), up: 1))
        }
        XCTAssertEqual(history.down.count, ShellNetworkHistory.length)
        XCTAssertEqual(history.down.first, 9)
        XCTAssertEqual(history.down.last, 39)
    }

    func testBatteryDetailsAndUptimeIncludeEverythingSinceBoot() {
        var power = ShellPower()
        power.describe([
            "CycleCount": 120,
            "AppleRawMaxCapacity": 4500,
            "DesignCapacity": 5000,
            "Temperature": 3050,
            "Voltage": 12500,
            "InstantAmperage": -1200,
            "AdapterDetails": ["Watts": 96]
        ])
        XCTAssertEqual(power.cycles, 120)
        XCTAssertEqual(power.health, 90)
        XCTAssertEqual(power.temperature, 30.5)
        XCTAssertEqual(power.watts, -15)
        XCTAssertEqual(power.adapter, 96)

        var empty = ShellPower()
        empty.describe(["AdapterDetails": ["FamilyCode": 0]])
        XCTAssertNil(empty.cycles)
        XCTAssertNil(empty.health)
        XCTAssertNil(empty.watts)
        XCTAssertNil(empty.adapter)

        XCTAssertGreaterThanOrEqual(SystemStatsSampler.uptime(), ProcessInfo.processInfo.systemUptime - 1)
    }

    func testCPUMeterMeasuresOverAtLeastHalfASecond() {
        var meter = CPUMeter()
        XCTAssertTrue(meter.isDue(at: 10))
        XCTAssertNil(meter.usage(of: CPUTicks(busy: 100, idle: 100), at: 10))
        XCTAssertFalse(meter.isDue(at: 10.01))
        XCTAssertTrue(meter.isDue(at: 10.5))
        XCTAssertEqual(meter.usage(of: CPUTicks(busy: 150, idle: 150), at: 10.5), 0.5)
        meter.reset()
        XCTAssertTrue(meter.isDue(at: 10.6))
        XCTAssertNil(meter.usage(of: CPUTicks(busy: 400, idle: 150), at: 10.6))
    }

    func testCPUUsageFromTickDeltas() {
        let previous = CPUTicks(busy: 1000, idle: 3000)
        let current = CPUTicks(busy: 1300, idle: 3900)

        XCTAssertEqual(SystemStatsSampler.cpuUsage(previous: previous, current: current), 0.25)
    }

    func testCPUUsageZeroDeltaReturnsNil() {
        let ticks = CPUTicks(busy: 500, idle: 500)

        XCTAssertNil(SystemStatsSampler.cpuUsage(previous: ticks, current: ticks))
    }

    func testCPUUsageFirstSampleReturnsNil() {
        XCTAssertNil(SystemStatsSampler.cpuUsage(previous: nil, current: CPUTicks(busy: 1, idle: 1)))
        XCTAssertNil(SystemStatsSampler.cpuUsage(previous: CPUTicks(busy: 1, idle: 1), current: nil))
    }

    func testMemoryUsedFormula() {
        XCTAssertEqual(
            SystemStatsSampler.memoryUsed(activePages: 100, wiredPages: 50, compressedPages: 25, pageSize: 16384),
            175 * 16384
        )
    }

    func testMemoryPressureMapping() {
        XCTAssertEqual(SystemStatsSampler.pressureLevel(fromSysctlValue: 1), .normal)
        XCTAssertEqual(SystemStatsSampler.pressureLevel(fromSysctlValue: 2), .warning)
        XCTAssertEqual(SystemStatsSampler.pressureLevel(fromSysctlValue: 4), .critical)
        XCTAssertNil(SystemStatsSampler.pressureLevel(fromSysctlValue: 0))
        XCTAssertNil(SystemStatsSampler.pressureLevel(fromSysctlValue: 3))
        XCTAssertNil(SystemStatsSampler.pressureLevel(fromSysctlValue: -1))
        XCTAssertNil(SystemStatsSampler.pressureLevel(fromSysctlValue: nil))
    }
}
