// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import QuartzCore
import XCTest

private struct TransformShape {
    let name: String
    let rect: CGRect
    let radius: CGFloat
    let model: CATransform3D
}

extension ShellGlassProbeTests {
    private static func reach(_ pixels: GlassProbePixels) -> Int {
        (130 ..< 200).count(where: { pixels.alpha($0, 70) > 8.0 / 255 })
    }

    private static func skew(_ pixels: GlassProbePixels) -> Int {
        (90 ..< 140).count(where: { pixels.alpha(100, $0) > 8.0 / 255 })
            - (0 ..< 50).count(where: { pixels.alpha(100, $0) > 8.0 / 255 })
    }

    private static func summary(_ ends: [Int], _ samples: [Int]) -> [String: Any] {
        let between = samples[1] > min(ends[0], ends[1]) && samples[1] < max(ends[0], ends[1])
        return ["endpoints": ends, "samples": samples, "outcome": between ? "interpolates" : "steps"]
    }

    private func shadowCanvas(_ effect: NSObject) throws -> (canvas: GlassProbeCanvas, layer: CALayer) {
        try sdfCanvas(
            effect,
            size: CGSize(width: 200, height: 140),
            elements: [element(CGRect(x: 70, y: 50, width: 60, height: 40))]
        )
    }

    private func effectProbe(
        _ start: NSObject,
        _ end: NSObject,
        _ animation: CABasicAnimation,
        measure: (GlassProbePixels) -> Int
    ) throws -> [String: Any] {
        let (canvas, layer) = try shadowCanvas(start)
        let first = measure(try canvas.render())
        Self.still { layer.setValue(end, forKey: ShellGlassCapability.BodyProperty.effect.rawValue) }
        let ends = [first, measure(try canvas.render())]
        canvas.animate(layer, animation)
        return Self.summary(ends, try [0, 0.5, 1].map { measure(try canvas.render($0)) })
    }

    private func replacementProbe() throws -> [String: Any] {
        let (canvas, layer) = try shadowCanvas(shadow(radius: 4))
        let first = Self.reach(try canvas.render())
        let key = ShellGlassCapability.BodyProperty.effect.rawValue
        let action = layer.action(forKey: key)
        let replacement = try shadow(radius: 24)
        CATransaction.begin()
        layer.setValue(replacement, forKey: key)
        CATransaction.commit()
        let keys = layer.animationKeys() ?? []
        let implicit = keys.first.flatMap(layer.animation(forKey:))
        let begin = implicit.map { $0.beginTime > 0 ? $0.beginTime : canvas.base } ?? canvas.base
        let duration = implicit?.duration ?? 1
        let samples = try [0, 0.5, 1].map { Self.reach(try canvas.render(at: begin + duration * $0)) }
        var result = Self.summary([first, samples[2]], samples)
        result["action"] = action.map { String(describing: type(of: $0)) } ?? "none"
        result["animationKeys"] = keys
        return result
    }

    func testEffectValueAnimationProbe() throws {
        let probe = "b.effectValues"
        try requireNative(probe)
        let offset = CGSize(width: 0, height: 16)
        try record(probe, [
            "setup": "black CASDFShadowEffect around a 60x40 rect; reach = shadow columns right of the rect, "
                + "skew = shadow rows below minus rows above",
            "effectRadiusKeyPath": effectProbe(
                shadow(radius: 4), shadow(radius: 24), linear("effect.radius", from: 4, to: 24), measure: Self.reach
            ),
            "effectOffsetKeyPath": effectProbe(
                shadow(radius: 6), shadow(radius: 6, offset: offset),
                linear("effect.offset", from: NSValue(size: .zero), to: NSValue(size: offset)), measure: Self.skew
            ),
            "effectObjectAnimation": effectProbe(
                shadow(radius: 4), shadow(radius: 24),
                linear(
                    ShellGlassCapability.BodyProperty.effect.rawValue,
                    from: shadow(radius: 4),
                    to: shadow(radius: 24)
                ),
                measure: Self.reach
            ),
            "replacementWithActionsEnabled": replacementProbe()
        ])
    }

    private static func keyframes(_ key: String, _ values: [NSValue]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = [0, 0.5, 1]
        animation.calculationMode = .linear
        animation.duration = 1
        return animation
    }

    private func geometryProbe(_ model: CGRect, _ animation: CAAnimation, _ expected: [[Double]]) throws
        -> [String: Any]
    {
        let shape = try element(model)
        let canvas = try sdfCanvas(fill(), size: CGSize(width: 240, height: 100), elements: [shape]).canvas
        canvas.animate(shape, animation)
        var samples: [[String: Any]] = []
        var matches = true
        for sample in expected {
            let span = try canvas.render(sample[0]).span(row: 50)
            let measured = [span?.min ?? -1, span?.max ?? -1].map(Self.rounded)
            matches = matches && abs(measured[0] - sample[1]) <= 1 && abs(measured[1] - sample[2]) <= 1
            samples.append(["t": sample[0], "expected": [sample[1], sample[2]], "measured": measured])
        }
        return ["outcome": matches ? "matches model plus offset within 1" : "deviates", "samples": samples]
    }

