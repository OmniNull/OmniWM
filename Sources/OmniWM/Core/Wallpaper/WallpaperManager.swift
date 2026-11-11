// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import Observation

struct WallpaperPaletteState: Equatable, Sendable {
    var active = false
    var scheme = ShellWallpaperScheme.tonalSpot
}

@MainActor
protocol WallpaperPaletteTarget: AnyObject {
    var wallpaperPaletteState: WallpaperPaletteState { get }
    func publishWallpaperPalette(_ pixels: [UInt32]) -> Bool
}

enum WallpaperTarget: Equatable, Sendable {
    case all
    case display(String)
}

struct WallpaperEnvironment {
    var home = NSHomeDirectory()
    var now: @MainActor () -> Date = { Date() }
    var schedule: @MainActor (Date, @escaping @MainActor () -> Void) -> (@MainActor () -> Void) = WallpaperEnvironment
        .wallClockTimer
    var sample: @Sendable (WallpaperSampleKey) async -> [UInt32]? = { key in
        await Task.detached(priority: .userInitiated) { WallpaperRendering.sample(key) }.value
    }

    var preview: @Sendable (WallpaperPreviewKey) async -> CGImage? = { key in
        await Task.detached(priority: .utility) {
            WallpaperRendering.preview(
                URL(fileURLWithPath: key.file.path), width: key.width, aspect: key.aspect, placement: key.placement
            )
        }.value
    }

    var seed = UInt64.random(in: .min ... .max)

    static func wallClockTimer(
        _ date: Date, _ action: @escaping @MainActor () -> Void
    ) -> (@MainActor () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(1, date.timeIntervalSinceNow), leeway: .seconds(1))
        timer.setEventHandler { MainActor.assumeIsolated { action() } }
        timer.resume()
        return { timer.cancel() }
    }
}

@MainActor @Observable
final class WallpaperManager {
    struct Entry: Equatable {
        var display: WallpaperDisplay
        var folder: URL
        var custom: Bool
        var files: [String]

        var currentName: String? {
            guard let current = display.current,
                  current.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
            else { return nil }
            return current.lastPathComponent
        }
    }

    struct Pin: Equatable {
        let url: URL
        let key: WallpaperSampleKey
        let pixels: [UInt32]
    }

    let settings: WallpaperSettings
    @ObservationIgnored let desktop: WallpaperDesktop
    @ObservationIgnored let environment: WallpaperEnvironment
    @ObservationIgnored private let loadState: @MainActor () -> WallpaperRuntimeState
    @ObservationIgnored private let saveState: @MainActor (WallpaperRuntimeState) -> Void
    @ObservationIgnored weak var palette: (any WallpaperPaletteTarget)?
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var random: WallpaperRandom
    @ObservationIgnored private var cancelTimer: (@MainActor () -> Void)?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private(set) var samples: [WallpaperSampleKey: [UInt32]] = [:]
    @ObservationIgnored private var sampleOrder: [WallpaperSampleKey] = []
    @ObservationIgnored let previews: WallpaperPreviews
    @ObservationIgnored private(set) var pin: Pin?

    private(set) var entries: [Entry] = []
    private(set) var nextChange: Date?
    private(set) var problem: String?
    private(set) var running = false
    private(set) var paletteSample: [UInt32]?

    init(
        settings: WallpaperSettings,
        desktop: WallpaperDesktop = LiveWallpaperDesktop(),
        environment: WallpaperEnvironment = WallpaperEnvironment(),
        loadState: @escaping @MainActor () -> WallpaperRuntimeState,
        saveState: @escaping @MainActor (WallpaperRuntimeState) -> Void
    ) {
        self.settings = settings
        self.desktop = desktop
        self.environment = environment
        self.loadState = loadState
        self.saveState = saveState
        random = WallpaperRandom(seed: environment.seed)
        previews = WallpaperPreviews(render: environment.preview)
        previews.onChange = { [weak self] in self?.onChange?() }
    }

    var placement: WallpaperPlacement {
        settings.placement
    }

    func settingsDidChange() {
        guard settings.enabled else {
            stop()
            return
        }
        if !running {
            running = true
            desktop.onChange = { [weak self] in self?.displaysDidChange() }
        }
        refresh()
        schedule(fresh: false)
        prefetch()
        onChange?()
    }

