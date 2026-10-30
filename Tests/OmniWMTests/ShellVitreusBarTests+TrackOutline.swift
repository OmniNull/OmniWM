// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

extension ShellVitreusBarTests {
    private struct TrackFixture {
        let widget: ShellRenderedWidget
        let renderer: ShellOffscreenRenderer
    }

    private struct ContourOwner {
        let layer: CALayer
        let parent: CALayer?
        let index: Int
    }

    private struct ContourVisibility {
        let layer: CALayer
        let hidden: Bool
    }

    private struct ContourFixture {
        let widget: ShellRenderedWidget
        let renderer: ShellOffscreenRenderer
        let root: CALayer
        let crop: CGRect
        let owners: [ContourOwner]
        var visibility: [ContourVisibility] = []
    }

    private struct ContourProbe {
        let entry: ShellShapeTrackEntry
        let body: CALayer
        let root: CALayer
        let crop: CGRect
        let nativeBegin: CFTimeInterval
    }

    private func trackBar(active: String) -> ShellBarData {
        var bar = VitreusFixture.bar()
        bar.workspaces = ["1", "2", "3"].map { id in
            ShellBarWorkspace(id: id, name: id, focused: id == active, windows: [ShellBarItem(
                id: id, bundle: "test." + id, name: id, focused: id == active,
                count: 1, hidden: 0, windows: []
            )])
        }
        return bar
    }

