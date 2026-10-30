// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

private struct ShellShapeCanvas {
    let rect: CGRect
    let begin: CFTimeInterval
    let duration: CFTimeInterval
}

extension ShellLayerScene {
    func remove(_ slot: Int32, animated: Bool) {
        if retainShape(slot, animated: animated) {
            forget(slot)
            return
        }
        if let mask = masks[slot], mask.host.mask === mask.layer {
            mask.host.mask = nil
        }
        if let layer = displayedLayer(slot) {
            retirePresence(
                slot, subtree: layer, animated: animated,
                children: children
            )
        }
        forget(slot)
    }

    func retainShape(_ slot: Int32, animated: Bool) -> Bool {
        guard animated, let raw = glassShapes[slot], let carrier = layers[slot],
              let bodySlot = parents[slot], let body = glassBodies[bodySlot],
              let recipe = presence.reveals[slot], recipe.exits,
              let morph = presence.morphs[slot] ?? ShellShapeTrackStore.identityMorph
        else { return false }
        let supplied = presence.revealPlans[slot]?.plan
        let now = supplied?.commit ?? CACurrentMediaTime()
        let old = shapeTracks.entries.removeValue(forKey: slot)
        let base = old?.base.state(at: now) ?? (shape: raw, velocity: SIMD8<Double>.zero)
        let prior = old?.progress(at: now) ?? (progress: 1.0, velocity: 0.0)
        let plan = ShellReveal(
            begin: supplied?.begin ?? now + recipe.hold, commit: now,
            progress: prior.progress, velocity: prior.velocity, target: 0,
            spring: supplied?.spring ?? ShellMorphRecipe.Spring(response: recipe.response, bounce: recipe.bounce)
                .parameters
        )
        let physical = nextRetainedShapeSlot()
        var entry = ShellShapeTrackEntry(
            body: bodySlot, identity: presence.identities[slot],
            base: ShellShapeBaseMotion(
                from: base.shape.with(slot: physical), velocity: base.velocity,
                to: raw.with(slot: physical), begin: now, spring: old?.base.spring, ease: old?.base.ease
            ),
            morph: morph, plan: plan, edges: old?.edges, begin: now, carrier: carrier
        )
        entry.bound = old?.bound
        entry.triggerPlans = old?.triggerPlans.filter { $0.begin <= now }.suffix(1).map { $0 } ?? []
        entry.triggerRevision = old?.triggerRevision
        entry.triggerBegin = old?.triggerBegin
        let carried = old?.impulses.compactMap { $0.carrying(at: now) } ?? []
        let closing = entry.bound != nil || !entry.triggerPlans.isEmpty ? [] : morph.impulses.flatMap {
            impulse in
            ShellShapeImpulse.scheduled([impulse], on: plan, commit: now)
                .filter { impulse.kind == .after || $0.begin > now }
        }
        entry.impulses = carried + closing
        body.rekeyShape(from: slot, to: physical)
        glassShapeSlots[ObjectIdentifier(carrier)] = physical
        glassShapes[physical] = raw.with(slot: physical)
        shapeTracks.entries[physical] = entry
        retainShapeFollow(from: slot, to: physical)
        if let target = entry.bound?.input.binding?.target {
            shapeTracks.retainedBounds[target, default: []].insert(physical)
        }
        if let identity = entry.identity { shapeTracks.retired[identity] = physical }
        return true
    }

    private func nextRetainedShapeSlot() -> Int32 {
        while glassShapes[shapeTracks.nextRetired] != nil { shapeTracks.nextRetired &-= 1 }
        let result = shapeTracks.nextRetired
        shapeTracks.nextRetired &-= 1
        return result
    }

    func completeShapeTrack(_ slot: Int32, generation: UInt64) {
        guard shapeTracks.entries[slot]?.generation == generation,
              shapeTracks.entries[slot]?.carrier != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        discardShapeCarrier(slot)
        CATransaction.commit()
    }

