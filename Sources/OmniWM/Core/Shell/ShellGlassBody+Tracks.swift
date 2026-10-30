// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellGlassBody {
    struct TrackSample {
        let time: CFTimeInterval
        let shape: ShellGlassShape
    }

    func trackAnimations(
        _ samples: [TrackSample], begin: CFTimeInterval, duration: CFTimeInterval, closing: Bool = false,
        calculationMode: CAAnimationCalculationMode = .linear
    ) -> (items: [ShellRevealAnimation], union: CGRect) {
        guard let last = samples.last else { return ([], .null) }
        setTrackGeometry(last.shape)
        guard duration > 0 else {
            removeTrack(last.shape.slot)
            return ([], Self.trackBounds(last.shape))
        }
        let layers = trackLayers(last.shape.slot)
        let times = samples.map { NSNumber(value: $0.time / duration) }
        var tracks: [Track: [Geometry]] = [:]
        var union = CGRect.null
        for sample in samples {
            for (track, geometry) in Self.trackGeometry(sample.shape) {
                tracks[track, default: []].append(geometry)
            }
            union = union.union(Self.trackBounds(sample.shape))
        }
        var items: [ShellRevealAnimation] = []
        for (track, geometries) in tracks {
            guard let targets = layers[track], let first = targets.first,
                  geometries.count == samples.count else { continue }
            let animations = Self.geometryAnimations(geometries)
            for animation in animations {
                animation.keyTimes = times
                animation.duration = duration
                animation.beginTime = first.convertTime(begin, from: nil)
                animation.calculationMode = calculationMode
                if closing {
                    animation.fillMode = .forwards
                    animation.isRemovedOnCompletion = false
                }
            }
            for target in targets {
                for animation in animations {
                    items.append(ShellRevealAnimation(
                        layer: target,
                        key: "omni.glass.\(animation.keyPath ?? "")",
                        animation: animation
                    ))
                }
            }
        }
        return (items, union)
    }

    func setTrackGeometry(_ shape: ShellGlassShape) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let geometries = Self.trackGeometry(shape)
        for (track, layers) in trackLayers(shape.slot) {
            guard let geometry = geometries[track] else { continue }
            for target in layers {
                for channel in Channel.geometry { target.removeAnimation(forKey: channel.key) }
                geometry.assign(to: target, replacing: Geometry(target))
            }
        }
    }

    func removeTrack(_ slot: Int32) {
        for layers in trackLayers(slot).values {
            for layer in layers {
                for path in ["position", "bounds", "cornerRadius", "transform"] {
                    layer.removeAnimation(forKey: "omni.glass.\(path)")
                }
            }
        }
    }

    private static func trackGeometry(_ shape: ShellGlassShape) -> [Track: Geometry] {
        let parts = parts(for: [shape])
        var geometries: [Track: Geometry] = [:]
        for part in parts.sdf + parts.mask { geometries[part.track] = part.geometry }
        if shape.kind == 2 {
            geometries[.container(shape.slot)] = Geometry(
                rect: shape.rect,
                radius: min(shape.radius, min(shape.rect.width, shape.rect.height) / 2)
            )
        }
        return geometries
    }

    private static func geometryAnimations(_ geometries: [Geometry]) -> [CAKeyframeAnimation] {
        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = geometries.map { NSValue(point: $0.position) }
        let bounds = CAKeyframeAnimation(keyPath: "bounds")
        bounds.values = geometries.map { NSValue(rect: $0.bounds) }
        let radius = CAKeyframeAnimation(keyPath: "cornerRadius")
        radius.values = geometries.map(\.radius)
        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = geometries.map { NSValue(caTransform3D: $0.transform) }
        return [position, bounds, radius, transform]
    }

    private static func trackBounds(_ shape: ShellGlassShape) -> CGRect {
        guard shape.rotation != 0 else { return shape.rect }
        let center = CGPoint(x: shape.rect.midX, y: shape.rect.midY)
        return shape.rect.applying(
            CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: shape.rotation)
                .translatedBy(x: -center.x, y: -center.y)
        )
    }
}