    private func initialTrackWidget() throws -> ShellRenderedWidget {
        let folder = try shell()
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(folder), scale: 1, resources: VitreusFixture.resources(folder)
        )
        VitreusFixture.settings(widget, ["pieces": .strings(["workspaces"])])
        VitreusFixture.show(widget, bar: trackBar(active: "1"))
        return widget
    }

    private func startTrack(_ widget: ShellRenderedWidget) {
        widget.resources.motion.userAnimationsEnabled = true
        widget.surface.animates = true
        VitreusFixture.show(widget, bar: trackBar(active: "2"))
    }

    private func trackWidget() throws -> TrackFixture {
        let widget = try initialTrackWidget()
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(origin: .zero, size: widget.surface.size)
            return try ShellOffscreenRenderer(root: root, width: Int(root.frame.width), height: Int(root.frame.height))
        }
        ShellLayerScene.engineQueue.sync {
            widget.surface.scene.container.speed = 0
            widget.surface.scene.container.timeOffset = CACurrentMediaTime()
        }
        startTrack(widget)
        return TrackFixture(widget: widget, renderer: renderer)
    }

    private func contourFixture() throws -> ContourFixture {
        let widget = try initialTrackWidget()
        let scene = widget.surface.scene
        let crop = try VitreusFixture.frame(widget, key: "shell").insetBy(dx: -12, dy: -12).integral
        let shape = try VitreusFixture.element(widget, key: "workspace-pill-shape").slot
        let outline = try VitreusFixture.element(widget, key: "workspace-pill-outline").slot
        let slots = try ShellLayerScene.engineQueue.sync { [try XCTUnwrap(scene.parents[shape]), outline] }
        var fixture = try contourRoot(widget, crop: crop)
        startTrack(widget)
        let root = fixture.root
        fixture.visibility = ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(scene.container.superlayer === root.sublayers?.first)
            return Self.hideContourSiblings(in: scene, keeping: slots)
        }
        return fixture
    }

    private func contourRoot(_ widget: ShellRenderedWidget, crop: CGRect) throws -> ContourFixture {
        let scene = widget.surface.scene
        return try ShellLayerScene.engineQueue.sync {
            let root = CALayer()
            root.frame = CGRect(x: 0, y: 0, width: crop.width * 2, height: crop.height * 2)
            root.isGeometryFlipped = true
            let holder = CALayer()
            holder.anchorPoint = .zero
            holder.setAffineTransform(CGAffineTransform(scaleX: 2, y: 2)
                .translatedBy(x: -crop.minX, y: -crop.minY))
            let owner = ContourOwner(
                layer: scene.container,
                parent: scene.container.superlayer,
                index: scene.container.superlayer?.sublayers?.firstIndex(of: scene.container) ?? 0
            )
            let time = CACurrentMediaTime()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.addSublayer(holder)
            scene.container.frame = CGRect(origin: .zero, size: widget.surface.size)
            root.speed = 0
            root.timeOffset = time
            holder.addSublayer(scene.container)
            CATransaction.commit()
            let renderer = try ShellOffscreenRenderer(
                root: root,
                width: Int(root.frame.width),
                height: Int(root.frame.height)
            )
            return ContourFixture(widget: widget, renderer: renderer, root: root, crop: crop, owners: [owner])
        }
    }

    private nonisolated static func hideContourSiblings(
        in scene: ShellLayerScene, keeping slots: [Int32]
    ) -> [ContourVisibility] {
        var allowed = Set(slots)
        for slot in slots {
            var current = scene.parents[slot]
            while let node = current {
                allowed.insert(node)
                current = scene.parents[node]
            }
            var descendants = Array(scene.children[slot] ?? [])
            while let node = descendants.popLast() {
                allowed.insert(node)
                descendants += scene.children[node] ?? []
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        return scene.layers.filter { !allowed.contains($0.key) }.map { _, layer in
            let value = ContourVisibility(layer: layer, hidden: layer.isHidden)
            layer.isHidden = true
            return value
        }
    }

    private func restoreContour(_ fixture: ContourFixture) {
        ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for value in fixture.visibility { value.layer.isHidden = value.hidden }
            for owner in fixture.owners {
                owner.layer.removeFromSuperlayer()
                owner.parent?.insertSublayer(owner.layer, at: UInt32(owner.index))
            }
            CATransaction.commit()
        }
    }

    func testWorkspacePencilRestContourKeepsTheTwoAuthoredPencilPasses() throws {
        let fixture = try trackWidget()
        defer { withExtendedLifetime(fixture) {} }
        let widget = fixture.widget
        let pill = try VitreusFixture.frame(widget, key: "workspace-pill-shape")
        let unit = 1.35
        let margin = 18.5 * unit
        let reference = try probe("""
        local pencil=require('../lib/vitreus/pencil')
        function render(ctx)
            local paths=pencil.outline(\(margin),\(margin),\(29 * unit),\(15 * unit),\(unit),0,0)
            return ui.column{ui.text{text=paths[1].d},ui.text{text=paths[2].d}}
        end
        """)
        XCTAssertEqual(reference.count, 2)
        let scene = widget.surface.scene
        let slots = try [1, 2].map { try VitreusFixture.element(widget, key: "workspace-pill-outline-\($0)").slot }
        try ShellLayerScene.engineQueue.sync {
            for (index, slot) in slots.enumerated() {
                let authored = try XCTUnwrap(scene.paths[slot]?.fitted(to: scene.layers[slot]?.bounds.size ?? .zero))
                let local = try XCTUnwrap(ShellPath.parse(reference[index])).path(fitting: nil, into: .zero)
                var transform = CGAffineTransform(translationX: pill.midX - margin, y: pill.midY - margin)
                let old = try XCTUnwrap(local.copy(using: &transform))
                let actual = Self.contourPoints(authored)
                let expected = Self.contourPoints(old)
                XCTAssertEqual(actual.count, expected.count)
                for (actual, expected) in zip(actual, expected) {
                    XCTAssertEqual(actual.x, expected.x, accuracy: 0.0011)
                    XCTAssertEqual(actual.y, expected.y, accuracy: 0.0011)
                }
            }
        }
    }

    func testWorkspacePencilContourAndFillShareEveryTrackSampleAndProportionalRadius() throws {
        let fixture = try trackWidget()
        defer { withExtendedLifetime(fixture) {} }
        let widget = fixture.widget
        let scene = widget.surface.scene
        let shape = try VitreusFixture.element(widget, key: "workspace-pill-shape").slot
        let paths = try [1, 2].map {
            try VitreusFixture.element(widget, key: "workspace-pill-outline-\($0)").slot
        }
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(scene.shapeTracks.entries[shape])
            let body = try XCTUnwrap(scene.glassBodies[entry.body])
            XCTAssertTrue(body.nativeAvailable, body.failure ?? "native body missing")
            let first = try XCTUnwrap(body.lockstepLayers(shape).first)
            let position = try XCTUnwrap(first.animation(forKey: "omni.glass.position") as? CAKeyframeAnimation)
            let baseRadius = entry.base.target.radius / min(entry.base.target.rect.width, entry.base.target.rect.height)
            XCTAssertGreaterThan(entry.duration, 0.2)
            for slot in paths {
                let layer = try XCTUnwrap(scene.layers[slot] as? CAShapeLayer)
                let animation = try XCTUnwrap(layer
                    .animation(forKey: ShellLayerScene.pathTrackKey) as? CAKeyframeAnimation)
                XCTAssertEqual(animation.beginTime, position.beginTime, accuracy: 1e-9)
                XCTAssertEqual(animation.duration, position.duration, accuracy: 1e-9)
                XCTAssertEqual(animation.keyTimes, position.keyTimes)
                let values = try XCTUnwrap(animation.values as? [CGPath])
                XCTAssertEqual(values.count, entry.samples.count)
                let target = try XCTUnwrap(scene.paths[slot]?.fitted(to: layer.bounds.size))
                XCTAssertEqual(values.last, target)
                let initial = try XCTUnwrap(values.first)
                XCTAssertLessThan(initial.boundingBoxOfPath.midX, target.boundingBoxOfPath.midX)
            }
            for elapsed in [0.0, 0.05, 0.10, 0.20, 0.60] {
                let sample = entry.shape(at: entry.begin + elapsed)
                XCTAssertEqual(sample.radius, min(sample.rect.width, sample.rect.height) * baseRadius, accuracy: 1e-9)
            }
            let stretched = entry.shape(at: entry.begin + 0.05)
            XCTAssertGreaterThan(stretched.rect.width, entry.base.target.rect.width + 5)
            XCTAssertLessThan(stretched.radius, entry.base.target.radius)
        }
    }

    func testWorkspacePencilContourPlaysInCARendererAtSeveralSwitchTimes() throws {
        let fixture = try contourFixture()
        defer { restoreContour(fixture) }
        let widget = fixture.widget
        let scene = widget.surface.scene
        let slot = try VitreusFixture.element(widget, key: "workspace-pill-shape").slot
        let outline = try VitreusFixture.element(widget, key: "workspace-pill-outline").slot
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(scene.shapeTracks.entries[slot])
            let body = try XCTUnwrap(scene.layers[entry.body])
            let native = try XCTUnwrap(scene.glassBodies[entry.body]?.lockstepLayers(slot).first)
            let nativeBegin = try XCTUnwrap(native.animation(forKey: "omni.glass.position")).beginTime
            XCTAssertEqual(native.convertTime(CACurrentMediaTime(), from: nil), nativeBegin, accuracy: 1e-9)
            let sketch = try XCTUnwrap(scene.layers[outline])
            let paths = sketch.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
            XCTAssertEqual(paths.count, 2)
            try Self.assertContourFrames(
                ContourProbe(
                    entry: entry,
                    body: body,
                    root: fixture.root,
                    crop: fixture.crop,
                    nativeBegin: nativeBegin
                ),
                paths: paths, renderer: fixture.renderer
            )
        }
    }

    func testWorkspacePencilTrackStopsWithReducedMotionAndBindingRemovalRestoresTheAuthoredPath() throws {
        let fixture = try trackWidget()
        defer { withExtendedLifetime(fixture) {} }
        let widget = fixture.widget
        widget.resources.motion.userAnimationsEnabled = false
        VitreusFixture.show(widget, bar: trackBar(active: "3"))
        let scene = widget.surface.scene
        let slot = try VitreusFixture.element(widget, key: "workspace-pill-outline-1").slot
        try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(scene.layers[slot] as? CAShapeLayer)
            let model = try XCTUnwrap(scene.paths[slot]?.fitted(to: layer.bounds.size))
            XCTAssertNil(layer.animation(forKey: ShellLayerScene.pathTrackKey))
            XCTAssertEqual(layer.path, model)
            XCTAssertTrue(scene.shapeTracks.contours.contains(slot))
            let stale = CGPath(rect: CGRect(x: 1, y: 2, width: 3, height: 4), transform: nil)
            layer.path = stale
            scene.presence.morphs.removeValue(forKey: slot)
            scene.flushPathTracks()
            XCTAssertEqual(layer.path, model)
            XCTAssertFalse(scene.shapeTracks.contours.contains(slot))
        }
    }

    private nonisolated static func assertContourFrames(
        _ probe: ContourProbe,
        paths: [CAShapeLayer], renderer: ShellOffscreenRenderer
    ) throws {
        let entry = probe.entry, body = probe.body, root = probe.root, crop = probe.crop
        for elapsed in [0.0, 0.05, 0.10, 0.20, 0.60] {
            let time = probe.nativeBegin + elapsed
            let sample = entry.shape(at: entry.begin + elapsed)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body.isHidden = true
            CATransaction.commit()
            let outlinePixels = try renderer.render(paused: time)
            if [0.0, 0.05, 0.20].contains(elapsed) {
                try Self.writeContour(
                    outlinePixels,
                    width: Int(root.frame.width),
                    name: "vitreus-pill-outline-\(Int(elapsed * 1000))ms"
                )
            }
            let drawn = try Self.contourBounds(outlinePixels, width: Int(root.frame.width))
            let target = sample.rect.offsetBy(dx: body.position.x - crop.minX, dy: body.position.y - crop.minY)
            for (actual, expected) in [
                (drawn.minX / 2, target.minX),
                (drawn.maxX / 2, target.maxX),
                (drawn.minY / 2, target.minY),
                (drawn.maxY / 2, target.maxY)
            ] {
                XCTAssertEqual(actual, expected, accuracy: 1.75, "time \(elapsed)")
            }
            for path in paths {
                let animation = try XCTUnwrap(path
                    .animation(forKey: ShellLayerScene.pathTrackKey) as? CAKeyframeAnimation)
                let values = try XCTUnwrap(animation.values as? [CGPath])
                let index = try XCTUnwrap(entry.samples.firstIndex { abs($0.time - elapsed) < 1e-8 })
                XCTAssertGreaterThan(values[index].boundingBoxOfPath.width, 0)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body.isHidden = false
            CATransaction.commit()
            let pixels = try renderer.render(paused: time)
            try Self.writeContour(
                pixels,
                width: Int(root.frame.width),
                name: "vitreus-pill-track-\(Int(elapsed * 1000))ms"
            )
        }
    }

    private nonisolated static func contourPoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let value = element.pointee
            let count = switch value.type {
            case .moveToPoint,
                 .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            case .closeSubpath: 0
            @unknown default: 0
            }
            points += (0 ..< count).map { value.points[$0] }
        }
        return points
    }

    private nonisolated static func contourBounds(_ pixels: [UInt8], width: Int) throws -> CGRect {
        var left = width, right = -1, top = pixels.count / (width * 4), bottom = -1
        for y in 0 ..< pixels.count / (width * 4) {
            for x in 0 ..< width where pixels[(y * width + x) * 4 + 3] > 16 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        XCTAssertGreaterThanOrEqual(right, left)
        guard right >= left else { throw NSError(domain: "ShellContourPixels", code: 1) }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private nonisolated static func writeContour(_ pixels: [UInt8], width: Int, name: String) throws {
        let height = pixels.count / (width * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue)), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        try ShellVitreusDeskTests.write(image, name: name)
    }
}
