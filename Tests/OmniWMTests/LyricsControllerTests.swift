// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class LyricsControllerTests: XCTestCase {
    private final class Loads: Sendable {
        private let state = Mutex<(
            tracks: [ShellLyricsTrack],
            waiting: [CheckedContinuation<Void, Never>],
            finished: Bool
        )>(([], [], false))
        let (changes, changed) = boundedChanges()
        let held: Bool
        let result: @Sendable (ShellLyricsTrack) throws -> ShellLyrics

        init(held: Bool = false, result: @escaping @Sendable (ShellLyricsTrack) throws -> ShellLyrics) {
            self.held = held
            self.result = result
        }

        var tracks: [ShellLyricsTrack] {
            state.withLock(\.tracks)
        }

        var waiting: Int {
            state.withLock(\.waiting.count)
        }

        func load(_ track: ShellLyricsTrack) async throws -> ShellLyrics {
            state.withLock { $0.tracks.append(track) }
            if held {
                await withCheckedContinuation { continuation in
                    let finished = state.withLock { state in
                        guard !state.finished else { return true }
                        state.waiting.append(continuation)
                        return false
                    }
                    if finished { continuation.resume() }
                    changed.yield()
                }
            }
            return try result(track)
        }

        func releaseAll() {
            state.withLock { state in
                state.waiting.forEach { $0.resume() }
                state.waiting.removeAll()
            }
        }

        func finish() {
            let waiting = state.withLock { state in
                state.finished = true
                let waiting = state.waiting
                state.waiting.removeAll()
                return waiting
            }
            for continuation in waiting { continuation.resume() }
        }
    }

    private nonisolated static let song = ShellLyricsTrack(
        title: "Song",
        artist: "Artist",
        album: "Album",
        duration: 200
    )
    private nonisolated static let other = ShellLyricsTrack(title: "Other", artist: "Artist", duration: 180)
    private nonisolated static let synced = ShellLyrics(lrc: "[00:01.00]Hello")

    func testLRCLinesAreTimedSortedAndSkipMetadata() {
        let lyrics = ShellLyrics(lrc: """
        [ar:Artist]
        [offset:+200]
        [00:12.50][01:02.25] Chorus 
        [00:03.00]First
        no tag here
        [00:20.00]
        """)
        XCTAssertEqual(lyrics.status, .synced)
        XCTAssertEqual(lyrics.lines, [
            .init(time: 3, text: "First"),
            .init(time: 12.5, text: "Chorus"),
            .init(time: 20, text: ""),
            .init(time: 62.25, text: "Chorus")
        ])
        XCTAssertEqual(ShellLyrics(lrc: "[ar:Artist]\nplain words").status, .missing)
        XCTAssertEqual(ShellLyrics(lrc: "").lines, [])
    }

    func testResponsesDecodeSyncedLyricsOnly() throws {
        let synced = try ShellLyricsClient
            .lyrics(from: Data(#"{"syncedLyrics":"[00:01.00]Hi","plainLyrics":"Hi"}"#.utf8))
        XCTAssertEqual(synced.lines, [.init(time: 1, text: "Hi")])
        let plain = try ShellLyricsClient.lyrics(from: Data(#"{"syncedLyrics":null,"plainLyrics":"Hi"}"#.utf8))
        XCTAssertEqual(plain.status, .missing)
        XCTAssertThrowsError(try ShellLyricsClient.lyrics(from: Data("not json".utf8)))
    }

    func testTheRequestEscapesTheTrackAndNamesOmniWM() throws {
        let track = ShellLyricsTrack(title: "Rock & Roll + You", artist: "A=B", duration: 201)
        let request = try XCTUnwrap(ShellLyricsClient.request(for: track))
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "lrclib.net")
        XCTAssertEqual(url.path, "/api/get")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
            "track_name=Rock%20%26%20Roll%20%2B%20You&artist_name=A%3DB&duration=201"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OmniWM (https://github.com/OmniNull/OmniWM)")

        var media = ShellMedia()
        XCTAssertNil(ShellLyricsTrack(media))
        media.title = " Song "
        media.artist = "Artist"
        media.album = "Album"
        media.duration = 199.6
        XCTAssertEqual(ShellLyricsTrack(media), Self.song)
    }

    func testTracksAreCachedIncludingMissesButNotFailures() async {
        let loads = Loads { track in
            switch track.title {
            case "Song": Self.synced
            case "Other": .missing
            default: throw URLError(.notConnectedToInternet)
            }
        }
        let controller = LyricsController(load: loads.load)
        var loaded: [ShellLyrics] = []
        controller.onLoad = { loaded.append($0) }

        controller.show(Self.song)
        XCTAssertEqual(controller.lyrics, .loading)
        await controller.task?.value
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(controller.lyrics, Self.synced)
        controller.show(Self.other)
        await controller.task?.value
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(controller.lyrics, .missing)
        let offline = ShellLyricsTrack(title: "Offline", artist: "Artist")
        controller.show(offline)
        await controller.task?.value
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(controller.lyrics, .missing)

        controller.show(Self.song)
        XCTAssertEqual(controller.lyrics, Self.synced)
        controller.show(Self.other)
        XCTAssertEqual(controller.lyrics, .missing)
        controller.show(offline)
        await controller.task?.value
        XCTAssertEqual(loaded.count, 4)
        XCTAssertEqual(loads.tracks.map(\.title), ["Song", "Other", "Offline", "Offline"])

        controller.show(nil)
        XCTAssertNil(controller.lyrics)
    }

    func testATrackChangeCancelsTheEarlierRequest() async throws {
        let loads = Loads(held: true) { $0.title == "Song" ? Self.synced : .missing }
        let controller = LyricsController(load: loads.load)
        defer {
            controller.show(nil)
            loads.finish()
        }
        var loaded: [ShellLyrics] = []
        controller.onLoad = { loaded.append($0) }

        controller.show(Self.song)
        let earlier = try XCTUnwrap(controller.task)
        await loads.changes.wait { loads.waiting == 1 }
        _ = try XCTUnwrap(loads.waiting == 1 ? loads : nil, "Expected the first held request")
        controller.show(Self.other)
        let current = try XCTUnwrap(controller.task)
        XCTAssertTrue(earlier.isCancelled)
        XCTAssertFalse(current.isCancelled)
        await loads.changes.wait { loads.waiting == 2 }
        _ = try XCTUnwrap(loads.waiting == 2 ? loads : nil, "Expected both held requests")
        loads.releaseAll()
        await earlier.value
        await current.value
        XCTAssertEqual(loaded, [.missing])
        XCTAssertEqual(controller.lyrics, .missing)

        controller.show(Self.song)
        let cleared = try XCTUnwrap(controller.task)
        XCTAssertEqual(controller.lyrics, .loading)
        await loads.changes.wait { loads.waiting == 1 }
        _ = try XCTUnwrap(loads.waiting == 1 ? loads : nil, "Expected the request cleared below")
        controller.show(nil)
        XCTAssertTrue(cleared.isCancelled)
        XCTAssertNil(controller.lyrics)
        loads.releaseAll()
        await cleared.value
        XCTAssertEqual(loads.tracks, [Self.song, Self.other, Self.song])
        XCTAssertEqual(loaded, [.missing])
        XCTAssertNil(controller.lyrics)
    }

    func testTheFeedLooksUpLyricsOnlyWhileAWidgetReadsThem() async {
        let loads = Loads { _ in Self.synced }
        let media = MediaController(adapter: MediaController.Adapter(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", #"""
            $| = 1;
            print qq({"title":"Song","artist":"Artist","album":"Album","duration":200,"pid":1,"playing":true}\n);
            while (<STDIN>) {}
            """#]
        ))
        let (changes, changed) = boundedChanges()
        let feed = ShellDataFeed(
            media: media,
            lyrics: LyricsController(load: loads.load),
            deliver: { _ in changed.yield() }
        )
        defer { feed.stop() }
        feed.start()

        feed.setDemand(ShellDataKey.media.bit, cadence: .of([(ShellDataKey.media.bit, nil)]))
        await changes.wait { feed.current.media?.title == "Song" }
        XCTAssertNil(feed.current.lyrics)
        XCTAssertEqual(loads.tracks, [])

        feed.setDemand(ShellDataKey.lyrics.bit, cadence: .of([(ShellDataKey.lyrics.bit, nil)]))
        await changes.wait { feed.current.lyrics == Self.synced }
        XCTAssertEqual(loads.tracks, [Self.song])

        feed.setDemand(ShellDataKey.clock.bit, cadence: .of([(ShellDataKey.clock.bit, nil)]))
        XCTAssertNil(feed.current.lyrics)
        XCTAssertNil(feed.current.media)
        XCTAssertEqual(loads.tracks, [Self.song])
    }
}
