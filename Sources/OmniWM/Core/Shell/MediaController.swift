// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
import Synchronization

enum ShellMediaCommand: Equatable, Sendable {
    case play
    case pause
    case toggle
    case next
    case previous
    case seek(seconds: Double)
    case shuffle
    case `repeat`
    case open

    init?(words: [String]) {
        switch words {
        case ["play"]: self = .play
        case ["pause"]: self = .pause
        case ["toggle"]: self = .toggle
        case ["next"]: self = .next
        case ["previous"]: self = .previous
        case ["shuffle"]: self = .shuffle
        case ["repeat"]: self = .repeat
        case ["open"]: self = .open
        case let words where words.count == 2 && words[0] == "seek":
            guard let seconds = Double(words[1]), seconds.isFinite, seconds >= 0 else { return nil }
            self = .seek(seconds: seconds)
        default: return nil
        }
    }

    var adapterLine: String? {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .toggle: "toggle"
        case .next: "next"
        case .previous: "previous"
        case let .seek(seconds): "seek \(seconds)"
        case .shuffle: "shuffle"
        case .repeat: "repeat"
        case .open: nil
        }
    }

    var mediaKey: Int32? {
        switch self {
        case .play,
             .pause,
             .toggle: 16
        case .next: 17
        case .previous: 18
        case .seek,
             .shuffle,
             .repeat,
             .open: nil
        }
    }
}

struct ShellMedia: Equatable, Sendable {
    enum Repeat: Int, Sendable {
        case off = 1
        case one
        case all

        var name: String {
            switch self {
            case .off: "off"
            case .one: "one"
            case .all: "all"
            }
        }
    }

    var title = ""
    var artist = ""
    var album = ""
    var app = ""
    var bundle = ""
    var pid: Int32 = 0
    var playing = false
    var duration: Double?
    var elapsed: Double?
    var rate = 0.0
    var sampledAt = 0.0
    var artwork: String?
    var shuffle: Bool?
    var repeatMode: Repeat?

    func write(into writer: inout ShellValueWriter) {
        writer.map(14)
        writer.key("title")
        writer.string(title)
        writer.key("artist")
        writer.string(artist)
        writer.key("album")
        writer.string(album)
        writer.key("app")
        writer.string(app)
        writer.key("bundle")
        writer.string(bundle)
        writer.key("pid")
        writer.number(Double(pid))
        writer.key("playing")
        writer.bool(playing)
        writer.key("duration")
        duration.map { writer.number($0) } ?? writer.null()
        writer.key("elapsed")
        elapsed.map { writer.number($0) } ?? writer.null()
        writer.key("rate")
        writer.number(rate)
        writer.key("sampledAt")
        writer.number(sampledAt)
        writer.key("artwork")
        artwork.map { writer.string($0) } ?? writer.null()
        writer.key("shuffle")
        shuffle.map { writer.bool($0) } ?? writer.null()
        writer.key("repeatMode")
        repeatMode.map { writer.string($0.name) } ?? writer.null()
    }
}

struct MediaAdapterLine: Sendable {
    let media: ShellMedia?
    let artworkId: String?
    let artwork: CGImage?
}

final class MediaAdapterReader: Sendable {
    private let pending = Mutex(Data())
    private let deliver: @Sendable (MediaAdapterLine?) -> Void

    init(deliver: @escaping @Sendable (MediaAdapterLine?) -> Void) {
        self.deliver = deliver
    }

    func consume(_ data: Data) {
        let lines = pending.withLock { pending -> [Data] in
            pending.append(data)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(pending[pending.startIndex ..< newline]))
                pending.removeSubrange(pending.startIndex ... newline)
            }
            return lines
        }
        for line in lines {
            if let parsed = Self.parse(line) {
                deliver(parsed)
            }
        }
    }

    func finish() {
        deliver(nil)
    }

    static func parse(_ line: Data) -> MediaAdapterLine? {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            object = parsed
        } catch {
            Log.shell.error("The Now Playing adapter wrote a line that is not JSON: \(error)")
            return nil
        }
        let pid = (object["pid"] as? NSNumber)?.int32Value ?? 0
        let title = object["title"] as? String ?? ""
        guard pid != 0 || !title.isEmpty else {
            return MediaAdapterLine(media: nil, artworkId: nil, artwork: nil)
        }
        var media = ShellMedia()
        media.title = title
        media.artist = object["artist"] as? String ?? ""
        media.album = object["album"] as? String ?? ""
        media.pid = pid
        media.playing = object["playing"] as? Bool ?? false
        media.duration = (object["duration"] as? NSNumber)?.doubleValue
        media.elapsed = (object["elapsed"] as? NSNumber)?.doubleValue
        media.rate = (object["rate"] as? NSNumber)?.doubleValue ?? (media.playing ? 1 : 0)
        media.sampledAt = (object["sampledAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        media.shuffle = (object["shuffle"] as? NSNumber).flatMap { 1 ... 3 ~= $0.intValue ? $0.intValue > 1 : nil }
        media.repeatMode = (object["repeat"] as? NSNumber).flatMap { ShellMedia.Repeat(rawValue: $0.intValue) }
        let artworkId = object["artworkId"] as? String
        let artwork = (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(thumbnail)
        return MediaAdapterLine(media: media, artworkId: artworkId, artwork: artwork)
    }

    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }
}

