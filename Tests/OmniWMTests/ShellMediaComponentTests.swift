// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellMediaComponentTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let vm: OpaquePointer
        var displays: [OpaquePointer] = []
        let text = ShellTextStore()
        var error = [CChar](repeating: 0, count: 512)
        var nodes: [omni_wire_node] = []
        var dependencies: UInt64 = 0
        var demand: UInt64 = 0

        init(custom: Bool = false) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
            func module(_ path: String, _ source: String) {
                let path = "profile/" + path
                XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            for path in [
                "lib/lake/init.luau",
                "lib/lake/view.luau",
                "lib/lake/motion.luau",
                "lib/lake/services/media.luau",
                "widgets/media/component.luau"
            ] {
                module(path, try String(contentsOf: profile.appendingPathComponent(path), encoding: .utf8))
            }
            if custom {
                module("widgets/custom-media/component.luau", """
                local lake = require('../lib/lake')
                local media = require('../lib/lake/services/media')
                local base = require('@component/media')
                return lake.extend(base, { views = { expanded = function(ctx)
                    return ui.column{ ui.text{ text = 'Custom: ' .. media.snapshot(ctx).title }, base.views.expanded(ctx) }
                end } })
                """)
            }
            let root = """
            function render(ctx)
                local activity = omniwm.components.activity('music')
                return ui.column{
                    ui.text{text='activity:'..(activity and activity.label or 'none')},
                    ui.component{id='music',view=ctx.data.title or 'compact',w=380,h=300,props={top=32,notchGap=88}}}
            end
            """
            XCTAssertEqual(
                omni_vm_load(
                    vm,
                    "@profile/widgets/root/init.luau",
                    root,
                    root.utf8.count,
                    200_000_000,
                    &error,
                    error.count
                ),
                OMNI_OK,
                message
            )
            var writer = ShellValueWriter()
            ShellServiceValue.array([.object([
                "id": .text("music"),
                "widget": .text(custom ? "custom-media" : "media"),
                "enabled": .bool(true),
                "options": .object([:])
            ])]).write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
            _ = try addDisplay()
        }

        isolated deinit {
            for display in displays { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        var captions: [String] {
            nodes.filter { $0.text != 0 }.map { text.string($0.text) }
        }

        var slider: omni_wire_node? {
            nodes.first { $0.kind == 8 }
        }

        func addDisplay() throws -> OpaquePointer {
            let display = try XCTUnwrap(omni_instance_create(vm))
            displays.append(display)
            return display
        }

        func set(_ media: ShellMedia?, mode: String, seconds: Double = 1005, display: OpaquePointer? = nil) {
            let display = display ?? displays[0]
            var writer = ShellValueWriter()
            if let media { media.write(into: &writer) } else { writer.null() }
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_set_value(display, "media", $0.baseAddress, $0.count)
            }, OMNI_OK)
            XCTAssertEqual(omni_instance_set_string(display, "title", mode, mode.utf8.count), OMNI_OK)
            XCTAssertEqual(omni_instance_set_number(display, "seconds", seconds), OMNI_OK)
        }

        @discardableResult
        func update(
            _ changed: UInt64 = .max,
            visible: Bool = true,
            display: OpaquePointer? = nil
        ) throws -> [omni_render_step_stats] {
            let display = display ?? displays[0]
            XCTAssertEqual(omni_instance_begin_update(display, OMNI_VIEW_BAR, changed, visible), OMNI_OK)
            var steps: [omni_render_step_stats] = []
            for _ in 0 ..< 32 {
                var step = omni_render_step_stats()
                XCTAssertEqual(
                    omni_instance_step_update(display, OMNI_VIEW_BAR, 200_000_000, &step, &error, error.count),
                    OMNI_OK,
                    message
                )
                XCTAssertEqual(step.unit_status, OMNI_OK, message)
                steps.append(step)
                if step.done {
                    dependencies = step.render.deps
                    if visible { try read(display) }
                    return steps
                }
            }
            XCTFail("media retained update did not complete")
            return steps
        }

        func read(_ display: OpaquePointer) throws {
            var size = 0
            let pointer = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &size))
            let bytes = Array(UnsafeBufferPointer(start: pointer, count: size))
            text.ingest(wire: bytes)
            demand = ShellWidgetDelivery.Tree(nodes: bytes).demand
            nodes = bytes.withUnsafeBytes { buffer in
                let header = buffer.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map {
                    buffer.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>
                            .stride,
                        as: omni_wire_node.self
                    )
                }
            }
        }

        @discardableResult
        func invoke(
            _ action: UInt32,
            phase: ShellEvent.Phase? = nil,
            value: Double? = nil,
            display: OpaquePointer? = nil
        ) -> [String] {
            let display = display ?? displays[0]
            var event = ShellEvent()
            event.kind = phase == nil ? .click : .slider
            event.phase = phase
            event.value = value
            XCTAssertEqual(event.bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    display,
                    OMNI_VIEW_BAR,
                    action,
                    0,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
            defer { omni_instance_clear_messages(display) }
            return (0 ..< omni_instance_message_count(display, OMNI_MESSAGE_REQUEST)).map { index in
                var size = 0
                guard let message = omni_instance_message(display, OMNI_MESSAGE_REQUEST, index, &size)
                else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: message, count: size), as: UTF8.self)
            }
        }
    }

    private func track(playing: Bool = true) -> ShellMedia {
        var result = ShellMedia()
        result.title = "Track A"
        result.artist = "Artist"
        result.album = "Album"
        result.bundle = "example.player"
        result.playing = playing
        result.duration = 200
        result.elapsed = 40
        result.rate = 1
        result.sampledAt = 1000
        return result
    }

    func testCompactArtworkAndWaveformKeepSpectrumOutOfLuauDependencies() throws {
        for custom in [false, true] {
            let fixture = try Fixture(custom: custom)
            var media = track()
            media.artwork = "media/0123456789abcdef"
            fixture.set(media, mode: "compact")
            try fixture.update()
            let artwork = try XCTUnwrap(fixture.nodes.first { $0.kind == 5 })
            XCTAssertEqual(fixture.text.string(artwork.text), media.artwork)
            XCTAssertEqual(artwork.width, 20)
            XCTAssertEqual(artwork.height, 20)
            let waveform = try XCTUnwrap(fixture.nodes.first { $0.options & UInt8(OMNI_NODE_OPTION_AUDIO) != 0 })
            XCTAssertEqual(fixture.text.string(waveform.text), "@omni-asset:media/waveform.metal")
            XCTAssertEqual(waveform.width, 36)
            XCTAssertEqual(waveform.height, 20)
            XCTAssertNotEqual(fixture.demand & ShellDataKey.spectrum.bit, 0)
            XCTAssertEqual(fixture.dependencies & ShellDataKey.spectrum.bit, 0)
            XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
            let steps = try fixture.update(ShellDataKey.spectrum.bit)
            XCTAssertFalse(steps.contains {
                $0.kind == OMNI_RENDER_ROOT || $0.kind == OMNI_RENDER_COMPONENT_VIEW || $0.kind == OMNI_RENDER_ACTIVITY
            })
            XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
        }
    }

    func testPausedAndUnavailableCompactViewsKeepTheirLabelsWithoutAudioDemand() throws {
        let fixture = try Fixture()
        for (media, label) in [(Optional(track(playing: false)), "Paused"), (nil, "Music")] {
            fixture.set(media, mode: "compact")
            try fixture.update()
            XCTAssertTrue(fixture.captions.contains(label))
            XCTAssertEqual(fixture.demand & ShellDataKey.spectrum.bit, 0)
            XCTAssertFalse(fixture.nodes.contains { $0.options & UInt8(OMNI_NODE_OPTION_AUDIO) != 0 })
        }
    }

    func testPeekAddsBoundedTrackTitleWithoutChangingScrubOrTransport() throws {
        let fixture = try Fixture()
        let media = track()
        fixture.set(media, mode: "peek")
        try fixture.update()
        let title = try XCTUnwrap(fixture.nodes.first { fixture.text.string($0.text) == media.title })
        XCTAssertEqual(title.max_width, 304)
        XCTAssertNotNil(fixture.slider)
        let button = try XCTUnwrap(fixture.nodes.first { $0.action != 0 && $0.kind != 8 })
        XCTAssertEqual(fixture.invoke(button.action), ["media toggle"])
    }

    func testOnlyVisiblePlayingPositionViewsDependOnSeconds() throws {
        let fixture = try Fixture()
        for mode in ["compact", "peek", "expanded"] {
            fixture.set(track(), mode: mode)
            try fixture.update()
            XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit != 0, mode != "compact")
            XCTAssertEqual(omni_instance_background_dependencies(fixture.displays[0]) & ShellDataKey.seconds.bit, 0)
            fixture.set(track(), mode: mode, seconds: 1006)
            let steps = try fixture.update(ShellDataKey.seconds.bit)
            XCTAssertEqual(steps.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, mode == "compact" ? 0 : 1)
            XCTAssertFalse(steps.contains { $0.kind == OMNI_RENDER_ACTIVITY || $0.kind == OMNI_RENDER_ROOT })
        }
        fixture.set(track(playing: false), mode: "expanded")
        try fixture.update()
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
        XCTAssertEqual(try XCTUnwrap(fixture.slider).series, 200)
        fixture.set(track(), mode: "expanded")
        try fixture.update()
        let hidden = try fixture.update(ShellDataKey.seconds.bit, visible: false)
        XCTAssertFalse(hidden.contains { $0.kind == OMNI_RENDER_COMPONENT_VIEW || $0.kind == OMNI_RENDER_ACTIVITY })
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testScrubPreviewIsDisplayLocalAndSeeksOnlyAtRelease() throws {
        let fixture = try Fixture()
        let second = try fixture.addDisplay()
        fixture.set(track(), mode: "expanded")
        fixture.set(track(), mode: "peek", display: second)
        try fixture.update()
        var slider = try XCTUnwrap(fixture.slider)
        XCTAssertEqual(slider.series, 225)
        XCTAssertEqual(fixture.invoke(slider.action, phase: .began, value: 0.3), [])
        try fixture.update(0)
        slider = try XCTUnwrap(fixture.slider)
        XCTAssertEqual(fixture.invoke(slider.action, phase: .changed, value: 0.75), [])
        try fixture.update(0)
        XCTAssertEqual(try XCTUnwrap(fixture.slider).series, 750)
        XCTAssertTrue(fixture.captions.contains("2:30"))
        try fixture.update(display: second)
        XCTAssertEqual(try XCTUnwrap(fixture.slider).series, 225)
        try fixture.read(fixture.displays[0])
        slider = try XCTUnwrap(fixture.slider)
        XCTAssertEqual(fixture.invoke(slider.action, phase: .ended, value: 0.8), ["media seek 160.0"])
        try fixture.update(0)
        XCTAssertEqual(try XCTUnwrap(fixture.slider).series, 225)
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testCancellationAndTrackSwitchDoNotSeek() throws {
        let fixture = try Fixture()
        fixture.set(track(), mode: "peek")
        try fixture.update()
        fixture.invoke(try XCTUnwrap(fixture.slider).action, phase: .began, value: 0.7)
        try fixture.update(0)
        XCTAssertEqual(fixture.invoke(try XCTUnwrap(fixture.slider).action, phase: .cancelled, value: 0.7), [])
        try fixture.update(0)
        XCTAssertEqual(try XCTUnwrap(fixture.slider).series, 225)
        fixture.invoke(try XCTUnwrap(fixture.slider).action, phase: .began, value: 0.7)
        var next = track()
        next.title = "Track B"
        fixture.set(next, mode: "peek")
        try fixture.update(ShellDataKey.media.bit)
        XCTAssertEqual(fixture.invoke(try XCTUnwrap(fixture.slider).action, phase: .changed, value: 0.8), [])
        try fixture.update(0)
        XCTAssertEqual(fixture.invoke(try XCTUnwrap(fixture.slider).action, phase: .ended, value: 0.9), [])
        try fixture.update(0)
        XCTAssertEqual(try XCTUnwrap(fixture.slider).series, 225)
    }

    func testUnavailableDurationAndAbsentPlayerHaveExplicitViewsWithoutClockDemand() throws {
        let fixture = try Fixture()
        let durations: [Double?] = [nil, 0]
        for duration in durations {
            var media = track()
            media.duration = duration
            fixture.set(media, mode: "peek")
            try fixture.update()
            XCTAssertNil(fixture.slider)
            XCTAssertTrue(fixture.captions.contains("Live or position unavailable"))
            XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
        }
        fixture.set(nil, mode: "expanded")
        try fixture.update()
        XCTAssertNil(fixture.slider)
        XCTAssertTrue(fixture.captions.contains("Nothing playing"))
        XCTAssertTrue(fixture.captions.contains("Start playback in a media app"))
        XCTAssertTrue(fixture.nodes.allSatisfy { $0.action == 0 })
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
    }

    func testPublicExtendRetainsMediaIntegrationAndInheritedPeek() throws {
        let fixture = try Fixture(custom: true)
        fixture.set(track(), mode: "expanded")
        try fixture.update()
        XCTAssertTrue(fixture.captions.contains("Custom: Track A"))
        XCTAssertTrue(fixture.captions.contains("activity:Track A"))
        let buttons = fixture.nodes.filter { $0.action != 0 && $0.kind != 8 }
        XCTAssertEqual(buttons.count, 3)
        XCTAssertEqual(buttons.flatMap { fixture.invoke($0.action) }, ["media previous", "media toggle", "media next"])
        fixture.set(track(), mode: "peek")
        try fixture.update(ShellDataKey.title.bit)
        XCTAssertNotNil(fixture.slider)
        XCTAssertFalse(fixture.captions.contains("Custom: Track A"))
        XCTAssertEqual(fixture.nodes.filter { $0.action != 0 && $0.kind != 8 }.count, 1)
    }
}
