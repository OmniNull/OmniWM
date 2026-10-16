// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ImageIO
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellImageTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func gif(at url: URL, delays: [Double]) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            delays.count,
            nil
        ))
        for (index, delay) in delays.enumerated() {
            let context = try XCTUnwrap(CGContext(
                data: nil,
                width: 4,
                height: 4,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: CGFloat(index) / 3, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testImagePathsStayInsideTheirFolders() throws {
        let widget = try folder("widget")
        let style = try folder("style/assets")
        let outside = try folder("outside")
        try gif(at: style.appendingPathComponent("cat.gif"), delays: [0.1])
        try gif(at: outside.appendingPathComponent("secret.gif"), delays: [0.1])
        try FileManager.default.createSymbolicLink(
            at: style.appendingPathComponent("link.gif"),
            withDestinationURL: outside.appendingPathComponent("secret.gif")
        )
        let folders = [widget, style.deletingLastPathComponent()]
        XCTAssertEqual(
            ShellImageLibrary.resolve("assets/cat.gif", in: folders)?.lastPathComponent,
            "cat.gif"
        )
        XCTAssertNil(ShellImageLibrary.resolve("../outside/secret.gif", in: folders))
        XCTAssertNil(ShellImageLibrary.resolve("assets/../../outside/secret.gif", in: folders))
        XCTAssertNil(ShellImageLibrary.resolve(outside.appendingPathComponent("secret.gif").path, in: folders))
        XCTAssertNil(ShellImageLibrary.resolve("~/secret.gif", in: folders))
        XCTAssertNil(ShellImageLibrary.resolve("assets//cat.gif", in: folders))
        XCTAssertNil(ShellImageLibrary.resolve("assets/link.gif", in: folders))
        XCTAssertNil(ShellImageLibrary.resolve("assets/missing.gif", in: folders))
    }

    func testAnimatedImagesKeepTheirFrameTimingAndAreCachedUntilTheyChange() throws {
        let folder = try folder("style")
        let url = folder.appendingPathComponent("cat.gif")
        try gif(at: url, delays: [0.1, 0.2, 0.005])
        let library = ShellImageLibrary()
        var loads = 0
        library.onLoad = { loads += 1 }
        let frames = try XCTUnwrap(library.image("cat.gif", folders: [folder]))
        XCTAssertEqual(frames.frames.count, 3)
        XCTAssertEqual(frames.ends[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(frames.ends[1], 0.3, accuracy: 0.001)
        XCTAssertEqual(frames.ends[2], 0.4, accuracy: 0.001)
        XCTAssertTrue(frames.animated)
        XCTAssertTrue(frames.frame(at: 0.15) === frames.frames[1])
        XCTAssertTrue(frames.frame(at: 0.45) === frames.frames[0])
        let animation = frames.animation(ShellPlayback(speed: 2, paused: false), phase: 0.5)
        XCTAssertEqual(animation.values?.count, 3)
        for (time, expected) in zip(animation.keyTimes?.map(\.doubleValue) ?? [], [0, 0.25, 0.75, 1.0]) {
            XCTAssertEqual(time, expected, accuracy: 0.001)
        }
        XCTAssertEqual(animation.keyTimes?.count, 4)
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.speed, 2)
        XCTAssertEqual(animation.timeOffset, 0.1, accuracy: 0.001)

        XCTAssertTrue(library.image("cat.gif", folders: [folder]) === frames)
        XCTAssertNil(library.image("cat.txt", folders: [folder]))
        XCTAssertEqual(loads, 1)
        XCTAssertFalse(library.refresh())
        try gif(at: url, delays: [0.1])
        XCTAssertTrue(library.refresh())
        let replaced = try XCTUnwrap(library.image("cat.gif", folders: [folder]))
        XCTAssertFalse(replaced === frames)
        XCTAssertFalse(replaced.animated)
    }

    func testPlaybackKeepsItsPhaseAcrossSpeedChangesAndPauses() throws {
        let folder = try folder("style")
        try gif(at: folder.appendingPathComponent("cat.gif"), delays: [0.1, 0.1])
        try gif(at: folder.appendingPathComponent("still.gif"), delays: [0.1])
        let library = ShellImageLibrary()
        let frames = try XCTUnwrap(library.image("cat.gif", folders: [folder]))
        let playing = ShellPlayback(speed: 2, paused: false)
        let running = ShellPlaybackState(frames: frames, phase: 0.5, start: 10, playback: playing)
        XCTAssertEqual(running.phase(at: 11), 2.5, accuracy: 0.001)
        let held = ShellPlaybackState(
            frames: frames,
            phase: 0.5,
            start: 10,
            playback: ShellPlayback(speed: 2, paused: true)
        )
        XCTAssertEqual(held.phase(at: 11), 0.5)
        let still = try XCTUnwrap(library.image("still.gif", folders: [folder]))
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 1)
        scene.submit([.insert(slot: 0, parent: -1, kind: .bitmap, after: -1)], animated: false)
        let state = try ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            defer { CATransaction.commit() }
            let layer = try XCTUnwrap(scene.layers[0])
            scene.imageFrames[0] = frames
            scene.playbackSettings[0] = playing
            scene.updatePlayback(0, contentsReplaced: true)
            let running = layer.animation(forKey: ShellLayerScene.framesKey) as? CAKeyframeAnimation
            scene.playbackSettings[0] = ShellPlayback(speed: 2, paused: true)
            scene.updatePlayback(0, contentsReplaced: false)
            let paused = (layer.animation(forKey: ShellLayerScene.framesKey) == nil, layer.contents != nil)
            scene.playbackSettings[0] = nil
            scene.updatePlayback(0, contentsReplaced: false)
            let stopped = layer.animation(forKey: ShellLayerScene.framesKey) == nil
            scene.imageFrames[0] = still
            scene.playbackSettings[0] = playing
            scene.updatePlayback(0, contentsReplaced: true)
            let single = layer.animation(forKey: ShellLayerScene.framesKey) == nil
            return (running?.speed, paused, stopped, single)
        }
        XCTAssertEqual(state.0, 2)
        XCTAssertTrue(state.1.0)
        XCTAssertTrue(state.1.1)
        XCTAssertTrue(state.2)
        XCTAssertTrue(state.3)
    }

    func testWidgetsShowImagesFromTheirFolderStillWhileAnimationsAreOff() throws {
        let folder = try folder("widget")
        try gif(at: folder.appendingPathComponent("cat.gif"), delays: [0.1, 0.1])
        let widget = try ShellRenderedWidget(name: "cat", source: """
        function render(ctx) return ui.image{ image = "cat.gif", w = 4, h = 4, speed = 3 } end
        """, directories: [folder])
        widget.render(ShellBarData())
        let (frames, playing, contents) = ShellLayerScene.engineQueue.sync {
            (
                widget.surface.scene.imageFrames.values.first,
                widget.surface.scene.playbacks.isEmpty,
                widget.surface.scene.layers.values.compactMap(\.contents).count
            )
        }
        XCTAssertEqual(frames?.frames.count, 2)
        XCTAssertTrue(playing)
        XCTAssertEqual(contents, 1)
    }
}
