// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

private struct VitreusProbe {
    let crop: CGRect
    let scale: Int
    let full: [UInt8]
    let twin: [UInt8]

    var width: Int {
        Int(crop.width) * scale
    }

    var height: Int {
        Int(crop.height) * scale
    }

    func pixel(_ bytes: [UInt8], _ x: CGFloat, _ y: CGFloat) -> [Int] {
        let row = Int((y - crop.minY) * CGFloat(scale))
        let index = (row * width + Int((x - crop.minX) * CGFloat(scale))) * 4
        return bytes[index ..< index + 4].map(Int.init)
    }

    func bounds() -> CGRect {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for row in 0 ..< height {
            for column in 0 ..< width where twin[(row * width + column) * 4 + 3] > 8 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        let factor = CGFloat(scale)
        return CGRect(
            x: crop.minX + CGFloat(minX) / factor, y: crop.minY + CGFloat(minY) / factor,
            width: CGFloat(maxX + 1 - minX) / factor, height: CGFloat(maxY + 1 - minY) / factor
        )
    }

    func span(column x: CGFloat) -> (min: CGFloat, max: CGFloat)? {
        let factor = CGFloat(scale)
        let column = Int((x - crop.minX) * factor)
        let rows = (0 ..< height).filter { twin[($0 * width + column) * 4 + 3] > 8 }
        guard let first = rows.first, let last = rows.last else { return nil }
        return (crop.minY + CGFloat(first) / factor, crop.minY + CGFloat(last + 1) / factor)
    }

    func reach(from start: CGPoint, step: CGVector) -> CGFloat {
        var point = start
        var distance: CGFloat = 0
        while crop.contains(point), pixel(full, point.x, point.y)[3] > 2 {
            point = CGPoint(x: point.x + step.dx, y: point.y + step.dy)
            distance += 1
        }
        return distance
    }

    func edges() -> VitreusEdges {
        let card = bounds()
        let (x, y) = (card.midX, card.midY)
        let interior = pixel(full, card.minX + 12.5, y)
        let rim = (0 ..< 12).prefix { offset in
            let value = pixel(full, card.minX + 0.5 + CGFloat(offset), y)
            return (0 ..< 3).contains { abs(value[$0] - interior[$0]) > 6 }
        }.count
        return VitreusEdges(
            card: card,
            below: reach(from: CGPoint(x: x, y: card.maxY + 0.5), step: CGVector(dx: 0, dy: 1)),
            above: reach(from: CGPoint(x: x, y: card.minY - 0.5), step: CGVector(dx: 0, dy: -1)),
            left: reach(from: CGPoint(x: card.minX - 0.5, y: y), step: CGVector(dx: -1, dy: 0)),
            right: reach(from: CGPoint(x: card.maxX + 0.5, y: y), step: CGVector(dx: 1, dy: 0)),
            rim: CGFloat(rim)
        )
    }

    func image(_ bytes: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

private struct VitreusEdges {
    let card: CGRect
    let below: CGFloat
    let above: CGFloat
    let left: CGFloat
    let right: CGFloat
    let rim: CGFloat

    var summary: String {
        "card \(card.integral) shadow below \(below) above \(above) left \(left) right \(right) rim \(rim)"
    }
}

@MainActor
extension ShellVitreusDeskTests {
    private nonisolated static func offscreen(_ layer: CALayer, crop: CGRect, scale: Int) throws -> [UInt8] {
        let previous = layer.superlayer
        let index = previous?.sublayers?.firstIndex(of: layer) ?? 0
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: Int(crop.width) * scale, height: Int(crop.height) * scale)
        root.isGeometryFlipped = true
        let holder = CALayer()
        holder.anchorPoint = .zero
        holder.bounds = layer.bounds
        holder.setAffineTransform(
            CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)).translatedBy(x: -crop.minX, y: -crop.minY)
        )
        root.addSublayer(holder)
        holder.addSublayer(layer)
        defer {
            layer.removeFromSuperlayer()
            previous?.insertSublayer(layer, at: UInt32(index))
        }
        return try ShellOffscreenRenderer(root: root, width: Int(root.frame.width), height: Int(root.frame.height))
            .render()
    }

