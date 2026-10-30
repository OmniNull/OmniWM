// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

struct ShellGlassShape: Sendable {
    let slot: Int32
    let kind: UInt8
    let rect: CGRect
    let radius: CGFloat
    let thickness: CGFloat
    var rotation: CGFloat = 0
}

final class ShellGlassBody {
    struct ElementKey: Hashable {
        let slot: Int32
        let part: UInt8
    }

    private struct Style: Equatable {
        let tint: CGColor
        let shadow: CGColor
        let blur: CGFloat
        let saturation: CGFloat
        let shadowRadius: CGFloat
        let light: CGPoint
        let offset: CGPoint
        let flat: Bool
        let band: CGFloat
        let gradient: [CGColor]
    }

    let layer = CALayer()
    private(set) var nativeAvailable: Bool
    private(set) var failure: String?
    private(set) var elements: [[ElementKey: CALayer]] = Array(repeating: [:], count: 4)
    private(set) var maskElements: [ElementKey: CALayer] = [:]
    private(set) var maskContainers: [Int32: CALayer] = [:]
    let sdfLayers: [CALayer]
    private var backdrop: CALayer?
    private var gradient: CAGradientLayer?
    private var bandLayer: CALayer?
    private var composition: ShellGlassComposition?
    private let coverage = CALayer()
    private let fallbackTint = CALayer()
    private let fallbackCoverage = CALayer()
    private let defaultTint = CGColor(srgbRed: 0.247, green: 0.278, blue: 0.408, alpha: 0.36)
    private let defaultShadow = CGColor(srgbRed: 0.043, green: 0.055, blue: 0.067, alpha: 0.08)
    private let elementClass: CALayer.Type?
    private let capability: ShellGlassCapability
    private var fallbackMaskElements: [ElementKey: CALayer] = [:]
    private var fallbackMaskContainers: [Int32: CALayer] = [:]
    private var style: Style?
    private var blend: CGFloat?
    private var reportedFailure: String?

    init(forceFallback: Bool = false, capability: ShellGlassCapability = .shared) {
        self.capability = capability
        elementClass = capability.elementClass
        let available = !forceFallback && capability.flatMissing == nil
        nativeAvailable = available
        if available, let sdfClass = capability.bodyClass { sdfLayers = (0 ..< 4).map { _ in sdfClass.init() } }
        else { sdfLayers = [] }
        layer.anchorPoint = .zero
        for mask in [coverage, fallbackCoverage] {
            mask.anchorPoint = .zero
            mask.masksToBounds = true
        }
        fallbackTint.anchorPoint = .zero
        fallbackTint.mask = fallbackCoverage
        for body in sdfLayers { body.anchorPoint = .zero }
        let stack = sdfLayers.count == 4 ? [sdfLayers[0], sdfLayers[1], sdfLayers[3], sdfLayers[2]] : []
        for child in stack + [fallbackTint] { layer.addSublayer(child) }
        failure = forceFallback ? "Native glass explicitly disabled" : capability.missing
    }

