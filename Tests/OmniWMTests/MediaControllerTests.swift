// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import Synchronization
import XCTest

@MainActor
final class MediaControllerTests: XCTestCase {
    private static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

    private final class Changes {
        var values: [ShellMedia?] = []
    }

    private func controller(_ script: String) -> MediaController {
        MediaController(adapter: MediaController.Adapter(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", script]
        ))
    }

    private func record(_ controller: MediaController) -> Changes {
        let changes = Changes()
        controller.onChange = { media in
            changes.values.append(media)
        }
        return changes
    }

    private func wait(in changes: Changes, until done: @escaping ([ShellMedia?]) -> Bool) async {
        await until { done(changes.values) }
    }

    func testMediaCommandsParseBesideVolume() {
        XCTAssertEqual(ShellAction("media toggle"), .media(.toggle))
        XCTAssertEqual(ShellAction("media seek 12.5"), .media(.seek(seconds: 12.5)))
        XCTAssertEqual(ShellAction("media open"), .media(.open))
        XCTAssertNil(ShellAction("media seek -1"))
        XCTAssertNil(ShellAction("media louder"))
        XCTAssertEqual(ShellMediaCommand.next.adapterLine, "next")
        XCTAssertNil(ShellMediaCommand.open.adapterLine)
        XCTAssertEqual(ShellMediaCommand.previous.mediaKey, 18)
        XCTAssertNil(ShellMediaCommand.seek(seconds: 3).mediaKey)
        XCTAssertEqual(ShellAction("media shuffle"), .media(.shuffle))
        XCTAssertEqual(ShellAction("media repeat"), .media(.repeat))
        XCTAssertNil(ShellAction("media shuffle on"))
        XCTAssertEqual(ShellMediaCommand.repeat.adapterLine, "repeat")
        XCTAssertNil(ShellMediaCommand.shuffle.mediaKey)
    }

