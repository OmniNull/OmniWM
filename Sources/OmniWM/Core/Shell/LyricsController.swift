// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellLyricsTrack: Hashable, Sendable {
    var title: String
    var artist: String
    var album = ""
    var duration: Int?
}

extension ShellLyricsTrack {
    init?(_ media: ShellMedia) {
        let title = media.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        self.title = title
        artist = media.artist.trimmingCharacters(in: .whitespaces)
        album = media.album
        duration = media.duration.flatMap { $0 > 0 && $0 < Double(Int32.max) ? Int($0.rounded()) : nil }
    }
}

struct ShellLyrics: Equatable, Sendable, ShellValueWritable {
    enum Status: String, Sendable {
        case loading
        case synced
        case missing = "none"
    }

    struct Line: Equatable, Sendable {
        var time: Double
        var text: String
    }

    static let loading = ShellLyrics(status: .loading)
    static let missing = ShellLyrics(status: .missing)

    var status: Status
    var lines: [Line] = []

    init(status: Status, lines: [Line] = []) {
        self.status = status
        self.lines = lines
    }

    init(lrc: String) {
        lines = Self.lines(lrc)
        status = lines.isEmpty ? .missing : .synced
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("status")
        writer.string(status.rawValue)
        writer.key("lines")
        writer.array(lines.count)
        for line in lines {
            writer.map(2)
            writer.key("time")
            writer.number(line.time)
            writer.key("text")
            writer.string(line.text)
        }
    }

    static func lines(_ lrc: String) -> [Line] {
        var lines: [Line] = []
        for row in lrc.split(whereSeparator: \.isNewline) {
            var rest = row[...]
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]"),
                  let time = time(rest[rest.index(after: rest.startIndex) ..< close])
            {
                times.append(time)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { Line(time: $0, text: text) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func time(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.first?.isNumber == true }),
              let minutes = Int(parts[0]), let seconds = Double(parts[1]), seconds.isFinite
        else {
            return nil
        }
        return Double(minutes) * 60 + seconds
    }
}

enum ShellLyricsClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    static func request(for track: ShellLyricsTrack) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        var query = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        if !track.album.isEmpty {
            query.append(URLQueryItem(name: "album_name", value: track.album))
        }
        if let duration = track.duration {
            query.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("OmniWM (https://github.com/OmniNull/OmniWM)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func lyrics(_ track: ShellLyricsTrack) async throws -> ShellLyrics {
        guard let request = request(for: track) else { throw URLError(.badURL) }
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try lyrics(from: data)
        case 404: return .missing
        default: throw URLError(.badServerResponse)
        }
    }

    static func lyrics(from data: Data) throws -> ShellLyrics {
        try ShellLyrics(lrc: JSONDecoder().decode(LyricsRecord.self, from: data).syncedLyrics ?? "")
    }
}

private struct LyricsRecord: Decodable {
    let syncedLyrics: String?
}

@MainActor
final class LyricsController {
    private static let cacheLimit = 64

    private let load: @Sendable (ShellLyricsTrack) async throws -> ShellLyrics
    private var cache: [ShellLyricsTrack: ShellLyrics] = [:]
    private var track: ShellLyricsTrack?
    private var task: Task<Void, Never>?
    private(set) var lyrics: ShellLyrics?
    var onLoad: ((ShellLyrics) -> Void)?

    init(load: @escaping @Sendable (ShellLyricsTrack) async throws -> ShellLyrics = ShellLyricsClient.lyrics) {
        self.load = load
    }

    func show(_ next: ShellLyricsTrack?) {
        guard next != track else { return }
        task?.cancel()
        task = nil
        track = next
        guard let next else {
            lyrics = nil
            return
        }
        if let cached = cache[next] {
            lyrics = cached
            return
        }
        lyrics = .loading
        task = Task { [weak self, load] in
            let result: ShellLyrics?
            do {
                result = try await load(next)
            } catch {
                if !Task.isCancelled {
                    Log.shell.error("Lyrics did not load: \(error.localizedDescription)")
                }
                result = nil
            }
            guard !Task.isCancelled else { return }
            self?.finish(next, result)
        }
    }

    private func finish(_ loaded: ShellLyricsTrack, _ result: ShellLyrics?) {
        guard loaded == track else { return }
        task = nil
        if let result {
            if cache.count >= Self.cacheLimit {
                cache.removeAll(keepingCapacity: true)
            }
            cache[loaded] = result
        }
        let lyrics = result ?? .missing
        self.lyrics = lyrics
        onLoad?(lyrics)
    }
}