    func apply(
        size: CGSize,
        shapes: [ShellGlassShape],
        recipe: ShellGlassRecipe,
        paint: ShellLayerPaint,
        animation: ShellAnimation?,
        shapeAnimations: [Int32: ShellAnimation]? = nil,
        geometryOwners: Set<Int32> = []
    ) {
        let validSize = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
        let canvas = validSize ? size : .zero
        let valid = validSize && Self.validShapes(shapes)
        let frames = valid ? shapes.filter { $0.kind == 2 } : []
        let tinted = paint.gradient == nil
        admit(valid: valid, frames: frames, canvas: canvas, blend: recipe.blend, backdrop: tinted && !recipe.flat)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let motion = animation == nil && shapeAnimations?.isEmpty != false ? nil : Motion(
            canvas: animation,
            shapes: shapeAnimations,
            begin: layer.convertTime(CACurrentMediaTime(), from: nil)
        )
        let placed = placeMaterial(backdrop: tinted && !recipe.flat, gradient: !tinted)
        let material = gradient ?? backdrop
        let recomposed = placeBand(nativeAvailable ? recipe.band : 0)
        applyStyle(recipe: recipe, paint: paint, motion: motion, placed: placed, recomposed: recomposed)
        let bounds = Geometry(rect: CGRect(origin: .zero, size: canvas))
        layoutCanvas(bounds, motion: motion, material: material, recipe: recipe)
        let parts: (sdf: [Part], mask: [Part]) = valid ? Self.parts(for: shapes) : ([], [])
        material?.isHidden = !valid
        let baseCoverage = material != nil
        Self.reconcileContainers(baseCoverage ? frames : [], elements: &maskContainers, motion: motion)
        reconcile(
            baseCoverage ? parts.mask : [],
            in: coverage,
            elements: &maskElements,
            containers: maskContainers,
            motion: motion,
            geometryOwners: geometryOwners
        )
        let fallback = !nativeAvailable && tinted
        fallbackTint.isHidden = !fallback || !valid
        applyNative(parts.sdf, bounds: bounds, blend: recipe.blend, motion: motion, geometryOwners: geometryOwners)
        Self.reconcileContainers(fallback ? frames : [], elements: &fallbackMaskContainers, motion: motion)
        reconcile(
            fallback ? parts.mask : [],
            in: fallbackCoverage,
            elements: &fallbackMaskElements,
            containers: fallbackMaskContainers,
            motion: motion,
            geometryOwners: geometryOwners
        )
        CATransaction.commit()
    }
}

extension ShellGlassBody {
    var canvasLayers: [CALayer] {
        [layer, gradient ?? backdrop, coverage, fallbackTint, fallbackCoverage, bandLayer]
            .compactMap(\.self) + sdfLayers + (composition?.canvasLayers ?? [])
    }

    func lockstepLayers(_ slot: Int32) -> [CALayer] {
        let key = ElementKey(slot: slot, part: 0)
        return elements.compactMap { $0[key] } + [maskElements[key], fallbackMaskElements[key]].compactMap(\.self)
    }

    func trackLayers(_ slot: Int32) -> [Track: [CALayer]] {
        var result: [Track: [CALayer]] = [:]
        for tree in elements {
            for (key, layer) in tree where key.slot == slot {
                result[Track(key: key, mask: false), default: []].append(layer)
            }
        }
        let frame = maskContainers[slot] != nil || fallbackMaskContainers[slot] != nil
        for tree in [maskElements, fallbackMaskElements] {
            for (key, layer) in tree where key.slot == slot {
                result[Track(key: key, mask: frame), default: []].append(layer)
            }
        }
        for layer in [maskContainers[slot], fallbackMaskContainers[slot]].compactMap(\.self) {
            result[.container(slot), default: []].append(layer)
        }
        return result
    }

    func rekeyShape(from source: Int32, to target: Int32) {
        guard source != target else { return }
        for index in elements.indices { Self.rekey(source, to: target, in: &elements[index]) }
        Self.rekey(source, to: target, in: &maskElements)
        Self.rekey(source, to: target, in: &fallbackMaskElements)
        maskContainers[target] = maskContainers.removeValue(forKey: source)
        fallbackMaskContainers[target] = fallbackMaskContainers.removeValue(forKey: source)
    }

    func removeShape(_ slot: Int32) {
        for index in elements.indices { Self.removeParts(slot, from: &elements[index]) }
        Self.removeParts(slot, from: &maskElements)
        Self.removeParts(slot, from: &fallbackMaskElements)
        maskContainers.removeValue(forKey: slot)?.removeFromSuperlayer()
        fallbackMaskContainers.removeValue(forKey: slot)?.removeFromSuperlayer()
    }

