// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
import ImageIO
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellBackingScaleTests: XCTestCase {
    func testDensityChangePreservesRootEditorSelectionAndRepaintsText() async throws {
        let originalScale: CGFloat = 1
        let nextScale: CGFloat = 2
        let pointSize: CGFloat = 14
        let label = "Density preserves the retained label"
        let draft = "The private draft stays selected"
        let selection = NSRange(location: "The ".utf16.count, length: "private draft".utf16.count)
        let frame = CGRect(x: 0, y: 0, width: 260, height: 120)
        var root = ShellBackingScaleFixture.node(.group, size: frame.size)
        var title = ShellBackingScaleFixture.node(.label, size: frame.size)
        title.text = 1
        title.text_size = UInt16(pointSize * 100)
        title.max_width = Float(frame.width / 2)
        title.lines = 2
        var editorNode = ShellBackingScaleFixture.node(.input, size: frame.size)
        editorNode.text = 2
        editorNode.text_size = title.text_size
        editorNode.input_flags = UInt8(OMNI_INPUT_MULTILINE)
        editorNode.input_max_length = UInt32(draft.utf16.count)
        var nodes = [root, title, editorNode]
        for index in nodes.indices { nodes[index].subtree_end = Int32(index + 1) }
        root.subtree_end = Int32(nodes.count)
        nodes[0] = root
        let fixture = ShellBackingScaleFixture(scale: originalScale)
        fixture.apply(nodes, strings: [label, draft])
        fixture.surface.view.frame = frame
        await fixture.complete()
        let surface = fixture.surface
        let scene = surface.scene
        let rootHandle = surface.layout.core.rootHandle
        let input = try XCTUnwrap(surface.textInputs.values.first)
        let editor = try XCTUnwrap(input.editor)
        editor.setSelectedRange(selection)
        surface.manipulationTargets[rootHandle] = rootHandle
        scene.submit(surface.ownedInputCommands(), animated: false)
        await fixture.complete()
        let titleHandle = try XCTUnwrap(surface.layout.core.elements { $0.text == title.text }.first)
        let originalSize = surface.size
        let originalFrame = surface.layout.core.layoutFrame(of: titleHandle)
        let originalLayer = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.layers[titleHandle.slot]) }
        let originalImages = try ShellLayerScene.engineQueue.sync {
            (
                try XCTUnwrap(originalLayer.contents as AnyObject?),
                try XCTUnwrap(scene.layers[input.handle.slot]?.contents as AnyObject?)
            )
        }
        XCTAssertFalse(surface.updateDisplayContext(scale: originalScale))
        XCTAssertTrue(surface.updateDisplayContext(scale: nextScale))
        await fixture.complete()
        XCTAssertTrue(surface.scene === scene)
        XCTAssertEqual(surface.layout.core.rootHandle, rootHandle)
        XCTAssertEqual(surface.layout.core.layoutFrame(of: titleHandle), originalFrame)
        XCTAssertEqual(surface.size, originalSize)
        XCTAssertTrue(surface.textInputs[input.handle] === input)
        XCTAssertEqual(editor.string, draft)
        XCTAssertEqual(editor.selectedRange(), selection)
        let style = UInt32(title.text_size) << OMNI_STYLE_SIZE_SHIFT
        let expected = ShellBackingScaleFixture.textSize(
            label, style: style, width: CGFloat(title.max_width), lines: Int(title.lines), scale: nextScale
        )
        let font = ShellTextStyle.font(for: style)
        let lineHeight = max(1, CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let inputLines = max(2, Int(frame.height / lineHeight))
        let expectedInput = ShellBackingScaleFixture.textSize(
            draft, style: style, width: frame.width, lines: inputLines, scale: nextScale
        )
        try ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(scene.layers[titleHandle.slot] === originalLayer)
            XCTAssertEqual(originalLayer.contentsScale, nextScale)
            XCTAssertEqual(scene.scale, nextScale)
            let image = try XCTUnwrap(originalLayer.contents as AnyObject?)
            XCTAssertFalse(image === originalImages.0)
            let snapshot = try XCTUnwrap(scene.layers[input.handle.slot]?.contents as AnyObject?)
            XCTAssertFalse(snapshot === originalImages.1)
            XCTAssertEqual(scene.layers[input.handle.slot]?.contentsScale, nextScale)
            let context = try XCTUnwrap(scene.textContext)
            XCTAssertEqual(CGSize(width: context.width, height: context.height), expectedInput)
            let raster = try XCTUnwrap(scene.rasterize(
                label, style: style, color: CGColor(gray: 1, alpha: 1),
                maxWidth: CGFloat(title.max_width), lines: Int(title.lines)
            ))
            XCTAssertEqual(CGSize(width: raster.width, height: raster.height), expected)
            let inputRaster = try XCTUnwrap(scene.rasterize(
                draft, style: style, color: CGColor(gray: 1, alpha: 1),
                maxWidth: frame.width, lines: inputLines
            ))
            XCTAssertEqual(CGSize(width: inputRaster.width, height: inputRaster.height), expectedInput)
        }
        XCTAssertFalse(surface.updateDisplayContext(scale: nextScale))
        XCTAssertEqual(surface.inputAppearances[input.handle]?.text, draft)
    }

    func testSymbolsIconsAndOriginalBitmapsKeepTheirOwners() async throws {
        let originalScale: CGFloat = 1
        let nextScale: CGFloat = 2
        let iconPoints = CGSize(width: 24, height: 24)
        let symbolName = "circle.fill"
        let iconReference = "test.density.icon"
        let bitmapReference = "test.density.original"
        let icon = NSImage(size: iconPoints, flipped: false) { rect in
            NSColor.red.setFill()
            NSBezierPath.fill(rect)
            return true
        }
        let resources = ShellResources(
            motion: MotionPolicy(animationsEnabled: false),
            iconOverride: { $0 == iconReference ? icon : nil }
        )
        let bitmap = try ShellBackingScaleFixture.image(size: iconPoints)
        resources.setBitmap(bitmap, for: bitmapReference)
        var root = ShellBackingScaleFixture.node(.group, size: iconPoints)
        var symbol = ShellBackingScaleFixture.node(.symbol, size: iconPoints)
        symbol.text = 1
        var iconNode = ShellBackingScaleFixture.node(.image, size: iconPoints)
        iconNode.text = 2
        var bitmapNode = ShellBackingScaleFixture.node(.bitmap, size: iconPoints)
        bitmapNode.text = 3
        var nodes = [root, symbol, iconNode, bitmapNode]
        for index in nodes.indices { nodes[index].subtree_end = Int32(index + 1) }
        root.subtree_end = Int32(nodes.count)
        nodes[0] = root
        let fixture = ShellBackingScaleFixture(scale: originalScale, resources: resources)
        fixture.apply(nodes, strings: [symbolName, iconReference, bitmapReference])
        await fixture.complete()
        let surface = fixture.surface
        let originalSymbol = try XCTUnwrap(surface.symbolImages.values.first)
        let bitmapHandle = try XCTUnwrap(surface.layout.core.elements { $0.text == bitmapNode.text }.first)
        XCTAssertTrue(surface.updateDisplayContext(scale: nextScale))
        await fixture.complete()
        let expectedIconPixels = Int((iconPoints.width * nextScale).rounded(.up))
        XCTAssertEqual(surface.iconImages.keys.map(\.pixels), [expectedIconPixels])
        var iconDemand = CGRect(
            origin: .zero,
            size: CGSize(width: expectedIconPixels, height: expectedIconPixels)
        )
        let expectedIcon = try XCTUnwrap(icon.cgImage(forProposedRect: &iconDemand, context: nil, hints: nil))
        let iconBitmap = try XCTUnwrap(surface.iconImages.values.first)
        XCTAssertEqual(iconBitmap.width, expectedIcon.width)
        XCTAssertEqual(iconBitmap.height, expectedIcon.height)
        let configured = try XCTUnwrap(NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: CGFloat(ShellTextStyle.symbolSize(for: 0)),
                weight: ShellTextStyle.symbolWeight(for: 0)
            )))
        var symbolDemand = CGRect(
            origin: .zero,
            size: CGSize(width: configured.size.width * nextScale, height: configured.size.height * nextScale)
        )
        let expectedSymbol = try XCTUnwrap(configured.cgImage(
            forProposedRect: &symbolDemand, context: nil, hints: nil
        ))
        let symbolBitmap = try XCTUnwrap(surface.symbolImages.values.first)
        XCTAssertEqual(symbolBitmap.width, expectedSymbol.width)
        XCTAssertEqual(symbolBitmap.height, expectedSymbol.height)
        XCTAssertFalse(symbolBitmap === originalSymbol)
        XCTAssertTrue(resources.icon(for: iconReference) === icon)
        try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(surface.scene.layers[bitmapHandle.slot])
            XCTAssertTrue((layer.contents as AnyObject?) === bitmap)
            XCTAssertEqual(layer.contentsScale, nextScale)
        }
        let symbolImage = try XCTUnwrap(surface.symbolImages.values.first)
        XCTAssertFalse(surface.updateDisplayContext(scale: nextScale))
        XCTAssertTrue(surface.symbolImages.values.first === symbolImage)
    }

    func testDensityRetainsAnimatedImageFramesAndPlaybackPhase() async throws {
        let originalScale: CGFloat = 1
        let nextScale: CGFloat = 2
        let size = CGSize(width: 24, height: 24)
        let frameDurations: [CFTimeInterval] = [0.25, 0.5]
        let playback = ShellPlayback(speed: 2, paused: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("density.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameDurations.count, nil
        ))
        for duration in frameDurations {
            let image = try ShellBackingScaleFixture.image(size: size)
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: duration]]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let frames = try XCTUnwrap(ShellImageFrames(url: url))
        XCTAssertEqual(frames.frames.count, frameDurations.count)
        XCTAssertEqual(frames.duration, frameDurations.reduce(0, +))
        let fixture = ShellBackingScaleFixture(scale: originalScale)
        var node = ShellBackingScaleFixture.node(.bitmap, size: size)
        node.subtree_end = 1
        fixture.apply([node], strings: [])
        await fixture.complete()
        let scene = fixture.surface.scene
        let handle = fixture.surface.layout.core.rootHandle
        let start = CACurrentMediaTime()
        ShellLayerScene.engineQueue.sync { scene.clock = { start } }
        var paint = ShellLayerPaint(
            fill: nil, border: nil, borderWidth: 0, radius: 0,
            opacity: 1, scale: 1, shadow: nil, shadowRadius: 0
        )
        paint.playback = playback
        await ShellBackingScaleFixture.submit([
            .paint(slot: handle.slot, paint, animation: nil),
            .image(slot: handle.slot, image: frames.frames.first, animation: nil, frames: frames)
        ], to: scene)
        let original = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.playbacks[handle.slot]) }
        XCTAssertTrue(original.frames === frames)
        XCTAssertEqual(original.start, start)
        XCTAssertEqual(original.phase, 0)
        XCTAssertEqual(original.playback, playback)
        let observedAt = start + frames.duration / playback.speed / 2
        let expectedPhase = (observedAt - start) * playback.speed
        ShellLayerScene.engineQueue.sync { scene.clock = { observedAt } }
        XCTAssertTrue(fixture.surface.updateDisplayContext(scale: nextScale))
        await fixture.complete()
        try ShellLayerScene.engineQueue.sync {
            let retained = try XCTUnwrap(scene.playbacks[handle.slot])
            XCTAssertTrue(scene.imageFrames[handle.slot] === frames)
            XCTAssertTrue(retained.frames === frames)
            XCTAssertEqual(retained.start, original.start)
            XCTAssertEqual(retained.phase, original.phase)
            XCTAssertEqual(retained.playback, playback)
            XCTAssertEqual(retained.phase(at: observedAt), expectedPhase)
            XCTAssertEqual(scene.playbackSettings[handle.slot], playback)
            let layer = try XCTUnwrap(scene.layers[handle.slot])
            XCTAssertTrue((layer.contents as AnyObject?) === frames.frames.first)
            XCTAssertEqual(layer.contentsScale, nextScale)
        }
        XCTAssertFalse(fixture.surface.updateDisplayContext(scale: nextScale))
    }

    func testDensityBeforeFirstTreeAndWhileHiddenUsesLatestValue() async throws {
        let fixture = ShellBackingScaleFixture(scale: 1)
        let destinationScale: CGFloat = 2
        let text = "The first tree uses the current density"
        var node = ShellBackingScaleFixture.node(.label, size: CGSize(width: 240, height: 30))
        node.text = 1
        node.subtree_end = 1
        XCTAssertTrue(fixture.surface.updateDisplayContext(scale: destinationScale))
        fixture.surface.setVisible(false)
        fixture.apply([node], strings: [text])
        await fixture.complete()
        XCTAssertFalse(fixture.surface.visible)
        let expected = ShellBackingScaleFixture.textSize(text, style: 0, scale: destinationScale)
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let layer = try XCTUnwrap(scene.layers[fixture.surface.layout.core.rootHandle.slot])
            XCTAssertNotNil(layer.contents)
            XCTAssertEqual(layer.contentsScale, destinationScale)
            XCTAssertEqual(scene.scale, destinationScale)
            let context = try XCTUnwrap(scene.textContext)
            XCTAssertEqual(CGSize(width: context.width, height: context.height), expected)
            let image = try XCTUnwrap(scene.rasterize(
                text, style: 0, color: CGColor(gray: 1, alpha: 1), maxWidth: 0, lines: 1
            ))
            XCTAssertEqual(CGSize(width: image.width, height: image.height), expected)
        }
        fixture.surface.setVisible(true)
        await fixture.complete()
        XCTAssertEqual(fixture.surface.scale, destinationScale)
        XCTAssertFalse(fixture.surface.updateDisplayContext(scale: .nan))
        XCTAssertFalse(fixture.surface.updateDisplayContext(scale: 0))
    }

    func testSameDensityRefreshesChangedEffectDisplayBinding() async throws {
        let scale: CGFloat = 2
        let previousDisplay = UInt32.max
        let fixture = ShellBackingScaleFixture(scale: scale)
        var root = ShellBackingScaleFixture.node(.group, size: CGSize(width: 24, height: 16))
        root.subtree_end = 1
        root.effect_ref = 1
        fixture.apply([root], strings: ["effect:0:0:0:0:0:0:density-fixture.metal"])
        await fixture.complete()
        let surface = fixture.surface
        let handle = surface.layout.core.rootHandle
        let binding = try XCTUnwrap(surface.effects[handle.slot])
        surface.effects[handle.slot] = .init(
            handle: handle, reference: binding.reference, recipe: binding.recipe, program: binding.program,
            display: previousDisplay, size: binding.size
        )
        XCTAssertNil(surface.view.window)
        XCTAssertTrue(surface.updateDisplayContext(scale: scale))
        await fixture.complete()
        XCTAssertNil(surface.effects[handle.slot]?.display)
        XCTAssertEqual(surface.scale, scale)
        XCTAssertFalse(surface.updateDisplayContext(scale: scale))
    }

    func testOldDensitySampleCannotRepopulateTheHitCache() async {
        let originalScale: CGFloat = 1
        let nextScale: CGFloat = 2
        let slot: Int32 = 0
        let point = CGPoint(x: 4, y: 3)
        let fixture = ShellBackingScaleFixture(scale: originalScale)
        let surface = fixture.surface
        surface.sampling.insert(slot)
        surface.samples[slot] = (point, false)
        var changes = 0
        surface.onShapeChange = { changes += 1 }
        XCTAssertTrue(surface.updateDisplayContext(scale: nextScale))
        XCTAssertNil(surface.samples[slot])
        let densityChanges = changes
        surface.receiveSample(slot, at: point, alpha: 0, scale: originalScale)
        XCTAssertNil(surface.samples[slot])
        XCTAssertFalse(surface.sampling.contains(slot))
        XCTAssertEqual(changes, densityChanges)
        surface.sampling.insert(slot)
        surface.receiveSample(slot, at: point, alpha: 1, scale: nextScale)
        XCTAssertEqual(surface.samples[slot]?.point, point)
        XCTAssertEqual(surface.samples[slot]?.inside, true)
        XCTAssertFalse(surface.sampling.contains(slot))
        await fixture.complete()
    }

    func testSceneUpdatesActivePartsButPreservesRetiringSnapshotAndMotion() async throws {
        let originalScale: CGFloat = 1
        let nextScale: CGFloat = 2
        let box: Int32 = 0
        let slider: Int32 = 1
        let progress: Int32 = 2
        let path: Int32 = 3
        let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        let scene = ShellLayerScene(container: CALayer(), scale: originalScale)
        var paint = ShellLayerPaint(
            fill: nil, border: nil, borderWidth: 0, radius: 0,
            opacity: 1, scale: 1, shadow: nil, shadowRadius: 0
        )
        paint.masks = true
        await ShellBackingScaleFixture.submit([
            .insert(slot: box, parent: -1, kind: .box, after: -1),
            .insert(slot: slider, parent: box, kind: .slider, after: -1),
            .insert(slot: progress, parent: box, kind: .progress, after: slider),
            .insert(slot: path, parent: box, kind: .path, after: progress),
            .frame(slot: box, rect: rect, animation: nil),
            .paint(slot: path, paint, animation: nil)
        ], to: scene)
        let retained = CALayer()
        let motionKey = "density-fixture-motion"
        let begin = CACurrentMediaTime()
        let renderer = try ShellLayerScene.engineQueue.sync {
            scene.container.frame = rect
            let renderer = try ShellOffscreenRenderer(
                root: scene.container, width: Int(rect.width), height: Int(rect.height)
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.container.speed = 0
            scene.container.timeOffset = begin
            CATransaction.commit()
            return renderer
        }
        defer { withExtendedLifetime(renderer) {} }
        let wrapper = try ShellLayerScene.engineQueue.sync {
            retained.contentsScale = originalScale
            retained.bounds = rect
            scene.layers[box]?.addSublayer(retained)
            scene.presence.retained[1] = .init(subtree: retained, identity: nil)
            let wrapper = try XCTUnwrap(scene.gestureWrapper(box)?.layer)
            wrapper.borderWidth = 1 / originalScale
            wrapper.borderColor = CGColor(gray: 1, alpha: 1)
            let motion = CABasicAnimation(keyPath: "opacity")
            motion.fromValue = 0
            motion.toValue = 1
            motion.duration = 1
            motion.beginTime = begin
            wrapper.add(motion, forKey: motionKey)
            XCTAssertNotNil(wrapper.animation(forKey: motionKey))
            return wrapper
        }
        await ShellBackingScaleFixture.submit([.backingScale(nextScale)], to: scene)
        ShellLayerScene.engineQueue.sync {
            XCTAssertEqual(scene.container.contentsScale, nextScale)
            XCTAssertEqual(scene.layers[box]?.contentsScale, nextScale)
            XCTAssertEqual(scene.progress[slider]?.fill.contentsScale, nextScale)
            XCTAssertEqual(scene.progress[slider]?.track?.contentsScale, nextScale)
            XCTAssertEqual(scene.progress[slider]?.knob?.contentsScale, nextScale)
            XCTAssertEqual(scene.progress[progress]?.fill.contentsScale, nextScale)
            XCTAssertEqual(scene.masks[path]?.layer.contentsScale, nextScale)
            XCTAssertEqual(wrapper.contentsScale, nextScale)
            XCTAssertEqual(wrapper.borderWidth, 1 / nextScale)
            XCTAssertNotNil(wrapper.animation(forKey: motionKey))
            XCTAssertTrue(scene.presence.retained[1]?.subtree === retained)
            XCTAssertEqual(retained.contentsScale, originalScale)
            XCTAssertEqual(retained.bounds, rect)
        }
    }
}