    private func assertGlass(_ probe: VitreusProbe, envelope rect: CGRect, du: CGFloat) throws {
        let label = "\(probe.scale)x"
        let bounds = probe.bounds()
        let tolerance = 1 / CGFloat(probe.scale)
        for (value, target) in [(bounds.minX, rect.minX), (bounds.minY, rect.minY), (bounds.maxY, rect.maxY)] {
            XCTAssertEqual(value, target, accuracy: tolerance, label)
        }
        let edge = min(probe.crop.maxX, 1920)
        XCTAssertGreaterThanOrEqual(bounds.maxX, edge - tolerance, label)
        let gap = Array(stride(from: rect.maxX + tolerance / 2, to: edge, by: tolerance))
        XCTAssertTrue(gap.allSatisfy { probe.pixel(probe.twin, $0, rect.midY)[3] > 8 }, label)
        let band = 2 * 35.1 + 1920 - rect.maxX + 1
        let neck = gap.filter { $0 > rect.maxX + 1 }.compactMap { probe.span(column: $0) }
        XCTAssertFalse(neck.isEmpty, label)
        XCTAssertGreaterThanOrEqual(neck.map(\.min).min() ?? -.infinity, rect.midY - band, label)
        XCTAssertLessThanOrEqual(neck.map(\.max).max() ?? .infinity, rect.midY + band, label)
        let corner = 35.1 - (35.1 + 3) / 2.squareRoot()
        XCTAssertEqual(probe.pixel(probe.twin, rect.minX + corner, rect.minY + corner)[3], 0, label)
        let center = CGPoint(x: rect.minX + 176.5 * du, y: rect.minY + 230 * du)
        let tint = probe.pixel(probe.full, center.x, center.y)
        XCTAssertGreaterThan(tint[0], tint[1], label)
        XCTAssertGreaterThan(tint[1], tint[2], label)
        XCTAssertEqual(tint, probe.pixel(probe.twin, center.x, center.y), label)
        print("Vitreus glass probe \(label) centre BGRA: \(tint)")
        let below = probe.pixel(probe.full, center.x, rect.maxY + 8)[3]
        XCTAssertGreaterThan(below, probe.pixel(probe.full, center.x, rect.minY - 8)[3], label)
        let left = (1 ... 6).map { probe.pixel(probe.full, rect.minX + CGFloat($0), center.y)[2] }.max() ?? 0
        let right = (1 ... 6).map { probe.pixel(probe.full, rect.maxX - CGFloat($0), center.y)[2] }.max() ?? 0
        XCTAssertGreaterThan(left, right, label)
        try Self.write(XCTUnwrap(probe.image(probe.full)), name: "vitreus-glass-probe-\(label)")
        try Self.write(XCTUnwrap(probe.image(probe.twin)), name: "vitreus-glass-probe-shadowless-\(label)")
    }

    func testOffscreenGlassProbeMatchesTheDeskSilhouetteTintShadowAndRim() throws {
        let widget = try VitreusFixture.desk(shell(), scale: 1)
        let (rect, du) = Self.envelope(width: 1920, height: 1080)
        let container = widget.surface.scene.container
        let body = try VitreusFixture.body(widget)
        let probes = try ShellLayerScene.engineQueue.sync {
            guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
            container.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            return try [(CGRect(x: 0, y: 80, width: 1920, height: 1000), 1), (rect.insetBy(dx: -40, dy: -40), 2)]
                .map { crop, scale in
                    let full = try Self.offscreen(container, crop: crop, scale: scale)
                    body.sdfLayers[0].isHidden = true
                    defer { body.sdfLayers[0].isHidden = false }
                    let twin = try Self.offscreen(container, crop: crop, scale: scale)
                    return VitreusProbe(crop: crop, scale: scale, full: full, twin: twin)
                }
        }
        for probe in probes {
            try assertGlass(probe, envelope: rect, du: du)
        }
    }