    func stop() {
        guard running || cancelTimer != nil else { return }
        running = false
        desktop.onChange = nil
        cancelTimer?()
        cancelTimer = nil
        nextChange = nil
        entries = []
        pin = nil
        problem = nil
        previews.reset()
        onChange?()
    }

    func refresh() {
        guard running else { return }
        let home = environment.home
        let fallback = WallpaperLibrary.folderURL(settings.folder, home: home)
            ?? URL(fileURLWithPath: WallpaperLibrary.expand(WallpaperLibrary.defaultFolder, home: home))
        entries = desktop.displays().map { display in
            let own = settings.folder(for: display.monitor)
                .flatMap { WallpaperLibrary.folderURL($0.folder, home: home) }
            let folder = own ?? fallback
            return Entry(
                display: display,
                folder: folder,
                custom: own != nil,
                files: WallpaperLibrary.files(in: folder)
            )
        }
        previews.retain(entries: entries, placement: placement)
    }

    func entry(for monitorId: String) -> Entry? {
        entries.first { $0.display.monitorId == monitorId }
    }

    func next(_ target: WallpaperTarget) async {
        await serialized { [self] in
            guard running else { return }
            refresh()
            let targets: [Entry] = switch target {
            case .all: entries
            case let .display(id): entries.filter { $0.display.monitorId == id }
            }
            if case .display = target, targets.isEmpty {
                problem = String(localized: "That display is no longer connected")
                onChange?()
                return
            }
            var state = loadState()
            var changes: [(entry: Entry, url: URL)] = []
            var empty: [Entry] = []
            for entry in targets {
                guard let name = state.shuffle.next(
                    display: entry.display.key, folder: entry.folder.path, files: entry.files, using: &random
                ) else {
                    empty.append(entry)
                    continue
                }
                changes.append((entry, entry.folder.appendingPathComponent(name)))
            }
            if target == .all { state.nextChange = nil }
            saveState(state)
            problem = empty.first.map {
                String(
                    localized: "No wallpapers in \(WallpaperLibrary.abbreviate($0.folder.path, home: environment.home))"
                )
            }
            await apply(changes)
            if target == .all { schedule(fresh: true) }
        }
    }

    func set(_ name: String, on monitorId: String) async {
        await serialized { [self] in
            guard running else { return }
            refresh()
            guard let entry = entry(for: monitorId) else {
                problem = String(localized: "That display is no longer connected")
                onChange?()
                return
            }
            guard entry.files.contains(name) else {
                problem = String(localized: "\(name) is not a wallpaper in this display’s folder")
                onChange?()
                return
            }
            problem = nil
            await apply([(entry, entry.folder.appendingPathComponent(name))])
        }
    }

    func setRotation(_ minutes: Int) {
        settings.rotationMinutes = SettingsExport.Wallpaper.normalizedRotation(minutes)
        var state = loadState()
        state.nextChange = nil
        saveState(state)
        schedule(fresh: true)
        onChange?()
    }

    func setFolder(_ url: URL?, for monitorId: String) {
        guard let display = entries.first(where: { $0.display.monitorId == monitorId })?.display else { return }
        let path = url.map { WallpaperLibrary.abbreviate($0.standardizedFileURL.path, home: environment.home) }
        settings.setFolder(path, for: display.monitor)
        refresh()
        prefetch()
        onChange?()
    }

    func reveal(_ monitorId: String) {
        guard let folder = entry(for: monitorId)?.folder else { return }
        desktop.reveal(folder)
    }
}

extension WallpaperManager {
    func palettePixels() -> [UInt32]? {
        guard let pin, let main = desktop.displays().first(where: \.isMain),
              main.current?.standardizedFileURL == pin.url.standardizedFileURL,
              pin.key == WallpaperSampleKey(pin.url, display: main.size, placement: placement)
        else { return nil }
        return pin.pixels
    }

    func mainPixels() -> [UInt32]? {
        guard let main = desktop.displays().first(where: \.isMain), let current = main.current else { return nil }
        return samples[WallpaperSampleKey(current, display: main.size, placement: placement)]
    }

