// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreAudio
import IOKit.ps

@MainActor
final class ShellDataFeed {
    static let weatherRetry = Duration.seconds(5 * 60)
    static let slowSampler = DispatchQueue(label: "com.barut.OmniWM.shell.sampler", qos: .utility)
    nonisolated static let sampledKeys: [ShellDataKey] = [
        .cpu,
        .memory,
        .gpu,
        .disk,
        .network,
        .networkHistory,
        .system
    ]
    nonisolated static let timedKeys: UInt64 = ([.seconds, .clock, .date] + sampledKeys).reduce(0) { $0 | $1.bit }

    struct Cadence: Equatable {
        var tick = 0
        var sampling = 0

        static func of(_ readers: [(deps: UInt64, interval: Double?)]) -> Cadence {
            var cadence = Cadence(tick: .max, sampling: .max)
            let sampled = sampledKeys.reduce(UInt64(0)) { $0 | $1.bit }
            let slow = ShellDataKey.clock.bit | ShellDataKey.date.bit | ShellDataKey.weather.bit
            for reader in readers {
                let declared = reader.interval.map { max(1, Int($0.rounded(.up))) }
                if reader.deps & ShellDataKey.seconds.bit != 0 {
                    cadence.tick = min(cadence.tick, declared ?? 1)
                }
                if reader.deps & sampled != 0 {
                    cadence.tick = min(cadence.tick, declared ?? 2)
                    cadence.sampling = min(cadence.sampling, declared ?? 2)
                }
                if reader.deps & slow != 0 {
                    cadence.tick = min(cadence.tick, declared ?? 60)
                }
            }
            return Cadence(
                tick: cadence.tick == .max ? 0 : cadence.tick,
                sampling: cadence.sampling == .max ? 0 : cadence.sampling
            )
        }
    }

    private let deliver: @MainActor (ShellWidgetData) -> Void
    let onBadgesDemandChange: @MainActor (Bool) -> Void
    let loadWeather: @Sendable (ShellWeatherLocation) async throws -> ShellWeatherReading
    private let clockFormatter: DateFormatter
    private let dateFormatter: DateFormatter
    private var timer: DispatchSourceTimer?
    private(set) var interval = 0
    var started = false
    var paused = false
    private var powerSource: CFRunLoopSource?
    private var lowPowerObserver: (any NSObjectProtocol)?
    var cpuMeter = CPUMeter()
    var data = ShellWidgetData()
    var tick = 0
    private var sampledTick = 0
    private var demand: UInt64 = 0
    private var cadence = Cadence()
    struct AudioListener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    var audioListeners: [AudioListener] = []
    var previousNetwork: (bytes: (received: UInt64, sent: UInt64), time: TimeInterval)?
    var diskBytes: (used: Int64, total: Int64)?
    var slowSampling = false
    var diskWanted = false
    lazy var host = SystemStatsSampler.hostInfo()
    var weatherLocation: ShellWeatherLocation?
    var weatherQuery: ShellWeatherLocation?
    var weatherTask: Task<Void, Never>?
    var nextWeather: ContinuousClock.Instant?

    let appVolumes: AppVolumeMixer?
    let media: MediaController?
    let lyrics: LyricsController
    let calendar: CalendarController?
    let devices: ShellDevices?

    init(
        loadWeather: @escaping @Sendable (ShellWeatherLocation) async throws -> ShellWeatherReading =
            ShellWeatherClient.forecast,
        appVolumes: AppVolumeMixer? = nil,
        media: MediaController? = nil,
        lyrics: LyricsController = LyricsController(),
        calendar: CalendarController? = nil,
        devices: ShellDevices? = nil,
        onBadgesDemandChange: @escaping @MainActor (Bool) -> Void = { _ in },
        deliver: @escaping @MainActor (ShellWidgetData) -> Void
    ) {
        self.deliver = deliver
        self.onBadgesDemandChange = onBadgesDemandChange
        self.loadWeather = loadWeather
        self.appVolumes = appVolumes
        self.media = media
        self.lyrics = lyrics
        self.calendar = calendar
        self.devices = devices
        clockFormatter = DateFormatter()
        clockFormatter.timeStyle = .short
        clockFormatter.dateStyle = .none
        dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        lyrics.onLoad = { [weak self] value in
            guard let self, data.lyrics != value else { return }
            data.lyrics = value
            publish()
        }
    }

