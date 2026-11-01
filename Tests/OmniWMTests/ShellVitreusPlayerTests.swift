// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellVitreusPlayerTests: XCTestCase {
    private struct Fixture {
        let widget: ShellRenderedWidget
        let monitor: Monitor
        var bar: ShellBarData
    }

    private func fixture(media: Bool = false, animations: Bool = false) throws -> Fixture {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), scale: 2,
            resources: VitreusFixture.resources(shell, animations: animations)
        )
        VitreusFixture.settings(widget, ["pieces": .strings(["workspaces", "title"])])
        let monitor = VitreusFixture.monitor()
        let fixture = Fixture(widget: widget, monitor: monitor, bar: VitreusFixture.bar(monitor))
        if media { setMedia(widget) }
        show(fixture)
        VitreusFixture.trigger(widget.instance, "drawer-player", fixture.bar.monitorId)
        show(fixture)
        omni_instance_clear_messages(widget.instance)
        return fixture
    }

    private func setMedia(_ widget: ShellRenderedWidget, duration: Double? = 240, playing: Bool = true) {
        var media = ShellMedia()
        media.title = "A song with a deliberately long title for a small glass plate"
        media.artist = "An artist with a long name"
        media.bundle = "test.music"
        media.app = "Music"
        media.playing = playing
        media.elapsed = 30
        media.duration = duration
        media.rate = playing ? 1 : 0
        media.sampledAt = 95
        widget.set("media") { media.write(into: &$0) }
    }

    private func show(_ fixture: Fixture) {
        fixture.widget.set("seconds") { $0.number(100) }
        fixture.widget.set("island") { VitreusFixture.island(fixture.monitor).write(to: &$0) }
        fixture.widget.render(fixture.bar)
        fixture.widget.surface.view.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
    }

    private func handle(_ fixture: Fixture, _ name: String) throws -> ElementHandle {
        try VitreusFixture.element(fixture.widget, key: name)
    }

    private func content(_ fixture: Fixture, _ name: String) throws -> Content {
        fixture.widget.surface.layout.core.content(of: try handle(fixture, name))
    }

    private func has(_ fixture: Fixture, _ name: String) -> Bool {
        let layout = fixture.widget.surface.layout
        return layout.core.elements { _ in true }.contains { layout.core.key(of: $0) == VitreusFixture.key(name) }
    }

    private func row(_ id: String, _ title: String, active: Bool = false) -> ShellBarWindow {
        .init(id: id, title: title, focused: active, hidden: false)
    }

    private func workspace(_ id: String, windows: [ShellBarWindow]) -> ShellBarWorkspace {
        .init(id: id, name: id, focused: windows.contains(where: \.focused), windows: [ShellBarItem(
            id: "app-" + id, bundle: "test.app", name: "An App", focused: windows.contains(where: \.focused),
            count: windows.count, hidden: 0, windows: windows
        )].filter { !$0.windows.isEmpty })
    }

    private func event(_ fixture: Fixture, key: String, middle: Bool = false) throws -> [String] {
        let frame = try VitreusFixture.frame(fixture.widget, key: key)
        let start = fixture.widget.events.count
        let input = ShellEvent(button: middle ? .middle : .left)
        fixture.widget.surface.press(at: CGPoint(x: frame.minX + 60, y: frame.midY), event: input)
        fixture.widget.surface.release(at: CGPoint(x: frame.minX + 60, y: frame.midY), event: input)
        return fixture.widget.events.dropFirst(start).flatMap { click in
            click.action & OMNI_ACTION_HANDLER != 0 ? fixture.widget.invoke(click.action, event: click.event) : []
        }
    }
}

extension ShellVitreusPlayerTests {
    func testPlayerHeightAndPlateAvailabilityFollowMediaAndPerDisplayRows() throws {
        var fixture = try fixture()
        XCTAssertFalse(has(fixture, "player-media"))
        XCTAssertTrue(has(fixture, "player-empty"))
        let empty = try VitreusFixture.frame(fixture.widget, key: "drawer-content-player")
        XCTAssertEqual(empty.width, 328 * 1.5525, accuracy: 0.001)
        XCTAssertEqual(empty.height, (55.5 + 14 + 156) * 1.5525, accuracy: 0.001)
        setMedia(fixture.widget)
        show(fixture)
        let media = try VitreusFixture.frame(fixture.widget, key: "player-media")
        let full = try VitreusFixture.frame(fixture.widget, key: "drawer-content-player")
        XCTAssertEqual(media.width, 288 * 1.5525, accuracy: 0.001)
        XCTAssertEqual(media.height, 148 * 1.5525, accuracy: 0.001)
        XCTAssertEqual(media.minX - full.minX, 20 * 1.5525, accuracy: 0.001)
        XCTAssertEqual(media.minY - full.minY, 22 * 1.5525, accuracy: 0.001)
        XCTAssertEqual(full.height, (55.5 + 14 + 156) * 1.5525, accuracy: 0.001)
        let cover = try VitreusFixture.frame(fixture.widget, key: "player-media-cover-fallback")
        XCTAssertEqual(cover.width, 72 * 1.5525, accuracy: 0.001)
        XCTAssertEqual(cover.minX - media.minX, 12 * 1.5525, accuracy: 0.001)
        fixture.widget.set("media") { $0.null() }
        fixture.bar.workspaces = [workspace("4", windows: [row("only-this-display", "Here")])]
        show(fixture)
        XCTAssertFalse(has(fixture, "player-media"))
        XCTAssertTrue(has(fixture, "player-task-only-this-display"))
        let deps = fixture.widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertEqual(deps & ShellDataKey.workspaces.bit, 0)
    }

