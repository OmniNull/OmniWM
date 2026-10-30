// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

struct GlassProbePixels {
    let bytes: [UInt8]
    let width: Int
    let height: Int

    func alpha(_ x: Int, _ y: Int) -> Double {
        Double(bytes[(y * width + x) * 4 + 3]) / 255
    }

    func rgb(_ x: Int, _ y: Int) -> [Int] {
        let index = (y * width + x) * 4
        return [Int(bytes[index + 2]), Int(bytes[index + 1]), Int(bytes[index])]
    }

    func luminance(_ x: Int, _ y: Int) -> Double {
        let value = rgb(x, y)
        return 0.2126 * Double(value[0]) + 0.7152 * Double(value[1]) + 0.0722 * Double(value[2])
    }

    func coverage(_ rect: CGRect) -> Double {
        var total = 0.0
        for y in Int(rect.minY) ..< Int(rect.maxY) {
            for x in Int(rect.minX) ..< Int(rect.maxX) {
                total += alpha(x, y)
            }
        }
        return total
    }

    func span(row y: Int) -> (min: Double, max: Double)? {
        Self.span((0 ..< width).map { alpha($0, y) })
    }

    func span(column x: Int) -> (min: Double, max: Double)? {
        Self.span((0 ..< height).map { alpha(x, $0) })
    }

    func box() -> CGRect? {
        let rows = (0 ..< height).filter { y in (0 ..< width).contains { alpha($0, y) >= 0.5 } }
        let columns = (0 ..< width).filter { x in (0 ..< height).contains { alpha(x, $0) >= 0.5 } }
        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last
        else { return nil }
        return CGRect(x: left, y: top, width: right + 1 - left, height: bottom + 1 - top)
    }

    func difference(_ other: GlassProbePixels) -> (changed: Int, max: Int) {
        var changed = 0
        var largest = 0
        for index in bytes.indices {
            let delta = abs(Int(bytes[index]) - Int(other.bytes[index]))
            if delta > 0 { changed += 1 }
            largest = max(largest, delta)
        }
        return (changed, largest)
    }

    private static func span(_ alphas: [Double]) -> (min: Double, max: Double)? {
        guard let first = alphas.firstIndex(where: { $0 > 0 }), let last = alphas.lastIndex(where: { $0 > 0 })
        else { return nil }
        let center = (first + last + 1) / 2
        return (
            Double(center) - alphas[first ..< center].reduce(0, +),
            Double(center) + alphas[center ... last].reduce(0, +)
        )
    }
}

@MainActor
final class GlassProbeCanvas {
    let root = CALayer()
    let renderer: ShellOffscreenRenderer
    let base = CACurrentMediaTime()
    let width: Int
    let height: Int

    init(width: Int, height: Int, background: CGColor? = nil, contents: CGImage? = nil) throws {
        self.width = width
        self.height = height
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        root.isGeometryFlipped = true
        renderer = try ShellOffscreenRenderer(root: root, width: width, height: height)
        ShellGlassProbeTests.still {
            root.speed = 0
            root.timeOffset = base
            guard background != nil || contents != nil else { return }
            let layer = CALayer()
            layer.frame = root.bounds
            layer.backgroundColor = background
            layer.contents = contents
            layer.magnificationFilter = .nearest
            root.addSublayer(layer)
        }
    }

    func add(_ layer: CALayer) {
        ShellGlassProbeTests.still { root.addSublayer(layer) }
    }

    func animate(_ layer: CALayer, _ animation: CAAnimation, key: String? = nil) {
        animation.beginTime = base
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key ?? (animation as? CAPropertyAnimation)?.keyPath)
    }

    func render(_ elapsed: CFTimeInterval = 0) throws -> GlassProbePixels {
        try render(at: base + elapsed)
    }

    func render(at time: CFTimeInterval) throws -> GlassProbePixels {
        GlassProbePixels(bytes: try renderer.render(paused: time), width: width, height: height)
    }
}

