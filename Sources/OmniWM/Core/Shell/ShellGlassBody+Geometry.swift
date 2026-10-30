// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

private struct ShellGlassMotionTrack: Hashable {
    let track: ShellGlassBody.Track
    let channel: ShellGlassBody.Channel
}

extension ShellGlassBody {
    struct Geometry {
        var position: CGPoint
        var bounds: CGRect
        var radius: CGFloat
        var transform = CATransform3DIdentity

        init(_ layer: CALayer) {
            position = layer.position
            bounds = layer.bounds
            radius = layer.cornerRadius
            transform = layer.transform
        }

        init(rect: CGRect, radius: CGFloat = 0, transform: CATransform3D = CATransform3DIdentity) {
            position = rect.origin
            bounds = CGRect(origin: .zero, size: rect.size)
            self.radius = radius
            self.transform = transform
        }

        func matches(_ other: Geometry) -> Bool {
            position == other.position && bounds == other.bounds && radius == other.radius
                && CATransform3DEqualToTransform(transform, other.transform)
        }

        func apply(to layer: CALayer, motion: Motion?, track: Track) {
            let model = Geometry(layer)
            guard !model.matches(self) else { return }
            assign(to: layer, replacing: model)
            guard let motion, motion.animates(track) else {
                for channel in Channel.geometry { layer.removeAnimation(forKey: channel.key) }
                return
            }
            func spring(_ channel: Channel, _ from: CGFloat, _ to: CGFloat) {
                guard from != to else { return }
                motion.add(
                    channel,
                    to: layer,
                    on: track,
                    from: NSNumber(value: Double(from)),
                    to: NSNumber(value: Double(to))
                )
            }
            spring(.x, model.position.x, position.x)
            spring(.y, model.position.y, position.y)
            spring(.width, model.bounds.width, bounds.width)
            spring(.height, model.bounds.height, bounds.height)
            spring(.radius, model.radius, radius)
            if !CATransform3DEqualToTransform(model.transform, transform) {
                motion.add(
                    .transform,
                    to: layer,
                    on: track,
                    from: NSValue(caTransform3D: model.transform),
                    to: NSValue(caTransform3D: transform)
                )
            }
        }

        func assign(to layer: CALayer, replacing model: Geometry) {
            if model.position != position { layer.position = position }
            if model.bounds != bounds { layer.bounds = bounds }
            if model.radius != radius { layer.cornerRadius = radius }
            if !CATransform3DEqualToTransform(model.transform, transform) { layer.transform = transform }
        }
    }

    struct Track: Hashable {
        static let canvas = Track(key: ElementKey(slot: -1, part: 0), mask: false)

        let key: ElementKey
        let mask: Bool

        static func container(_ slot: Int32) -> Track {
            Track(key: ElementKey(slot: slot, part: .max), mask: true)
        }
    }

    enum Channel: Int {
        case x
        case y
        case width
        case height
        case radius
        case transform
        case smoothness
        case shadowRadius
        case shadowOffset

        static let geometry: [Channel] = [.x, .y, .width, .height, .radius, .transform]
        private static let keyPaths = [
            "position.x", "position.y", "bounds.size.width", "bounds.size.height", "cornerRadius", "transform",
            ShellGlassCapability.BodyProperty.smoothness.rawValue,
            effectPath(.radius),
            effectPath(.offset)
        ]
        private static let keys = keyPaths.map { "omni.glass.motion.\($0)" }
        private static let owners = keyPaths.map { "omni.glass.\($0.prefix { $0 != "." })" }

        var keyPath: String {
            Self.keyPaths[rawValue]
        }

        var key: String {
            Self.keys[rawValue]
        }

        var owner: String {
            Self.owners[rawValue]
        }

        private static func effectPath(_ key: ShellGlassCapability.EffectKey) -> String {
            ShellGlassCapability.BodyProperty.effect.rawValue + "." + key.rawValue
        }
    }

    final class Motion {
        private let canvas: ShellAnimation?
        private let shapes: [Int32: ShellAnimation]?
        private let begin: CFTimeInterval
        private var built: [ShellGlassMotionTrack: CAAnimation] = [:]

        init(canvas: ShellAnimation?, shapes: [Int32: ShellAnimation]?, begin: CFTimeInterval) {
            self.canvas = canvas
            self.shapes = shapes
            self.begin = begin
        }

        func animates(_ track: Track) -> Bool {
            animation(for: track) != nil
        }

