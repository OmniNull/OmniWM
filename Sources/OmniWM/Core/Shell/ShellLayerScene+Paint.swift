// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
import OmniWMShellCore
import QuartzCore

extension ShellLayerScene {
    func applyValue(
        _ slot: Int32,
        _ fraction: CGFloat,
        color: CGColor,
        track: CGColor?,
        animation: ShellAnimation?
    ) {
        guard let entry = progress[slot] else { return }
        entry.track?.backgroundColor = track
        if let animation {
            add(
                animation,
                to: entry.fill,
                "backgroundColor",
                from: (entry.fill.presentation() ?? entry.fill).backgroundColor,
                to: color,
                changed: !Self.same(entry.fill.backgroundColor, color)
            )
        }
        progress[slot]?.fraction = fraction
        entry.fill.backgroundColor = color
        layoutProgress(slot, animation: animation)
    }

    func applyPaint(_ slot: Int32, _ paint: ShellLayerPaint, preset: ShellAnimation?, animated: Bool) {
        guard let layer = layers[slot] else { return }
        setPresence(slot, appear: paint.appear, exit: paint.exit)
        applyMaterial(slot, paint, to: layer)
        let fill = paint.material > 0 ? nil : paint.fill
        exitAnimations[slot] = preset
        let animation = framedAnimation(preset, slot, animated)
        if let animation {
            animatePaint(animation, of: layer, slot: slot, to: paint, fill: fill)
        }
        scales[slot] = paint.scale == 1 ? nil : paint.scale
        rotations[slot] = paint.rotation == 0 ? nil : paint.rotation
        if paint.quarter != quarters.contains(slot) {
            if paint.quarter {
                quarters.insert(slot)
            } else {
                quarters.remove(slot)
            }
            layer.bounds.size = CGSize(width: layer.bounds.height, height: layer.bounds.width)
        }
        layer.shadowColor = paint.shadow
        layer.shadowOpacity = paint.shadow == nil ? 0 : 1
        layer.shadowRadius = paint.shadowRadius
        layer.shadowOffset = .zero
        applyScale(slot, to: layer)
        applyLoop(slot, paint.loop, to: layer)
        playbackSettings[slot] = paint.playback
        updatePlayback(slot, contentsReplaced: false)
        applyFill(fill, paint, to: layer, animation: animation)
        layer.opacity = paint.opacity
        layoutProgress(slot, animation: nil)
        layoutMaterial(slot, in: layer)
        if paint.enter != enters[slot] {
            enters[slot] = paint.enter
            applyEnter(slot, to: layer)
        }
        if bitmaps.contains(slot) {
            layer.masksToBounds = paint.radius > 0
        }
        if maskable.contains(slot), paint.masks != (masks[slot] != nil) {
            setMask(paint.masks, slot: slot, layer: layer)
        }
    }

    private func applyFill(_ fill: CGColor?, _ paint: ShellLayerPaint, to layer: CALayer, animation: ShellAnimation?) {
        if let shape = layer as? CAShapeLayer {
            if let animation {
                let from = shape.presentation() ?? shape
                add(
                    animation,
                    to: shape,
                    "fillColor",
                    from: from.fillColor ?? Self.clear,
                    to: fill ?? Self.clear,
                    changed: !Self.same(shape.fillColor, fill)
                )
                add(
                    animation,
                    to: shape,
                    "strokeColor",
                    from: from.strokeColor ?? Self.clear,
                    to: paint.border ?? Self.clear,
                    changed: !Self.same(shape.strokeColor, paint.border)
                )
            }
            shape.fillColor = fill ?? Self.clear
            shape.strokeColor = paint.border
            shape.lineWidth = paint.borderWidth
        } else {
            let fading = animation != nil
            layer.backgroundColor = fill ?? (fading ? Self.clear : nil)
            layer.borderColor = paint.border ?? Self.clear
            layer.borderWidth = paint.borderWidth
            layer.cornerRadius = paint.radius
        }
    }

