// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellGestureLayer {
    let layer: CALayer
    var token: UInt64
    var raised = false
    var generation: UInt64 = 0
    var active = false
    var moving = false

    var zPosition: CGFloat {
        raised || active || moving ? 1 : 0
    }
}

extension ShellLayerScene {
    func displayedLayer(_ slot: Int32) -> CALayer? {
        gestureLayers[slot]?.layer ?? effects[slot]
            .flatMap { $0.output.superlayer == nil ? nil : $0.output } ?? layers[slot]
    }

    func gestureWrapper(_ slot: Int32) -> ShellGestureLayer? {
        guard let content = layers[slot], masks[slot] == nil else { return nil }
        if let existing = gestureLayers[slot] { return existing }
        guard let host = content.superlayer else { return nil }
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.contentsScale = scale
        host.insertSublayer(layer, above: content)
        content.removeFromSuperlayer()
        layer.addSublayer(content)
        let state = ShellGestureLayer(layer: layer, token: 0)
        gestureLayers[slot] = state
        updateGestureCenter(slot)
        return state
    }

    func applyGesture(_ slot: Int32, token: UInt64, value: ShellGestureTransform) {
        guard var state = gestureWrapper(slot) else { return }
        if state.token != token {
            state.token = token
            gestureLayers[slot] = state
            clearGestureAnimations(state.layer)
        }
        state.layer.transform = CATransform3DScale(
            CATransform3DMakeTranslation(value.dx, value.dy, 0),
            value.scale,
            value.scale,
            1
        )
        state.layer.opacity = Float(value.opacity)
    }

    func updateGestureCenter(_ slot: Int32) {
        guard let state = gestureLayers[slot], !state.active, !state.moving, let content = layers[slot] else { return }
        let layer = state.layer
        let size = quarters
            .contains(slot) ? CGSize(width: content.bounds.height, height: content.bounds.width) : content.bounds.size
        let center = CGPoint(x: content.position.x + size.width / 2, y: content.position.y + size.height / 2)
        layer.position = center
        layer.bounds = CGRect(origin: center, size: .zero)
    }

    func settleGesture(_ slot: Int32, token: UInt64, velocity: ShellGestureTransform, animation: ShellAnimation?) {
        guard var state = gestureLayers[slot], state.token == token else { return }
        state.token = 0
        gestureLayers[slot] = state
        let layer = state.layer
        let value = ShellGestureTransform(
            dx: layer.transform.m41,
            dy: layer.transform.m42,
            scale: layer.transform.m11,
            opacity: Double(layer.opacity)
        )
        if let animation {
            animateGestureSettlement(animation, on: layer, from: value, velocity: velocity)
        } else {
            clearGestureAnimations(layer)
        }
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
    }

    private func animateGestureSettlement(
        _ animation: ShellAnimation, on layer: CALayer,
        from value: ShellGestureTransform, velocity: ShellGestureTransform
    ) {
        add(
            animation,
            to: layer,
            "transform.translation.x",
            from: value.dx,
            to: 0,
            changed: value.dx != 0,
            velocity: velocity.dx
        )
        add(
            animation,
            to: layer,
            "transform.translation.y",
            from: value.dy,
            to: 0,
            changed: value.dy != 0,
            velocity: velocity.dy
        )
        add(
            animation,
            to: layer,
            "transform.scale",
            from: value.scale,
            to: 1,
            changed: value.scale != 1,
            velocity: velocity.scale
        )
        add(
            animation,
            to: layer,
            "opacity",
            from: value.opacity,
            to: 1,
            changed: value.opacity != 1,
            velocity: velocity.opacity
        )
    }

    func clearGestureAnimations(_ layer: CALayer) {
        layer.removeAnimation(forKey: "transform.translation.x")
        layer.removeAnimation(forKey: "transform.translation.y")
        layer.removeAnimation(forKey: "transform.scale")
        layer.removeAnimation(forKey: "opacity")
    }
}