    var current: ShellWidgetData {
        data
    }

    var observesPowerSources: Bool {
        powerSource != nil
    }

    func setWorld(_ world: ShellWorldData) {
        guard world != data.world else { return }
        data.world = world
        publish()
    }

    func setHiddenBar(_ hiddenBar: ShellHiddenBarData) {
        guard hiddenBar != data.hiddenBar else { return }
        data.hiddenBar = hiddenBar
        publish()
    }

    func setBadges(_ labels: [String: String]) {
        guard labels != data.badges else { return }
        data.badges = labels
        publish()
    }

    func listenToBadges() {
        let listening = started && !paused && demands(.badges)
        if !listening { data.badges = [:] }
        onBadgesDemandChange(listening)
    }

    func setVars(_ vars: [String: String]) {
        guard vars != data.vars else { return }
        data.vars = vars
        publish()
    }

    func start() {
        guard !started else { return }
        started = true
        listenToBadges()
        sampleBattery()
        refresh()
        deliver(data)
        reschedule()
    }

    func stop() {
        started = false
        listenToBadges()
        cancelTimer()
        removeAudioListeners()
        listAudioApps(false)
        listenToMedia(false)
        showLyrics(false)
        listenToCalendar(false)
        listenToReminders(false)
        devices.map(stopDevices)
        weatherTask?.cancel()
        weatherTask = nil
        removePowerSource()
    }

    func setPaused(_ isPaused: Bool) {
        guard paused != isPaused else { return }
        paused = isPaused
        updateProviders()
        guard !paused, started else { return }
        refresh()
        deliver(data)
    }

    func publish() {
        guard !paused else { return }
        deliver(data)
    }

    private var desiredInterval: Int {
        started && !paused ? cadence.tick : 0
    }

    func reschedule() {
        let next = desiredInterval
        guard next != interval else { return }
        cancelTimer()
        interval = next
        guard next > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            self?.fire()
        }
        self.timer = timer
        arm(timer)
        timer.resume()
    }

    private func arm(_ timer: DispatchSourceTimer) {
        let step = Double(interval)
        let now = Date().timeIntervalSince1970
        let next = (now / step).rounded(.down) * step + step
        timer.schedule(
            wallDeadline: .now() + (next - now),
            leeway: .milliseconds(interval >= 60 ? 500 : 50)
        )
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        interval = 0
    }

    func observePowerSources() {
        guard powerSource == nil else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let feed = Unmanaged<ShellDataFeed>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                feed.powerSourcesChanged()
            }
        }, context)?.takeRetainedValue() else {
            Unmanaged<ShellDataFeed>.fromOpaque(context).release()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.powerSourcesChanged()
            }
        }
    }

    func removePowerSource() {
        guard let powerSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
        self.powerSource = nil
        lowPowerObserver.map(NotificationCenter.default.removeObserver)
        lowPowerObserver = nil
        Unmanaged.passUnretained(self).release()
    }

    private func powerSourcesChanged() {
        let previous = (data.battery, data.charging, data.power)
        sampleBattery()
        if previous != (data.battery, data.charging, data.power) {
            publish()
        }
    }

    private func fire() {
        guard let timer else { return }
        let previous = data
        tick += interval
        if cadence.sampling > 0, tick - sampledTick >= cadence.sampling {
            sampledTick = tick
            sampleSystem()
        }
        updateWeather()
        refresh()
        arm(timer)
        if data != previous {
            deliver(data)
        }
    }

    private func refresh() {
        let now = Date()
        data.clock = clockFormatter.string(from: now)
        data.date = dateFormatter.string(from: now)
        data.seconds = now.timeIntervalSince1970.rounded(.down)
    }

    func setDemand(_ deps: UInt64, cadence: Cadence) {
        guard deps != demand || cadence != self.cadence else { return }
        let changed = deps != demand
        demand = deps
        self.cadence = cadence
        updateProviders()
        if changed {
            publish()
        }
    }

    func demands(_ key: ShellDataKey) -> Bool {
        demand & key.bit != 0
    }
}
