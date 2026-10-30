// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

final class ShellGlassComposition {
    let layer = CALayer()
    let tone = CALayer()
    let alpha = CAGradientLayer()
    private let fill: CALayer

    var canvasLayers: [CALayer] {
        [layer, tone, alpha]
    }

    init(fill: CALayer, band: CALayer) {
        self.fill = fill
        for target in canvasLayers {
            target.anchorPoint = .zero
            ShellGlassBody.followGeometry(target, fill)
        }
        fill.removeFromSuperlayer()
        layer.mask = fill
        layer.addSublayer(tone)
        layer.addSublayer(band)
    }

    func update(tint: CGColor, colors: [CGColor], material: CAGradientLayer?, coverage: CALayer) -> CGColor {
        tone.isHidden = material != nil
        if let material {
            material.mask = nil
            material.colors = colors.map { $0.copy(alpha: 1)! }
            if material.superlayer !== layer { layer.insertSublayer(material, at: 1) }
            let opacity = colors.first?.alpha ?? 1
            if colors.allSatisfy({ $0.alpha == opacity }) {
                layer.opacity = Float(opacity)
                mask(with: coverage)
            } else {
                layer.opacity = 1
                alpha.colors = colors.map { CGColor(gray: 1, alpha: $0.alpha) }
                mask(with: alpha, source: coverage)
            }
            if fill.superlayer !== layer { layer.addSublayer(fill) }
            return ShellLayerScene.clear
        }
        fill.removeFromSuperlayer()
        tone.backgroundColor = tint.copy(alpha: 1)
        layer.opacity = Float(tint.alpha)
        mask(with: fill)
        return CGColor(gray: 1, alpha: 1)
    }

    func restore(in parent: CALayer, material: CALayer?, coverage: CALayer, above shadow: CALayer) {
        layer.mask = nil
        alpha.mask = nil
        if let gradient = material as? CAGradientLayer {
            gradient.removeFromSuperlayer()
            gradient.mask = coverage
            parent.insertSublayer(gradient, above: shadow)
        }
        fill.removeFromSuperlayer()
        parent.insertSublayer(fill, above: material ?? shadow)
        layer.removeFromSuperlayer()
    }

    func releaseCoverage(_ coverage: CALayer) {
        if layer.mask === coverage { layer.mask = nil }
        if alpha.mask === coverage { alpha.mask = nil }
    }

    private func mask(with target: CALayer, source: CALayer? = nil) {
        guard layer.mask !== target else { return }
        layer.mask = nil
        alpha.mask = nil
        if target === alpha {
            let source = source ?? fill
            ShellGlassBody.followGeometry(alpha, source)
            alpha.mask = source
        }
        layer.mask = target
    }
}
