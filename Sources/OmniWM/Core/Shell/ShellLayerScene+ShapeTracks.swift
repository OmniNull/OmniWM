// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellLayerScene {
    func prepareShapeTracks(animated: Bool) {
        let now = CACurrentMediaTime()
        for (slot, shape) in glassShapes where shapeTracks.entries[slot]?.carrier == nil {
            let tracked = presence.reveals[slot] != nil || shapeTracks.follows[slot]?.radius != nil
            guard let body = parents[slot], glassBodies[body] != nil,
                  let morph = presence.morphs[slot] ?? (tracked ? ShellShapeTrackStore.identityMorph : nil)
            else { continue }
            updateShapeTrack(shape, body: body, morph: morph, at: now, animated: animated)
        }
        prepareBoundTracks()
        resolveShapeTriggers(animated: animated)
    }

    func flushShapeTracks() {
        for slot in Array(shapeTracks.entries.keys) {
            guard var entry = shapeTracks.entries[slot], let body = glassBodies[entry.body] else { continue }
            if entry.dirty {
                shapeTracks.generation &+= 1
                entry.generation = shapeTracks.generation
                let plan = trackPlan(entry, slot: slot)
                let built = body.trackAnimations(
                    plan.samples,
                    begin: plan.begin,
                    duration: plan.duration,
                    closing: entry.carrier != nil,
                    calculationMode: entry.bound?.input.active == true ? .cubic : .linear
                )
                entry.animations = built.items
                entry.union = built.union
                entry.dirty = false
                if entry.carrier != nil {
                    let generation = entry.generation
                    let completion = ShellManipulationCompletion { [weak self] finished in
                        guard finished else { return }
                        Self.engineQueue.async { [weak self] in self?.completeShapeTrack(slot, generation: generation) }
                    }
                    entry.animations.first?.animation.delegate = completion
                }
                for item in entry.animations { item.layer.add(item.animation, forKey: item.key) }
                shapeTracks.entries[slot] = entry
                if entry.carrier != nil, plan.duration == 0 || entry.animations.isEmpty { completeShapeTrack(
                    slot,
                    generation: entry.generation
                ) }
            } else if shapeTracks.updatedBodies.contains(entry.body) {
                body.setTrackGeometry(trackTerminal(entry, slot: slot))
            }
        }
        shapeTracks.updatedBodies.removeAll(keepingCapacity: true)
        flushPathTracks()
    }

    private func updateShapeTrack(
        _ shape: ShellGlassShape, body: Int32, morph: ShellMorphRecipe, at time: CFTimeInterval, animated: Bool
    ) {
        let source = shapeRevealSource(shape.slot)
        let sourcePlan = source.flatMap { presence.revealPlans[$0]?.plan }
        let supplied = morph.waits ? nil : sourcePlan
        let now = sourcePlan?.commit ?? time
        var old = shapeTracks.entries[shape.slot]
        if old == nil, let identity = presence.identities[shape.slot], let retired = shapeTracks.retired[identity],
           let previous = shapeTracks.entries[retired]
        {
            old = previous
            glassBodies[body]?.rekeyShape(from: retired, to: shape.slot)
            discardShapeCarrier(retired, removeNative: false)
        }
        let sourceChanged = !morph.waits && old.map { $0.root != source } == true
        let geometryChanged = old
            .map {
                ($0.base.target.kind != shape.kind || ShellShapeBaseMotion
                    .vector($0.base.target) != ShellShapeBaseMotion
                    .vector(shape))
            } ?? true
        let planChanged = supplied.map { $0.begin != old?.plan?.begin || $0.target != old?.plan?.target } ?? false
        guard old == nil || geometryChanged || old?.morph != morph || sourceChanged || planChanged else { return }
        let base = shapeBase(from: old, to: shape, morph: morph, at: now, changed: geometryChanged)
        var entry = ShellShapeTrackEntry(
            body: body, identity: presence.identities[shape.slot], base: base, morph: morph,
            plan: sourceChanged ? supplied : supplied ?? old?.plan, begin: now, root: source,
            triggerBegin: old?.triggerBegin
        )
        entry.bound = morph.source == nil ? nil : old?.bound
        entry.triggerPlans = old?.triggerPlans ?? []
        entry.triggerRevision = old?.morph.trigger == morph.trigger ? old?.triggerRevision : nil
        if let old, old.carrier != nil, let supplied {
            let seed = old.plan?.state(at: now) ?? (progress: 1.0, velocity: 0.0)
            entry.plan = ShellReveal(
                begin: now, progress: seed.progress, velocity: seed.velocity, target: 1, spring: supplied.spring
            )
        }
        entry.edges = shapeEdges(from: old, to: shape, morph: morph, at: now)
        if morph.source != nil {
            entry.impulses = old?.impulses ?? []
            if let input = old?.bound?.input,
               old?.morph.impulses != morph.impulses || old?.morph.source != morph.source
            {
                shapeTracks.pendingBounds[shape.slot] = shapeTracks.pendingBounds[shape.slot] ?? ShellBoundInput(
                    layout: input.layout, canvas: input.canvas, presentation: input.presentation,
                    active: input.active, time: now, animates: input.animates, binding: input.binding
                )
            }
        } else { replanShapeImpulses(&entry, from: old, at: now) }
        if !animated { entry.finish(at: time) }
        shapeTracks.entries[shape.slot] = entry
    }

    private func shapeEdges(
        from old: ShellShapeTrackEntry?, to shape: ShellGlassShape, morph: ShellMorphRecipe, at now: CFTimeInterval
    ) -> ShellShapeEdges? {
        if let edges = morph.edges, let old {
            if let active = old.edges {
                let state = active.state(at: now)
                return ShellShapeEdges(
                    from: state.rect, to: shape.rect, recipe: edges, begin: now, velocity: state.velocity
                )
            } else {
                return ShellShapeEdges(
                    from: old.base.state(at: now).shape.rect,
                    to: shape.rect,
                    recipe: edges,
                    begin: now
                )
            }
        }
        return nil
    }

    private func shapeBase(
        from old: ShellShapeTrackEntry?, to shape: ShellGlassShape, morph: ShellMorphRecipe, at now: CFTimeInterval,
        changed: Bool
    ) -> ShellShapeBaseMotion {
        if let old, changed {
            let start = morph.source == nil && old.bound != nil
                ? (shape: old.shape(at: now), velocity: SIMD8<Double>.zero) : old.base.state(at: now)
            let preset = shapeTracks.presets[shape.slot]
            return ShellShapeBaseMotion(
                from: start.shape.with(slot: shape.slot), velocity: start.velocity, to: shape, begin: now,
                spring: preset.flatMap { ShellSpringDynamics.Parameters($0) }, ease: preset
            )
        } else if let old {
            return old.base.rekeyed(to: shape.slot)
        } else { return ShellShapeBaseMotion(from: shape, to: shape, begin: now) }
    }

    private func shapeRevealSource(_ slot: Int32) -> Int32? {
        var current = slot
        while layers[current] != nil {
            if presence.reveals[current] != nil { return current }
            guard let parent = parents[current] else { return nil }
            current = parent
        }
        return nil
    }

    private func replanShapeImpulses(
        _ entry: inout ShellShapeTrackEntry, from old: ShellShapeTrackEntry?, at time: CFTimeInterval
    ) {
        let carried = old?.impulses.compactMap { $0.carrying(at: time) } ?? []
        if entry.morph.waits, entry.plan == nil {
            entry.impulses = old?.impulses ?? []
            replanPulseImpulses(&entry, at: time)
            return
        }
        let plan = entry.plan ?? ShellReveal(
            begin: time, progress: 1, target: 1,
            spring: ShellMorphRecipe.Spring(response: 0.35, bounce: 0.15).parameters
        )
        let scheduled = entry.morph.impulses.flatMap { recipe in
            ShellShapeImpulse.scheduled([recipe], on: plan, commit: time).filter {
                recipe.kind == .after || old == nil || $0.begin > time
            }
        }
        entry.impulses = carried + scheduled
    }

    private func resolveShapeTriggers(animated: Bool) {
        var remaining = Set(shapeTracks.entries.keys
            .filter { shapeTracks.entries[$0]?.morph.trigger != nil && shapeTracks.entries[$0]?.carrier == nil })
        for _ in 0 ..< remaining.count {
            var resolved: [Int32] = []
            for slot in remaining {
                guard var entry = shapeTracks.entries[slot], let trigger = entry.morph.trigger,
                      let source = shapeTriggerSource(trigger.shape),
                      !remaining.contains(source.key) else { continue }
                if let bound = source.value.bound {
                    resolveBoundTrigger(&entry, from: bound)
                    shapeTracks.entries[slot] = entry
                    resolved.append(slot)
                    continue
                }
                if source.value.triggerRevision != nil {
                    resolvePlannedTrigger(&entry, from: source.value, animated: animated)
                    shapeTracks.entries[slot] = entry
                    resolved.append(slot)
                    continue
                }
                resolveRevealTrigger(&entry, plan: source.value.plan, animated: animated)
                shapeTracks.entries[slot] = entry
                resolved.append(slot)
            }
            if resolved.isEmpty { break }
            remaining.subtract(resolved)
        }
    }

    private func resolveRevealTrigger(_ entry: inout ShellShapeTrackEntry, plan: ShellReveal?, animated: Bool) {
        if entry.triggerRevision != nil || !entry.triggerPlans.isEmpty {
            entry.triggerPlans = []
            entry.triggerRevision = nil
            entry.triggerBegin = nil
            entry.plan = nil
            entry.impulses = entry.impulses.compactMap { $0.carrying(at: entry.begin) }
            entry.dirty = true
        }
        guard let plan, let trigger = entry.morph.trigger, entry.triggerBegin != plan.begin,
              let crossing = plan.crossings(at: trigger.at, rising: trigger.rising).first else { return }
        let spring = presence.reveals[entry.base.target.slot].map {
            ShellMorphRecipe.Spring(response: $0.response, bounce: $0.bounce).parameters
        } ?? plan.spring
        entry.plan = ShellReveal(begin: crossing, progress: 0, target: 1, spring: spring)
        entry.begin = min(entry.begin, crossing)
        entry.triggerBegin = plan.begin
        entry.dirty = true
        replanShapeImpulses(&entry, from: nil, at: crossing)
        if !animated { entry.begin = entry.end }
    }

    func startBeats(at time: CFTimeInterval) -> Bool {
        let bass = ShellSpectrumShapeRecipe.bass(ShellSpectrumShapeRecipe.resample(spectrum.bands.current))
        guard bass > ShellSpectrumShapeStore.beatThreshold else {
            spectrum.armed = true
            return false
        }
        guard spectrum.armed else { return false }
        spectrum.armed = false
        guard spectrum.motion.animationsEnabled else { return false }
        var started = false
        for (slot, var entry) in shapeTracks.entries where entry.morph.beat && entry.carrier == nil {
            guard let reveal = presence.reveals[slot] else { continue }
            let spring = ShellMorphRecipe.Spring(response: reveal.response, bounce: reveal.bounce).parameters
            entry.plan = ShellReveal(begin: time, progress: 0, target: 1, spring: spring)
            entry.begin = time
            entry.dirty = true
            replanShapeImpulses(&entry, from: nil, at: time)
            shapeTracks.entries[slot] = entry
            started = true
        }
        return started
    }

    private func shapeTriggerSource(_ key: UInt64) -> (key: Int32, value: ShellShapeTrackEntry)? {
        var selected: (key: Int32, value: ShellShapeTrackEntry)?
        for candidate in shapeTracks.entries where candidate.value.identity?.key == key {
            if let selected {
                if selected.value.carrier == nil, candidate.value.carrier != nil { continue }
                if (selected.value.carrier == nil) == (candidate.value.carrier == nil),
                   candidate.value.generation <= selected.value.generation { continue }
            }
            selected = candidate
        }
        return selected
    }

    func shapeRevealAnimations(
        _ shape: ShellGlassShape, recipe: ShellMorphRecipe, plan: ShellReveal, closing: Bool
    ) -> (items: [ShellRevealAnimation], union: CGRect)? {
        guard let parent = parents[shape.slot], let body = glassBodies[parent] else { return nil }
        if !closing, let entry = shapeTracks.entries[shape.slot] { return (entry.animations, entry.union) }
        let old = shapeTracks.entries[shape.slot]
        let begin = plan.begin
        var entry = ShellShapeTrackEntry(
            body: parent, identity: presence.identities[shape.slot],
            base: old?.base ?? ShellShapeBaseMotion(from: shape, to: shape, begin: begin),
            morph: recipe, plan: plan, begin: begin
        )
        replanShapeImpulses(&entry, from: old, at: begin)
        let built = body.trackAnimations(entry.samples, begin: begin, duration: entry.duration, closing: closing)
        return (built.items + (closing ? closingPathTrackAnimations(entry) : []), built.union)
    }
}