        func add(_ channel: Channel, to layer: CALayer, on track: Track, from model: Any, to target: Any) {
            guard layer.animation(forKey: channel.owner) == nil, let animation = animation(for: track) else {
                layer.removeAnimation(forKey: channel.key)
                return
            }
            let id = ShellGlassMotionTrack(track: track, channel: channel)
            let value = built[id] ?? make(channel, animation, on: layer, from: model, to: target)
            built[id] = value
            layer.add(value, forKey: channel.key)
        }

        private func animation(for track: Track) -> ShellAnimation? {
            guard track.key.slot >= 0, let shapes else { return canvas }
            return shapes[track.key.slot]
        }

        private func make(
            _ channel: Channel,
            _ animation: ShellAnimation,
            on layer: CALayer,
            from model: Any,
            to target: Any
        ) -> CAAnimation {
            let running = layer.animation(forKey: channel.key)
            let state = Self.state(of: running, channel, at: begin)
            let from: Any = if let state {
                Self.object(state.value, channel)
            } else if running != nil {
                (layer.presentation() ?? layer).value(forKeyPath: channel.keyPath) ?? model
            } else {
                model
            }
            let value: CAAnimation
            if let keyframes = animation.keyframes(channel.keyPath, from: from, to: target) {
                value = keyframes
            } else {
                let basic = animation.make(channel.keyPath)
                basic.fromValue = from
                basic.toValue = target
                if let spring = basic as? CASpringAnimation, let state, let end = Self.vector(target, channel) {
                    let remaining = end - state.value
                    let length = (remaining * remaining).sum()
                    let normalized = length > 0 ? (state.velocity * remaining).sum() / length : 0
                    if normalized.isFinite, normalized != 0 {
                        spring.initialVelocity = normalized
                        spring.duration = spring.settlingDuration
                    }
                }
                value = basic
            }
            value.beginTime = begin
            return value
        }

        private static func state(
            of animation: CAAnimation?,
            _ channel: Channel,
            at time: CFTimeInterval
        ) -> (value: SIMD2<Double>, velocity: SIMD2<Double>)? {
            guard let spring = animation as? CASpringAnimation,
                  let from = vector(spring.fromValue, channel), let to = vector(spring.toValue, channel)
            else { return nil }
            let elapsed = max(0, (time - spring.beginTime) * Double(spring.speed) + spring.timeOffset)
            guard elapsed < spring.duration else { return (to, .zero) }
            let parameters = ShellSpringDynamics.Parameters(
                mass: spring.mass, stiffness: spring.stiffness, damping: spring.damping
            )
            let progress = 1 + ShellSpringDynamics.position(
                at: elapsed, displacement: -1, initialVelocity: spring.initialVelocity, spring: parameters
            )
            let rate = ShellSpringDynamics.velocity(
                at: elapsed, displacement: -1, initialVelocity: spring.initialVelocity, spring: parameters
            ) * Double(spring.speed)
            return (from + (to - from) * progress, (to - from) * rate)
        }

        private static func vector(_ value: Any?, _ channel: Channel) -> SIMD2<Double>? {
            switch channel {
            case .transform: nil
            case .shadowOffset: (value as? NSValue)
                .map { SIMD2(Double($0.sizeValue.width), Double($0.sizeValue.height)) }
            default: (value as? NSNumber).map { SIMD2($0.doubleValue, 0) }
            }
        }

        private static func object(_ vector: SIMD2<Double>, _ channel: Channel) -> Any {
            channel == .shadowOffset ? NSValue(size: CGSize(width: vector.x, height: vector.y)) :
                NSNumber(value: vector.x)
        }
    }

    struct Part {
        let key: ElementKey
        let geometry: Geometry
        var subtract = false
        var corner = false
        var container: Int32?

        var track: Track {
            Track(key: key, mask: container != nil)
        }
    }

    static func validShapes(_ shapes: [ShellGlassShape]) -> Bool {
        var slots = Set<Int32>()
        var frame = false
        for (index, shape) in shapes.enumerated() {
            let rect = shape.rect
            guard slots.insert(shape.slot).inserted, shape.slot >= 0, shape.kind <= 2,
                  [rect.minX, rect.minY, rect.width, rect.height, shape.radius, shape.thickness, shape.rotation]
                      .allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                  rect.width > 0, rect.height > 0, shape.radius >= 0, shape.thickness >= 0 else { return false }
            if shape.kind == 2 {
                guard !frame, index == 0, shape.thickness > 0,
                      shape.thickness * 2 < min(rect.width, rect.height)
                else { return false }
                frame = true
            }
        }
        return true
    }