    private func animatePaint(
        _ animation: ShellAnimation,
        of layer: CALayer,
        slot: Int32,
        to paint: ShellLayerPaint,
        fill: CGColor?
    ) {
        let from = layer.presentation() ?? layer
        add(
            animation,
            to: layer,
            "backgroundColor",
            from: from.backgroundColor ?? Self.clear,
            to: fill ?? Self.clear,
            changed: !Self.same(layer.backgroundColor, fill)
        )
        animateOutline(animation, of: layer, from: from, to: paint)
        add(
            animation,
            to: layer,
            "opacity",
            from: from.opacity,
            to: paint.opacity,
            changed: layer.opacity != paint.opacity
        )
        add(
            animation,
            to: layer,
            "shadowOpacity",
            from: from.shadowOpacity,
            to: paint.shadow == nil ? 0 : 1,
            changed: layer.shadowOpacity != (paint.shadow == nil ? 0 : 1)
        )
        let finalSize = paint.frameSize.map { paint.quarter ? CGSize(width: $0.height, height: $0.width) : $0 }
            ?? (paint.quarter == quarters.contains(slot) ? layer.bounds.size : CGSize(
                width: layer.bounds.height,
                height: layer.bounds.width
            ))
        add(
            animation,
            to: layer,
            "transform",
            from: NSValue(caTransform3D: from.transform),
            to: NSValue(caTransform3D: Self.scaleTransform(
                scale: paint.scale, rotation: paint.rotation,
                size: finalSize,
                quarter: paint.quarter
            )),
            changed: (scales[slot] ?? 1) != paint.scale || (rotations[slot] ?? 0) != paint.rotation
        )
    }

    private func animateOutline(
        _ animation: ShellAnimation, of layer: CALayer, from: CALayer, to paint: ShellLayerPaint
    ) {
        add(
            animation,
            to: layer,
            "borderColor",
            from: from.borderColor ?? Self.clear,
            to: paint.border ?? Self.clear,
            changed: !Self.same(layer.borderColor, paint.border)
        )
        add(
            animation,
            to: layer,
            "borderWidth",
            from: from.borderWidth,
            to: paint.borderWidth,
            changed: layer.borderWidth != paint.borderWidth
        )
        add(
            animation,
            to: layer,
            "cornerRadius",
            from: from.cornerRadius,
            to: paint.radius,
            changed: layer.cornerRadius != paint.radius
        )
    }

    private static let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type

    private static let filterClass = NSClassFromString("CAFilter") as? NSObject.Type

    private static let blurRadii: [CGFloat] = [0, 8, 14, 20, 28, 36, 20]
    private static let filterInputsKey = "omniwmFilterInputs"

    private func applyMaterial(_ slot: Int32, _ paint: ShellLayerPaint, to layer: CALayer) {
        guard paint.material > 0 else {
            if let entry = backdrops.removeValue(forKey: slot) {
                entry.backdrop.removeFromSuperlayer()
                entry.tint.removeFromSuperlayer()
            }
            return
        }
        let entry = backdrops[slot] ?? makeBackdrop(in: layer)
        backdrops[slot] = entry
        let radius = paint.blurRadius >= 0
            ? paint.blurRadius : Self.blurRadii[min(Int(paint.material), Self.blurRadii.count - 1)]
        let inputs = [radius, paint.saturation]
        if entry.backdrop.value(forKey: Self.filterInputsKey) as? [CGFloat] != inputs {
            entry.backdrop.setValue(inputs, forKey: Self.filterInputsKey)
            entry.backdrop.filters = [
                Self.filter("gaussianBlur", "inputRadius", radius),
                Self.filter("colorSaturate", "inputAmount", paint.saturation)
            ].compactMap(\.self)
        }
        entry.tint.backgroundColor = paint.fill
    }

    private func makeBackdrop(in layer: CALayer) -> (backdrop: CALayer, tint: CALayer) {
        let backdrop = Self.backdropClass?.init() ?? CALayer()
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.anchorPoint = .zero
        backdrop.zPosition = -2
        backdrop.masksToBounds = true
        let tint = CALayer()
        tint.anchorPoint = .zero
        tint.zPosition = -1
        layer.addSublayer(backdrop)
        layer.addSublayer(tint)
        return (backdrop, tint)
    }

    func layoutMaterial(_ slot: Int32, in layer: CALayer) {
        guard let entry = backdrops[slot] else { return }
        for part in [entry.backdrop, entry.tint] {
            part.frame = layer.bounds
            part.cornerRadius = layer.cornerRadius
            part.cornerCurve = layer.cornerCurve
        }
    }

    private static func filter(_ type: String, _ key: String, _ value: CGFloat) -> NSObject? {
        guard let filter = filterClass?
            .perform(NSSelectorFromString("filterWithType:"), with: type)?
            .takeUnretainedValue() as? NSObject
        else {
            return nil
        }
        filter.setValue(value, forKey: key)
        return filter
    }

