// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore
import QuartzCore

struct ShellEnter: Equatable, Sendable {
    let opacity: Float
    let scale: CGFloat
    let offset: CGPoint
    let from: Float
    let to: Float
    let curve: ShellCurve
    let stretch: CGFloat
    var path: ShellPathData?

    init?(_ enter: Enter, path: ShellPathData? = nil, curve custom: String? = nil) {
        guard let curve = ShellCurve(wire: enter.curve, custom: custom) else { return nil }
        opacity = enter.opacity
        scale = CGFloat(enter.scale)
        offset = CGPoint(x: CGFloat(enter.dx), y: CGFloat(enter.dy))
        from = enter.from
        to = enter.to
        self.curve = curve
        stretch = CGFloat(enter.stretch)
        self.path = path
    }

    func fraction(at progress: Float) -> Float {
        guard to > from else { return progress >= to ? 1 : 0 }
        return min(max((progress - from) / (to - from), 0), 1)
    }

    struct Plan {
        let begin: CFTimeInterval
        let duration: CFTimeInterval
        let opacity: (from: Float, to: Float)
        let transform: (from: CATransform3D, to: CATransform3D)
        let curve: ShellCurve
        let sample: @Sendable (CGFloat) -> (opacity: Float, transform: CATransform3D)
        let settles: Bool
        let opening: Bool
    }

    func plan(
        _ transition: ShellShaderTransition,
        at now: CFTimeInterval,
        opacity model: Float,
        transform base: CATransform3D,
        size: CGSize
    ) -> Plan? {
        let span = transition.to - transition.from
        guard transition.duration > 0, span != 0, now < transition.start + transition.duration else { return nil }
        let opening = span > 0
        let time = { (progress: Float) in
            transition.start + transition.duration
                * CFTimeInterval(min(max((progress - transition.from) / span, 0), 1))
        }
        let begin = max(now, time(opening ? from : to))
        let finish = max(time(opening ? to : from), begin)
        let start = fraction(at: transition.progress(at: begin))
        let target = fraction(at: transition.to)
        let sample = { @Sendable (progress: CGFloat) in
            let at = start + (target - start) * Float(progress)
            return (model * opacity(at: at), CATransform3DConcat(base, transform(at: at, size: size)))
        }
        return Plan(
            begin: begin,
            duration: max(finish - begin, 0.001),
            opacity: (model * opacity(at: start), model * opacity(at: target)),
            transform: (
                CATransform3DConcat(base, transform(at: start, size: size)),
                CATransform3DConcat(base, transform(at: target, size: size))
            ),
            curve: opening ? curve : curve.reversed,
            sample: sample,
            settles: target >= 1,
            opening: opening
        )
    }

    func stretched(_ plan: Plan, size: CGSize) -> CAKeyframeAnimation? {
        guard stretch > 0, offset != .zero else { return nil }
        let count = max(Int((plan.duration * ShellStretch.rate).rounded()), 2)
        let transforms = (0 ... count).map { index in
            plan.sample(plan.curve.value(at: CGFloat(index) / CGFloat(count))).transform
        }
        let deforms = ShellStretch.deforms(positions: transforms.map { CGPoint(x: $0.m41, y: $0.m42) }, amount: stretch)
        let center = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = zip(transforms, deforms).map { transform, deform in
            let centered = CATransform3DConcat(
                CATransform3DConcat(CATransform3DInvert(center), CATransform3DMakeAffineTransform(deform)),
                center
            )
            return NSValue(caTransform3D: CATransform3DConcat(centered, transform))
        }
        animation.keyTimes = (0 ... count).map { NSNumber(value: Double($0) / Double(count)) }
        animation.duration = plan.duration
        return animation
    }

    func opacity(at fraction: Float) -> Float {
        opacity + (1 - opacity) * fraction
    }

    func transform(at fraction: Float, size: CGSize) -> CATransform3D {
        let remaining = CGFloat(1 - fraction)
        let scale = 1 - (1 - self.scale) * remaining
        var transform = CATransform3DMakeTranslation(
            size.width / 2 + offset.x * remaining,
            size.height / 2 + offset.y * remaining,
            0
        )
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
    }
}

extension ShellLayerScene {
    func applyPath(_ slot: Int32, _ path: ShellLayerPath, animation: ShellAnimation?) {
        paths[slot] = path
        layoutPath(slot, animation: animation)
        if enters[slot]?.path != nil, let layer = layers[slot] {
            applyEnter(slot, to: layer)
        }
    }

    func applyTransition(_ next: ShellShaderTransition) {
        transition = next
        shaders?.setTransition(next)
        for slot in enters.keys {
            if let layer = layers[slot] {
                applyEnter(slot, to: layer)
            }
        }
    }

    func setMask(_ masks: Bool, slot: Int32, layer: CALayer) {
        if let mask = self.masks.removeValue(forKey: slot) {
            if mask.host.mask === mask.layer {
                mask.host.mask = nil
            }
            layer.isHidden = false
            shaders?.setMask(slot, nil)
        }
        guard masks, let host = parents[slot].flatMap({ layers[$0] }) ?? (parents[slot] == nil ? container : nil) else {
            return
        }
        let mask = layer is CAShapeLayer ? CAShapeLayer() : CALayer()
        mask.anchorPoint = .zero
        mask.contentsScale = scale
        mask.contentsGravity = layer.contentsGravity
        mask.contents = layer.contents
        Self.align(mask, with: layer)
        Self.mirror(layer, into: mask)
        host.mask = mask
        layer.isHidden = true
        let entry = ShellLayerMask(layer: mask, host: host)
        self.masks[slot] = entry
        shaders?.setMask(slot, entry)
        if enters[slot] != nil {
            applyEnter(slot, to: layer)
        }
    }