    static func nativeFrameCoversCanvas(_ shape: ShellGlassShape, canvas: CGSize, blend: CGFloat) -> Bool {
        guard blend >= 8 else { return false }
        let padding = 2 * blend
        let rect = shape.rect.insetBy(dx: padding, dy: padding)
        guard !rect.isNull, !rect.isEmpty else { return false }
        let radius = max(0, min(shape.radius, min(shape.rect.width, shape.rect.height) / 2) - padding)
        return [
            CGPoint.zero,
            CGPoint(x: canvas.width, y: 0),
            CGPoint(x: 0, y: canvas.height),
            CGPoint(x: canvas.width, y: canvas.height)
        ].allSatisfy { point in
            let x = abs(point.x - rect.midX) - rect.width / 2 + radius
            let y = abs(point.y - rect.midY) - rect.height / 2 + radius
            return hypot(max(x, 0), max(y, 0)) + min(max(x, y), 0) - radius <= 0
        }
    }

    static func parts(for shapes: [ShellGlassShape]) -> (sdf: [Part], mask: [Part]) {
        var sdf: [Part] = []
        var mask: [Part] = []
        for shape in shapes { append(shape, sdf: &sdf, mask: &mask) }
        return (sdf, mask)
    }

    static func orient(_ gradient: CAGradientLayer, angle: CGFloat, size: CGSize) {
        let direction = CGPoint(x: cos(angle * .pi / 180), y: sin(angle * .pi / 180))
        let reach = abs(size.width * direction.x) + abs(size.height * direction.y)
        guard size.width > 0, size.height > 0, reach > 0 else { return }
        let half = CGPoint(x: direction.x * reach / (2 * size.width), y: direction.y * reach / (2 * size.height))
        let start = CGPoint(x: 0.5 - half.x, y: 0.5 - half.y)
        let end = CGPoint(x: 0.5 + half.x, y: 0.5 + half.y)
        if gradient.startPoint != start { gradient.startPoint = start }
        if gradient.endPoint != end { gradient.endPoint = end }
    }