    func testElementKeyframeAndAdditiveGeometryProbe() throws {
        let probe = "c.elementKeyframeAndAdditive"
        try requireNative(probe)
        let square = CGRect(x: 80, y: 30, width: 40, height: 40)
        let wide = CGRect(x: 20, y: 30, width: 80, height: 40)
        let positions = [20.0, 140, 80].map { NSValue(point: CGPoint(x: $0, y: 30)) }
        let sizes = [40.0, 160, 80].map { NSValue(rect: CGRect(x: 0, y: 0, width: $0, height: 40)) }
        let shift = NSValue(point: CGPoint(x: 60, y: 0))
        let grow = NSValue(rect: CGRect(x: 0, y: 0, width: 60, height: 0))
        try record(probe, [
            "setup": "one 40 pt tall CASDFElementLayer (anchorPoint zero) in a filled CASDFLayer; edges on row 50",
            "positionKeyframes": geometryProbe(
                square, Self.keyframes("position", positions), [[0.25, 80, 120], [0.5, 140, 180], [0.75, 110, 150]]
            ),
            "positionAdditive": geometryProbe(
                square, linear("position", from: shift, to: NSValue(point: .zero), additive: true),
                [[0, 140, 180], [0.5, 110, 150], [1, 80, 120]]
            ),
            "boundsKeyframes": geometryProbe(
                wide, Self.keyframes("bounds", sizes), [[0.25, 20, 120], [0.5, 20, 180], [0.75, 20, 140]]
            ),
            "boundsAdditive": geometryProbe(
                wide, linear("bounds", from: grow, to: NSValue(rect: .zero), additive: true),
                [[0, 20, 160], [0.5, 20, 130], [1, 20, 100]]
            )
        ])
    }

    private func transformBox(
        _ shape: TransformShape,
        model: CATransform3D,
        animate: (GlassProbeCanvas, CALayer) -> Void = { _, _ in }
    ) throws -> CGRect? {
        let layer = try element(shape.rect, radius: shape.radius, transform: model)
        let canvas = try sdfCanvas(fill(), size: CGSize(width: 260, height: 160), elements: [layer]).canvas
        animate(canvas, layer)
        return try canvas.render(0.5).box()
    }

    private func subKeyMode(_ shape: TransformShape, additive: Bool, reference: CGRect?, still: CGRect?) throws
        -> [String: Any]
    {
        let animations = [
            linear("transform.translation.x", from: 0, to: 30, additive: additive),
            linear("transform.translation.y", from: 0, to: 10, additive: additive),
            linear("transform.scale", from: 1, to: 1.5, additive: additive)
        ]
        let model = NSValue(caTransform3D: shape.model)
        let hold = linear("transform", from: model, to: model)
        let animated = try transformBox(shape, model: shape.model) { canvas, layer in
            animations.forEach { canvas.animate(layer, $0) }
        }
        let overridden = try transformBox(shape, model: shape.model) { canvas, layer in
            animations.forEach { canvas.animate(layer, $0) }
            canvas.animate(layer, hold, key: "omni.glass.transform")
        }
        let matches = Self.boxesMatch(animated, reference)
        let overrides = Self.boxesMatch(overridden, still) && !Self.boxesMatch(animated, still)
        return [
            "box": Self.box(animated),
            "matchesCompositeWithin1": matches,
            "boxWithLaterWholeTransform": Self.box(overridden),
            "laterWholeTransformOverridesSubKeys": overrides,
            "outcome": (matches ? "matches" : "differs from") + " the composite; a later whole transform "
                + (overrides ? "overrides" : "does not override") + " the sub-keys"
        ]
    }

    func testTransformSubKeyAnimationProbe() throws {
        let probe = "i.transformSubKeys"
        try requireNative(probe)
        let shapes = [
            TransformShape(
                name: "ellipse", rect: CGRect(x: 30, y: 30, width: 40, height: 40), radius: 20,
                model: CATransform3DMakeScale(3, 1, 1)
            ),
            TransformShape(
                name: "rotated", rect: CGRect(x: 90, y: 24, width: 60, height: 30), radius: 0,
                model: CATransform3DMakeRotation(.pi / 6, 0, 0, 1)
            )
        ]
        var cases: [String: Any] = [:]
        var outcome: [String: Any] = [:]
        for shape in shapes {
            let scaled = CATransform3DConcat(shape.model, CATransform3DMakeScale(1.25, 1.25, 1))
            let reference = try transformBox(
                shape,
                model: CATransform3DConcat(scaled, CATransform3DMakeTranslation(15, 5, 0))
            )
            let still = try transformBox(shape, model: shape.model)
            let absolute = try subKeyMode(shape, additive: false, reference: reference, still: still)
            let additive = try subKeyMode(shape, additive: true, reference: reference, still: still)
            outcome["\(shape.name) absolute"] = absolute["outcome"]
            outcome["\(shape.name) additive"] = additive["outcome"]
            cases[shape.name] = [
                "compositeReferenceBox": Self.box(reference), "modelOnlyBox": Self.box(still),
                "absolute": absolute, "additive": additive
            ]
        }
        try record(probe, [
            "outcome": outcome,
            "setup": "translation.x 0->30, translation.y 0->10, scale 1->1.5 over 1 s sampled at 0.5; "
                + "composite reference = translate(15, 5) * scale(1.25) * model as a still model transform",
            "cases": cases
        ])
    }
}