@MainActor
final class ShellGlassProbeTests: XCTestCase {
    let capability = ShellGlassCapability.shared
    let recipe = ShellGlassRecipe("glass:26:-1:0:0:1")
    let paint = ShellLayerPaint(
        fill: nil, border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1, shadow: nil, shadowRadius: 6,
        blurRadius: 6, saturation: 1
    )

    nonisolated static func still<T>(_ body: () throws -> T) rethrows -> T {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        return try body()
    }

    static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    static func box(_ rect: CGRect?) -> [Double] {
        guard let rect else { return [] }
        return [rect.minX, rect.minY, rect.maxX, rect.maxY].map { rounded(Double($0)) }
    }

    static func boxesMatch(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }
        return [lhs.minX - rhs.minX, lhs.minY - rhs.minY, lhs.maxX - rhs.maxX, lhs.maxY - rhs.maxY]
            .allSatisfy { abs($0) <= 1 }
    }

    func record(_ probe: String, _ result: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["OMNI_PROBE_OUT"] else { return }
        let url = URL(fileURLWithPath: path)
        var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var probes = document["probes"] as? [String: Any] ?? [:]
        var entry = result
        let nested = result.compactMapValues { ($0 as? [String: Any])?["outcome"] }
        if entry["outcome"] == nil, !nested.isEmpty { entry["outcome"] = nested }
        probes[probe] = entry
        document["probes"] = probes
        document["renderer"] = "CARenderer into a Metal texture with paused media time; not WindowServer"
        document["system"] = ProcessInfo.processInfo.operatingSystemVersionString
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    func requireNative(_ probe: String, classes: [String] = []) throws {
        let missing = (capability.missing.map { [$0] } ?? [])
            + classes.filter { NSClassFromString($0) == nil }.map { "\($0).class" }
        guard !missing.isEmpty else { return }
        try record(probe, ["outcome": "skipped", "missing": missing])
        throw XCTSkip("Missing private glass API: \(missing.joined(separator: ", "))")
    }

    func fill() throws -> NSObject {
        try XCTUnwrap(capability.effect(.fill, values: [.color: CGColor(gray: 1, alpha: 1)]))
    }

    func shadow(radius: CGFloat, offset: CGSize = .zero) throws -> NSObject {
        try XCTUnwrap(capability.effect(.shadow, values: [
            .color: CGColor(gray: 0, alpha: 1), .offset: offset, .radius: radius, .punchout: false
        ]))
    }

    func element(_ rect: CGRect, radius: CGFloat = 0, transform: CATransform3D = CATransform3DIdentity) throws
        -> CALayer
    {
        let element = try XCTUnwrap(capability.elementClass).init()
        Self.still {
            element.setValue("bounds", forKey: ShellGlassCapability.ElementProperty.mode.rawValue)
            element.setValue("union", forKey: ShellGlassCapability.ElementProperty.operation.rawValue)
            element.anchorPoint = .zero
            element.cornerCurve = .circular
            element.position = rect.origin
            element.bounds = CGRect(origin: .zero, size: rect.size)
            element.cornerRadius = radius
            element.transform = transform
        }
        return element
    }

    func sdfCanvas(_ effect: NSObject, size: CGSize, smoothness: CGFloat = 0, elements: [CALayer]) throws
        -> (canvas: GlassProbeCanvas, layer: CALayer)
    {
        let canvas = try GlassProbeCanvas(width: Int(size.width), height: Int(size.height))
        let layer = try XCTUnwrap(capability.bodyClass).init()
        Self.still {
            layer.anchorPoint = .zero
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.setValue(smoothness, forKey: ShellGlassCapability.BodyProperty.smoothness.rawValue)
            layer.setValue(effect, forKey: ShellGlassCapability.BodyProperty.effect.rawValue)
            elements.forEach(layer.addSublayer)
        }
        canvas.add(layer)
        return (canvas, layer)
    }

    func body(_ shapes: [ShellGlassShape], size: CGSize) throws -> ShellGlassBody {
        let body = ShellGlassBody()
        body.apply(size: size, shapes: shapes, recipe: try XCTUnwrap(recipe), paint: paint, animation: nil)
        return body
    }

    func linear(_ key: String, from: Any, to: Any, additive: Bool = false) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.isAdditive = additive
        animation.duration = 1
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        return animation
    }
}