    func testTasksSortActiveThenWorkspaceAndTitleCapAtTwelveAndScrollSixRows() throws {
        var fixture = try fixture()
        fixture.bar.workspaces = [
            workspace(
                "10",
                windows: [row("active", "Zulu", active: true)] + (0 ..< 7).map { row("z\($0)", "Zulu \($0)") }
            ),
            workspace("2", windows: (0 ..< 8).reversed().map { row("b\($0)", $0 == 0 ? "beta 0" : "Beta \($0)") })
        ]
        show(fixture)
        let expected = ["active"] + (0 ..< 8).map { "b\($0)" } + ["z0", "z1", "z2"]
        let frames = try expected.map { try VitreusFixture.frame(fixture.widget, key: "player-task-" + $0) }
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.width, 288 * 1.5525, accuracy: 0.001)
            XCTAssertEqual(frame.height, 36 * 1.5525, accuracy: 0.001)
            XCTAssertEqual(frame.minY - frames[0].minY, Double(index) * 40 * 1.5525, accuracy: 0.001)
        }
        let badge = try VitreusFixture.frame(fixture.widget, key: "player-task-badge-active")
        let number = try VitreusFixture.frame(fixture.widget, key: "player-task-workspace-active")
        XCTAssertEqual(number.midX, badge.midX, accuracy: 0.001)
        XCTAssertEqual(number.midY, badge.midY, accuracy: 0.001)
        XCTAssertFalse(has(fixture, "player-task-z3"))
        let scroll = try VitreusFixture.frame(fixture.widget, key: "player-tasks")
        XCTAssertEqual(scroll.height, 236 * 1.5525, accuracy: 0.001)
        let text = try content(fixture, "player-task-title-active")
        XCTAssertEqual(ShellTextStyle.symbolWeight(for: text.style), .bold)
        let slot = try handle(fixture, "player-task-title-active").slot
        XCTAssertEqual(text.color.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
        XCTAssertNotNil(ShellLayerScene.engineQueue.sync { fixture.widget.surface.scene.layers[slot] })
        let point = CGPoint(x: scroll.midX, y: scroll.maxY - 12)
        XCTAssertTrue(fixture.widget.surface.containsShape(at: point))
        _ = fixture.widget.surface.scroll(at: point, event: ShellEvent(), content: CGPoint(x: 0, y: 140))
        ShellLayerScene.engineQueue.sync {}
        let moved = try VitreusFixture.frame(fixture.widget, key: "player-task-z2")
        XCTAssertLessThan(moved.minY, frames.last!.minY)
    }

    func testWindowFocusMiddleCloseAndCrossUseTheSuppliedOpaqueIds() throws {
        var fixture = try fixture()
        let id = IPCWindowOpaqueID.encode(pid: 42, windowId: 7, sessionToken: "d3-session")
        fixture.bar.workspaces = [workspace("2", windows: [row(id, "Document")])]
        show(fixture)
        XCTAssertEqual(try event(fixture, key: "player-task-" + id, middle: true), ["window close " + id])
        show(fixture)
        let close = try content(fixture, "player-task-close-" + id)
        XCTAssertEqual(fixture.widget.text.string(close.action), "window close " + id)
        let hit = try VitreusFixture.frame(fixture.widget, key: "player-task-close-" + id)
        let before = fixture.widget.events.count
        fixture.widget.surface.press(at: CGPoint(x: hit.midX, y: hit.midY))
        fixture.widget.surface.release(at: CGPoint(x: hit.midX, y: hit.midY))
        XCTAssertEqual(fixture.widget.events.dropFirst(before).filter {
            $0.action & OMNI_ACTION_HANDLER == 0
        }.map { fixture.widget.text.string($0.action) }, ["window close " + id])
        XCTAssertEqual(try event(fixture, key: "player-task-" + id), ["window focus " + id])
        show(fixture)
        XCTAssertFalse(has(fixture, "drawer-content-player"))
    }

    func testBackgroundAppsHaveThreeRowsAndExistingActivationWithoutSettingsOverrides() throws {
        let fixture = try fixture()
        var data = ShellHiddenBarData()
        data.enabled = true
        data.available = true
        data.items = (0 ..< 5).map { .init(
            id: "tray\($0)",
            name: "Background app \($0)",
            image: nil,
            width: 18,
            height: 18
        ) }
        fixture.widget.set("hiddenBar") { data.write(into: &$0) }
        show(fixture)
        XCTAssertTrue(has(fixture, "player-background-heading"))
        for index in 0 ..< 3 {
            let row = try content(fixture, "player-background-tray\(index)")
            XCTAssertEqual(fixture.widget.text.string(row.action), "hidden-bar activate tray\(index)")
        }
        XCTAssertFalse(has(fixture, "player-background-tray3"))
        let frame = try VitreusFixture.frame(fixture.widget, key: "drawer-content-player")
        XCTAssertEqual(frame.height, (55.5 + 14 + 156 + 8 + 26 + 116) * 1.5525, accuracy: 0.001)
    }

    func testSpectrumIsDemandGatedAndSixtyBandsResampleDeterministicallyToTwentyFour() throws {
        let fixture = try fixture(media: true)
        let source = (0 ..< 60).map { Float($0) / 100 }
        fixture.widget.set("spectrum") { ShellSpectrum(access: .granted, bars: source).write(into: &$0) }
        show(fixture)
        var deps = fixture.widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertEqual(deps & ShellDataKey.spectrum.bit, 0)
        for index in 1 ... 24 {
            XCTAssertEqual(
                try VitreusFixture.frame(fixture.widget, key: "player-media-band-\(index)").height,
                1.5 * 1.5525,
                accuracy: 0.001
            )
        }
        VitreusFixture.settings(fixture.widget, ["visualiser": .bool(true)])
        show(fixture)
        deps = fixture.widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertNotEqual(deps & ShellDataKey.spectrum.bit, 0)
        for index in 0 ..< 24 {
            let left = Double(index) * 2.5, right = Double(index + 1) * 2.5
            var average = 0.0
            for sample in Int(floor(left)) ..< Int(ceil(right)) {
                average += Double(source[sample]) * max(0, min(right, Double(sample + 1)) - max(left, Double(sample))) /
                    2.5
            }
            let gain = 0.8 + 0.7 * Double(index) / 23
            let height = (1.5 + 31 * min(1, average * gain)) * 1.5525
            XCTAssertEqual(
                try VitreusFixture.frame(fixture.widget, key: "player-media-band-\(index + 1)").height,
                height,
                accuracy: 0.001
            )
        }
        VitreusFixture.settings(fixture.widget, ["visualiser": .bool(false)])
        show(fixture)
        deps = fixture.widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertEqual(deps & ShellDataKey.spectrum.bit, 0)
    }

    func testTransportSeekAndStreamUseExistingCommandsAndCorrectSeconds() throws {
        let fixture = try fixture(media: true)
        for (key, command) in [("previous", "media previous"), ("play", "media toggle"), ("next", "media next")] {
            XCTAssertEqual(fixture.widget.text.string(try content(fixture, "player-media-" + key).action), command)
        }
        let knob = try VitreusFixture.frame(fixture.widget, key: "player-media-seek-knob")
        let plate = try VitreusFixture.frame(fixture.widget, key: "player-media")
        XCTAssertEqual(knob.midX - plate.minX, (48 + 192 * 35 / 240) * 1.5525, accuracy: 0.001)
        let input = try content(fixture, "player-media-seek")
        var down = ShellEvent(button: .left)
        down.phase = .down
        down.x = (8 + 192 * 0.75) * 1.5525
        XCTAssertEqual(fixture.widget.invoke(input.pressAction, event: down), [])
        down.phase = .up
        XCTAssertEqual(fixture.widget.invoke(input.pressAction, event: down), ["media seek 180.000"])
        XCTAssertEqual(fixture.widget.invoke(input.gestureAction, event: down), [])
        setMedia(fixture.widget, duration: nil, playing: false)
        show(fixture)
        XCTAssertFalse(has(fixture, "player-media-seek"))
        XCTAssertTrue(fixture.widget.strings().contains("Live"))
        XCTAssertTrue(fixture.widget.strings().contains("0:30"))
    }

    func testNativeSeekDragCancelsThePressAndCommitsOnlyOnceAtRelease() throws {
        let fixture = try fixture(media: true)
        let frame = try VitreusFixture.frame(fixture.widget, key: "player-media-seek")
        let begin = CGPoint(x: frame.minX + (8 + 192 * 0.25) * 1.5525, y: frame.midY)
        let end = CGPoint(x: frame.minX + (8 + 192 * 0.75) * 1.5525, y: frame.midY)
        let offset = fixture.widget.events.count
        fixture.widget.surface.press(at: begin, timestamp: 0)
        fixture.widget.surface.drag(to: end, screen: .zero, timestamp: 0.05)
        fixture.widget.surface.release(at: end, timestamp: 0.1)
        let events = Array(fixture.widget.events.dropFirst(offset))
        XCTAssertTrue(events.contains { $0.event.phase == .cancel })
        XCTAssertTrue(events.contains { $0.event.phase == .began })
        XCTAssertTrue(events.contains { $0.event.phase == .ended })
        let commands = events.flatMap { fixture.widget.invoke($0.action, event: $0.event) }
        XCTAssertEqual(commands, ["media seek 180.000"])
    }

    func testStagingAndHaloContractHonorTheMotionPolicy() throws {
        var fixture = try fixture(media: true, animations: true)
        fixture.bar.workspaces = [
            workspace("1", windows: [row("one", "One", active: true)]),
            workspace("2", windows: [row("two", "Two")]),
            workspace("3", windows: [])
        ]
        show(fixture)
        let target = try handle(fixture, "player-f3")
        let paint = fixture.widget.surface.layout.core.paint(of: target)
        let presence = try XCTUnwrap(fixture.widget.surface.presence(paint.appear, for: target))
        XCTAssertEqual(presence.delay, 0.2)
        XCTAssertEqual(presence.opacity, 0)
        XCTAssertEqual(presence.offset.y, 12 * 1.5525, accuracy: 0.001)
        guard case let .spring(response, bounce) = presence.animation?.motion
        else { return XCTFail("Missing f3 spring") }
        XCTAssertEqual(response, 2 * .pi * 0.52 / 6.64, accuracy: 0.0001)
        XCTAssertEqual(bounce, 0)
        fixture.widget.resources.motion.userAnimationsEnabled = false
        show(fixture)
        XCTAssertNil(fixture.widget.surface.presence(paint.appear, for: target)?.animation)
        for key in ["workspace-overview-icon", "workspace-mark-halo-2", "workspace-plus-halo"] {
            let slot = try handle(fixture, key).slot
            try ShellLayerScene.engineQueue.sync {
                let layer = try XCTUnwrap(fixture.widget.surface.scene.layers[slot])
                XCTAssertEqual(layer.shadowRadius, 2.4 * 1.35, accuracy: 0.001)
                XCTAssertEqual(layer.shadowOpacity, 1)
                XCTAssertEqual(layer.shadowOffset, .zero)
            }
        }
    }
}

