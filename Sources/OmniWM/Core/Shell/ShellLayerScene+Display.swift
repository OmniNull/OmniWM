// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellLayerScene {
    func updateBackingScale(_ next: CGFloat) {
        guard next != scale else { return }
        scale = next
        let retiring = Set(presence.retained.values.map { ObjectIdentifier($0.subtree) })
        func update(_ layer: CALayer) {
            guard !retiring.contains(ObjectIdentifier(layer)) else { return }
            layer.contentsScale = next
            if let mask = layer.mask { update(mask) }
            for child in layer.sublayers ?? [] { update(child) }
        }
        update(container)
        for effect in effects.values {
            update(effect.source)
            effect.updateBackingScale(next)
        }
        for wrapper in gestureLayers.values where wrapper.layer.borderWidth > 0 {
            wrapper.layer.borderWidth = 1 / next
        }
        shaders?.updateBackingScale(next)
    }
}
