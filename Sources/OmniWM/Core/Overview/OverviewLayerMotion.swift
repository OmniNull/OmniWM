// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

enum OverviewLayoutUpdate {
    case preserve
    case immediate
    case structural
    case viewport
}

@MainActor
struct OverviewLayerMotion {
    private let layer: CALayer
    private let position: CGPoint
    private let bounds: CGRect
    private let opacity: Float
    private let modelPosition: CGPoint
    private let modelBounds: CGRect
    private let modelOpacity: Float
    private let response: Double?

    init(_ layer: CALayer, response: Double? = nil) {
        self.layer = layer
        self.response = response
        position = Self.displayedPosition(of: layer)
        bounds = Self.displayedBounds(of: layer)
        opacity = Self.displayedOpacity(of: layer)
        modelPosition = layer.position
        modelBounds = layer.bounds
        modelOpacity = layer.opacity
    }

    func apply(_ transition: OverviewNativeTransition, at time: CFTimeInterval, replacing: Bool) {
        guard time < transition.startTime + transition.duration else {
            Self.remove(from: layer)
            return
        }
        guard replacing || modelPosition != layer.position || modelBounds != layer.bounds || modelOpacity != layer
            .opacity else { return }
        let animation = transition.makeAnimation(keyPath: "", response: response)
        if replacing {
            animation.beginTime = layer.convertTime(transition.startTime, from: nil)
        } else {
            let remaining = transition.startTime + transition.duration - time
            let rate = transition.duration / remaining
            animation.stiffness *= rate * rate
            animation.damping *= rate
            animation.initialVelocity = 0
            animation.duration = remaining
            animation.beginTime = layer.convertTime(time, from: nil)
        }
        if replacing || modelPosition != layer.position {
            add(
                animation,
                keyPath: "position",
                from: NSValue(point: position),
                to: NSValue(point: layer.position),
                changed: position != layer.position
            )
        }
        if replacing || modelBounds != layer.bounds {
            add(
                animation,
                keyPath: "bounds",
                from: NSValue(rect: bounds),
                to: NSValue(rect: layer.bounds),
                changed: bounds != layer.bounds
            )
        }
        if replacing || modelOpacity != layer.opacity {
            add(
                animation,
                keyPath: "opacity",
                from: opacity,
                to: layer.opacity,
                changed: opacity != layer.opacity
            )
        }
    }

    static func remove(from layer: CALayer) {
        for key in ["position", "bounds", "opacity"] { layer.removeAnimation(forKey: "overview.\(key)") }
    }

    static func displayedFrame(of layer: CALayer) -> CGRect {
        let position = displayedPosition(of: layer)
        let bounds = displayedBounds(of: layer)
        return CGRect(
            x: position.x - bounds.width * layer.anchorPoint.x,
            y: position.y - bounds.height * layer.anchorPoint.y,
            width: bounds.width,
            height: bounds.height
        )
    }

    static func displayedBounds(of layer: CALayer) -> CGRect {
        guard let animation = layer.animation(forKey: "overview.bounds") as? CABasicAnimation else {
            return layer.bounds
        }
        return layer.presentation()?.bounds ?? (animation.fromValue as? NSValue)?.rectValue ?? layer.bounds
    }

    static func displayedOpacity(of layer: CALayer, animationKey: String = "overview.opacity") -> Float {
        guard let animation = layer.animation(forKey: animationKey) else {
            return layer.opacity
        }
        return layer.presentation()?.opacity
            ?? ((animation as? CABasicAnimation)?.fromValue as? NSNumber)?.floatValue
            ?? layer.opacity
    }

    private static func displayedPosition(of layer: CALayer) -> CGPoint {
        guard let animation = layer.animation(forKey: "overview.position") as? CABasicAnimation else {
            return layer.position
        }
        return layer.presentation()?.position ?? (animation.fromValue as? NSValue)?.pointValue ?? layer.position
    }

    private func add(
        _ animation: CASpringAnimation,
        keyPath: String,
        from: Any,
        to: Any,
        changed: Bool
    ) {
        let key = "overview.\(keyPath)"
        guard changed else {
            layer.removeAnimation(forKey: key)
            return
        }
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        layer.add(animation, forKey: key)
    }
}
