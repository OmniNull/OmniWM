// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import os

@MainActor
final class ShellWallpaperPaletteWriter {
    typealias Lookup = @Sendable () -> ShellWallpaperPalette.Source
    typealias Perform = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Deliver = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    nonisolated static let store = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store", isDirectory: true)
    static let recheckInterval: TimeInterval = 60
    private nonisolated static let queue = DispatchQueue(label: "com.barut.OmniWM.shell.wallpaper", qos: .utility)

    private final class Record: @unchecked Sendable {
        var generation: UInt64 = 0
        var scheme: ShellWallpaperScheme?
        var written: ShellWallpaperPalette.StillWallpaper?
        var unreadable: ShellWallpaperPalette.StillWallpaper?
        var pixels: [UInt32]?

        func readStill(_ still: ShellWallpaperPalette.StillWallpaper, using read: (URL) -> CGImage?) -> CGImage? {
            let image = read(still.url)
            if image == nil, unreadable != still {
                Log.shell.error("Failed to read the wallpaper file for the wallpaper palette")
            }
            unreadable = image == nil ? still : nil
            return image
        }
    }

    private let destination: URL
    private let source: @MainActor () -> Lookup
    private let read: @Sendable (URL) -> CGImage?
    private let image: @MainActor (_ aerial: Bool) -> CGImage?
    private let perform: Perform
    private let deliver: Deliver
    private let onFailure: @MainActor (String) -> Void
    private var observation: ShellDirectoryObservation?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var scheme: ShellWallpaperScheme
    private var recheck: DispatchSourceTimer?
    private let record = Record()
    private var refreshLifetime: OSAllocatedUnfairLock<Bool>?
    var onWrite: (@MainActor () -> Void)?

    var isRechecking: Bool {
        recheck != nil
    }

    init(
        destination: URL,
        scheme: ShellWallpaperScheme,
        source: @escaping @MainActor () -> Lookup = {
            let probe = ShellWallpaperPalette.stillProbe(for: CGMainDisplayID())
            return { ShellWallpaperPalette.source(probe, store: ShellWallpaperPalette.storeIndex()) }
        },
        read: @escaping @Sendable (URL) -> CGImage? = { ShellWallpaperPalette.read($0) },
        image: @escaping @MainActor (_ aerial: Bool) -> CGImage? = {
            ShellWallpaperPalette.screenImage(for: CGMainDisplayID(), aerial: $0)
        },
        perform: @escaping Perform = ShellWallpaperPaletteWriter.performOnWriterQueue,
        deliver: @escaping Deliver = ShellWallpaperPaletteWriter.deliverOnMain,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.destination = destination
        self.scheme = scheme
        self.source = source
        self.read = read
        self.image = image
        self.perform = perform
        self.deliver = deliver
        self.onFailure = onFailure
    }

    isolated deinit {
        stop()
    }

    nonisolated static func performOnWriterQueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    nonisolated static func deliverOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }

    func start() {
        guard observation == nil else { return }
        observation = ShellDirectoryObservation { [weak self] in
            self?.watchStore()
            self?.refresh()
        }
        watchStore()
        observers = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        ].map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let recheck = DispatchSource.makeTimerSource(queue: .main)
        recheck.schedule(
            deadline: .now() + Self.recheckInterval,
            repeating: Self.recheckInterval,
            leeway: .milliseconds(Int(Self.recheckInterval * 100))
        )
        recheck.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshIfChanged() }
        }
        recheck.resume()
        self.recheck = recheck
        refreshLifetime = OSAllocatedUnfairLock(initialState: true)
        refresh()
    }

    func setScheme(_ next: ShellWallpaperScheme) {
        guard next != scheme else { return }
        scheme = next
        refresh()
    }

    func stop() {
        refreshLifetime?.withLock { $0 = false }
        refreshLifetime = nil
        observation?.cancel()
        observation = nil
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
        recheck?.cancel()
        recheck = nil
    }

    func refresh() {
        refresh(onlyIfChanged: false)
    }

    func refreshIfChanged() {
        refresh(onlyIfChanged: true)
    }

    private func refresh(onlyIfChanged: Bool) {
        guard let refreshLifetime else { return }
        let lookup = source()
        let read = read
        let scheme = scheme
        let destination = destination
        let record = record
        let deliver = deliver
        let publish = writeNotification(for: refreshLifetime)
        perform { [weak self] in
            guard refreshLifetime.withLock({ $0 }) else { return }
            record.generation &+= 1
            let generation = record.generation
            let capture = { (aerial: Bool) in
                deliver {
                    guard refreshLifetime.withLock({ $0 }) else { return }
                    self?.refreshImage(onlyIfChanged: onlyIfChanged, aerial: aerial, generation: generation)
                }
            }
            switch lookup() {
            case let .capture(aerial):
                capture(aerial)
            case let .still(still, aerial):
                let needsRead = still != record.written || record.unreadable == still
                    || scheme != record.scheme || !Self.exists(destination)
                guard !onlyIfChanged || needsRead else { return }
                guard let image = record.readStill(still, using: read) else {
                    capture(aerial)
                    return
                }
                let pixels = ShellWallpaperPalette.pixels(of: image)
                guard refreshLifetime.withLock({ $0 }),
                      let changed = Self.write(pixels: pixels, scheme: scheme, to: destination)
                else {
                    return
                }
                record.scheme = scheme
                record.written = still
                record.pixels = nil
                if changed { publish() }
            }
        }
    }

    private func refreshImage(onlyIfChanged: Bool, aerial: Bool, generation: UInt64) {
        guard let refreshLifetime else { return }
        guard let image = image(aerial) else {
            onFailure("The wallpaper palette keeps its last colors because the wallpaper image is unavailable")
            return
        }
        let pixels = ShellWallpaperPalette.pixels(of: image)
        let scheme = scheme
        let destination = destination
        let record = record
        let publish = writeNotification(for: refreshLifetime)
        perform {
            guard refreshLifetime.withLock({ $0 }), record.generation == generation,
                  !onlyIfChanged || pixels != record.pixels || scheme != record.scheme || !Self.exists(destination),
                  let changed = Self.write(pixels: pixels, scheme: scheme, to: destination)
            else { return }
            record.scheme = scheme
            record.pixels = pixels
            record.written = nil
            if changed { publish() }
        }
    }

    private func writeNotification(for lifetime: OSAllocatedUnfairLock<Bool>) -> @Sendable () -> Void {
        let deliver = deliver
        return { [weak self] in
            deliver {
                guard lifetime.withLock({ $0 }) else { return }
                self?.onWrite?()
            }
        }
    }

    private nonisolated static func write(
        pixels: [UInt32],
        scheme: ShellWallpaperScheme,
        to destination: URL
    ) -> Bool? {
        do {
            return try ShellWallpaperPalette.write(
                ShellWallpaperPalette.theme(pixels: pixels, scheme: scheme),
                to: destination
            )
        } catch {
            Log.shell.error("Failed to write the wallpaper palette: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func exists(_ destination: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination.path)
    }

    private func watchStore() {
        observation?.sync(
            paths: [Self.store, Self.store.appendingPathComponent("Index.plist")], recursivePaths: [Self.store]
        )
    }
}
