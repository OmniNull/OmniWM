// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WallpaperManager {
    func next(_ target: WallpaperTarget) async {
        await serialized { [self] in await advance(target) }
    }

    func set(_ name: String, on monitorId: String) async {
        await serialized { [self] in
            await snapshot(rescan: true)
            guard running else { return }
            guard let entry = entry(for: monitorId) else {
                problems.action = String(localized: "That display is no longer connected")
                onChange?()
                return
            }
            guard entry.files.contains(name) else {
                problems.action = String(localized: "\(name) is not a wallpaper in this display’s folder")
                onChange?()
                return
            }
            problems.action = nil
            _ = await apply([(entry, entry.folder.appendingPathComponent(name))])
        }
    }

    func idle() async {
        while true {
            if let task = tail {
                await task.value
                if tail == task { tail = nil }
            } else if let pending = prefetching.values.first {
                _ = await pending.value
            } else if let sampling {
                await sampling.value
                if self.sampling == sampling { self.sampling = nil }
            } else {
                return
            }
        }
    }

    func advance(_ target: WallpaperTarget) async {
        await snapshot(rescan: true)
        guard running, var proposed = state?.shuffle else { return }
        let targets: [Entry] = switch target {
        case .all: entries
        case let .display(id): entries.filter { $0.display.monitorId == id }
        }
        if case .display = target, targets.isEmpty {
            problems.action = String(localized: "That display is no longer connected")
            onChange?()
            return
        }
        problems.action = nil
        var changes: [(entry: Entry, url: URL)] = []
        for entry in targets {
            guard entry.failure == nil, let name = proposed.next(
                display: entry.display.key, folder: entry.folder.path, files: entry.files, using: &random
            ) else {
                report(folderProblem(entry))
                continue
            }
            changes.append((entry, entry.folder.appendingPathComponent(name)))
        }
        let applied = await apply(changes)
        guard running, var state else { return }
        for key in applied ?? [] {
            state.shuffle.displays[key] = proposed.displays[key]
        }
        if target == .all { state.nextChange = nil }
        persist(state)
        if target == .all { schedule(fresh: true) }
    }

    func folderProblem(_ entry: Entry) -> String {
        let folder = WallpaperLibrary.abbreviate(entry.folder.path, home: environment.home)
        guard let failure = entry.failure else { return String(localized: "No wallpapers in \(folder)") }
        return String(localized: "\(folder) can’t be read: \(failure)")
    }

    func report(_ message: String) {
        problems.action = problems.action.map { $0 + "\n" + message } ?? message
    }

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
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

    private func publish(_ main: (entry: Entry, url: URL), to palette: any WallpaperPaletteTarget) async -> Pin? {
        let epoch = epoch
        let key = await WallpaperSampleKey(file: stamp(main.url))
        guard epoch == self.epoch, let pixels = await pixels(for: key), epoch == self.epoch else { return nil }
        let previous = pin
        let candidate = Pin(
            url: main.url, key: key, pixels: pixels, before: main.entry.display.current?.standardizedFileURL.path
        )
        pin = candidate
        do {
            if try await palette.publishWallpaperPalette(pixels) { return candidate }
        } catch {
            report(String(localized: "The wallpaper colors can’t be updated: \(error.localizedDescription)"))
        }
        if pin == candidate { pin = previous }
        return nil
    }

    func apply(_ changes: [(entry: Entry, url: URL)]) async -> Set<String>? {
        let epoch = epoch
        var published: Pin?
        if let main = changes.first(where: { $0.entry.display.isMain }), let palette,
           palette.wallpaperPaletteState.active
        {
            published = await publish(main, to: palette)
            guard epoch == self.epoch else {
                if published != nil, running {
                    if pin == published { pin = nil }
                    palette.refreshWallpaperPalette()
                }
                return nil
            }
        }
        if published == nil, changes.contains(where: { $0.entry.display.isMain }) { pin = nil }
        if let published {
            sampled = published.key
            sampleEpoch &+= 1
            setPaletteSample(published.pixels)
        }
        var applied: Set<String> = []
        for change in changes {
            do {
                try desktop.setWallpaper(change.url, on: change.entry.display, placement: placement)
                applied.insert(change.entry.display.key)
            } catch {
                report(error.localizedDescription)
                if change.entry.display.isMain, published != nil {
                    pin = nil
                    palette?.refreshWallpaperPalette()
                }
            }
        }
        refresh()
        onChange?()
        return applied
    }

    func stamp(_ url: URL) async -> WallpaperFileStamp {
        let environment = environment
        return await withCheckedContinuation { continuation in
            environment.perform { continuation.resume(returning: environment.stamp(url)) }
        }
    }

    func pixels(for key: WallpaperSampleKey) async -> [UInt32]? {
        if let known = samples[key] { return known }
        if let pending = prefetching[key] { return await pending.value }
        let pixels = await environment.sample(key)
        if let pixels { remember(pixels, for: key) }
        return pixels
    }

    private func remember(_ pixels: [UInt32], for key: WallpaperSampleKey) {
        if samples[key] == nil { sampleOrder.append(key) }
        samples[key] = pixels
        while sampleOrder.count > Self.sampleLimit {
            samples.removeValue(forKey: sampleOrder.removeFirst())
        }
    }

    func prefetch() {
        guard running, palette?.wallpaperPaletteState.active == true else { return }
        if let upcoming {
            fetch(WallpaperSampleKey(file: upcoming))
        }
        if let current = mainKey() {
            fetch(current)
        }
    }

    private func fetch(_ key: WallpaperSampleKey, then: (@MainActor ([UInt32]?) -> Void)? = nil) {
        if let pending = prefetching[key] {
            guard let then else { return }
            sampling = Task { @MainActor in then(await pending.value) }
            return
        }
        guard samples[key] == nil else { return }
        let sample = environment.sample
        prefetching[key] = Task { @MainActor [weak self] in
            let pixels = await sample(key)
            if let pixels { self?.remember(pixels, for: key) }
            self?.prefetching[key] = nil
            then?(pixels)
            return pixels
        }
    }

    func followPin() {
        guard var pin, let main = entries.first(where: \.display.isMain) else { return }
        let shown = main.display.current?.standardizedFileURL.path
        if let shown, shown == pin.url.standardizedFileURL.path, stamps[shown] == pin.key.file {
            if !pin.seen {
                pin.seen = true
                self.pin = pin
            }
            return
        }
        guard pin.seen || shown != pin.before else { return }
        self.pin = nil
        palette?.refreshWallpaperPalette()
    }

    func reapplyPlacement() async {
        await snapshot(rescan: false)
        guard running else { return }
        _ = await apply(entries.compactMap { entry in
            entry.currentName.map { (entry, entry.folder.appendingPathComponent($0)) }
        })
    }

    func schedule(fresh: Bool) {
        cancelTimer?()
        cancelTimer = nil
        let minutes = settings.rotationMinutes
        guard running, minutes > 0, var state else {
            nextChange = nil
            return
        }
        let now = environment.now()
        let period = TimeInterval(minutes) * Self.minute
        var due = now.addingTimeInterval(period)
        if !fresh, let saved = state.nextChange, saved.timeIntervalSince(now) <= period {
            due = max(saved, now)
        }
        if state.nextChange != due {
            state.nextChange = due
            persist(state)
        }
        nextChange = due
        cancelTimer = environment.schedule(due) { [weak self] in
            guard let self else { return }
            cancelTimer = nil
            enqueue { [self] in await advance(.all) }
        }
    }
}

