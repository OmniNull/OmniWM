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
    func publishWallpaperPalette(_ pixels: [UInt32]) async throws -> Bool
    func refreshWallpaperPalette()
}

enum WallpaperTarget: Equatable, Sendable {
    case all
    case display(String)
}

enum WallpaperSwatchReader: Hashable {
    case widget
    case settings
}

@MainActor @Observable
final class WallpaperManager {
    struct Entry: Equatable, Sendable {
        var display: WallpaperDisplay
        var folder: URL
        var custom: Bool
        var files: [String] = []
        var failure: String?

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

    static let sampleLimit = 48

    let settings: WallpaperSettings
    @ObservationIgnored let desktop: WallpaperDesktop
    @ObservationIgnored let environment: WallpaperEnvironment
    @ObservationIgnored let previews: WallpaperPreviews
    @ObservationIgnored weak var palette: (any WallpaperPaletteTarget)?
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored var random: WallpaperRandom
    @ObservationIgnored var cancelTimer: (@MainActor () -> Void)?
    @ObservationIgnored var tail: Task<Void, Never>?
    @ObservationIgnored var samples: [WallpaperSampleKey: [UInt32]] = [:]
    @ObservationIgnored var sampleOrder: [WallpaperSampleKey] = []
    @ObservationIgnored var prefetching: [WallpaperSampleKey: Task<[UInt32]?, Never>] = [:]
    @ObservationIgnored var pin: Pin?
    @ObservationIgnored var appliedPlacement: WallpaperPlacement?
    @ObservationIgnored var epoch = 0
    @ObservationIgnored var sampleEpoch = 0
    @ObservationIgnored var state: WallpaperRuntimeState?
    @ObservationIgnored var stamps: [String: WallpaperFileStamp] = [:]
    @ObservationIgnored var upcoming: WallpaperFileStamp?
    @ObservationIgnored var swatchReaders: Set<WallpaperSwatchReader> = []
    @ObservationIgnored var sampled: WallpaperSampleKey?
    @ObservationIgnored var sampling: Task<Void, Never>?
    @ObservationIgnored private var resumesRotation = false
    @ObservationIgnored private var folders: [String] = []
    @ObservationIgnored private var passes: UInt64 = 0
    @ObservationIgnored private var saves: UInt64 = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    private(set) var entries: [Entry] = []
    private(set) var lists: [URL: WallpaperFolderList] = [:]
    var nextChange: Date?
    var problems = WallpaperProblems()
    private(set) var running = false
    var paletteSample: [UInt32]?
    var paletteSwatches: [ShellWallpaper.Swatch] = []
    var listsEveryFolder = false {
        didSet { if listsEveryFolder, !oldValue { refresh(rescan: true) } }
    }

    init(
        settings: WallpaperSettings,
        desktop: WallpaperDesktop = LiveWallpaperDesktop(),
        environment: WallpaperEnvironment
    ) {
        self.settings = settings
        self.desktop = desktop
        self.environment = environment
        random = WallpaperRandom(seed: environment.seed)
        previews = WallpaperPreviews(render: environment.preview)
        previews.onChange = { [weak self] in self?.onChange?() }
    }

    var placement: WallpaperPlacement {
        settings.placement
    }

    var problem: String? {
        problems.text
    }

    func start(resumingRotation: Bool) {
        resumesRotation = resumingRotation
        settingsDidChange()
    }

    func settingsDidChange() {
        guard settings.enabled else {
            stop()
            return
        }
        if !running {
            running = true
            desktop.onChange = { [weak self] in self?.refresh() }
        }
        let folders = [settings.folder] + settings.displays.map { "\($0.id) \($0.folder)" }
        if folders != self.folders {
            self.folders = folders
            epoch &+= 1
        }
        refresh(rescan: true)
        if let appliedPlacement, appliedPlacement != placement {
            enqueue { [self] in await reapplyPlacement() }
        }
        appliedPlacement = placement
        if state != nil { schedule(fresh: false) }
        onChange?()
    }

    func stop() {
        guard running || cancelTimer != nil else { return }
        running = false
        epoch &+= 1
        passes &+= 1
        folders = []
        desktop.onChange = nil
        cancelTimer?()
        cancelTimer = nil
        appliedPlacement = nil
        nextChange = nil
        entries = []
        lists = [:]
        stamps = [:]
        upcoming = nil
        pin = nil
        state = nil
        resumesRotation = false
        problems = WallpaperProblems()
        previews.reset()
        resumeWaiters()
        onChange?()
    }