    private func layoutSlider(_ entry: Progress, in bounds: CGRect, track: CALayer, knob: CALayer) {
        let thickness = min(4, bounds.height)
        let middle = (bounds.height - thickness) / 2
        let side = bounds.height
        let offset = max(bounds.width - side, 0) * min(max(entry.fraction, 0), 1)
        track.frame = CGRect(x: 0, y: middle, width: bounds.width, height: thickness)
        track.cornerRadius = thickness / 2
        entry.fill.frame = CGRect(x: 0, y: middle, width: offset + side / 2, height: thickness)
        entry.fill.cornerRadius = thickness / 2
        knob.frame = CGRect(x: offset, y: 0, width: side, height: side)
        knob.cornerRadius = side / 2
    }

    func applyScale(_ slot: Int32, to layer: CALayer) {
        layer.transform = Self.scaleTransform(
            scale: scales[slot] ?? 1,
            rotation: rotations[slot] ?? 0,
            size: layer.bounds.size,
            quarter: quarters.contains(slot)
        )
    }

    private static func scaleTransform(
        scale: CGFloat,
        rotation: CGFloat,
        size: CGSize,
        quarter: Bool
    ) -> CATransform3D {
        guard scale != 1 || rotation != 0 else { return CATransform3DIdentity }
        let frame = quarter ? CGSize(width: size.height, height: size.width) : size
        var transform = CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(rotation, 0, 0, 1))
        return CATransform3DConcat(
            transform,
            CATransform3DMakeTranslation(frame.width / 2, frame.height / 2, 0)
        )
    }

    func applyLoop(_ slot: Int32, _ loop: ShellLoop?, to layer: CALayer) {
        let size = layer.bounds.size
        guard let current = loops[slot] else {
            if loop != nil {
                startLoop(slot, loop, on: layer, size: size)
            }
            return
        }
        guard current.loop != loop || current.size != size else { return }
        startLoop(slot, loop, on: layer, size: size)
    }

    private func startLoop(_ slot: Int32, _ loop: ShellLoop?, on layer: CALayer, size: CGSize) {
        for key in ShellLoop.keys {
            layer.removeAnimation(forKey: key)
        }
        guard let loop else {
            loops[slot] = nil
            return
        }
        loops[slot] = (loop, size)
        for (key, animation) in loop.animations(size: size) {
            layer.add(animation, forKey: key)
        }
    }

    func updatePlayback(_ slot: Int32, contentsReplaced: Bool) {
        guard let layer = layers[slot] else { return }
        let frames = imageFrames[slot].flatMap { $0.animated ? $0 : nil }
        let playback = frames == nil ? nil : playbackSettings[slot]
        let current = playbacks[slot]
        if let current, current.frames === frames, current.playback == playback {
            if contentsReplaced, current.playback.paused {
                layer.contents = current.frames.frame(at: current.phase)
            }
            return
        }
        layer.removeAnimation(forKey: Self.framesKey)
        guard let frames, let playback else {
            playbacks[slot] = nil
            return
        }
        let now = CACurrentMediaTime()
        let phase = (current.flatMap { $0.frames === frames ? $0.phase(at: now) : nil } ?? 0)
            .truncatingRemainder(dividingBy: frames.duration)
        playbacks[slot] = ShellPlaybackState(frames: frames, phase: phase, start: now, playback: playback)
        if playback.paused || playback.speed <= 0 {
            layer.contents = frames.frame(at: phase)
        } else {
            layer.add(frames.animation(playback, phase: phase), forKey: Self.framesKey)
        }
    }

    func layoutProgress(_ slot: Int32, animation: ShellAnimation?) {
        guard let entry = progress[slot], let layer = layers[slot] else { return }
        if let track = entry.track, let knob = entry.knob {
            layoutSlider(entry, in: layer.bounds, track: track, knob: knob)
            return
        }
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: layer.bounds.width * min(max(entry.fraction, 0), 1),
            height: layer.bounds.height
        )
        if let animation {
            add(
                animation,
                to: entry.fill,
                "bounds",
                from: NSValue(rect: (entry.fill.presentation() ?? entry.fill).bounds),
                to: NSValue(rect: bounds),
                changed: entry.fill.bounds != bounds
            )
        }
        entry.fill.cornerRadius = layer.cornerRadius
        entry.fill.bounds = bounds
    }
}