extension ShellGlassProbeTests {
    func testSmoothnessAnimationProbe() throws {
        let probe = "a.smoothnessAnimation"
        try requireNative(probe)
        let circles = try [30, 110].map { try element(CGRect(x: $0, y: 20, width: 60, height: 60), radius: 30) }
        let (canvas, layer) = try sdfCanvas(fill(), size: CGSize(width: 200, height: 100), elements: circles)
        let key = ShellGlassCapability.BodyProperty.smoothness.rawValue
        let bridge = CGRect(x: 90, y: 0, width: 20, height: 100)
        var statics: [String: Double] = [:]
        for value in [0.0, 40, 80] {
            Self.still { layer.setValue(value, forKey: key) }
            statics["\(Int(value))"] = Self.rounded(try canvas.render().coverage(bridge))
        }
        canvas.animate(layer, linear(key, from: 0, to: 80))
        let times = [0, 0.25, 0.5, 0.75, 1]
        let sampled = try times.map { Self.rounded(try canvas.render($0).coverage(bridge)) }
        let interpolates = abs(sampled[2] - sampled[0]) > 1 && abs(sampled[2] - sampled[4]) > 1
        let monotonic = zip(sampled, sampled.dropFirst()).allSatisfy { $1 >= $0 - 0.5 }
        try record(probe, [
            "outcome": interpolates && monotonic ? "animates" : "steps",
            "setup": "two r=30 circles 20 pt apart in a 200x100 CASDFLayer, smoothness 0 -> 80 over 1 s",
            "bridgeCoverageStatic": statics,
            "bridgeCoverageAnimated": Dictionary(uniqueKeysWithValues: zip(times.map { "\($0)" }, sampled)),
            "midMinusStatic40": Self.rounded(sampled[2] - (statics["40"] ?? 0)),
            "monotonic": monotonic
        ])
        XCTAssertTrue(sampled.allSatisfy(\.isFinite))
    }

    private static func costShapes(_ count: Int, shift: CGFloat, widen: CGFloat) -> [ShellGlassShape] {
        let spacing = 1728 / CGFloat(count)
        return (0 ..< count).map { index in
            ShellGlassShape(
                slot: Int32(index + 1),
                kind: index % 5 == 4 ? 1 : 0,
                rect: CGRect(
                    x: CGFloat(index) * spacing + 2 + shift, y: 14,
                    width: spacing - 4 + (index == 0 ? widen : 0), height: 48
                ),
                radius: 12,
                thickness: 0
            )
        }
    }