extension WallpaperManager {
    func palettePin() -> ShellWallpaperPaletteOverride? {
        pin.map { ShellWallpaperPaletteOverride(file: $0.key.file, pixels: $0.pixels) }
    }

    func palettePixels() -> [UInt32]? {
        guard let pin, let key = mainKey(), key == pin.key,
              entries.first(where: \.display.isMain)?.display.current?.standardizedFileURL
              == pin.url.standardizedFileURL
        else { return nil }
        return pin.pixels
    }

    func mainPixels() -> [UInt32]? {
        mainKey().flatMap { samples[$0] }
    }

    func mainKey() -> WallpaperSampleKey? {
        guard let current = entries.first(where: \.display.isMain)?.display.current,
              let stamp = stamps[current.standardizedFileURL.path]
        else { return nil }
        return WallpaperSampleKey(file: stamp)
    }

    func showSwatches(_ shown: Bool, for reader: WallpaperSwatchReader) {
        guard shown else {
            swatchReaders.remove(reader)
            return
        }
        guard swatchReaders.insert(reader).inserted else { return }
        if let paletteSample, paletteSwatches.isEmpty {
            makeSwatches(paletteSample)
        }
        followMainSample()
    }

    func followMainSample() {
        guard running, !swatchReaders.isEmpty, let key = mainKey(), key != sampled else { return }
        sampled = key
        if let known = samples[key] {
            setPaletteSample(known)
            return
        }
        let started = sampleEpoch
        fetch(key) { [weak self] pixels in
            guard let self, let pixels, running, started == sampleEpoch, sampled == key else { return }
            setPaletteSample(pixels)
        }
    }

    func setPaletteSample(_ pixels: [UInt32]) {
        guard paletteSample != pixels else { return }
        paletteSample = pixels
        paletteSwatches = []
        onChange?()
        guard !swatchReaders.isEmpty else { return }
        makeSwatches(pixels)
    }

    private func makeSwatches(_ pixels: [UInt32]) {
        let environment = environment
        environment.perform { [weak self] in
            let swatches = ShellWallpaperPalette.swatches(pixels: pixels)
            environment.deliver { self?.made(swatches, from: pixels) }
        }
    }

    private func made(_ swatches: [ShellWallpaper.Swatch], from pixels: [UInt32]) {
        guard paletteSample == pixels else { return }
        paletteSwatches = swatches
        onChange?()
    }
}
