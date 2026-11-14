// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct WallpaperEnvironment {
    typealias Perform = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Deliver = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    private nonisolated static let queue = DispatchQueue(label: "com.barut.OmniWM.wallpaper", qos: .utility)

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

    var files: @Sendable (URL) throws -> [String] = { try WallpaperLibrary.files(in: $0) }
    var stamp: @Sendable (URL) -> WallpaperFileStamp = { WallpaperFileStamp($0) }
    var loadState: @Sendable () throws -> WallpaperRuntimeState
    var saveState: @Sendable (WallpaperRuntimeState) throws -> Void
    var perform: Perform = WallpaperEnvironment.performOnWorker
    var deliver: Deliver = WallpaperEnvironment.deliverOnMain
    var seed = UInt64.random(in: .min ... .max)

    init(stateFile: URL) {
        loadState = { try WallpaperStateFile.load(stateFile) }
        saveState = { try WallpaperStateFile.save($0, to: stateFile) }
    }

    nonisolated static func performOnWorker(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    nonisolated static func deliverOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            work()
        }
    }

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

enum WallpaperStateFile {
    static let name = "wallpaper-state.json"

    static func load(_ url: URL) throws -> WallpaperRuntimeState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return WallpaperRuntimeState()
        }
        return try JSONDecoder().decode(WallpaperRuntimeState.self, from: data)
    }

    static func save(_ state: WallpaperRuntimeState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

struct WallpaperFolderList: Equatable, Sendable {
    var files: [String] = []
    var failure: String?
}

struct WallpaperProblems: Equatable {
    var action: String?
    var desktop: String?
    var state: String?

    var text: String? {
        Self.joined(Self.joined(action, desktop), state)
    }

    private static func joined(_ first: String?, _ second: String?) -> String? {
        guard let first else { return second }
        return second.map { first + "\n" + $0 } ?? first
    }
}

struct WallpaperSnapshot: Sendable {
    var entries: [WallpaperManager.Entry] = []
    var lists: [URL: WallpaperFolderList] = [:]
    var stamps: [String: WallpaperFileStamp] = [:]
    var upcoming: WallpaperFileStamp?
    var failure: String?
    var state: Result<WallpaperRuntimeState, any Error>?

    mutating func list(
        _ folder: URL, reading files: @Sendable (URL) throws -> [String]
    ) -> WallpaperFolderList {
        if let known = lists[folder] { return known }
        let list: WallpaperFolderList
        do {
            list = try WallpaperFolderList(files: files(folder))
        } catch {
            list = WallpaperFolderList(failure: error.localizedDescription)
        }
        lists[folder] = list
        return list
    }

    @discardableResult
    mutating func stamp(_ url: URL, with stamp: @Sendable (URL) -> WallpaperFileStamp) -> WallpaperFileStamp {
        let path = url.standardizedFileURL.path
        if let known = stamps[path] { return known }
        let made = stamp(url)
        stamps[path] = made
        return made
    }
}

struct WallpaperPass: Sendable {
    struct Upcoming: Sendable {
        var shuffle: WallpaperShuffle
        var random: WallpaperRandom
    }

    var planned: [WallpaperManager.Entry]
    var lists: [URL: WallpaperFolderList]
    var extra: [URL] = []
    var pages: [String: WallpaperPreviews.Window]?
    var upcoming: Upcoming?
    var loadsState = false

    func run(
        _ shown: WallpaperShownLookup,
        files: @escaping @Sendable (URL) throws -> [String],
        stamp: @escaping @Sendable (URL) -> WallpaperFileStamp,
        loadState: @escaping @Sendable () throws -> WallpaperRuntimeState
    ) -> WallpaperSnapshot {
        var snapshot = WallpaperSnapshot(lists: lists)
        var found: [WallpaperShown] = []
        switch shown() {
        case let .success(displays): found = displays
        case let .failure(failure): snapshot.failure = failure.message
        }
        for (index, planned) in planned.enumerated() {
            var entry = planned
            entry.display = entry.display.showing(index < found.count ? found[index] : WallpaperShown())
            let list = snapshot.list(entry.folder, reading: files)
            entry.files = list.files
            entry.failure = list.failure
            if let current = entry.display.current {
                snapshot.stamp(current, with: stamp)
            }
            if let thumbnail = entry.display.thumbnail {
                snapshot.stamp(thumbnail, with: stamp)
            }
            if let pages {
                let window = WallpaperPreviews.window(for: entry, saved: pages[entry.display.key])
                for name in WallpaperPreviews.visible(entry, in: window) {
                    snapshot.stamp(entry.folder.appendingPathComponent(name), with: stamp)
                }
            }
            snapshot.entries.append(entry)
        }
        for folder in extra {
            _ = snapshot.list(folder, reading: files)
        }
        if let upcoming, let main = snapshot.entries.first(where: \.display.isMain),
           let name = upcoming.shuffle.peek(
               display: main.display.key, folder: main.folder.path, files: main.files, random: upcoming.random
           )
        {
            snapshot.upcoming = snapshot.stamp(main.folder.appendingPathComponent(name), with: stamp)
        }
        if loadsState {
            snapshot.state = Result { try loadState() }
        }
        return snapshot
    }
}