    private func admit(valid: Bool, frames: [ShellGlassShape], canvas: CGSize, blend: CGFloat, backdrop: Bool) {
        let supportedFrame = !valid || frames.allSatisfy { frame in
            Self.nativeFrameCoversCanvas(frame, canvas: canvas, blend: blend)
        }
        let missing = capability.missing(backdrop: backdrop)
        failure = !valid ? "Native glass geometry is invalid" :
            missing != nil ? missing :
            !supportedFrame ?
            "Native SDF frame needs blend at least 8 and outer padding at least twice blend; using masked material and tint" :
            sdfLayers.count == 4 ? nil : "Native glass explicitly disabled"
        nativeAvailable = sdfLayers.count == 4 && missing == nil && valid && supportedFrame
        if !valid || (missing == nil && !supportedFrame), let failure {
            reportFallback(failure)
        } else {
            reportedFailure = nil
        }
    }

    private func layoutCanvas(_ bounds: Geometry, motion: Motion?, material: CALayer?, recipe: ShellGlassRecipe) {
        for target in [layer, material, coverage, fallbackTint, fallbackCoverage].compactMap(\.self)
            + (composition?.canvasLayers ?? [])
        {
            bounds.apply(to: target, motion: motion, track: .canvas)
        }
        if let gradient {
            Self.orient(gradient, angle: recipe.gradientAngle, size: bounds.bounds.size)
            if let composition { Self.orient(composition.alpha, angle: recipe.gradientAngle, size: bounds.bounds.size) }
        }
    }

    private func applyNative(
        _ parts: [Part], bounds: Geometry, blend next: CGFloat, motion: Motion?, geometryOwners: Set<Int32>
    ) {
        let bandTree = sdfLayers.count
        let fresh = bandLayer == nil ? [] : parts.map(\.key).filter { elements[bandTree][$0] == nil }
        for (index, body) in (sdfLayers + [bandLayer].compactMap(\.self)).enumerated() {
            body.isHidden = !nativeAvailable
            bounds.apply(to: body, motion: motion, track: .canvas)
            if blend != next {
                body.setValue(2 * next, forKey: ShellGlassCapability.BodyProperty.smoothness.rawValue)
                if let blend {
                    let from = NSNumber(value: Double(2 * blend))
                    animate(.smoothness, on: body, motion: motion, from: from, to: NSNumber(value: Double(2 * next)))
                }
            }
            reconcile(
                nativeAvailable ? parts : [],
                in: body,
                elements: &elements[index],
                native: true,
                motion: motion,
                geometryOwners: geometryOwners
            )
        }
        for key in fresh {
            if let element = elements[bandTree][key], let leader = elements[1][key] {
                Self.follow(element, leader)
                if geometryOwners.contains(key.slot) { element.anchorPoint = leader.anchorPoint }
            }
        }
        blend = next
    }

    private func animate(_ channel: Channel, on target: CALayer, motion: Motion?, from: Any, to: Any) {
        if let motion, motion.animates(.canvas) {
            motion.add(channel, to: target, on: .canvas, from: from, to: to)
        } else {
            target.removeAnimation(forKey: channel.key)
        }
    }