    func testShuffleAndRepeatDecodeOnlyFromKnownModes() throws {
        func media(_ json: String) throws -> ShellMedia {
            try XCTUnwrap(MediaAdapterReader.parse(Data(json.utf8))?.media)
        }
        let shuffled = try media(#"{"title":"Song","pid":1,"shuffle":3,"repeat":2}"#)
        XCTAssertEqual(shuffled.shuffle, true)
        XCTAssertEqual(shuffled.repeatMode, .one)
        let plain = try media(#"{"title":"Song","pid":1,"shuffle":1,"repeat":3}"#)
        XCTAssertEqual(plain.shuffle, false)
        XCTAssertEqual(plain.repeatMode, .all)
        let unknown = try media(#"{"title":"Song","pid":1,"shuffle":0,"repeat":0}"#)
        XCTAssertNil(unknown.shuffle)
        XCTAssertNil(unknown.repeatMode)
        XCTAssertNil(try media(#"{"title":"Song","pid":1}"#).shuffle)

        let widget = try ShellRenderedWidget(name: "modes", source: """
        function render(ctx)
            local media = ctx.data.media
            return ui.text{ text = tostring(media.shuffle) .. " " .. media.repeatMode }
        end
        """)
        widget.set("media") { shuffled.write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("true one"))
    }

    func testAdapterLinesDecodeAcrossChunksAndSkipNothingPlaying() throws {
        let lines = Mutex<[MediaAdapterLine]>([])
        let reader = MediaAdapterReader { line in
            if let line {
                lines.withLock { $0.append(line) }
            }
        }
        let first = #"{"title":"Song","artist":"Artist","pid":42,"playing":true,"duration":200,"elapsed":20,"rate":1,"#
        reader.consume(Data(first.utf8))
        XCTAssertTrue(lines.withLock(\.isEmpty))
        let rest = #""sampledAt":7,"artworkId":"a1","artwork":"\#(Self.pixel)"}"# + "\n{\"pid\":0}\nnot json\n"
        reader.consume(Data(rest.utf8))
        let decoded = lines.withLock { $0 }
        XCTAssertEqual(decoded.count, 2)
        let media = try XCTUnwrap(decoded[0].media)
        XCTAssertEqual(media.title, "Song")
        XCTAssertEqual(media.artist, "Artist")
        XCTAssertEqual(media.pid, 42)
        XCTAssertTrue(media.playing)
        XCTAssertEqual(media.duration, 200)
        XCTAssertEqual(media.sampledAt, 7)
        XCTAssertEqual(decoded[0].artworkId, "a1")
        XCTAssertEqual(decoded[0].artwork?.width, 1)
        XCTAssertNil(decoded[1].media)
    }

    func testTheAdapterRunsOnlyWhileListenedToAndReceivesCommands() async throws {
        let controller = controller(#"""
        $| = 1;
        print qq({"title":"One","pid":1,"playing":true,"artworkId":"a1","artwork":"\#(Self.pixel)"}\n);
        while (my $line = <STDIN>) { chomp $line; print qq({"title":"$line","pid":1,"artworkId":"a1"}\n); }
        """#)
        let changes = record(controller)
        controller.setListening(true)
        await wait(in: changes) { $0.count >= 1 }
        XCTAssertEqual(controller.media?.title, "One")
        XCTAssertEqual(controller.media?.artwork, "media/a1")
        XCTAssertEqual(controller.bitmap("media/a1")?.width, 1)
        XCTAssertNil(controller.bitmap("media/other"))
        XCTAssertNotNil(ShellResources(motion: MotionPolicy(animationsEnabled: false), media: controller)
            .bitmap("media/a1"))

        controller.perform(.seek(seconds: 5))
        await wait(in: changes) { $0.count >= 2 }
        XCTAssertEqual(controller.media?.title, "seek 5.0")
        XCTAssertEqual(controller.media?.artwork, "media/a1")

        controller.setListening(false)
        XCTAssertNil(controller.media)
        XCTAssertNil(controller.bitmap("media/a1"))
        XCTAssertEqual(changes.values.count, 3)
    }

    func testACommandToAnAdapterThatClosedItsInputIsLoggedInsteadOfRaisingSIGPIPE() async {
        let controller = controller(#"""
        $| = 1;
        close(STDIN);
        print qq({"title":"closed","pid":1}\n);
        select(undef, undef, undef, undef);
        """#)
        let changes = record(controller)
        controller.setListening(true)
        await wait(in: changes) { $0.last??.title == "closed" }
        controller.perform(.seek(seconds: 1))
        XCTAssertTrue(LogErrorTap.shared.dump().contains("seek 1.0 did not reach the Now Playing adapter"))
        controller.setListening(false)
    }

    func testACrashingAdapterRestartsAtMostThreeTimes() async throws {
        let counter = FileManager.default.temporaryDirectory.appendingPathComponent("omniwm-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: counter) }
        let controller = controller(#"""
        $| = 1;
        open(my $file, ">>", "\#(counter.path)") or die;
        print $file "run\n";
        close($file);
        open($file, "<", "\#(counter.path)") or die;
        my @runs = <$file>;
        print qq({"title":"run ) . scalar(@runs) . qq(","pid":1}\n);
        exit 1;
        """#)
        let changes = record(controller)
        controller.setListening(true)
        await wait(in: changes) { $0.last.map { $0 == nil } ?? false }
        XCTAssertEqual(changes.values.map { $0?.title }, ["run 1", "run 2", "run 3", "run 4", nil])
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count, 4)
        controller.setListening(false)
    }

    func testTheFeedListensToMediaOnlyWhileItIsRead() {
        let media = MediaController(adapter: nil)
        let feed = ShellDataFeed(media: media, deliver: { _ in })
        feed.start()
        XCTAssertNil(media.onChange)
        feed.setDemand(ShellDataKey.media.bit, cadence: .of([(ShellDataKey.media.bit, nil)]))
        XCTAssertNotNil(media.onChange)
        feed.setDemand(ShellDataKey.volume.bit, cadence: .of([(ShellDataKey.volume.bit, nil)]))
        XCTAssertNil(media.onChange)
        XCTAssertNil(feed.current.media)
        feed.stop()
    }

    func testTheMediaWidgetShowsTheTrackAndSeeksWhenTheSliderIsReleased() throws {
        let widget = try ShellRenderedWidget("media")
        widget.set("seconds") { $0.number(1_000_010) }
        widget.set("media") { writer in
            var media = ShellMedia()
            media.title = "Song"
            media.artist = "Artist"
            media.playing = true
            media.duration = 200
            media.elapsed = 20
            media.rate = 1
            media.sampledAt = 1_000_000
            media.write(into: &writer)
        }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Song"))
        let nodes = widget.renderPopout()
        let actions = Set(nodes.map { widget.text.string($0.content.action) })
        XCTAssertTrue(actions.isSuperset(of: ["media previous", "media toggle", "media next", "media open"]))
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("0:30"))
        let slider = try XCTUnwrap(nodes.first { $0.kind == .slider }?.content.action)
        var event = ShellEvent(button: .left)
        event.value = 0.5
        event.phase = .changed
        XCTAssertEqual(widget.invoke(slider, view: OMNI_VIEW_POPOUT, event: event), [])
        event.phase = .ended
        XCTAssertEqual(widget.invoke(slider, view: OMNI_VIEW_POPOUT, event: event), ["media seek 100.0"])

        widget.set("media") { $0.null() }
        widget.render(ShellBarData())
        XCTAssertEqual(widget.surface.size, .zero)
    }

    func testTheMediaPopoutSpreadsItsTimesAcrossTheSlider() throws {
        let widget = try ShellRenderedWidget("media")
        widget.set("seconds") { $0.number(1_000_010) }
        widget.set("media") { writer in
            var media = ShellMedia()
            media.title = "Song"
            media.playing = true
            media.duration = 200
            media.elapsed = 20
            media.rate = 1
            media.sampledAt = 1_000_000
            media.write(into: &writer)
        }
        widget.render(ShellBarData())
        widget.layoutPopout()
        var frames: [String: Rect] = [:]
        for handle in widget.surface.layout.core.elements(matching: { $0.text != 0 }) {
            let text = widget.text.string(widget.surface.layout.core.content(of: handle).text)
            frames[text] = widget.surface.layout.core.absoluteFrame(of: handle)
        }
        let elapsed = try XCTUnwrap(frames["0:30"])
        let duration = try XCTUnwrap(frames["3:20"])
        XCTAssertEqual(elapsed.x, 12, accuracy: 0.5)
        XCTAssertEqual(duration.x + duration.width, 288, accuracy: 0.5)
    }
}
