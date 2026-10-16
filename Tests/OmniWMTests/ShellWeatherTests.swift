// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

@MainActor
final class ShellWeatherTests: XCTestCase {
    private final class Loads: Sendable {
        private let queries = Mutex<[ShellWeatherLocation]>([])

        func record(_ query: ShellWeatherLocation) {
            queries.withLock { $0.append(query) }
        }

        var all: [ShellWeatherLocation] {
            queries.withLock { $0 }
        }
    }

    private static let report = Data("""
    {"current":{"temperature_2m":21.4,"apparent_temperature":20.1,"is_day":0,"weather_code":2,"wind_speed_10m":9.5,
                 "relative_humidity_2m":63},
     "daily":{"temperature_2m_max":[24.0],"temperature_2m_min":[13.2],"precipitation_probability_max":[null],
              "sunrise":[1791441000],"sunset":[1791480000]}}
    """.utf8)

    func testReportsDecodeIntoWidgetWeather() throws {
        let weather = try ShellWeatherClient.weather(from: Self.report, fahrenheit: true)
        XCTAssertEqual(weather.temp, 21.4)
        XCTAssertEqual(weather.high, 24)
        XCTAssertNil(weather.rain)
        XCTAssertEqual(weather.unit, "°F")
        XCTAssertFalse(weather.day)
        XCTAssertEqual(weather.condition.symbol, "cloud.moon")
        XCTAssertEqual(weather.humidity, 63)
        XCTAssertEqual(weather.sunrise, 1_791_441_000)
        XCTAssertEqual(weather.sunset, 1_791_480_000)
        XCTAssertThrowsError(try ShellWeatherClient.weather(from: Data("{}".utf8), fahrenheit: false))
    }

    func testForecastsDecodeWithLabelsInThePlacesTimeZone() throws {
        let report = Data("""
        {"utc_offset_seconds":3600,
         "current":{"temperature_2m":5,"is_day":1,"weather_code":0},
         "hourly":{"time":[1791464400,1791468000,1791471600],"temperature_2m":[5.4,null,7],
                   "weather_code":[0,3,61],"is_day":[1,1,0],"precipitation_probability":[0,10,80]},
         "daily":{"time":[1791414000,1791500400],"temperature_2m_max":[9,12],"temperature_2m_min":[2,4],
                  "precipitation_probability_max":[20,null],"weather_code":[3,95]}}
        """.utf8)
        let locale = Locale(identifier: "en_US")
        let weather = try ShellWeatherClient.weather(from: report, fahrenheit: false, locale: locale)
        XCTAssertEqual(weather.hours.map { $0.label.replacingOccurrences(of: "\u{202F}", with: " ") }, ["2 PM", "4 PM"])
        XCTAssertEqual(weather.hours.map(\.temp), [5.4, 7])
        XCTAssertEqual(weather.hours.last?.rain, 80)
        XCTAssertFalse(try XCTUnwrap(weather.hours.last).day)
        XCTAssertEqual(weather.days.map(\.high), [9, 12])
        XCTAssertEqual(weather.days.last?.label, "Fri")
        XCTAssertNil(weather.days.last?.rain)
        let relative = DateFormatter()
        relative.locale = locale
        relative.timeZone = TimeZone(secondsFromGMT: 3600)
        relative.dateStyle = .medium
        relative.doesRelativeDateFormatting = true
        XCTAssertEqual(weather.days.first?.label, relative.string(from: Date(timeIntervalSince1970: 1791414000)))
        XCTAssertEqual(ShellWeather.condition(code: 95, day: true).symbol, "cloud.bolt.rain")
        XCTAssertNil(weather.humidity)
        XCTAssertNil(weather.sunrise)
    }