@MainActor
final class MediaController {
    struct Adapter: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private static let restartLimit = 3
    private static let artworkPrefix = "media/"

    private let adapter: Adapter?
    private var process: Process?
    private var input: FileHandle?
    private var generation = 0
    private var restarts = 0
    private var listening = false
    private var artwork: (id: String, image: CGImage)?
    private(set) var media: ShellMedia?
    var onChange: (@MainActor (ShellMedia?) -> Void)?

    init(adapter: Adapter? = MediaController.bundledAdapter()) {
        self.adapter = adapter
    }

    static func bundledAdapter() -> Adapter? {
        guard let script = Bundle.module.url(forResource: "now-playing", withExtension: "pl") else { return nil }
        let library = [Bundle.main.privateFrameworksURL, Bundle.main.executableURL?.deletingLastPathComponent()]
            .compactMap { $0?.appendingPathComponent("libOmniWMNowPlaying.dylib") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let library else { return nil }
        return Adapter(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: [script.path, library.path])
    }

    func bitmap(_ id: String) -> CGImage? {
        guard let artwork, id == Self.artworkPrefix + artwork.id else { return nil }
        return artwork.image
    }

    func setListening(_ listening: Bool) {
        guard self.listening != listening else { return }
        self.listening = listening
        restarts = 0
        if listening {
            launch()
        } else {
            terminate()
            artwork = nil
            publish(nil)
        }
    }

    func perform(_ command: ShellMediaCommand) {
        if command == .open {
            if let pid = media?.pid, pid > 0 {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            return
        }
        if let input, let line = command.adapterLine {
            do {
                try input.write(contentsOf: Data((line + "\n").utf8))
                return
            } catch {
                Log.shell.error("The media command \(line) did not reach the Now Playing adapter: \(error)")
            }
        }
        if let key = command.mediaKey {
            Self.postMediaKey(key)
        }
    }

    private func launch() {
        guard let adapter, process == nil else { return }
        generation += 1
        let generation = generation
        let process = Process()
        process.executableURL = adapter.executable
        process.arguments = adapter.arguments
        let input = Pipe()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            Log.shell
                .error("The Now Playing adapter's input could not refuse SIGPIPE: \(String(cString: strerror(errno)))")
            return
        }
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = MediaAdapterReader { [weak self] line in
            guard let controller = self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let line {
                        controller.received(line, generation: generation)
                    } else {
                        controller.finished(generation: generation)
                    }
                }
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                reader.finish()
            } else {
                reader.consume(data)
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            Log.shell.error("The Now Playing adapter did not start: \(error)")
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
    }

    private func terminate() {
        generation += 1
        if let input {
            do {
                try input.close()
            } catch {
                Log.shell.error("Closing the Now Playing adapter's input failed: \(error)")
            }
        }
        input = nil
        process?.terminate()
        process = nil
    }

    private func received(_ line: MediaAdapterLine, generation: Int) {
        guard generation == self.generation else { return }
        guard var media = line.media else {
            artwork = nil
            publish(nil)
            return
        }
        let application = NSRunningApplication(processIdentifier: media.pid)
        media.app = application?.localizedName ?? ""
        media.bundle = application?.bundleIdentifier ?? ""
        if let id = line.artworkId {
            if let image = line.artwork {
                artwork = (id, image)
            }
            media.artwork = artwork?.id == id ? Self.artworkPrefix + id : nil
        } else {
            artwork = nil
        }
        publish(media)
    }

    private func finished(generation: Int) {
        guard generation == self.generation else { return }
        process = nil
        input = nil
        guard listening else { return }
        restarts += 1
        if restarts <= Self.restartLimit {
            launch()
        } else {
            Log.shell
                .error(
                    "The Now Playing adapter stopped \(Self.restartLimit) times; media stays off until it is read again"
                )
            artwork = nil
            publish(nil)
        }
    }

    private func publish(_ media: ShellMedia?) {
        guard media != self.media else { return }
        self.media = media
        onChange?(media)
    }

    private static func postMediaKey(_ key: Int32) {
        for state: Int32 in [0xA, 0xB] {
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | (state << 8)),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
