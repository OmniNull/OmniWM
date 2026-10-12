// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class HiddenBarDrawerCompletion: NSObject, CAAnimationDelegate {
    private weak var drawer: HiddenBarDrawerView?
    private let generation: UInt64

    init(drawer: HiddenBarDrawerView, generation: UInt64) {
        self.drawer = drawer
        self.generation = generation
    }

    nonisolated func animationDidStop(_: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        Task { @MainActor [self] in
            drawer?.complete(generation: generation)
        }
    }
}

@MainActor
final class HiddenBarDrawerView: NSView {
    static let opening = CubicConfig(
        duration: 0.22, controlPoint1: CGPoint(x: 0.33, y: 1), controlPoint2: CGPoint(x: 0.68, y: 1)
    )
    static let fadingIn = CubicConfig(
        duration: 0.12, controlPoint1: CGPoint(x: 0, y: 0), controlPoint2: CGPoint(x: 0.58, y: 1)
    )
    static let closing = CubicConfig(
        duration: 0.15, controlPoint1: CGPoint(x: 0.32, y: 0), controlPoint2: CGPoint(x: 0.67, y: 0)
    )

    private(set) var generation: UInt64 = 0
    private var completion: (@MainActor () -> Void)?
    private let revealMask = CAShapeLayer()

    init(contentView: NSView) {
        super.init(frame: contentView.frame)
        wantsLayer = true
        layer?.masksToBounds = true
        revealMask.anchorPoint = .zero
        revealMask.fillColor = NSColor.white.cgColor
        revealMask.strokeColor = NSColor.white.cgColor
        revealMask.lineJoin = .round
        layer?.mask = revealMask
        setRevealShape(CGPath(rect: bounds, transform: nil), spread: 0)
        contentView.wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        contentView.frame = bounds
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRevealShape(_ contour: CGPath, spread: CGFloat) {
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        let path = layer?.isGeometryFlipped == true ? contour : contour.copy(using: &flip) ?? contour
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.bounds = bounds
        revealMask.path = path
        revealMask.lineWidth = spread * 2
        CATransaction.commit()
    }

    func containsContent(at point: CGPoint) -> Bool {
        revealMask.path?.contains(convertToLayer(point)) == true
    }

    func setVisible(
        _ visible: Bool,
        edge: PopupAttachment.Edge,
        motion: MotionSnapshot,
        completion: (@MainActor () -> Void)? = nil
    ) {
        generation &+= 1
        self.completion = completion
        guard let layer else {
            complete(generation: generation)
            return
        }
        let fromPosition = revealMask.animation(forKey: "hiddenBar.reveal") == nil
            ? revealMask.position : revealMask.presentation()?.position ?? revealMask.position
        let fromOpacity = layer.animation(forKey: "hiddenBar.fade") == nil
            ? layer.opacity : layer.presentation()?.opacity ?? layer.opacity
        let position = visible
            ? CGPoint.zero
            : Self.collapsedOffset(edge: edge, size: bounds.size, flipped: layer.isGeometryFlipped)
        let opacity: Float = visible ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.position = position
        layer.opacity = opacity
        revealMask.removeAnimation(forKey: "hiddenBar.reveal")
        layer.removeAnimation(forKey: "hiddenBar.fade")
        if motion.animationsEnabled {
            let travel = motion.scaled(visible ? Self.opening : Self.closing)
            let fading = motion.scaled(visible ? Self.fadingIn : Self.closing)
            let reveal = CABasicAnimation(keyPath: "position")
            reveal.fromValue = fromPosition
            reveal.toValue = position
            reveal.duration = travel.duration
            reveal.timingFunction = Self.timingFunction(travel)
            reveal.delegate = HiddenBarDrawerCompletion(drawer: self, generation: generation)
            revealMask.add(reveal, forKey: "hiddenBar.reveal")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = opacity
            fade.duration = fading.duration
            fade.timingFunction = Self.timingFunction(fading)
            layer.add(fade, forKey: "hiddenBar.fade")
        }
        CATransaction.commit()
        if !motion.animationsEnabled {
            complete(generation: generation)
        }
    }

    func complete(generation: UInt64) {
        guard generation == self.generation else { return }
        let completion = completion
        self.completion = nil
        completion?()
    }

    nonisolated static func collapsedOffset(edge: PopupAttachment.Edge, size: CGSize, flipped: Bool) -> CGPoint {
        switch edge {
        case .above: CGPoint(x: 0, y: flipped ? size.height : -size.height)
        case .below: CGPoint(x: 0, y: flipped ? -size.height : size.height)
        case .left: CGPoint(x: size.width, y: 0)
        case .right: CGPoint(x: -size.width, y: 0)
        }
    }

    private static func timingFunction(_ config: CubicConfig) -> CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(config.controlPoint1.x), Float(config.controlPoint1.y),
            Float(config.controlPoint2.x), Float(config.controlPoint2.y)
        )
    }
}
