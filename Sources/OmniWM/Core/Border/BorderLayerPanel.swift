// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMLayerCorners
import QuartzCore

@MainActor
class BorderLayerPanel: NSPanel {
    let borderLayer = CALayer()
    private let containerLayer = CALayer()
    private let effects = BorderEffectLayers()
    var glowColorLayer: CAGradientLayer {
        effects.glowColorLayer
    }

    var glowMaskLayer: CALayer {
        effects.glowMaskLayer
    }

    var gradientStrokeLayer: CAGradientLayer {
        effects.gradientStrokeLayer
    }

    var gradientRingMaskLayer: CAShapeLayer {
        effects.gradientRingMaskLayer
    }

    init?(frame: CGRect) {
        guard omniwm_layer_border_available() else { return nil }
        super.init(
            contentRect: frame.integral,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isRestorable = false

        let view = NSView(frame: CGRect(origin: .zero, size: frame.integral.size))
        view.wantsLayer = true
        borderLayer.cornerCurve = .continuous
        borderLayer.rimOpacity = 0
        borderLayer.actions = [
            "rimWidth": NSNull(), "rimColor": NSNull(), "rimOpacity": NSNull(), "cornerRadii": NSNull(),
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull()
        ]
        containerLayer.actions = ["hidden": NSNull()]
        containerLayer.addSublayer(effects.root)
        containerLayer.addSublayer(borderLayer)
        view.layer = containerLayer
        contentView = view
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    func applyFrame(targetFrame: CGRect, surfaceFrame: CGRect) {
        let panelFrame = surfaceFrame.integral
        let layerFrame = targetFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        let effectsFrame = surfaceFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        guard frame != panelFrame || borderLayer.frame != layerFrame
            || effects.root.frame != effectsFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != panelFrame {
            setFrame(panelFrame, display: false)
        }
        if borderLayer.frame != layerFrame {
            borderLayer.frame = layerFrame
        }
        if effects.root.frame != effectsFrame {
            effects.root.frame = effectsFrame
        }
        CATransaction.commit()
    }

    func updateBorder(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        color: CGColor,
        scale: CGFloat
    ) {
        let radii = cornerRadii.normalized(to: geometry.targetFrame.size)
        let nativeRadii = CACornerRadii(
            topLeft: CGSize(width: radii.topLeft, height: radii.topLeft),
            topRight: CGSize(width: radii.topRight, height: radii.topRight),
            bottomRight: CGSize(width: radii.bottomRight, height: radii.bottomRight),
            bottomLeft: CGSize(width: radii.bottomLeft, height: radii.bottomLeft)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if containerLayer.contentsScale != scale { containerLayer.contentsScale = scale }
        if borderLayer.contentsScale != scale { borderLayer.contentsScale = scale }
        if borderLayer.rimWidth != geometry.width { borderLayer.rimWidth = geometry.width }
        if borderLayer.rimColor != color { borderLayer.rimColor = color }
        let currentRadii = borderLayer.cornerRadii
        if currentRadii.topLeft != nativeRadii.topLeft || currentRadii.topRight != nativeRadii.topRight
            || currentRadii.bottomRight != nativeRadii.bottomRight || currentRadii.bottomLeft != nativeRadii.bottomLeft
        {
            borderLayer.cornerRadii = nativeRadii
        }
        CATransaction.commit()
    }
}

extension BorderLayerPanel {
    func updateEffects(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        config: BorderConfig,
        baseColor: CGColor,
        scale: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effects.updateEffects(
            geometry: geometry,
            cornerRadii: cornerRadii,
            config: config,
            baseColor: baseColor,
            scale: scale,
            drawsSolidStroke: true
        )
        CATransaction.commit()
    }

    static func cgColor(_ color: SettingsColor) -> CGColor {
        BorderEffectLayers.cgColor(color)
    }
}
