// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellPulseRecipe {
    static let channels = ["rotate", "scale", "dx", "dy"]
    static let animationKeys = channels.map { "omni.pulse.\($0)" }

    func animations(size: CGSize) -> [(key: String, animation: CAKeyframeAnimation)] {
        let center = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        let origin = CATransform3DInvert(center)
        return zip(Self.channels, [rotate, scale, dx, dy]).compactMap { channel, samples in
            guard !samples.isEmpty else { return nil }
            let transform = channel == "rotate" || channel == "scale"
            let animation =
                CAKeyframeAnimation(keyPath: transform ? "transform" : "position.\(channel == "dx" ? "x" : "y")")
            animation.values = transform ? samples.map { sample in
                let delta = channel == "rotate"
                    ? CATransform3DMakeRotation(sample * .pi / 180, 0, 0, 1)
                    : CATransform3DMakeScale(1 + sample, 1 + sample, 1)
                return NSValue(caTransform3D: CATransform3DConcat(
                    CATransform3DConcat(origin, delta), center
                ))
            } : samples.map { NSNumber(value: $0) }
            animation.duration = duration
            animation.isAdditive = true
            animation.calculationMode = .linear
            return ("omni.pulse.\(channel)", animation)
        }
    }
}

extension ShellLayerScene {
    func applyPulse(_ slot: Int32, _ pulse: ShellPulseRecipe?, to layer: CALayer, size: CGSize, animated: Bool) {
        guard let pulse else {
            if pulseKeys.removeValue(forKey: slot) != nil { Self.removePulse(from: layer) }
            return
        }
        let changed = pulseKeys[slot] != pulse.key
        pulseKeys[slot] = pulse.key
        guard animated else {
            Self.removePulse(from: layer)
            return
        }
        guard changed else { return }
        Self.removePulse(from: layer)
        let begin = layer.convertTime(now(), from: nil)
        for (key, animation) in pulse.animations(size: size) {
            animation.beginTime = begin
            layer.add(animation, forKey: key)
        }
    }

    func forgetPulse(_ slot: Int32) {
        pulseKeys.removeValue(forKey: slot)
        if let layer = layers[slot] { Self.removePulse(from: layer) }
    }

    func flushPulses() {
        for slot in pulseKeys.keys {
            guard let layer = layers[slot], let keys = layer.animationKeys(),
                  let first = keys.firstIndex(where: { ShellPulseRecipe.animationKeys.contains($0) }),
                  keys[first...].contains(where: { !ShellPulseRecipe.animationKeys.contains($0) })
            else { continue }
            for key in ShellPulseRecipe.animationKeys {
                guard let animation = layer.animation(forKey: key) else { continue }
                layer.removeAnimation(forKey: key)
                layer.add(animation, forKey: key)
            }
        }
    }

    private static func removePulse(from layer: CALayer) {
        for key in ShellPulseRecipe.animationKeys { layer.removeAnimation(forKey: key) }
    }
}