    static let bandDistances: [CGFloat] = (0 ... 12).map { -2.2 + 0.15 * CGFloat($0) } + [2]
    static let bandWeights: [CGFloat] = bandDistances.map { distance in
        let progress = min(max((distance + 2.2) / 1.8, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    private static let geometryKeyPaths = Set(Channel.geometry.map(\.keyPath)).union(["position", "bounds"])

    static func followGeometry(_ layer: CALayer, _ leader: CALayer) {
        Geometry(leader).assign(to: layer, replacing: Geometry(layer))
        for key in leader.animationKeys() ?? [] {
            guard let animation = leader.animation(forKey: key) as? CAPropertyAnimation,
                  geometryKeyPaths.contains(animation.keyPath ?? "") else { continue }
            layer.add(animation, forKey: key)
        }
    }

    static func follow(_ layer: CALayer, _ leader: CALayer) {
        Geometry(leader).assign(to: layer, replacing: Geometry(layer))
        for key in leader.animationKeys() ?? [] {
            if let animation = leader.animation(forKey: key) { layer.add(animation, forKey: key) }
        }
    }

    static func removeParts(_ slot: Int32, from tree: inout [ElementKey: CALayer]) {
        let keys = tree.keys.filter { $0.slot == slot }
        for key in keys { tree.removeValue(forKey: key)?.removeFromSuperlayer() }
    }

    static func rekey(_ source: Int32, to target: Int32, in tree: inout [ElementKey: CALayer]) {
        let moved = tree.filter { $0.key.slot == source }
        for (key, layer) in moved {
            tree.removeValue(forKey: key)
            tree[ElementKey(slot: target, part: key.part)] = layer
        }
    }

    static func reconcileContainers(_ frames: [ShellGlassShape], elements: inout [Int32: CALayer], motion: Motion?) {
        var kept: [Int32: CALayer] = [:]
        for frame in frames {
            let old = elements[frame.slot]
            let container = old ?? CALayer()
            if old == nil {
                container.anchorPoint = .zero
                container.cornerCurve = .circular
                container.masksToBounds = true
            }
            Geometry(rect: frame.rect, radius: min(frame.radius, min(frame.rect.width, frame.rect.height) / 2))
                .apply(to: container, motion: old == nil ? nil : motion, track: .container(frame.slot))
            kept[frame.slot] = container
        }
        for (slot, container) in elements where kept[slot] == nil { container.removeFromSuperlayer() }
        elements = kept
    }

    static func setOrder(_ order: [CALayer], in root: CALayer) {
        let current = root.sublayers ?? []
        if current.count != order.count || !zip(current, order).allSatisfy({ $0.0 === $0.1 }) { root.sublayers = order }
    }

    static func cornerPath() -> CGPath {
        let path = CGMutablePath()
        let control = 4 * (sqrt(CGFloat(2)) - 1) / 3
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 1, y: 0))
        path.addCurve(
            to: CGPoint(x: 0, y: 1),
            control1: CGPoint(x: 1 - control, y: 0),
            control2: CGPoint(x: 0, y: 1 - control)
        )
        path.closeSubpath()
        return path
    }

    private static func append(_ shape: ShellGlassShape, sdf: inout [Part], mask: inout [Part]) {
        let key = ElementKey(slot: shape.slot, part: 0)
        if shape.kind == 2 {
            let radius = min(shape.radius, min(shape.rect.width, shape.rect.height) / 2)
            sdf.append(Part(key: key, geometry: Geometry(rect: shape.rect, radius: radius)))
            let thickness = max(0, min(shape.thickness, min(shape.rect.width, shape.rect.height) / 2))
            let hole = shape.rect.insetBy(dx: thickness, dy: thickness)
            let holeRadius = max(0, radius - thickness)
            sdf.append(Part(
                key: ElementKey(slot: shape.slot, part: 1),
                geometry: Geometry(rect: hole, radius: holeRadius),
                subtract: true
            ))
            appendFrameMask(
                slot: shape.slot,
                hole: CGRect(origin: CGPoint(x: thickness, y: thickness), size: hole.size),
                radius: holeRadius,
                canvas: shape.rect.size,
                to: &mask
            )
        } else {
            let geometry: Geometry
            if shape.kind == 1 {
                let radius = min(shape.rect.width, shape.rect.height) / 2
                let scale = radius > 0
                    ? CATransform3DMakeScale(shape.rect.width / (2 * radius), shape.rect.height / (2 * radius), 1)
                    : CATransform3DIdentity
                geometry = Geometry(
                    rect: CGRect(origin: shape.rect.origin, size: CGSize(width: radius * 2, height: radius * 2)),
                    radius: radius,
                    transform: turned(scale, by: shape.rotation, size: shape.rect.size)
                )
            } else {
                geometry = Geometry(
                    rect: shape.rect,
                    radius: min(shape.radius, min(shape.rect.width, shape.rect.height) / 2),
                    transform: turned(CATransform3DIdentity, by: shape.rotation, size: shape.rect.size)
                )
            }
            let part = Part(key: key, geometry: geometry)
            sdf.append(part)
            mask.append(part)
        }
    }

    private static func turned(_ transform: CATransform3D, by angle: CGFloat, size: CGSize) -> CATransform3D {
        guard angle != 0 else { return transform }
        var turned = CATransform3DConcat(transform, CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0))
        turned = CATransform3DConcat(turned, CATransform3DMakeRotation(angle, 0, 0, 1))
        return CATransform3DConcat(turned, CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
    }

    private static func appendFrameMask(
        slot: Int32,
        hole: CGRect,
        radius: CGFloat,
        canvas: CGSize,
        to parts: inout [Part]
    ) {
        let top = min(max(hole.minY, 0), canvas.height)
        let bottom = min(max(hole.maxY, 0), canvas.height)
        let left = min(max(hole.minX, 0), canvas.width)
        let right = min(max(hole.maxX, 0), canvas.width)
        let strips = [
            CGRect(x: 0, y: 0, width: canvas.width, height: top),
            CGRect(x: 0, y: bottom, width: canvas.width, height: canvas.height - bottom),
            CGRect(x: 0, y: top, width: left, height: max(0, bottom - top)),
            CGRect(x: right, y: top, width: canvas.width - right, height: max(0, bottom - top))
        ]
        for (index, rect) in strips.enumerated() {
            parts.append(Part(
                key: ElementKey(slot: slot, part: UInt8(index)),
                geometry: Geometry(rect: rect),
                container: slot
            ))
        }
        let signs = [CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1), CGPoint(x: 1, y: -1), CGPoint(x: -1, y: -1)]
        for (index, sign) in signs.enumerated() {
            let origin = CGPoint(x: sign.x > 0 ? hole.minX : hole.maxX, y: sign.y > 0 ? hole.minY : hole.maxY)
            parts.append(Part(
                key: ElementKey(slot: slot, part: UInt8(index + 4)),
                geometry: Geometry(
                    rect: CGRect(origin: origin, size: CGSize(width: 1, height: 1)),
                    transform: CATransform3DMakeScale(sign.x * radius, sign.y * radius, 1)
                ),
                corner: true,
                container: slot
            ))
        }
    }
}