    private static func time(_ work: () -> Void) -> (cpu: Double, wall: Double) {
        CATransaction.flush()
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        work()
        return (
            Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1000,
            Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wall) / 1000
        )
    }

    private static func stats(_ samples: [(cpu: Double, wall: Double)]) -> [String: Double] {
        let cpu = samples.map(\.cpu).sorted()
        let wall = samples.map(\.wall).sorted()
        return [
            "cpuMedianUs": rounded(cpu[cpu.count / 2]),
            "cpuP90Us": rounded(cpu[cpu.count * 9 / 10]),
            "wallMedianUs": rounded(wall[wall.count / 2]),
            "wallP90Us": rounded(wall[wall.count * 9 / 10])
        ]
    }

    private func applyCost(count: Int, canvas: GlassProbeCanvas) throws -> [String: Any] {
        let recipe = try XCTUnwrap(recipe)
        let modes: [(String, ShellAnimation?)] = [
            ("stepped", nil),
            ("spring", ShellAnimation(motion: .spring, speed: 1))
        ]
        var measured: [String: Any] = [:]
        for (mode, animation) in modes {
            let glass = ShellGlassBody()
            canvas.add(glass.layer)
            let apply = { (shapes: [ShellGlassShape]) in
                glass.apply(
                    size: CGSize(width: 1728, height: 76), shapes: shapes, recipe: recipe, paint: self.paint,
                    animation: animation
                )
            }
            let cold = Self.time { apply(Self.costShapes(count, shift: 0, widen: 0)) }
            let one = (0 ..< 80).map { index in
                let shapes = Self.costShapes(count, shift: 0, widen: index.isMultiple(of: 2) ? 2 : 0)
                return Self.time { apply(shapes) }
            }
            let all = (0 ..< 80).map { index in
                let shapes = Self.costShapes(count, shift: index.isMultiple(of: 2) ? 1 : 0, widen: 0)
                return Self.time { apply(shapes) }
            }
            if animation == nil {
                let element = try XCTUnwrap(glass.lockstepLayers(1).first)
                XCTAssertEqual(element.presentation()?.position, element.position, "timed apply left its commit open")
            }
            measured[mode] = [
                "coldCpuUs": Self.rounded(cold.cpu), "oneShapeChanged": Self.stats(one),
                "allShapesChanged": Self.stats(all)
            ]
            Self.still { glass.layer.removeFromSuperlayer() }
        }
        return measured
    }

    func testApplyCostPerShapeCountProbe() throws {
        let probe = "h.applyCost"
        try requireNative(probe)
        let canvas = try GlassProbeCanvas(width: 1728, height: 76)
        var counts: [String: Any] = [:]
        for count in [12, 24, 47, 64] {
            counts["\(count)"] = try applyCost(count: count, canvas: canvas)
        }
        try record(probe, [
            "outcome": "measured app-side apply cost only; WindowServer cost is not established",
            "scope": "App-side ShellGlassBody.apply on the test thread, including its CATransaction commit into a "
                + "CARenderer-attached tree and excluding rendering. This does not establish WindowServer cost.",
            "setup": "1728x76 body, every fifth shape an ellipse, 80 applies per variant",
            "shapes": counts
        ])
    }

    func testComponentShapeInsideGlassProbe() throws {
        let probe = "j.componentShapeInGlass"
        let widget = try ShellRenderedWidget(
            name: "root",
            source: """
            function render(ctx)
                return ui.glass{w=160,h=100,ui.shape{key='own',w=60,h=40},ui.component{id='probe'}}
            end
            """,
            modules: [.init(
                path: "profile/widgets/probe/component.luau",
                source: "return { views = { compact = function(ctx) return ui.shape{w=40,h=30,dx=80,dy=20} end } }"
            )],
            chunk: "@profile/widgets/root/init.luau"
        )
        widget.configure(ShellComponentCatalog.configurationBytes(
            instances: [ShellComponentInstance(id: "probe", widget: "probe")], descriptors: []
        ))
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 512)
        let status = omni_instance_render(widget.instance, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count)
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var result: [String: Any] = ["status": Int(status.rawValue), "message": message]
        if status == OMNI_OK {
            let output = widget.output()
            widget.text.ingest(wire: output)
            result["applied"] = widget.surface.apply(output, text: widget.text)
            let scene = widget.surface.scene
            let shapes = ShellLayerScene.engineQueue.sync { scene.glassBodies.values.map(\.maskElements.count) }
            result["shapesInBody"] = shapes.first ?? 0
            result["outcome"] = shapes.first == 2 ? "component shape melts into the body" : "not in the body"
        } else {
            result["outcome"] = "rejected by validation"
        }
        try record(probe, result)
    }
}