    func sampleMainWallpaper() async {
        guard let main = desktop.displays().first(where: \.isMain), let current = main.current else { return }
        let key = WallpaperSampleKey(current, display: main.size, placement: placement)
        if let known = samples[key] {
            if paletteSample != known { paletteSample = known }
            return
        }
        guard let pixels = await environment.sample(key) else { return }
        remember(pixels, for: key)
        paletteSample = pixels
        onChange?()
    }

    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }

    private func apply(_ changes: [(entry: Entry, url: URL)]) async {
        if let main = changes.first(where: { $0.entry.display.isMain }), let palette,
           palette.wallpaperPaletteState.active
        {
            let key = WallpaperSampleKey(main.url, display: main.entry.display.size, placement: placement)
            var pixels = samples[key]
            if pixels == nil, let computed = await environment.sample(key) {
                remember(computed, for: key)
                pixels = computed
            }
            if let pixels {
                pin = Pin(url: main.url, key: key, pixels: pixels)
                paletteSample = pixels
                _ = palette.publishWallpaperPalette(pixels)
            }
        }
        var failure: String?
        for change in changes {
            do {
                try desktop.setWallpaper(change.url, on: change.entry.display, placement: placement)
            } catch {
                failure = error.localizedDescription
            }
        }
        if let failure { problem = failure }
        refresh()
        prefetch()
        onChange?()
    }

    private func remember(_ pixels: [UInt32], for key: WallpaperSampleKey) {
        if samples[key] == nil { sampleOrder.append(key) }
        samples[key] = pixels
        while sampleOrder.count > 48 {
            samples.removeValue(forKey: sampleOrder.removeFirst())
        }
    }

    private func prefetch() {
        guard running, palette?.wallpaperPaletteState.active == true,
              let main = entries.first(where: \.display.isMain)
        else { return }
        let state = loadState()
        var keys: [WallpaperSampleKey] = []
        if let upcoming = state.shuffle.peek(
            display: main.display.key, folder: main.folder.path, files: main.files, random: random
        ) {
            keys.append(WallpaperSampleKey(
                main.folder.appendingPathComponent(upcoming), display: main.display.size, placement: placement
            ))
        }
        if let current = main.display.current {
            keys.append(WallpaperSampleKey(current, display: main.display.size, placement: placement))
        }
        let sample = environment.sample
        for key in keys where samples[key] == nil {
            Task { @MainActor [weak self] in
                guard let pixels = await sample(key) else { return }
                self?.remember(pixels, for: key)
            }
        }
    }

    private func displaysDidChange() {
        refresh()
        if let pin, let main = entries.first(where: \.display.isMain),
           main.display.current?.standardizedFileURL == pin.url.standardizedFileURL
        {
            let key = WallpaperSampleKey(pin.url, display: main.display.size, placement: placement)
            if pin.key != key {
                self.pin = nil
                Task { await self.repin(pin.url, key: key) }
            }
        }
        prefetch()
        onChange?()
    }

    private func repin(_ url: URL, key: WallpaperSampleKey) async {
        await serialized { [self] in
            var pixels = samples[key]
            if pixels == nil, let computed = await environment.sample(key) {
                remember(computed, for: key)
                pixels = computed
            }
            guard let pixels, let palette, palette.wallpaperPaletteState.active else { return }
            pin = Pin(url: url, key: key, pixels: pixels)
            paletteSample = pixels
            _ = palette.publishWallpaperPalette(pixels)
        }
    }

    private func schedule(fresh: Bool) {
        cancelTimer?()
        cancelTimer = nil
        let minutes = settings.rotationMinutes
        guard running, minutes > 0 else {
            nextChange = nil
            return
        }
        let now = environment.now()
        let period = TimeInterval(minutes * 60)
        var state = loadState()
        var due = now.addingTimeInterval(period)
        if !fresh, let saved = state.nextChange, saved > now, saved.timeIntervalSince(now) <= period {
            due = saved
        }
        if state.nextChange != due {
            state.nextChange = due
            saveState(state)
        }
        nextChange = due
        cancelTimer = environment.schedule(due) { [weak self] in
            guard let self else { return }
            cancelTimer = nil
            Task { await self.next(.all) }
        }
    }
}