extension ShellVitreusPlayerTests {
    func testSpectrumChangesPresentImmediatelyWithReducedMotion() throws {
        let fixture = try fixture(media: true)
        fixture.widget.set("spectrum") {
            ShellSpectrum(access: .granted, bars: [Float](repeating: 1, count: 60)).write(into: &$0)
        }
        VitreusFixture.settings(fixture.widget, ["visualiser": .bool(true)])
        show(fixture)
        let slot = try handle(fixture, "player-media-band-1").slot
        try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(fixture.widget.surface.scene.layers[slot])
            XCTAssertEqual(layer.bounds.height, (1.5 + 31 * 0.8) * 1.5525, accuracy: 0.001)
            for key in ["bounds", "bounds.size.height", "position", "position.y"] {
                XCTAssertNil(layer.animation(forKey: key), key)
            }
        }
    }

    func testOpenPlayerHasNativePixelsAtTwoTimesScale() throws {
        var fixture = try fixture(media: true)
        fixture.bar.workspaces = [workspace(
            "1",
            windows: (0 ..< 9).map { row("row\($0)", "Window \($0)", active: $0 == 4) }
        )]
        show(fixture)
        let panel = try VitreusFixture.frame(fixture.widget, key: "drawer-content-player")
        let crop = panel.insetBy(dx: -10, dy: -10).integral
        let scale = 2
        let bytes = try VitreusFixture.pixels(fixture.widget, crop: crop, scale: scale)
        XCTAssertTrue(bytes.contains { $0 > 100 })
        let width = Int(crop.width) * scale, height = Int(crop.height) * scale
        let cover = try VitreusFixture.frame(fixture.widget, key: "player-media-cover-fallback")
        let x = Int((cover.midX - crop.minX) * Double(scale))
        let y = Int((cover.midY - crop.minY) * Double(scale))
        XCTAssertGreaterThan(bytes[(y * width + x) * 4 + 3], 0)
        try save(bytes, width: width, height: height, name: "vitreus-player-\(scale)x")
    }

    private func save(_ bytes: [UInt8], width: Int, height: Int, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let rep = NSBitmapImageRep(cgImage: image)
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent(name + ".png"))
    }
}