    private func applyStyle(
        recipe: ShellGlassRecipe, paint: ShellLayerPaint, motion: Motion?, placed: CALayer?, recomposed: Bool
    ) {
        let next = Style(
            tint: paint.gradient == nil ? paint.fill ?? defaultTint : ShellLayerScene.clear,
            shadow: paint.shadow ?? defaultShadow,
            blur: paint.blurRadius >= 0 ? paint.blurRadius : 6,
            saturation: paint.saturation,
            shadowRadius: paint.shadowRadius,
            light: recipe.light,
            offset: recipe.shadowOffset,
            flat: recipe.flat,
            band: recipe.band,
            gradient: paint.gradient ?? []
        )
        let previous = style
        guard previous != next || placed != nil || recomposed else { return }
        style = next
        if let backdrop, placed === backdrop || previous?.blur != next.blur
            || previous?.saturation != next.saturation
        {
            backdrop.filters = [
                ShellLayerScene.filter("gaussianBlur", "inputRadius", next.blur),
                ShellLayerScene.filter("colorSaturate", "inputAmount", next.saturation)
            ]
            .compactMap(\.self)
        }
        if composition == nil, let gradient, placed === gradient || previous?.gradient != next.gradient || recomposed {
            gradient.colors = next.gradient
        }
        if previous?.tint != next.tint { fallbackTint.backgroundColor = next.tint }
        guard sdfLayers.count == 4 else { return }
        applyShadow(next, previous: previous, motion: motion)
        if previous?.tint != next.tint || previous?.gradient != next.gradient || recomposed || placed != nil {
            let fill = composition?.update(
                tint: next.tint, colors: next.gradient, material: gradient, coverage: coverage
            ) ?? next.tint
            setEffect(.fill, on: sdfLayers[1], values: [.color: fill])
        }
        if previous?.light != next.light || previous?.flat != next.flat { applyLight(next.light, shine: !next.flat) }
        if next.band > 0, let bandLayer, recomposed || previous?.band != next.band
            || previous?.tint != next.tint || previous?.gradient != next.gradient || previous?.flat != next.flat
        {
            let alpha = !next.flat && next.gradient.isEmpty ? next.tint.alpha : 1
            setBand(alpha > 0 ? next.band / alpha : 0, on: bandLayer)
        }
    }

    private func applyShadow(_ next: Style, previous: Style?, motion: Motion?) {
        if previous?.shadow != next.shadow || previous?.offset != next.offset || previous?.shadowRadius != next
            .shadowRadius
        {
            setEffect(.shadow, on: sdfLayers[0], values: [
                .color: next.shadow,
                .offset: CGSize(width: next.offset.x, height: next.offset.y),
                .radius: next.shadowRadius,
                .punchout: true
            ])
            if let previous {
                animateShadow(from: previous, to: next, motion: motion)
            }
        }
    }

    private func placeMaterial(backdrop wanted: Bool, gradient painted: Bool) -> CALayer? {
        guard (backdrop != nil) != wanted || (gradient != nil) != painted else { return nil }
        let previous = gradient ?? backdrop
        previous?.removeFromSuperlayer()
        previous?.mask = nil
        backdrop = wanted ? capability.backdrop() : nil
        gradient = painted ? CAGradientLayer() : nil
        guard let next = gradient ?? backdrop else { return nil }
        next.anchorPoint = .zero
        if previous == nil, sdfLayers.count == 4 { Self.followGeometry(coverage, sdfLayers[1]) }
        Self.follow(next, coverage)
        if gradient == nil || composition == nil {
            composition?.releaseCoverage(coverage)
            next.mask = coverage
        }
        layer.insertSublayer(next, at: sdfLayers.isEmpty ? 0 : 1)
        return next
    }

    private func placeBand(_ amount: CGFloat) -> Bool {
        guard (bandLayer != nil) != (amount > 0) else { return false }
        if let bandLayer {
            composition?.restore(in: layer, material: gradient ?? backdrop, coverage: coverage, above: sdfLayers[0])
            composition = nil
            bandLayer.removeFromSuperlayer()
            self.bandLayer = nil
            elements.removeLast()
            return true
        }
        guard let next = capability.bodyClass?.init() else { return false }
        let fill = sdfLayers[1]
        let index = layer.sublayers?.firstIndex(of: fill) ?? 1
        let smoothness = ShellGlassCapability.BodyProperty.smoothness.rawValue
        next.anchorPoint = .zero
        next.compositingFilter = capability.compositing(.add)
        next.setValue(fill.value(forKey: smoothness), forKey: smoothness)
        Self.follow(next, fill)
        let composition = ShellGlassComposition(fill: fill, band: next)
        layer.insertSublayer(composition.layer, at: UInt32(index))
        self.composition = composition
        bandLayer = next
        elements.append([:])
        return true
    }

    private func setBand(_ amount: CGFloat, on target: CALayer) {
        setEffect(.band, on: target, values: [
            .colors: Self.bandWeights.map { CGColor(gray: 1, alpha: min(1, amount * $0)) },
            .distances: Self.bandDistances
        ])
    }