@MainActor
final class ShellBackingScaleFixture {
    let surface: ShellWidgetSurface
    let text = ShellTextStore()

    init(scale: CGFloat, resources: ShellResources? = nil, directories: [URL] = []) {
        surface = ShellWidgetSurface(
            scale: scale,
            resources: resources ?? ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            directories: directories
        )
    }

    static func node(_ kind: ElementKind, size: CGSize) -> omni_wire_node {
        var node = omni_wire_node()
        node.kind = kind.rawValue
        node.width = Float(size.width)
        node.height = Float(size.height)
        node.opacity = 1
        node.scale = 1
        return node
    }

    func apply(_ nodes: [omni_wire_node], strings: [String]) {
        for (index, string) in strings.enumerated() {
            var record = omni_wire_string(id: UInt32(index + 1), length: UInt32(string.utf8.count))
            var bytes = withUnsafeBytes(of: &record) { Array($0) }
            bytes.append(contentsOf: string.utf8)
            text.ingest(bytes, count: 1)
        }
        var header = omni_wire_header()
        header.magic = UInt32(OMNI_WIRE_MAGIC)
        header.node_count = UInt32(nodes.count)
        var bytes = withUnsafeBytes(of: &header) { Array($0) }
        nodes.withUnsafeBytes { bytes.append(contentsOf: $0) }
        XCTAssertTrue(surface.apply(bytes, text: text))
    }

    func complete() async {
        await Self.submit([], to: surface.scene)
    }

    static func submit(_ commands: [ShellLayerCommand], to scene: ShellLayerScene) async {
        await withCheckedContinuation { continuation in
            scene.submit(commands, animated: false) { continuation.resume() }
        }
    }

    static func image(size: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    static func textSize(
        _ text: String, style: UInt32, width: CGFloat = 0, lines: Int = 1, scale: CGFloat
    ) -> CGSize {
        let font = ShellTextStyle.font(for: style)
        let string = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let points: CGSize
        if lines > 1, width > 0 {
            points = ShellTextStyle.wrappedSize(
                of: ShellTextStyle.wrappedLines(string, width: width, limit: lines), font: font
            )
        } else {
            let line = CTLineCreateWithAttributedString(string)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            points = CGSize(width: width, height: ascent + descent)
        }
        return CGSize(width: (points.width * scale).rounded(.up), height: (points.height * scale).rounded(.up))
    }
}
