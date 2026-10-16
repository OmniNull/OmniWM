// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import ImageIO
import QuartzCore

struct ShellPlayback: Equatable, Sendable {
    var speed: Double
    var paused: Bool
}

struct ShellPlaybackState {
    let frames: ShellImageFrames
    let phase: CFTimeInterval
    let start: CFTimeInterval
    let playback: ShellPlayback

    func phase(at now: CFTimeInterval) -> CFTimeInterval {
        playback.paused ? phase : phase + max(now - start, 0) * playback.speed
    }
}

final class ShellImageFrames: Sendable {
    static let extensions: Set<String> = ["gif", "png", "apng", "jpg", "jpeg", "webp", "heic", "heics"]
    static let sizeLimit = 16 << 20
    static let frameLimit = 512
    static let pixelLimit = 4096
    private static let shortestDelay = 0.011
    private static let defaultDelay = 0.1

    let frames: [CGImage]
    let ends: [CFTimeInterval]

    var duration: CFTimeInterval {
        ends.last ?? 0
    }

    var animated: Bool {
        frames.count > 1 && duration > 0
    }

    init?(url: URL, decodeImmediately: Bool = false) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= Self.frameLimit else { return nil }
        var frames: [CGImage] = []
        var ends: [CFTimeInterval] = []
        for index in 0 ..< count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard width <= Self.pixelLimit, height <= Self.pixelLimit,
                  let frame = CGImageSourceCreateImageAtIndex(
                      source,
                      index,
                      [kCGImageSourceShouldCacheImmediately: decodeImmediately] as CFDictionary
                  )
            else {
                return nil
            }
            frames.append(frame)
            ends.append((ends.last ?? 0) + Self.delay(properties))
        }
        self.frames = frames
        self.ends = ends
    }

    func frame(at time: CFTimeInterval) -> CGImage? {
        guard animated else { return frames.first }
        let local = time.truncatingRemainder(dividingBy: duration)
        return frames[ends.firstIndex { local < $0 } ?? frames.count - 1]
    }

    func animation(_ playback: ShellPlayback, phase: CFTimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = ([0] + ends).map { NSNumber(value: $0 / duration) }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.speed = Float(playback.speed)
        animation.timeOffset = phase.truncatingRemainder(dividingBy: duration)
        animation.isRemovedOnCompletion = false
        return animation
    }

    private static func delay(_ properties: [CFString: Any]) -> CFTimeInterval {
        let delayKeys: [CFString: [CFString]] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime],
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime],
            kCGImagePropertyWebPDictionary: [kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime],
            kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime]
        ]
        for (container, keys) in delayKeys {
            guard let values = properties[container] as? [CFString: Any] else { continue }
            let delay = keys.lazy.compactMap { values[$0] as? Double }.first ?? 0
            return delay < shortestDelay ? defaultDelay : delay
        }
        return defaultDelay
    }
}

actor ShellImagePreparation {
    struct Prepared: Sendable {
        let revision: ShellAssetRevision
        let frames: ShellImageFrames
    }

    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.images", qos: .utility)
    private var entries: [URL: Prepared] = [:]

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func prepare(_ asset: ShellAsset) throws -> Prepared {
        let revision = try asset.revision(limit: ShellImageFrames.sizeLimit)
        if let cached = entries[revision.url], cached.revision == revision { return cached }
        guard let frames = ShellImageFrames(url: revision.url, decodeImmediately: true) else {
            throw ShellAsset.Failure
                .invalid("asset \(asset.path) must contain at most 512 frames and 4096 pixels per side")
        }
        let prepared = Prepared(revision: revision, frames: frames)
        entries[revision.url] = prepared
        return prepared
    }
}

@MainActor
final class ShellImageLibrary {
    private struct Entry {
        let frames: ShellImageFrames?
        let fingerprint: SettingsFileAccess.Fingerprint?
    }

    private struct AssetEntry {
        var frames: ShellImageFrames?
        var revision: ShellAssetRevision?
        var loading = false
        var invalidated = false
    }

    var onLoad: (@MainActor () -> Void)?
    var onAssetChange: (@MainActor (URL) -> Void)?
    private var entries: [URL: Entry] = [:]
    private var assets: [ShellAsset: AssetEntry] = [:]
    private let preparation = ShellImagePreparation()

    var files: [URL] {
        Array(Set(entries.keys).union(assets.keys.map(\.url)).union(assets.values.compactMap { $0.revision?.url }))
    }

    func image(_ path: String, folders: [URL], packages: [String: URL] = [:]) -> ShellImageFrames? {
        if path.hasPrefix(ShellAsset.prefix) {
            do {
                let asset = try ShellAsset(path, packages: packages)
                guard ShellImageFrames.extensions.contains(asset.url.pathExtension.lowercased()) else {
                    throw ShellAsset.Failure.invalid("unsupported image type in \(asset.path)")
                }
                if let entry = assets[asset] { return entry.frames }
                assets[asset] = AssetEntry()
                prepare(asset)
            } catch {
                Log.shell.error("\(String(describing: error))")
            }
            return nil
        }
        guard ShellImageFrames.extensions.contains((path as NSString).pathExtension.lowercased()),
              let url = Self.resolve(path, in: folders)
        else {
            return nil
        }
        if let entry = entries[url] {
            return entry.frames
        }
        let fingerprint = SettingsFileAccess.currentFingerprint(at: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        let frames = size <= ShellImageFrames.sizeLimit ? ShellImageFrames(url: url) : nil
        if frames == nil {
            Log.shell
                .error(
                    "The image \(path) could not be read; images must be at most 16 MB, 512 frames and 4096 pixels wide"
                )
        }
        entries[url] = Entry(frames: frames, fingerprint: fingerprint)
        onLoad?()
        return frames
    }

    @discardableResult
    func refresh() -> Bool {
        for asset in assets.keys { prepare(asset) }
        let changed = entries.keys.filter { SettingsFileAccess.currentFingerprint(at: $0) != entries[$0]?.fingerprint }
        for url in changed { entries.removeValue(forKey: url) }
        for url in changed { onAssetChange?(url) }
        return !changed.isEmpty
    }

    private func prepare(_ asset: ShellAsset) {
        guard assets[asset]?.loading != true else {
            assets[asset]?.invalidated = true
            return
        }
        assets[asset]?.loading = true
        Task { [weak self, preparation] in
            let result: Result<ShellImagePreparation.Prepared, any Error>
            do { result = .success(try await preparation.prepare(asset)) }
            catch { result = .failure(error) }
            guard let self, var entry = assets[asset] else { return }
            let again = entry.invalidated
            entry.loading = false
            entry.invalidated = false
            var changed = false
            switch result {
            case let .success(prepared):
                changed = entry.revision != prepared.revision
                entry.revision = prepared.revision
                entry.frames = prepared.frames
            case let .failure(error):
                Log.shell.error("\(String(describing: error))")
            }
            assets[asset] = entry
            onLoad?()
            if changed { onAssetChange?(asset.url) }
            if again { prepare(asset) }
        }
    }

    static func resolve(_ path: String, in folders: [URL]) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.hasPrefix("~"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            return nil
        }
        for folder in folders {
            let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
            let candidate = folder.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard candidate.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: candidate.path) else {
                continue
            }
            return candidate
        }
        return nil
    }
}
