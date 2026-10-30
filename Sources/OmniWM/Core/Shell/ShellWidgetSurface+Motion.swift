// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMShellCore

struct ShellPresenceRecipe {
    let source: String
    let opacity: Float
    let scale: CGFloat
    let offset: CGPoint
    let anchor: CGPoint
    let delay: Double
    let inherited: Bool
    let motion: ShellMotion?
    let curve: ShellCurve?

    init?(_ source: String) {
        guard source.utf8.count <= 1536 else { return nil }
        let parts = source.split(separator: ":", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count >= 9, parts[0] == "life",
              let opacity = Float(parts[1]), opacity.isFinite, (0 ... 1).contains(opacity),
              let scale = Double(parts[2]), scale.isFinite, (0 ... 1_000_000).contains(scale),
              let dx = Double(parts[3]), dx.isFinite, abs(dx) <= 1_000_000,
              let dy = Double(parts[4]), dy.isFinite, abs(dy) <= 1_000_000,
              let ax = Double(parts[5]), ax.isFinite, (0 ... 1).contains(ax),
              let ay = Double(parts[6]), ay.isFinite, (0 ... 1).contains(ay),
              let delay = Double(parts[7]), delay.isFinite, (0 ... 2).contains(delay) else { return nil }
        self.source = source
        self.opacity = opacity
        self.scale = scale
        offset = CGPoint(x: dx, y: dy)
        anchor = CGPoint(x: ax, y: ay)
        self.delay = delay
        inherited = parts[8] == "inherit"
        if inherited {
            guard parts.count == 9 else { return nil }
            motion = nil
            curve = nil
        } else {
            guard parts.count == 11, let wire = UInt8(parts[8]), let curveWire = UInt8(parts[9]) else { return nil }
            let payload = String(parts[10])
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
    func reveal(_ reference: UInt32) -> ShellRevealRecipe? {
        guard reference != 0, let text else { return nil }
        return ShellRevealRecipe(text.string(reference))
    }

    func morph(_ reference: UInt32) -> ShellMorphRecipe? {
        guard reference != 0, let text else { return nil }
        return ShellMorphRecipe(text.string(reference))
    }

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
        return ShellPresence(
            opacity: recipe.opacity, scale: recipe.scale, offset: recipe.offset, animation: animation,
            anchor: recipe.anchor, delay: recipe.delay
        )
    }
}
