// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellLayerScene {
    func bindSpectrum(_ slot: Int32, shape: ShellGlassShape, content: ShellGlassContent) {
        guard let recipe = ShellSpectrumShapeRecipe(content.recipe) else {
            spectrum.bindings.removeValue(forKey: slot)
            return
        }
        if let binding = spectrum.bindings[slot] {
            binding.base = shape
            binding.recipe = recipe
        } else {
            spectrum.bindings[slot] = ShellSpectrumShapeBinding(base: shape, recipe: recipe)
        }
        setSpectrumMotion(content.spectrumMotion)
    }

    func forgetSpectrum(_ slot: Int32) {
        if glassBodies[slot] != nil {
            spectrum.bindings = spectrum.bindings.filter { $0.value.body != slot }
        } else { spectrum.bindings.removeValue(forKey: slot) }
        scheduleSpectrum()
    }

    func spectrumOwners(in body: Int32) -> Set<Int32> {
        Set(spectrum.bindings.keys.filter { parents[$0] == body })
    }

    func refreshSpectrumTargets(in bodies: Set<Int32>) {
        guard !bodies.isEmpty else { scheduleSpectrum()
            return
        }
        var refreshed = false
        for (slot, binding) in spectrum.bindings {
            guard let parent = parents[slot], bodies.contains(parent), let body = glassBodies[parent] else { continue }
            binding.body = parent
            binding.targets = body.trackLayers(slot)
            refreshed = true
        }
        if refreshed { _ = stepSpectrum(at: CACurrentMediaTime(), refresh: true) }
        scheduleSpectrum()
    }

    func setSpectrumMotion(_ motion: MotionSnapshot) {
        guard spectrum.motion != motion else { return }
        spectrum.motion = motion
        if !motion.animationsEnabled {
            for binding in spectrum.bindings.values {
                for layers in binding.targets.values {
                    for layer in layers {
                        for channel in ShellGlassBody.Channel.geometry { layer.removeAnimation(forKey: channel.key) }
                    }
                }
            }
        }
        _ = stepSpectrum(at: CACurrentMediaTime())
    }

    func setSpectrumVisible(_ visible: Bool) {
        spectrum.visible = visible
        scheduleSpectrum()
    }

    private func scheduleSpectrum() {
        let active = spectrum.automatic && spectrum.visible && !spectrum.bindings.isEmpty
        guard active else {
            spectrum.timer?.cancel()
            spectrum.timer = nil
            return
        }
        guard spectrum.timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: Self.engineQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            _ = stepSpectrum(at: CACurrentMediaTime())
            CATransaction.commit()
        }
        spectrum.timer = timer
        timer.resume()
    }

    @discardableResult
    func stepSpectrum(at time: CFTimeInterval, refresh: Bool = false) -> Int {
        guard spectrum.visible, !spectrum.bindings.isEmpty else { return 0 }
        let bands = ShellSpectrumShapeRecipe.resample(spectrum.bands.current)
        var motions: [ShellSpectrumMotionKey: ShellGlassBody.Motion] = [:]
        var changed = 0
        for binding in spectrum.bindings.values {
            guard let bodySlot = binding.body, let body = glassBodies[bodySlot],
                  !binding.targets.isEmpty else { continue }
            let next = binding.recipe.shape(binding.base, bands: bands)
            if !refresh, let target = binding.target,
               target.rect == next.shape.rect, target.radius == next.shape.radius,
               target.rotation == next.shape.rotation
            {
                continue
            }
            let animates = spectrum.motion.animationsEnabled && next.visible && binding.visible
            let motion: ShellGlassBody.Motion?
            if animates {
                let spring = binding.recipe.spring
                let key = ShellSpectrumMotionKey(body: bodySlot, spring: spring)
                if let cached = motions[key] { motion = cached }
                else {
                    let built = ShellGlassBody.Motion(canvas: ShellAnimation(
                        motion: .spring(response: spring.response, bounce: spring.bounce),
                        speed: spectrum.motion.animationSpeed
                    ), shapes: nil, begin: body.layer.convertTime(time, from: nil))
                    motions[key] = built
                    motion = built
                }
            } else { motion = nil }
            if applySpectrum(next.shape, binding: binding, motion: motion) { changed += 1 }
            binding.target = next.shape
            binding.visible = next.visible
        }
        return changed
    }

    private func applySpectrum(
        _ shape: ShellGlassShape, binding: ShellSpectrumShapeBinding, motion: ShellGlassBody.Motion?
    ) -> Bool {
        var geometry = ShellGlassBody.Geometry(
            rect: shape.rect,
            radius: min(shape.radius, min(shape.rect.width, shape.rect.height) / 2),
            transform: CATransform3DMakeRotation(shape.rotation, 0, 0, 1)
        )
        geometry.position = CGPoint(x: shape.rect.midX, y: shape.rect.midY)
        var changed = false
        for (track, layers) in binding.targets {
            for layer in layers {
                let model = ShellGlassBody.Geometry(layer)
                if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) { layer.anchorPoint = CGPoint(x: 0.5, y: 0.5) }
                if !geometry.matches(model) { changed = true }
                geometry.apply(to: layer, motion: motion, track: track)
            }
        }
        return changed
    }
}

private struct ShellSpectrumMotionKey: Hashable {
    let body: Int32
    let spring: ShellSpectrumShapeRecipe.Spring
}
