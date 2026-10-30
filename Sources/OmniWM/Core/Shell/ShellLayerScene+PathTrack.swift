// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellShapeContour {
    private struct Axis {
        let origin: CGFloat
        let span: CGFloat
        let radius: CGFloat
    }

    let path: CGPath
    let base: ShellGlassShape
    let toBody: CGAffineTransform

    func path(at shape: ShellGlassShape) -> CGPath {
        if ShellShapeBaseMotion.vector(base) == ShellShapeBaseMotion.vector(shape) { return path }
        let result = CGMutablePath()
        let inverse = toBody.inverted()
        func map(_ point: CGPoint) -> CGPoint {
            let local = rotate(point.applying(toBody), around: base.rect, radians: -base.rotation)
            let radius = min(base.radius, min(base.rect.width, base.rect.height) / 2)
            let nextRadius = min(shape.radius, min(shape.rect.width, shape.rect.height) / 2)
            let deformed = CGPoint(
                x: coordinate(
                    local.x,
                    from: Axis(origin: base.rect.minX, span: base.rect.width, radius: radius),
                    to: Axis(origin: shape.rect.minX, span: shape.rect.width, radius: nextRadius)
                ),
                y: coordinate(
                    local.y,
                    from: Axis(origin: base.rect.minY, span: base.rect.height, radius: radius),
                    to: Axis(origin: shape.rect.minY, span: shape.rect.height, radius: nextRadius)
                )
            )
            return rotate(deformed, around: shape.rect, radians: shape.rotation).applying(inverse)
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: result.move(to: map(element.points[0]))
            case .addLineToPoint: result.addLine(to: map(element.points[0]))
            case .addQuadCurveToPoint:
                result.addQuadCurve(to: map(element.points[1]), control: map(element.points[0]))
            case .addCurveToPoint:
                result.addCurve(
                    to: map(element.points[2]),
                    control1: map(element.points[0]),
                    control2: map(element.points[1])
                )
            case .closeSubpath: result.closeSubpath()
            @unknown default: break
            }
        }
        return result
    }

    private func coordinate(
        _ value: CGFloat, from: Axis, to: Axis
    ) -> CGFloat {
        guard from.span > 0 else { return to.origin }
        if value <= from.origin { return to.origin + value - from.origin }
        if value >= from.origin + from.span { return to.origin + to.span + value - from.origin - from.span }
        if from.radius > 0, value < from.origin + from.radius {
            return to.origin + (value - from.origin) * to.radius / from.radius
        }
        if from.radius > 0, value > from.origin + from.span - from.radius {
            return to.origin + to.span - (from.origin + from.span - value) * to.radius / from.radius
        }
        let centreSpan = from.span - 2 * from.radius
        return centreSpan > 0
            ? to.origin + to.radius + (value - from.origin - from.radius) * (to.span - 2 * to.radius) / centreSpan
            : to.origin + to.span / 2
    }

    private func rotate(_ point: CGPoint, around rect: CGRect, radians: CGFloat) -> CGPoint {
        guard radians != 0 else { return point }
        let angle = radians
        let x = point.x - rect.midX, y = point.y - rect.midY
        return CGPoint(
            x: rect.midX + x * cos(angle) - y * sin(angle),
            y: rect.midY + x * sin(angle) + y * cos(angle)
        )
    }
}

extension ShellLayerScene {
    static let pathTrackKey = "omni.path.track"

    func flushPathTracks() {
        var bound: Set<Int32> = []
        for (slot, spec) in paths {
            guard let layer = layers[slot] as? CAShapeLayer else { continue }
            guard let key = presence.morphs[slot]?.track,
                  let entry = shapeTracks.entries.values.first(where: { $0.identity?.key == key && $0.carrier == nil }),
                  glassBodies[entry.body] != nil
            else {
                if shapeTracks.contours.contains(slot) {
                    layer.removeAnimation(forKey: Self.pathTrackKey)
                    layer.path = spec.fitted(to: layer.bounds.size)
                }
                continue
            }
            bound.insert(slot)
            if let item = pathTrackAnimation(slot, spec: spec, entry: entry, closing: false) {
                item.layer.add(item.animation, forKey: item.key)
            }
        }
        shapeTracks.contours = bound
    }

    func closingPathTrackAnimations(_ entry: ShellShapeTrackEntry) -> [ShellRevealAnimation] {
        guard let key = entry.identity?.key else { return [] }
        return paths.compactMap { slot, spec in
            guard presence.morphs[slot]?.track == key else { return nil }
            return pathTrackAnimation(slot, spec: spec, entry: entry, closing: true)
        }
    }

    private func pathTrackAnimation(
        _ slot: Int32, spec: ShellLayerPath, entry: ShellShapeTrackEntry, closing: Bool
    ) -> ShellRevealAnimation? {
        guard let layer = layers[slot] as? CAShapeLayer, let body = glassBodies[entry.body],
              let path = spec.fitted(to: layer.bounds.size) else { return nil }
        let origin = layer.convert(CGPoint.zero, to: body.layer)
        let x = layer.convert(CGPoint(x: 1, y: 0), to: body.layer)
        let y = layer.convert(CGPoint(x: 0, y: 1), to: body.layer)
        let map = CGAffineTransform(
            a: x.x - origin.x, b: x.y - origin.y,
            c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y
        )
        let contour = ShellShapeContour(path: path, base: entry.base.target, toBody: map)
        layer.removeAnimation(forKey: "path")
        layer.removeAnimation(forKey: Self.pathTrackKey)
        let plan = trackPlan(entry, slot: entry.base.target.slot, includingTransform: true)
        layer.path = contour.path(at: plan.samples.last?.shape ?? entry.terminal)
        guard plan.duration > 0 else { return nil }
        let samples = plan.samples
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = samples.map { contour.path(at: $0.shape) }
        animation.keyTimes = samples.map { NSNumber(value: $0.time / plan.duration) }
        animation.beginTime = layer.convertTime(plan.begin, from: nil)
        animation.duration = plan.duration
        animation.calculationMode = entry.bound?.input.active == true ? .cubic : .linear
        if closing {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        return ShellRevealAnimation(layer: layer, key: Self.pathTrackKey, animation: animation)
    }
}
