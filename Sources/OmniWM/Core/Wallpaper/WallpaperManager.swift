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
    func publishWallpaperPalette(_ pixels: [UInt32]) async -> Bool
    func refreshWallpaperPalette()
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

    var files: @MainActor (URL) -> [String] = { WallpaperLibrary.files(in: $0) }
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
    @ObservationIgnored private var appliedPlacement: WallpaperPlacement?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var folders: [String] = []
    @ObservationIgnored private var sampleEpoch = 0
    @ObservationIgnored private var prefetching: [WallpaperSampleKey: Task<[UInt32]?, Never>] = [:]

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
            var state = loadState()
            if state.nextChange != nil {
                state.nextChange = nil
                saveState(state)
            }
            return
        }
        if !running {
            running = true
            desktop.onChange = { [weak self] in self?.displaysDidChange() }
        }
        let folders = [settings.folder] + settings.displays.map { "\($0.id) \($0.folder)" }
        if folders != self.folders {
            self.folders = folders
            epoch &+= 1
        }
        refresh()
        if let appliedPlacement, appliedPlacement != placement {
            enqueue { [self] in await reapplyPlacement() }
        }
        appliedPlacement = placement
        schedule(fresh: false)
        prefetch()
        onChange?()
    }

    func stop() {
        guard running || cancelTimer != nil else { return }
        running = false
        epoch &+= 1
        folders = []
        desktop.onChange = nil
        cancelTimer?()
        cancelTimer = nil
        appliedPlacement = nil
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
        var scanned: [URL: [String]] = [:]
        entries = desktop.displays().map { display in
            let own = settings.folder(for: display.monitor)
                .flatMap { WallpaperLibrary.folderURL($0.folder, home: home) }
            let folder = own ?? fallback
            let files = scanned[folder] ?? environment.files(folder)
            scanned[folder] = files
            return Entry(display: display, folder: folder, custom: own != nil, files: files)
        }
        previews.retain(entries: entries, placement: placement)
    }

    func entry(for monitorId: String) -> Entry? {
        entries.first { $0.display.monitorId == monitorId }
    }

    func next(_ target: WallpaperTarget) async {
        await serialized { [self] in await advance(target) }
    }

    func idle() async {
        while true {
            if let task = tail {
                await task.value
                if tail == task { tail = nil }
            } else if let pending = prefetching.values.first {
                _ = await pending.value
            } else {
                return
            }
        }
    }

    private func advance(_ target: WallpaperTarget) async {
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
        var proposed = loadState().shuffle
        var changes: [(entry: Entry, url: URL)] = []
        var empty: [Entry] = []
        for entry in targets {
            guard let name = proposed.next(
                display: entry.display.key, folder: entry.folder.path, files: entry.files, using: &random
            ) else {
                empty.append(entry)
                continue
            }
            changes.append((entry, entry.folder.appendingPathComponent(name)))
        }
        problem = empty.first.map {
            String(
                localized: "No wallpapers in \(WallpaperLibrary.abbreviate($0.folder.path, home: environment.home))"
            )
        }
        let applied = await apply(changes)
        guard running else { return }
        var state = loadState()
        for key in applied ?? [] {
            state.shuffle.displays[key] = proposed.displays[key]
        }
        if target == .all { state.nextChange = nil }
        saveState(state)
        if target == .all { schedule(fresh: true) }
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
            _ = await apply([(entry, entry.folder.appendingPathComponent(name))])
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
    func palettePin() -> ShellWallpaperPaletteOverride? {
        pin.map { ShellWallpaperPaletteOverride(file: $0.key.file, pixels: $0.pixels) }
    }

    func palettePixels() -> [UInt32]? {
        guard let pin, let main = desktop.displays().first(where: \.isMain),
              main.current?.standardizedFileURL == pin.url.standardizedFileURL,
              pin.key == WallpaperSampleKey(pin.url)
        else { return nil }
        return pin.pixels
    }

    func mainPixels() -> [UInt32]? {
        guard let main = desktop.displays().first(where: \.isMain), let current = main.current else { return nil }
        return samples[WallpaperSampleKey(current)]
    }

    func sampleMainWallpaper() async {
        guard let main = desktop.displays().first(where: \.isMain), let current = main.current else { return }
        let started = sampleEpoch
        guard let pixels = await pixels(for: WallpaperSampleKey(current)), started == sampleEpoch,
              paletteSample != pixels
        else { return }
        paletteSample = pixels
        onChange?()
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        await enqueue(operation).value
    }

    private func apply(_ changes: [(entry: Entry, url: URL)]) async -> Set<String>? {
        let epoch = epoch
        var published: Pin?
        if let main = changes.first(where: { $0.entry.display.isMain }), let palette,
           palette.wallpaperPaletteState.active
        {
            let key = WallpaperSampleKey(main.url)
            let pixels = await pixels(for: key)
            guard epoch == self.epoch else { return nil }
            if let pixels, await palette.publishWallpaperPalette(pixels) {
                published = Pin(url: main.url, key: key, pixels: pixels)
            }
            guard epoch == self.epoch else {
                if published != nil { palette.refreshWallpaperPalette() }
                return nil
            }
        }
        pin = published ?? (changes.contains { $0.entry.display.isMain } ? nil : pin)
        if let published {
            paletteSample = published.pixels
            sampleEpoch &+= 1
        }
        var applied: Set<String> = []
        var failure: String?
        for change in changes {
            do {
                try desktop.setWallpaper(change.url, on: change.entry.display, placement: placement)
                applied.insert(change.entry.display.key)
            } catch {
                failure = error.localizedDescription
                if change.entry.display.isMain, published != nil {
                    pin = nil
                    palette?.refreshWallpaperPalette()
                }
            }
        }
        if let failure { problem = failure }
        refresh()
        prefetch()
        onChange?()
        return applied
    }

    private func pixels(for key: WallpaperSampleKey) async -> [UInt32]? {
        if let known = samples[key] { return known }
        if let pending = prefetching[key] { return await pending.value }
        let pixels = await environment.sample(key)
        if let pixels { remember(pixels, for: key) }
        return pixels
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
            keys.append(WallpaperSampleKey(main.folder.appendingPathComponent(upcoming)))
        }
        if let current = main.display.current {
            keys.append(WallpaperSampleKey(current))
        }
        let sample = environment.sample
        for key in keys where samples[key] == nil && prefetching[key] == nil {
            prefetching[key] = Task { @MainActor [weak self] in
                let pixels = await sample(key)
                if let pixels { self?.remember(pixels, for: key) }
                self?.prefetching[key] = nil
                return pixels
            }
        }
    }

    private func displaysDidChange() {
        refresh()
        prefetch()
        if paletteSample != nil {
            enqueue { [self] in await sampleMainWallpaper() }
        }
        onChange?()
    }

    private func reapplyPlacement() async {
        refresh()
        _ = await apply(entries.compactMap { entry in
            entry.currentName.map { (entry, entry.folder.appendingPathComponent($0)) }
        })
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
        if !fresh, let saved = state.nextChange, saved.timeIntervalSince(now) <= period {
            due = max(saved, now)
        }
        if state.nextChange != due {
            state.nextChange = due
            saveState(state)
        }
        nextChange = due
        cancelTimer = environment.schedule(due) { [weak self] in
            guard let self else { return }
            cancelTimer = nil
            enqueue { [self] in await advance(.all) }
        }
    }
}