    private func animateShadow(from previous: Style, to next: Style, motion: Motion?) {
        if previous.shadowRadius != next.shadowRadius {
            animate(
                .shadowRadius,
                on: sdfLayers[0],
                motion: motion,
                from: NSNumber(value: Double(previous.shadowRadius)),
                to: NSNumber(value: Double(next.shadowRadius))
            )
        }
        if previous.offset != next.offset {
            animate(
                .shadowOffset,
                on: sdfLayers[0],
                motion: motion,
                from: NSValue(size: CGSize(width: previous.offset.x, height: previous.offset.y)),
                to: NSValue(size: CGSize(width: next.offset.x, height: next.offset.y))
            )
        }
    }

    func setEffect(
        _ effect: ShellGlassCapability.Effect,
        on target: CALayer,
        values: [ShellGlassCapability.EffectKey: Any]
    ) {
        target.setValue(
            capability.effect(effect, values: values),
            forKey: ShellGlassCapability.BodyProperty.effect.rawValue
        )
    }

    private func reconcileElement(
        _ part: Part, old: CALayer?, native: Bool, motion: Motion?, managed: Bool
    ) -> CALayer {
        let element: CALayer
        if let old, native || (old is CAShapeLayer) == part.corner {
            element = old
        } else if native, let elementClass {
            element = elementClass.init()
            element.setValue("bounds", forKey: ShellGlassCapability.ElementProperty.mode.rawValue)
        } else if part.corner {
            let corner = CAShapeLayer()
            corner.path = Self.cornerPath()
            corner.fillColor = CGColor(gray: 1, alpha: 1)
            element = corner
        } else {
            element = CALayer()
            element.backgroundColor = CGColor(gray: 1, alpha: 1)
        }
        if old !== element {
            element.anchorPoint = .zero
            element.cornerCurve = .circular
            if native {
                element.setValue(
                    part.subtract ? "subtraction" : "union",
                    forKey: ShellGlassCapability.ElementProperty.operation.rawValue
                )
            }
        }
        let seed = native || old != nil || part.corner || part.container != nil ? nil : self.elements[1][part.key]
        if let seed {
            Self.follow(element, seed)
            if managed { element.anchorPoint = seed.anchorPoint }
        }
        if !managed || (old !== element && seed == nil) {
            let releasing = !managed && element.anchorPoint != .zero
            if releasing {
                element.anchorPoint = .zero
                for channel in Channel.geometry { element.removeAnimation(forKey: channel.key) }
            }
            part.geometry.apply(
                to: element,
                motion: !releasing && (old === element || seed != nil) ? motion : nil,
                track: part.track
            )
        }
        return element
    }

    private func reconcile(
        _ parts: [Part],
        in root: CALayer,
        elements: inout [ElementKey: CALayer],
        native: Bool = false,
        containers: [Int32: CALayer] = [:],
        motion: Motion?,
        geometryOwners: Set<Int32> = []
    ) {
        var kept: [ElementKey: CALayer] = [:]
        var order: [CALayer] = []
        var frameOrder: [CALayer] = []
        var hasFrame = false
        kept.reserveCapacity(parts.count)
        order.reserveCapacity(parts.count)
        for part in parts {
            let element = reconcileElement(
                part, old: elements[part.key], native: native, motion: motion,
                managed: geometryOwners.contains(part.key.slot)
            )
            kept[part.key] = element
            if let slot = part.container, let container = containers[slot] {
                if !hasFrame {
                    order.append(container)
                    hasFrame = true
                }
                frameOrder.append(element)
            } else {
                order.append(element)
            }
        }
        Self.setOrder(order, in: root)
        if let container = containers.values.first { Self.setOrder(frameOrder, in: container) }
        elements = kept
    }

    private func reportFallback(_ reason: String) {
        guard reportedFailure != reason else { return }
        reportedFailure = reason
        Log.shell.notice("Glass body fallback: \(reason)")
    }
}