    func refresh(rescan: Bool = false) {
        guard running else { return }
        passes &+= 1
        let generation = passes
        let lookup = desktop.lookup()
        let home = environment.home
        let fallback = WallpaperLibrary.folderURL(settings.folder, home: home)
            ?? URL(fileURLWithPath: WallpaperLibrary.expand(WallpaperLibrary.defaultFolder, home: home))
        var planned: [Entry] = []
        planned.reserveCapacity(lookup.screens.count)
        for display in lookup.screens {
            let own = settings.folder(for: display.monitor)
                .flatMap { WallpaperLibrary.folderURL($0.folder, home: home) }
            planned.append(Entry(display: display, folder: own ?? fallback, custom: own != nil))
        }
        let pass = WallpaperPass(
            planned: planned,
            lists: rescan ? [:] : lists,
            extra: listsEveryFolder ? configuredFolders(fallback: fallback) : [],
            pages: previews.demanded ? previews.windows : nil,
            upcoming: palette?.wallpaperPaletteState.active == true
                ? state.map { WallpaperPass.Upcoming(shuffle: $0.shuffle, random: random) } : nil,
            loadsState: state == nil
        )
        let (shown, environment) = (lookup.shown, environment)
        environment.perform { [weak self] in
            let snapshot = pass.run(
                shown, files: environment.files, stamp: environment.stamp, loadState: environment.loadState
            )
            environment.deliver { self?.land(snapshot, generation: generation) }
        }
    }

    private func configuredFolders(fallback: URL) -> [URL] {
        var folders = [fallback]
        for display in settings.displays {
            guard let folder = WallpaperLibrary.folderURL(display.folder, home: environment.home) else { continue }
            folders.append(folder)
        }
        return folders
    }

    private func land(_ snapshot: WallpaperSnapshot, generation: UInt64) {
        guard running, generation == passes else { return }
        if state == nil, let loaded = snapshot.state {
            restore(loaded)
        }
        entries = snapshot.entries
        lists = snapshot.lists
        stamps = snapshot.stamps
        upcoming = snapshot.upcoming
        problems.desktop = snapshot.failure
        previews.retain(entries: entries, stamps: stamps, placement: placement)
        prefetch()
        followMainSample()
        resumeWaiters()
        onChange?()
    }

    private func restore(_ loaded: Result<WallpaperRuntimeState, any Error>) {
        switch loaded {
        case let .success(saved):
            state = saved
        case let .failure(error):
            state = WallpaperRuntimeState()
            problems.state = String(localized: "Wallpaper rotation can’t be restored: \(error.localizedDescription)")
        }
        if !resumesRotation {
            state?.nextChange = nil
        }
        schedule(fresh: false)
    }

    func snapshot(rescan: Bool) async {
        guard running else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            refresh(rescan: rescan)
        }
    }

    private func resumeWaiters() {
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }

    func persist(_ next: WallpaperRuntimeState) {
        state = next
        saves &+= 1
        let generation = saves
        let environment = environment
        environment.perform { [weak self] in
            let failure: String?
            do {
                try environment.saveState(next)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            environment.deliver { self?.saved(failure, generation: generation) }
        }
    }

    private func saved(_ failure: String?, generation: UInt64) {
        guard running, generation == saves else { return }
        let problem = failure.map { String(localized: "Wallpaper rotation can’t be saved: \($0)") }
        guard problems.state != problem else { return }
        problems.state = problem
        onChange?()
    }

    func entry(for monitorId: String) -> Entry? {
        entries.first { $0.display.monitorId == monitorId }
    }

    func list(for folder: URL) -> WallpaperFolderList? {
        lists[folder]
    }

    func setRotation(_ minutes: Int) {
        guard running, settings.enabled else { return }
        settings.rotationMinutes = SettingsExport.Wallpaper.normalizedRotation(minutes)
        if var state {
            state.nextChange = nil
            persist(state)
        }
        schedule(fresh: true)
        onChange?()
    }

    func setFolder(_ url: URL?, for monitorId: String) {
        guard running, let display = entry(for: monitorId)?.display else { return }
        let path = url.map { WallpaperLibrary.abbreviate($0.standardizedFileURL.path, home: environment.home) }
        settings.setFolder(path, for: display.monitor)
    }

    func reveal(_ monitorId: String) {
        guard let folder = entry(for: monitorId)?.folder else { return }
        desktop.reveal(folder)
    }

    func showPage(_ window: WallpaperPreviews.Window, for monitorId: String) {
        guard let entry = entry(for: monitorId) else { return }
        previews.setWindow(window, for: entry)
        refresh()
        onChange?()
    }

    func showPreviews(_ shown: Bool) {
        guard previews.demanded != shown else { return }
        previews.demanded = shown
        if shown { refresh() }
    }
}