    private nonisolated static func assertSpring(_ motion: ShellMotion?, _ response: Double, _ bounce: Double) {
        guard case let .spring(actual, spring)? = motion else { return XCTFail("\(String(describing: motion))") }
        XCTAssertEqual(actual, response, accuracy: 0.0001)
        XCTAssertEqual(spring, bounce, accuracy: 0.0001)
    }

    func testOpeningTheDeskRevealsTheGlassAndDelaysOnlyTheTabBandAndSections() throws {
        let widget = try VitreusFixture.desk(shell(), scale: 1, animations: true)
        let (rect, du) = Self.envelope(width: 1920, height: 1080)
        let glass = try VitreusFixture.element(widget, key: "desk-glass")
        let shape = try VitreusFixture.element(widget, key: "desk-shape")
        let slots = try ["desk-frame", "fd1", "fd2", "fd3", "page", "desk", "desk-clip"].map {
            try VitreusFixture.element(widget, key: $0).slot
        }
        let desk = try VitreusFixture.element(widget, key: "desk")
        let opening = try XCTUnwrap(widget.surface.reveals[desk]?.plan)
        XCTAssertEqual(try XCTUnwrap(widget.surface.reveals[shape]?.plan).begin, opening.begin)
        try ShellLayerScene.engineQueue.sync {
            let scene = widget.surface.scene
            let body = try XCTUnwrap(scene.glassBodies[glass.slot])
            XCTAssertEqual(body.layer.bounds.size, CGSize(width: 1920, height: 1080))
            let drawn = try XCTUnwrap(scene.glassShapes[shape.slot]).rect
            for (value, target) in [
                (drawn.minX, rect.minX), (drawn.minY, rect.minY), (drawn.width, rect.width), (drawn.height, rect.height)
            ] {
                XCTAssertEqual(value, target, accuracy: 0.01)
            }
            XCTAssertNotNil(scene.presence.reveals[shape.slot])
            XCTAssertEqual(scene.shapeTracks.follows[shape.slot]?.radius, .scaled)
            XCTAssertNil(scene.presence.appearances[glass.slot])
            XCTAssertNotNil(scene.presence.reveals[slots[5]])
            XCTAssertNotNil(scene.presence.morphs[slots[6]])
            for (slot, response) in zip(slots[0 ... 3], [0.360, 0.530, 0.643, 0.738]) {
                let rise = try XCTUnwrap(scene.presence.appearances[slot])
                XCTAssertEqual(rise.opacity, 0)
                XCTAssertEqual(rise.offset.y, 12 * du, accuracy: 0.01)
                XCTAssertEqual(rise.delay, 0.2, accuracy: 1e-6)
                Self.assertSpring(rise.animation?.motion, response, 0)
                let fall = try XCTUnwrap(scene.presence.departures[slot])
                XCTAssertEqual(fall.offset.y, 12 * du, accuracy: 0.01)
                Self.assertSpring(fall.animation?.motion, 0.076, 0)
            }
            XCTAssertNil(scene.presence.appearances[slots[4]])
            XCTAssertNil(scene.presence.departures[slots[4]])
            let home = try XCTUnwrap(scene.presence.departures[slots[5]])
            XCTAssertEqual(home.opacity, 1)
            XCTAssertEqual(home.scale, 1)
            XCTAssertEqual(home.anchor, .zero)
            Self.assertSpring(home.animation?.motion, 0.363, 0.42)
        }
    }