    private static func mirror(_ layer: CALayer, into mask: CALayer) {
        guard let shape = layer as? CAShapeLayer, let mask = mask as? CAShapeLayer else { return }
        mask.path = shape.path
        mask.fillRule = shape.fillRule
        mask.fillColor = CGColor(gray: 0, alpha: 1)
    }

    func layoutPath(_ slot: Int32, animation: ShellAnimation?) {
        guard let shape = layers[slot] as? CAShapeLayer, let spec = paths[slot] else { return }
        let path = spec.fitted(to: shape.bounds.size)
        if let animation, shape.path != nil, path != nil, shape.path != path {
            let from = (shape.presentation() ?? shape).path
            add(animation, to: shape, "path", from: from, to: path)
            if let mask = masks[slot]?.layer {
                add(animation, to: mask, "path", from: from, to: path)
            }
        }
        shape.path = path
        shape.fillRule = spec.evenOdd ? .evenOdd : .nonZero
        if let mask = masks[slot] {
            Self.mirror(shape, into: mask.layer)
        }
    }

    static func align(_ mask: CALayer, with layer: CALayer) {
        mask.position = layer.position
        mask.bounds = CGRect(origin: .zero, size: layer.bounds.size)
    }

    func applyEnter(_ slot: Int32, to layer: CALayer) {
        let mirror = masks[slot]?.layer
        let shown = { (target: CALayer?) -> CALayer? in
            target?.animation(forKey: Self.enterOpacityKey) == nil ? nil : target?.presentation()
        }
        let layerShown = shown(layer)
        let mirrorShown = shown(mirror)
        for target in [layer, mirror].compactMap(\.self) {
            target.removeAnimation(forKey: Self.enterOpacityKey)
            target.removeAnimation(forKey: Self.enterTransformKey)
            target.removeAnimation(forKey: Self.enterPathKey)
        }
        guard let enter = enters[slot] else { return }
        let now = CACurrentMediaTime()
        animateEnter(enter, slot: slot, on: layer, shown: layerShown, at: now)
        if let mirror {
            animateEnter(enter, slot: slot, on: mirror, shown: mirrorShown, at: now)
        }
    }

    private func animateEnter(
        _ enter: ShellEnter,
        slot: Int32,
        on layer: CALayer,
        shown: CALayer?,
        at now: CFTimeInterval
    ) {
        guard let plan = enter.plan(
            transition,
            at: now,
            opacity: layer.opacity,
            transform: layer.transform,
            size: layer.bounds.size
        )
        else {
            return
        }
        let resumed = plan.begin <= now ? shown : nil
        let frames = resumed == nil ? plan.curve.keyframes : nil
        let schedule = { (animation: CAPropertyAnimation, key: String) in
            animation.beginTime = layer.convertTime(plan.begin, from: nil)
            animation.duration = plan.duration
            animation.fillMode = .both
            animation.isRemovedOnCompletion = plan.settles
            layer.add(animation, forKey: key)
        }
        schedule(
            Self.enterAnimation(
                "opacity",
                plan,
                frames,
                values: (resumed?.opacity ?? plan.opacity.from, plan.opacity.to)
            ) {
                plan.sample($0).opacity
            },
            Self.enterOpacityKey
        )
        let stretched = resumed == nil ? enter.stretched(plan, size: layer.bounds.size) : nil
        schedule(
            stretched ?? Self.enterAnimation(
                "transform",
                plan,
                frames,
                values: (
                    NSValue(caTransform3D: resumed?.transform ?? plan.transform.from),
                    NSValue(caTransform3D: plan.transform.to)
                )
            ) { NSValue(caTransform3D: plan.sample($0).transform) },
            Self.enterTransformKey
        )
        if let path = enterPath(enter, slot: slot, on: layer, resumed: resumed, opening: plan.opening) {
            schedule(Self.enterAnimation("path", plan, nil, values: path, sample: nil), Self.enterPathKey)
        }
    }

    private func enterPath(
        _ enter: ShellEnter,
        slot: Int32,
        on layer: CALayer,
        resumed: CALayer?,
        opening: Bool
    ) -> (from: Any, to: Any)? {
        guard let shape = layer as? CAShapeLayer, let current = shape.path, let spec = paths[slot],
              let morph = enter.path,
              let start = ShellLayerPath(path: morph, viewBox: spec.viewBox, evenOdd: spec.evenOdd)
                  .fitted(to: shape.bounds.size)
        else {
            return nil
        }
        return ((resumed as? CAShapeLayer)?.path ?? (opening ? start : current), opening ? current : start)
    }

    private static func enterAnimation(
        _ keyPath: String,
        _ plan: ShellEnter.Plan,
        _ frames: ShellCurve.Keyframes?,
        values: (from: Any, to: Any),
        sample: ((CGFloat) -> Any)?
    ) -> CAPropertyAnimation {
        if let frames, let sample {
            let keyframes = CAKeyframeAnimation(keyPath: keyPath)
            keyframes.values = frames.progress.map(sample)
            keyframes.keyTimes = frames.times
            keyframes.timingFunctions = frames.timings
            return keyframes
        }
        let basic = CABasicAnimation(keyPath: keyPath)
        basic.fromValue = values.from
        basic.toValue = values.to
        basic.timingFunction = plan.curve.timing()
        return basic
    }
}
