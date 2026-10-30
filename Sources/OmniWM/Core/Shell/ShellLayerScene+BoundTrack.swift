// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

private struct ShellPulseTiming {
    let revision: UInt64
    let begin: CFTimeInterval
    let time: CFTimeInterval
    let spring: ShellSpringDynamics.Parameters
    let animates: Bool
}

extension ShellLayerScene {
    func prepareBoundTracks() {
        for (slot, input) in shapeTracks.pendingBounds {
            guard var entry = shapeTracks.entries[slot], let source = entry.morph.source else { continue }
            if let old = entry.bound, old.source == source, old.input.matches(input), !entry.dirty { continue }
            let previous = entry.bound?.state(at: input.time).progress
            shapeTracks.generation &+= 1
            let bound = ShellBoundTrack(
                input: input,
                source: source,
                previous: previous,
                revision: shapeTracks.generation
            )
            entry.bound = bound
            if entry.carrier == nil { entry.begin = input.time }
            if entry.base.duration == 0 {
                entry.base = ShellShapeBaseMotion(from: entry.base.target, to: entry.base.target, begin: input.time)
            }
            entry.dirty = true
            let carried = entry.impulses.compactMap { $0.carrying(at: input.time) }
            let scheduled = input.animates && entry.carrier == nil ? entry.morph.impulses.flatMap { impulse in
                let opening = bound.plan.target >= bound.plan.progress
                guard impulse.phase == .both || impulse.phase == .open && opening || impulse.phase == .close && !opening
                else { return [ShellShapeImpulse]() }
                let times = impulse.kind == .after ? [input.time + impulse.time]
                    : bound.crossings(at: impulse.time, rising: impulse.rising)
                return times.filter { $0 > input.time || bound.plan.duration == 0 }.map {
                    ShellShapeImpulse(impulse, begin: $0)
                }
            } : []
            entry.impulses = input.animates ? carried + scheduled : []
            shapeTracks.entries[slot] = entry
        }
        shapeTracks.pendingBounds.removeAll(keepingCapacity: true)
    }

    func resolveBoundTrigger(_ entry: inout ShellShapeTrackEntry, from bound: ShellBoundTrack) {
        resolvePulseTrigger(
            &entry, contact: { bound.contact(at: $0, on: $1) }, timing: ShellPulseTiming(
                revision: bound.revision, begin: bound.plan.begin, time: bound.input.time,
                spring: bound.plan.spring, animates: bound.input.animates
            ), crossings: { trigger, now in
                bound.crossings(at: trigger.at, rising: trigger.rising).filter { $0 >= now }
            }
        )
    }

    func resolvePlannedTrigger(_ entry: inout ShellShapeTrackEntry, from source: ShellShapeTrackEntry, animated: Bool) {
        guard let revision = source.triggerRevision else { return }
        let begin = source.triggerBegin ?? source.begin
        let spring = source.triggerPlans.first?.spring
            ?? ShellMorphRecipe.Spring(response: 0.35, bounce: 0.15).parameters
        resolvePulseTrigger(
            &entry, timing: ShellPulseTiming(
                revision: revision, begin: begin, time: begin, spring: spring, animates: animated
            )
        ) { trigger, now in
            source.triggerPlans.flatMap { $0.crossings(at: trigger.at, rising: trigger.rising) }.filter { $0 >= now }
        }
    }

    private func resolvePulseTrigger(
        _ entry: inout ShellShapeTrackEntry,
        contact: (CFTimeInterval, ShellGlassShape) -> ShellShapeContact? = { _, _ in nil },
        timing: ShellPulseTiming,
        crossings: (ShellMorphRecipe.Trigger, CFTimeInterval) -> [CFTimeInterval]
    ) {
        guard entry.triggerRevision != timing.revision, let trigger = entry.morph.trigger else { return }
        let now = entry.triggerRevision == nil && entry.triggerBegin != nil
            ? max(timing.time, entry.begin) : timing.time
        let carried = entry.triggerPlans.last { $0.begin <= now } ?? entry.plan.flatMap { $0.begin <= now ? $0 : nil }
        let spring = presence.reveals[entry.base.target.slot].map {
            ShellMorphRecipe.Spring(response: $0.response, bounce: $0.bounce).parameters
        } ?? timing.spring
        let starts = Set(crossings(trigger, now)).filter { time in
            carried.map { abs($0.begin - time) > 1e-9 } ?? true
        }.sorted()
        let plans = (carried.map { [$0] } ?? []) + starts.map {
            ShellReveal(
                begin: $0, progress: 0, target: 1, spring: spring, duration: timing.animates ? nil : 0,
                contact: trigger.contact ? contact($0, entry.base.state(at: $0).shape) : nil
            )
        }
        entry.triggerRevision = timing.revision
        entry.triggerBegin = timing.begin
        if timing.animates, entry.plan == nil, entry.triggerPlans == plans { return }
        entry.triggerPlans = plans
        entry.plan = nil
        entry.begin = now
        if entry.base.duration == 0 {
            entry.base = ShellShapeBaseMotion(from: entry.base.target, to: entry.base.target, begin: now)
        }
        entry.dirty = true
        if timing.animates { replanPulseImpulses(&entry, at: now) }
        else { entry.impulses = [] }
    }

    func replanPulseImpulses(_ entry: inout ShellShapeTrackEntry, at time: CFTimeInterval) {
        let carried = entry.impulses.filter { $0.begin < time && $0.end > time }
        let future = entry.triggerPlans.flatMap {
            ShellShapeImpulse.scheduled(entry.morph.impulses, on: $0, commit: $0.begin)
        }.filter { $0.begin >= time }
        entry.impulses = carried + future
    }
}