    func testSectionsRiseOnlyAfterOpeningAndStillFallWhenTheDeskClosesAfterATabSwitch() throws {
        let widget = try VitreusFixture.desk(shell(), scale: 1, animations: true)
        let surface = widget.surface
        let layout = surface.layout
        let du = Self.envelope(width: 1920, height: 1080).du
        XCTAssertNotEqual(layout.core.paint(of: try VitreusFixture.element(widget, key: "fd1")).appear, 0)
        surface.finishReveals()
        try VitreusFixture.click(widget, key: "tab-pad")
        XCTAssertTrue(widget.strings().contains("Nothing to do. Nice."))
        let section = try VitreusFixture.element(widget, key: "fd2")
        XCTAssertEqual(layout.core.paint(of: section).appear, 0)
        XCTAssertNotEqual(layout.core.paint(of: section).exit, 0)
        let band = try VitreusFixture.element(widget, key: "desk-frame").slot
        let scene = surface.scene
        let host = try ShellLayerScene.engineQueue.sync {
            try Self.hosted(scene.container, crop: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        }
        VitreusFixture.trigger(widget.instance, "desk-close", nil)
        VitreusFixture.show(widget)
        XCTAssertFalse(layout.core.contains(section))
        try ShellLayerScene.engineQueue.sync {
            let departures = scene.presence.retained.values.flatMap(\.animations.values)
            XCTAssertTrue(Set(departures.map(\.slot)).isSuperset(of: [band, section.slot]))
            let fall = try XCTUnwrap(departures
                .first { $0.slot == section.slot && $0.key == ShellLayerScene.departureKey })
            XCTAssertEqual(fall.layer.opacity, 0)
            XCTAssertEqual(fall.layer.transform.m42, 12 * du, accuracy: 0.01)
            XCTAssertNotNil(fall.layer.animation(forKey: ShellLayerScene.departureKey))
        }
        withExtendedLifetime(host.renderer) {}
    }

    func testScaleCommitAtHalfSizeKeepsTheCardShadowAndRim() throws {
        let widget = try VitreusFixture.desk(shell(), scale: 1)
        let (home, du) = Self.envelope(width: 1920, height: 1080)
        let container = widget.surface.scene.container
        let crop = home.insetBy(dx: -60, dy: -60)
        func measure() throws -> VitreusProbe {
            let body = try VitreusFixture.body(widget)
            return try ShellLayerScene.engineQueue.sync {
                guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
                container.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                let full = try Self.offscreen(container, crop: crop, scale: 1)
                body.sdfLayers[0].isHidden = true
                defer { body.sdfLayers[0].isHidden = false }
                return try VitreusProbe(
                    crop: crop,
                    scale: 1,
                    full: full,
                    twin: Self.offscreen(container, crop: crop, scale: 1)
                )
            }
        }
        let handle = try VitreusFixture.frame(widget, key: "resize-sw")
        let start = CGPoint(x: handle.midX, y: handle.midY)
        let end = CGPoint(x: start.x + 200 * du, y: start.y - 200 * du)
        VitreusFixture.grab(widget, at: start, to: end)
        XCTAssertNotNil(widget.surface.manipulation)
        let drag = try measure().edges()
        VitreusFixture.drop(widget, at: end)
        XCTAssertNil(widget.surface.manipulation)
        let rect = try VitreusFixture.frame(widget, key: "desk")
        XCTAssertEqual(rect.width / home.width, 0.5, accuracy: 1e-6)
        let rest = try measure().edges()
        for (before, after) in [
            (drag.card.minX, rest.card.minX), (drag.card.maxX, rest.card.maxX), (drag.card.minY, rest.card.minY),
            (drag.card.maxY, rest.card.maxY)
        ] {
            XCTAssertEqual(before, after, accuracy: 1)
        }
        XCTAssertEqual(rest.card.minX, rect.minX, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(rest.card.maxX, 1920 - 1)
        XCTAssertEqual(rest.card.midY, rect.midY, accuracy: 1.5)
        XCTAssertEqual(rest.card.height, rect.height, accuracy: 3)
        for (before, after) in [
            (drag.below, rest.below), (drag.above, rest.above), (drag.left, rest.left), (drag.right, rest.right),
            (drag.rim, rest.rim)
        ] {
            XCTAssertEqual(before, after, accuracy: 1)
        }
        XCTAssertGreaterThan(rest.below, rest.above)
        print("Vitreus scale-commit probe at s 0.5, dragging: \(drag.summary)")
        print("Vitreus scale-commit probe at s 0.5, committed: \(rest.summary)")
    }

    private nonisolated static func hosted(
        _ container: CALayer,
        crop: CGRect
    ) throws -> (root: CALayer, renderer: ShellOffscreenRenderer) {
        container.removeFromSuperlayer()
        container.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: crop.size)
        root.isGeometryFlipped = true
        let holder = CALayer()
        holder.anchorPoint = .zero
        holder.bounds = container.bounds
        holder.setAffineTransform(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        root.addSublayer(holder)
        holder.addSublayer(container)
        return try (root, ShellOffscreenRenderer(root: root, width: Int(crop.width), height: Int(crop.height)))
    }

    private nonisolated static func silhouette(
        _ body: ShellGlassBody,
        hiding content: CALayer?,
        host: (root: CALayer, renderer: ShellOffscreenRenderer),
        crop: CGRect,
        at time: CFTimeInterval
    ) throws -> CGRect {
        guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.sdfLayers[0].isHidden = true
        content?.isHidden = true
        CATransaction.commit()
        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body.sdfLayers[0].isHidden = false
            content?.isHidden = false
            host.root.speed = 1
            host.root.timeOffset = 0
            CATransaction.commit()
        }
        let bytes = try host.renderer.render(paused: time)
        return VitreusProbe(crop: crop, scale: 1, full: bytes, twin: bytes).bounds()
    }

    func testOpeningDeskGlassAt84MillisecondsMatchesTheRevealSampler() throws {
        let shell = try shell()
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), scale: 1, resources: VitreusFixture.resources(shell, animations: true)
        )
        let clock = ShellManipulationSurfaceTests.Clock()
        widget.surface.clock = { clock.now }
        VitreusFixture.show(widget)
        let (rect, _) = Self.envelope(width: 1920, height: 1080)
        let crop = rect.insetBy(dx: -80, dy: -80)
        let scene = widget.surface.scene
        let host = try ShellLayerScene.engineQueue.sync { try Self.hosted(scene.container, crop: crop) }
        VitreusFixture.trigger(widget.instance, "desk-open", VitreusFixture.bar().monitorId)
        VitreusFixture.show(widget)
        let shape = try VitreusFixture.element(widget, key: "desk-shape")
        let plan = try XCTUnwrap(widget.surface.reveals[shape]?.plan)
        let content = try XCTUnwrap(widget.surface.reveals[VitreusFixture.element(widget, key: "desk")]?.plan)
        XCTAssertEqual(plan.begin, content.begin)
        XCTAssertEqual(plan.duration, content.duration)
        let morph = try XCTUnwrap(widget.surface.morph(widget.surface.layout.core.paint(of: shape).morph))
        let clip = try VitreusFixture.element(widget, key: "desk-clip").slot
        let body = try VitreusFixture.body(widget)
        func silhouette(at time: CFTimeInterval) throws -> CGRect {
            try ShellLayerScene.engineQueue.sync {
                try Self.silhouette(body, hiding: scene.layers[clip], host: host, crop: crop, at: time)
            }
        }
        let settled = try silhouette(at: plan.end + 0.1)
        let rim = (minX: settled.minX - rect.minX, minY: settled.minY - rect.minY, maxY: settled.maxY - rect.maxY)
        XCTAssertTrue([rim.minX, rim.minY, rim.maxY].allSatisfy { abs($0) <= 2 }, "\(rim)")
        XCTAssertGreaterThanOrEqual(settled.maxX, 1920 - 1, "\(settled)")
        let time = plan.begin + 0.084
        let state = plan.state(at: time)
        let expected = morph.shape(
            CGRect(origin: .zero, size: rect.size), radius: 35.1, progress: state.progress, velocity: state.velocity
        ).rect.offsetBy(dx: rect.minX, dy: rect.minY)
        let drawn = try silhouette(at: time)
        let right = scene.container.masksToBounds ? min(expected.maxX - rim.minX, 1920) : expected.maxX - rim.minX
        XCTAssertEqual(drawn.minX, expected.minX + rim.minX, accuracy: 1)
        XCTAssertEqual(drawn.maxX, right, accuracy: 1)
        XCTAssertEqual(drawn.minY, expected.minY + rim.minY, accuracy: 1)
        XCTAssertEqual(drawn.maxY, expected.maxY + rim.maxY, accuracy: 1)
        XCTAssertGreaterThan(expected.maxX, rect.maxX + 4)
        print("Vitreus reveal probe at 84 ms: p \(state.progress) drawn \(drawn) sampler \(expected)")
        withExtendedLifetime(host.renderer) {}
    }
}
