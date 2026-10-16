// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMShellCore

struct ShellPresenceRecipe {
    let source: String
    let opacity: Float
    let scale: CGFloat
    let offset: CGPoint
    let inherited: Bool
    let motion: ShellMotion?
    let curve: ShellCurve?

    init?(_ source: String) {
        let parts = source.split(separator: ":", maxSplits: 7, omittingEmptySubsequences: false)
        guard parts.count >= 6, parts[0] == "life",
              let opacity = Float(parts[1]), opacity.isFinite, (0 ... 1).contains(opacity),
              let scale = Double(parts[2]), scale.isFinite, (0 ... 1_000_000).contains(scale),
              let dx = Double(parts[3]), dx.isFinite, abs(dx) <= 1_000_000,
              let dy = Double(parts[4]), dy.isFinite, abs(dy) <= 1_000_000 else { return nil }
        self.source = source
        self.opacity = opacity
        self.scale = scale
        offset = CGPoint(x: dx, y: dy)
        inherited = parts[5] == "inherit"
        if inherited {
            guard parts.count == 6 else { return nil }
            motion = nil
            curve = nil
        } else {
            guard parts.count == 8, let wire = UInt8(parts[5]), let curveWire = UInt8(parts[6]) else { return nil }
            let payload = String(parts[7])
            if let spring = ShellMotion(recipe: payload), wire != 0, curveWire == ShellCurve.custom {
                motion = spring
                curve = nil
            } else {
                motion = ShellMotion(wire: wire)
                curve = ShellCurve(wire: curveWire, custom: payload)
            }
        }
    }
}

extension ShellWidgetSurface {
    func presence(_ reference: UInt32, for handle: ElementHandle) -> ShellPresence? {
        guard reference != 0, let text else { return nil }
        let source = text.string(reference)
        if presenceRecipes[reference]?.source != source {
            presenceRecipes[reference] = ShellPresenceRecipe(source)
        }
        guard let recipe = presenceRecipes[reference] else { return nil }
        let animation: ShellAnimation?
        if !motionPolicy.animationsEnabled {
            animation = nil
        } else if recipe.inherited {
            animation = self.animation(for: handle)
                ?? ShellAnimation(motion: .ease(seconds: 0.18), speed: motionPolicy.animationSpeed)
        } else {
            animation = recipe.motion.map {
                ShellAnimation(motion: $0, speed: motionPolicy.animationSpeed, curve: recipe.curve)
            }
        }
        return ShellPresence(opacity: recipe.opacity, scale: recipe.scale, offset: recipe.offset, animation: animation)
    }
}