    func discardShapeCarrier(_ slot: Int32, removeNative: Bool = true) {
        guard let entry = shapeTracks.entries.removeValue(forKey: slot) else { return }
        if let carrier = entry.carrier {
            glassShapeSlots.removeValue(forKey: ObjectIdentifier(carrier))
            carrier.removeFromSuperlayer()
        }
        if let identity = entry.identity, shapeTracks.retired[identity] == slot {
            shapeTracks.retired.removeValue(forKey: identity)
        }
        glassShapes.removeValue(forKey: slot)
        forgetShapeBindings(slot)
        if removeNative { glassBodies[entry.body]?.removeShape(slot) }
    }

    func forgetShapeTracks(_ slot: Int32) {
        if glassBodies[slot] != nil {
            for physical in Array(shapeTracks.entries.keys) where shapeTracks.entries[physical]?.body == slot {
                if shapeTracks.entries[physical]?.carrier != nil { discardShapeCarrier(physical) }
                else { shapeTracks.entries.removeValue(forKey: physical) }
            }
        } else {
            shapeTracks.entries.removeValue(forKey: slot)
        }
    }

    func finishShapeTracks() {
        for slot in Array(shapeTracks.entries.keys) {
            guard var entry = shapeTracks.entries[slot] else { continue }
            if entry.carrier != nil { discardShapeCarrier(slot)
                continue
            }
            if let body = glassBodies[entry.body] {
                body.setTrackGeometry(entry.terminal)
                body.removeTrack(slot)
            }
            entry.finish(at: CACurrentMediaTime())
            entry.animations = []
            entry.dirty = false
            shapeTracks.entries[slot] = entry
        }
        replanShapeFollows()
        for slot in presence.morphs.keys where glassShapes[slot] == nil {
            presentedContent(slot)?.removeAnimation(forKey: Self.revealTransformKey)
            presentedContent(slot)?.removeAnimation(forKey: Self.revealOpacityKey)
        }
        presence.revealPlans.removeAll()
        presence.dirtyReveals.removeAll()
        flushPathTracks()
    }

    func finishReplacedFrames(in body: Int32) {
        let replaced = glassShapes.contains { slot, shape in
            shape.kind == 2 && parents[slot] == body
        }
        for slot in Array(shapeTracks.entries.keys) {
            guard let entry = shapeTracks.entries[slot], entry.body == body, let carrier = entry.carrier,
                  entry.base.target.kind == 2 else { continue }
            if replaced {
                discardShapeCarrier(slot)
            } else if let host = layers[body], host.sublayers?.first !== carrier {
                host.insertSublayer(carrier, at: 0)
            }
        }
    }

    func flushShapeCanvases() {
        var canvases: [Int32: ShellShapeCanvas] = [:]
        let now = CACurrentMediaTime()
        for entry in shapeTracks.entries.values where !entry.animations.isEmpty && now < entry.end {
            guard let body = glassBodies[entry.body] else { continue }
            let bounds = body.layer.bounds.union(entry.union)
            if let previous = canvases[entry.body] {
                let begin = min(previous.begin, entry.begin)
                let duration = max(previous.duration + (previous.begin - begin), entry.duration + (entry.begin - begin))
                canvases[entry.body] = ShellShapeCanvas(
                    rect: previous.rect.union(bounds),
                    begin: begin,
                    duration: duration
                )
            } else {
                canvases[entry.body] = ShellShapeCanvas(rect: bounds, begin: entry.begin, duration: entry.duration)
            }
        }
        for (slot, canvas) in canvases {
            guard let body = glassBodies[slot] else { continue }
            for (path, value) in [
                ("position", NSValue(point: canvas.rect.origin)),
                ("bounds", NSValue(rect: canvas.rect))
            ] {
                let hold = CABasicAnimation(keyPath: path)
                hold.fromValue = value
                hold.toValue = value
                hold.beginTime = body.layer.convertTime(canvas.begin, from: nil)
                hold.duration = canvas.duration
                for layer in body.canvasLayers { layer.add(hold, forKey: "omni.glass.\(path)") }
            }
        }
    }
}