    func testConfigReadsCityOrCoordinates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cases: [(String, ShellWeatherLocation?)] = [
            (
                "[weather]\ncity = \"Toronto\"\nunits = \"fahrenheit\"\n",
                .init(place: .city("Toronto"), fahrenheit: true)
            ),
            (
                "[weather]\nlatitude = 43.6\nlongitude = -79\n",
                .init(place: .coordinates(latitude: 43.6, longitude: -79))
            ),
            ("[weather]\nlatitude = 120\nlongitude = 0\n", nil),
            ("[weather]\ncity = \"Toronto\"\nunits = \"kelvin\"\n", nil),
            ("", nil)
        ]
        for (toml, expected) in cases {
            try Data(toml.utf8).write(to: root.appendingPathComponent("shell.toml"))
            XCTAssertEqual(try XCTUnwrap(ShellConfig.load(shellDirectory: root)).weather, expected, toml)
        }
    }

    func testConfigReadsWidgetIntervalsAndWeatherRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        [profiles.default.widgets.stats]
        interval = 10
        [weather]
        city = "Toronto"
        refresh = 30
        """.utf8).write(to: root.appendingPathComponent("shell.toml"))
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.widgetIntervals, ["stats": 10])
        XCTAssertEqual(config.weather?.refresh, .seconds(1800))

        for refresh in ["inf", "1e300"] {
            try Data("""
            [profiles.default.widgets.forever]
            interval = inf
            [profiles.default.widgets.never]
            interval = nan
            [weather]
            city = "Toronto"
            refresh = \(refresh)
            """.utf8).write(to: root.appendingPathComponent("shell.toml"))
            let unbounded = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
            XCTAssertEqual(unbounded.widgetIntervals, ["forever": ShellWidgetDeclaration.maximumInterval])
            XCTAssertEqual(unbounded.weather?.refresh, .seconds(24 * 60 * 60))
        }
    }

    func testFeedFetchesWeatherOnlyWhileDemandedAndRefetchesForNewLocations() async throws {
        let loads = Loads()
        let weather = try ShellWeatherClient.weather(from: Self.report, fahrenheit: false)
        let (deliveries, delivered) = AsyncStream.makeStream(of: ShellWidgetData.self)
        let feed = ShellDataFeed(loadWeather: { query in
            loads.record(query)
            return ShellWeatherReading(weather: weather, latitude: 1, longitude: 2)
        }, deliver: { delivered.yield($0) })
        var updates = deliveries.makeAsyncIterator()
        defer { feed.stop() }

        feed.setWeatherLocation(ShellWeatherLocation(place: .city("Toronto")))
        XCTAssertTrue(loads.all.isEmpty)

        feed.setDemand(ShellDataKey.weather.bit, cadence: .of([(ShellDataKey.weather.bit, nil)]))
        while await updates.next()?.weather != weather {}
        XCTAssertEqual(loads.all, [ShellWeatherLocation(place: .city("Toronto"))])

        feed.setDemand(
            ShellDataKey.weather.bit | ShellDataKey.cpu.bit,
            cadence: .of([(ShellDataKey.weather.bit | ShellDataKey.cpu.bit, nil)])
        )
        XCTAssertEqual(loads.all.count, 1)

        let paris = ShellWeatherLocation(place: .coordinates(latitude: 48.9, longitude: 2.3))
        feed.setWeatherLocation(paris)
        XCTAssertNil(feed.current.weather)
        while await updates.next()?.weather != nil {}
        while await updates.next()?.weather != weather {}
        XCTAssertEqual(loads.all.last, paris)
    }

    func testAFailedRefreshMarksTheLastWeatherStaleAndKeepsThePlace() async throws {
        let failing = Mutex(false)
        let loads = Loads()
        var weather = try ShellWeatherClient.weather(from: Self.report, fahrenheit: false)
        weather.place = "Toronto"
        let (deliveries, delivered) = AsyncStream.makeStream(of: ShellWidgetData.self)
        let feed = ShellDataFeed(loadWeather: { [weather] query in
            loads.record(query)
            if failing.withLock({ $0 }) {
                throw URLError(.notConnectedToInternet)
            }
            return ShellWeatherReading(weather: weather, latitude: 1, longitude: 2)
        }, deliver: { delivered.yield($0) })
        var updates = deliveries.makeAsyncIterator()
        defer { feed.stop() }
        feed.setWeatherLocation(ShellWeatherLocation(place: .city("Toronto"), refresh: .zero))
        feed.setDemand(ShellDataKey.weather.bit, cadence: .of([(ShellDataKey.weather.bit, nil)]))
        while await updates.next()?.weather != weather {}

        failing.withLock { $0 = true }
        feed.setDemand(
            ShellDataKey.weather.bit | ShellDataKey.cpu.bit,
            cadence: .of([(ShellDataKey.weather.bit | ShellDataKey.cpu.bit, nil)])
        )
        while await updates.next()?.weather?.stale != true {}
        XCTAssertEqual(feed.current.weather?.temp, weather.temp)
        XCTAssertEqual(loads.all.last?.name, "Toronto")
        XCTAssertEqual(loads.all.last?.place, .coordinates(latitude: 1, longitude: 2))
    }

    func testTheWeatherPopoutShowsTheForecastAndAStaleNotice() throws {
        let widget = try ShellRenderedWidget("weather")
        var weather = try ShellWeatherClient.weather(from: Self.report, fahrenheit: false)
        weather.place = "Toronto"
        weather.hours = [ShellWeatherHour(time: 0, label: "2 PM", temp: 5, code: 0, day: true, rain: nil)]
        weather.days = [ShellWeatherDay(time: 0, label: "Wed", high: 12, low: 4, code: 95, rain: 40)]
        widget.set("weather") { weather.write(into: &$0) }
        _ = widget.renderPopout()
        var strings = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(strings.contains("Toronto"))
        XCTAssertTrue(strings.contains("2 PM"))
        XCTAssertTrue(strings.contains("Wed"))
        XCTAssertTrue(strings.contains(ShellFormatter.string(kind: OMNI_FORMAT_PERCENT, 0.4, digits: 0)))
        XCTAssertFalse(strings.contains(ShellLocalizer.string("Last update failed", [])))

        weather.stale = true
        widget.set("weather") { weather.write(into: &$0) }
        _ = widget.renderPopout()
        strings = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(strings.contains(ShellLocalizer.string("Last update failed", [])))
    }
}

@MainActor
final class ShellDataFeedDemandTests: XCTestCase {
    private final class Deliveries {
        var count = 0
    }

    private func demand(_ keys: [ShellDataKey]) -> UInt64 {
        keys.reduce(0) { $0 | $1.bit }
    }

    func testCadenceFollowsTheFastestReaderAndDeclaredIntervals() {
        let cases: [([(UInt64, Double?)], ShellDataFeed.Cadence)] = [
            ([(demand([.clock]), nil)], .init(tick: 60, sampling: 0)),
            ([(demand([.date, .weather]), nil)], .init(tick: 60, sampling: 0)),
            ([(demand([.cpu]), nil)], .init(tick: 2, sampling: 2)),
            ([(demand([.network, .clock]), nil)], .init(tick: 2, sampling: 2)),
            ([(demand([.seconds, .cpu]), nil)], .init(tick: 1, sampling: 2)),
            ([(demand([.cpu]), 10), (demand([.clock]), nil)], .init(tick: 10, sampling: 10)),
            ([(demand([.cpu]), 10), (demand([.memory]), 3)], .init(tick: 3, sampling: 3)),
            ([(demand([.seconds]), 0.4)], .init(tick: 1, sampling: 0)),
            ([(demand([.app, .battery]), 5)], .init(tick: 0, sampling: 0)),
            ([], .init(tick: 0, sampling: 0))
        ]
        for (readers, cadence) in cases {
            XCTAssertEqual(
                ShellDataFeed.Cadence.of(readers.map { (deps: $0.0, interval: $0.1) }),
                cadence,
                "\(readers)"
            )
        }
        let feed = ShellDataFeed(deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertEqual(feed.interval, 0)
        feed.setDemand(demand([.cpu]), cadence: .init(tick: 7, sampling: 7))
        XCTAssertEqual(feed.interval, 7)
        feed.setDemand(0, cadence: .of([]))
        XCTAssertEqual(feed.interval, 0)
    }

    func testBatteryIsObservedOnlyWhileDemanded() {
        let feed = ShellDataFeed(deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertFalse(feed.observesPowerSources)
        feed.setDemand(demand([.battery]), cadence: .of([(demand([.battery]), nil)]))
        XCTAssertTrue(feed.observesPowerSources)
        feed.setDemand(demand([.clock]), cadence: .of([(demand([.clock]), nil)]))
        XCTAssertFalse(feed.observesPowerSources)
    }

    func testPowerDetailsArriveOnlyWhileReadAndRideTheBatteryObserver() {
        let feed = ShellDataFeed(deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        feed.setDemand(demand([.battery]), cadence: .of([(demand([.battery]), nil)]))
        XCTAssertNil(feed.current.power)
        feed.setDemand(demand([.battery, .power]), cadence: .of([(demand([.battery, .power]), nil)]))
        let power = feed.current.power
        XCTAssertEqual(power?.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled)
        XCTAssertTrue(["ac", "battery", "ups"].contains(power?.source ?? ""))
        feed.setDemand(demand([.power]), cadence: .of([(demand([.power]), nil)]))
        XCTAssertTrue(feed.observesPowerSources)
        XCTAssertEqual(feed.current.power?.source, power?.source)
        feed.setDemand(demand([.battery]), cadence: .of([(demand([.battery]), nil)]))
        XCTAssertNil(feed.current.power)
        XCTAssertEqual(ShellPower.minutes(-1), nil)
        XCTAssertEqual(ShellPower.minutes(95), 95)
        XCTAssertEqual(ShellAction("battery settings"), .settings(.battery))
        XCTAssertNil(ShellAction("battery"))
        XCTAssertEqual(
            ShellSettingsPane.battery.url?.absoluteString,
            "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        )
    }

    func testPausedFeedStopsItsTimerAndHoldsDeliveries() {
        let deliveries = Deliveries()
        let feed = ShellDataFeed(deliver: { _ in deliveries.count += 1 })
        defer { feed.stop() }
        feed.start()
        feed.setDemand(demand([.seconds, .battery]), cadence: .of([(demand([.seconds, .battery]), nil)]))
        XCTAssertEqual(feed.interval, 1)

        feed.setPaused(true)
        XCTAssertEqual(feed.interval, 0)
        XCTAssertFalse(feed.observesPowerSources)
        let held = deliveries.count
        feed.setVars(["a": "b"])
        XCTAssertEqual(deliveries.count, held)

        feed.setPaused(false)
        XCTAssertEqual(feed.interval, 1)
        XCTAssertTrue(feed.observesPowerSources)
        XCTAssertEqual(deliveries.count, held + 1)
        XCTAssertEqual(feed.current.vars, ["a": "b"])
    }

    func testCPUAndMemoryAreSampledOnlyWhileDemanded() {
        let feed = ShellDataFeed(deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertNil(feed.current.cpu)
        XCTAssertEqual(feed.current.memory, 0)

        feed.setDemand(ShellDataKey.cpu.bit, cadence: .of([(ShellDataKey.cpu.bit, nil)]))
        XCTAssertNil(feed.current.cpu)

        feed.setDemand(ShellDataKey.memory.bit, cadence: .of([(ShellDataKey.memory.bit, nil)]))
        XCTAssertGreaterThan(feed.current.memory, 0)
        XCTAssertNil(feed.current.cpu)

        feed.setDemand(0, cadence: .of([]))
        XCTAssertEqual(feed.current.memory, 0)
    }

    func testSystemDetailsAreSampledEverySecondOnlyWhileDemanded() async throws {
        let feed = ShellDataFeed(deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertNil(feed.current.system)

        feed.setDemand(ShellDataKey.system.bit, cadence: .of([(ShellDataKey.system.bit, 1)]))
        XCTAssertEqual(feed.interval, 1)
        await until { feed.current.system != nil }
        let system = try XCTUnwrap(feed.current.system)
        XCTAssertGreaterThan(system.memoryUsed, 0)
        XCTAssertGreaterThan(system.memoryTotal, system.memoryUsed)
        XCTAssertGreaterThan(system.diskTotal, system.diskUsed)
        XCTAssertGreaterThan(system.diskUsed, 0)
        XCTAssertGreaterThan(system.uptime, 0)
        XCTAssertFalse(system.host.chip.isEmpty)
        XCTAssertFalse(system.host.modelIdentifier.isEmpty)
        XCTAssertEqual(system.displays.count, NSScreen.screens.count)
        XCTAssertEqual(feed.current.memory, 0)
        XCTAssertNil(feed.current.disk)

        feed.setDemand(0, cadence: .of([]))
        XCTAssertNil(feed.current.system)
        XCTAssertEqual(feed.interval, 0)
    }

    func testDiskAskedForDuringAGPUReadIsReadOnTheNextSample() async {
        let feed = ShellDataFeed(deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        feed.tick = 1
        feed.diskBytes = (used: 1, total: 2)
        let gpu = ShellDataKey.gpu.bit
        feed.setDemand(gpu, cadence: .of([(gpu, 1)]))
        XCTAssertTrue(feed.slowSampling)
        let both = gpu | ShellDataKey.disk.bit
        feed.setDemand(both, cadence: .of([(both, 1)]))
        await until { !feed.slowSampling }
        feed.sampleSystem()
        await until { feed.diskBytes.map { $0.total != 2 } == true }
    }
}

@MainActor
final class ShellWidgetPackageRenderTests: XCTestCase {
    private final class Sink {
        var sequences: [Int] = []
    }

    func testDataUpdatesRenderOnlyWidgetsThatReadTheChangedData() async {
        let bar = ShellBarKey(monitor: Monitor.ID(displayId: 92_400))
        let sink = Sink()
        let outbox = ShellWidgetOutbox { batch in
            if let tree = batch["test"]?.trees[ShellTreeKey(bar: bar, view: .bar)] {
                sink.sequences.append(tree.sequence)
            }
        }
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: outbox)
        let failure = await package.load(source: """
        local renders = 0
        function render(ctx)
            renders += 1
            return ui.text{ text = ctx.data.clock .. tostring(renders) }
        end
        """)
        XCTAssertNil(failure)
        var data = ShellWidgetData()
        data.clock = "12:00"
        await package.receive(.update(data))
        await package.receive(.bars([bar: ShellBarData()]))
        for second in 1 ... 3 {
            data.seconds = Double(second)
            data.cpu = Double(second)
            await package.receive(.update(data))
        }
        data.clock = "12:01"
        await package.receive(.update(data))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(sink.sequences.last, 2)
        await package.close()
    }

    func testUnboundedWidgetIntervalsClampToADay() async {
        let bar = ShellBarKey(monitor: Monitor.ID(displayId: 92_403))
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        interval = math.huge
        function render(ctx)
            return ui.text{ text = ctx.data.clock }
        end
        """)
        XCTAssertNil(failure)
        let declared = await package.declaration.interval
        XCTAssertEqual(declared, ShellWidgetDeclaration.maximumInterval)
        guard declared == ShellWidgetDeclaration.maximumInterval else { return }
        XCTAssertEqual(
            ShellDataFeed.Cadence.of([(ShellDataKey.clock.bit, declared)]).tick,
            Int(ShellWidgetDeclaration.maximumInterval)
        )
        await package.receive(.interval(declared))
        await package.receive(.bars([bar: ShellBarData()]))
        var data = ShellWidgetData()
        data.clock = "12:00"
        await package.receive(.update(data))
        data.clock = "12:01"
        await package.receive(.update(data))
        await package.close()

        let undefined = ShellWidgetPackage(name: "nan", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let undefinedFailure = await undefined.load(source: "interval = 0/0\nfunction render(ctx) return ui.box{} end")
        XCTAssertNil(undefinedFailure)
        let none = await undefined.declaration.interval
        XCTAssertNil(none)
        await undefined.close()
    }

    func testSlowWidgetsSkipTimedUpdatesButNotOtherData() async {
        let bar = ShellBarKey(monitor: Monitor.ID(displayId: 92_402))
        let sink = Sink()
        let outbox = ShellWidgetOutbox { batch in
            if let tree = batch["test"]?.trees[ShellTreeKey(bar: bar, view: .bar)] {
                sink.sequences.append(tree.sequence)
            }
        }
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: outbox)
        let failure = await package.load(source: """
        interval = 3600
        function render(ctx)
            return ui.text{ text = ctx.data.clock .. ctx.data.app }
        end
        """)
        XCTAssertNil(failure)
        let declared = await package.declaration.interval
        XCTAssertEqual(declared, 3600)
        await package.receive(.interval(3600))
        var data = ShellWidgetData()
        data.clock = "12:00"
        await package.receive(.update(data))
        await package.receive(.bars([bar: ShellBarData()]))
        data.clock = "12:01"
        await package.receive(.update(data))
        data.world.app = "Finder"
        await package.receive(.update(data))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(sink.sequences.last, 2)
        await package.close()
    }

    func testStringsRetireIntoANewEpochPastTheLimit() async {
        let bar = ShellBarKey(monitor: Monitor.ID(displayId: 92_401))
        let sink = EpochSink()
        let outbox = ShellWidgetOutbox { batch in
            guard let delivery = batch["test"], !delivery.trees.isEmpty else { return }
            if delivery.epoch != sink.epoch {
                sink.epoch = delivery.epoch
                sink.text = ShellTextStore()
            }
            sink.text.ingest(delivery.strings, count: delivery.stringCount)
        }
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: outbox)
        let failure = await package.load(source: "function render(ctx) return ui.text{ text = ctx.data.vars.n } end")
        XCTAssertNil(failure)
        var data = ShellWidgetData()
        data.vars = ["n": "v0"]
        await package.receive(.update(data))
        await package.receive(.bars([bar: ShellBarData()]))
        let last = Int(ShellWidgetPackage.stringLimit) + 64
        for value in 1 ... last {
            data.vars = ["n": "v\(value)"]
            await package.receive(.update(data))
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(sink.epoch, 1)
        XCTAssertTrue(sink.text.strings.contains("v\(last)"))
        XCTAssertLessThan(sink.text.strings.count, 256)
        await package.close()
    }

    func testStringBytesRetireIntoANewEpochPastTheByteLimit() async {
        let bar = ShellBarKey(monitor: Monitor.ID(displayId: 92_404))
        let sink = EpochSink()
        let outbox = ShellWidgetOutbox { batch in
            guard let delivery = batch["test"], !delivery.trees.isEmpty else { return }
            if delivery.epoch != sink.epoch {
                sink.epoch = delivery.epoch
                sink.text = ShellTextStore()
            }
            sink.text.ingest(delivery.strings, count: delivery.stringCount)
        }
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: outbox)
        let failure = await package.load(source: """
        function render(ctx)
            return ui.text{ text = string.rep("x", 262144) .. ctx.data.vars.n }
        end
        """)
        XCTAssertNil(failure)
        var data = ShellWidgetData()
        data.vars = ["n": "v0"]
        await package.receive(.update(data))
        await package.receive(.bars([bar: ShellBarData()]))
        for value in 1 ... 64 {
            data.vars = ["n": "v\(value)"]
            await package.receive(.update(data))
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertGreaterThan(sink.epoch, 0)
        XCTAssertTrue(sink.text.strings.contains { $0.hasSuffix("v64") })
        XCTAssertLessThanOrEqual(
            sink.text.strings.reduce(0) { $0 + $1.utf8.count },
            ShellWidgetPackage.stringByteLimit + 262_144 + 16
        )
        await package.close()
    }

    func testAWidgetWithoutARenderFunctionFailsToLoad() async {
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: "function popout(ctx) return ui.box{ w = 5, h = 5 } end")
        XCTAssertEqual(failure?.kind, .compile)
        XCTAssertEqual(failure?.message, "the widget does not define a render function")
        await package.close()
    }

    private final class EpochSink {
        var epoch = 0
        var text = ShellTextStore()
    }
}
