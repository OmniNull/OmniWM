// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellRevealAnimation {
    let layer: CALayer
    let key: String
    let animation: CAAnimation
}

private struct ShellRevealTiming {
    let plan: ShellReveal
    let samples: [ShellReveal.Sample]
    let times: [NSNumber]
    let duration: CFTimeInterval
    let begin: CFTimeInterval
    let closing: Bool

    init(_ plan: ShellReveal, begin: CFTimeInterval, closing: Bool) {
        self.plan = plan
        samples = plan.samples
        times = samples.map { NSNumber(value: $0.time / plan.duration) }
        duration = plan.duration
        self.begin = begin
        self.closing = closing
    }

    func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        return timed(animation)
    }

    func hold(_ keyPath: String, _ value: NSValue) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.toValue = value
        return timed(animation)
    }

    private func timed<Animation: CAAnimation>(_ animation: Animation) -> Animation {
        animation.duration = duration
        animation.beginTime = begin
        animation.fillMode = closing ? .both : .backwards
        if closing {
            animation.isRemovedOnCompletion = false
        }
        return animation
    }
}

extension ShellLayerScene {
    static let revealTransformKey = "omni.reveal.transform"
    static let revealOpacityKey = "omni.reveal.opacity"

    func flushReveals(animated: Bool) {
        let built = shapeTracks.generation
        flushShapeTracks()
        defer { flushShapeCanvases() }
        keepRevealSettles(rebuiltAfter: built)
        guard !presence.dirtyReveals.isEmpty else { return }
        for slot in presence.dirtyReveals {
            guard let (plan, token) = presence.revealPlans[slot] else { continue }
            let items = revealAnimations(slot, plan: plan, children: children, closing: false)
            items.first?.animation.delegate = animated ? revealSettle(slot, token: token) : nil
            for item in items {
                if animated { item.layer.add(item.animation, forKey: item.key) }
                else { item.layer.removeAnimation(forKey: item.key) }
            }
            if items.isEmpty || !animated { settleReveal(slot, token: token, finished: true) }
        }
        presence.dirtyReveals.removeAll(keepingCapacity: true)
    }

    func revealAnimations(
        _ root: Int32,
        plan: ShellReveal,
        children: [Int32: Set<Int32>],
        closing: Bool
    ) -> [ShellRevealAnimation] {
        guard plan.duration > 0, let host = layers[root] else { return [] }
        let timing = ShellRevealTiming(plan, begin: host.convertTime(plan.begin, from: nil), closing: closing)
        var items: [ShellRevealAnimation] = []
        var canvases: [Int32: (layout: CGRect, union: CGRect)] = [:]
        let shapes = glassShapes[root] == nil ? morphDescendants(root, children: children) : [root]
        for slot in shapes {
            guard let recipe = presence.morphs[slot], recipe.track == nil else { continue }
            if let shape = glassShapes[slot], let body = parents[slot], let glass = glassBodies[body] {
                let layout = canvases[body]?.layout ?? CGRect(origin: .zero, size: layers[body]?.bounds.size ?? .zero)
                let union = shapeAnimations(shape, recipe: recipe, in: glass, timing: timing, into: &items)
                canvases[body] = (layout, (canvases[body]?.union ?? layout).union(union))
            } else if let layer = presentedContent(slot) {
                groupAnimations(layer, recipe: recipe, timing: timing, into: &items)
            }
        }
        for (body, canvas) in canvases where canvas.union != canvas.layout {
            guard let glass = glassBodies[body] else { continue }
            for (keyPath, value) in [
                ("position", NSValue(point: canvas.union.origin)),
                ("bounds", NSValue(rect: canvas.union))
            ] {
                let hold = timing.hold(keyPath, value)
                items += glass.canvasLayers.map {
                    ShellRevealAnimation(layer: $0, key: "omni.glass.\(keyPath)", animation: hold)
                }
            }
        }
        return items
    }

    private func shapeAnimations(
        _ shape: ShellGlassShape,
        recipe: ShellMorphRecipe,
        in glass: ShellGlassBody,
        timing: ShellRevealTiming,
        into items: inout [ShellRevealAnimation]
    ) -> CGRect {
        guard let built = shapeRevealAnimations(shape, recipe: recipe, plan: timing.plan, closing: timing.closing)
        else {
            return .null
        }
        items += built.items
        return built.union
    }

    private func groupAnimations(
        _ layer: CALayer,
        recipe: ShellMorphRecipe,
        timing: ShellRevealTiming,
        into items: inout [ShellRevealAnimation]
    ) {
        let stops = timing.samples.map { recipe.stop(at: $0.progress) }
        let base = layer.transform
        let size = layer.bounds.size
        let transforms = stops.map {
            NSValue(caTransform3D: ShellPresence.transform(
                from: base,
                size: size,
                anchor: recipe.anchor,
                scale: $0.scale,
                offset: CGPoint(x: $0.dx, y: $0.dy)
            ))
        }
        items.append(ShellRevealAnimation(
            layer: layer, key: Self.revealTransformKey, animation: timing.keyframes("transform", transforms)
        ))
        items.append(ShellRevealAnimation(
            layer: layer,
            key: Self.revealOpacityKey,
            animation: timing.keyframes("opacity", stops.map { layer.opacity * Float($0.opacity) })
        ))
    }

    private func morphDescendants(_ root: Int32, children: [Int32: Set<Int32>]) -> [Int32] {
        var result: [Int32] = []
        func collect(_ parent: Int32) {
            for child in children[parent] ?? [] {
                if presence.morphs[child] != nil,
                   !(glassShapes[child] != nil &&
                       (presence.reveals[child] != nil || presence.morphs[child]?.trigger != nil
                           || presence.morphs[child]?.source != nil))
                { result.append(child) }
                if presence.reveals[child] == nil { collect(child) }
            }
        }
        collect(root)
        return result
    }

    private func keepRevealSettles(rebuiltAfter generation: UInt64) {
        for entry in shapeTracks.entries.values where entry.generation > generation && entry.carrier == nil {
            guard let root = entry.root, !presence.dirtyReveals.contains(root),
                  let (plan, token) = presence.revealPlans[root], plan.target != 0,
                  let first = entry.animations.first else { continue }
            first.animation.delegate = revealSettle(root, token: token)
            first.layer.add(first.animation, forKey: first.key)
        }
    }

    private func revealSettle(_ slot: Int32, token: UInt64) -> ShellManipulationCompletion {
        ShellManipulationCompletion { [weak self] finished in
            Self.engineQueue.async { [weak self] in self?.settleReveal(slot, token: token, finished: finished) }
        }
    }

    private func settleReveal(_ slot: Int32, token: UInt64, finished: Bool) {
        guard finished, presence.revealPlans[slot]?.token == token else { return }
        presence.revealPlans.removeValue(forKey: slot)
        guard let settled = presence.onRevealSettled else { return }
        DispatchQueue.main.async { settled(slot, token) }
    }
}
