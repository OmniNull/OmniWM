// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMLayerCorners
import QuartzCore

@MainActor
class BorderLayerPanel: NSPanel {
    let borderLayer = CALayer()
    private(set) var placedFrame: CGRect?
    private var placementIsMoving = false
    private var layerContext: NSObject?
    private var appliedColorSpace: CGColorSpace?
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
        omniwm_window_manager_begin_coordinator_capture()
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

        omniwm_window_manager_end_coordinator_capture()
        borderLayer.cornerCurve = .continuous
        borderLayer.rimOpacity = 1
        borderLayer.actions = [
            "rimWidth": NSNull(), "rimColor": NSNull(), "rimOpacity": NSNull(), "cornerRadii": NSNull(),
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull()
        ]
        containerLayer.actions = ["hidden": NSNull()]
        containerLayer.addSublayer(effects.root)
        containerLayer.addSublayer(borderLayer)
        guard let layerContext = SkyLight.shared.attachLayerContext(
            rootLayer: containerLayer, toWindow: UInt32(windowNumber)
        ) else {
            super.close()
            return nil
        }
        self.layerContext = layerContext
    }

    override func close() {
        if let layerContext {
            omniwm_layer_context_invalidate(layerContext)
            self.layerContext = nil
        }
        super.close()
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

    override func setFrame(_: NSRect, display _: Bool, animate _: Bool) {}

    override func sendEvent(_ event: NSEvent) {
        guard event.isWindowServerMove else {
            super.sendEvent(event)
            return
        }
        if !placementIsMoving { reassertPlacement() }
    }

    func applyFrame(
        targetFrame: CGRect, surfaceFrame: CGRect, displayClip: CGRect? = nil,
        presentation: BorderPresentation? = nil, isMoving: Bool = false
    ) {
        let moving = presentation?.isMoving ?? isMoving
        placementIsMoving = moving
        let stableBacking = (presentation != nil || moving) && displayClip == nil
        let backingFrame = stableBacking ? SurfacePanelGeometry.backingFrame(for: surfaceFrame)
            : displayClip.map { surfaceFrame.integral.intersection($0) } ?? surfaceFrame.integral
        let contentOrigin = stableBacking ? surfaceFrame.origin : backingFrame.origin
        let nextFrame = stableBacking && presentation == nil
            ? CGRect(origin: surfaceFrame.origin, size: backingFrame.size) : backingFrame
        let placed = placedFrame == nextFrame || placeInWindowServer(nextFrame)
        if !placed {
            setFrame(backingFrame, display: false)
            placedFrame = backingFrame
        }
        let origin = placed ? contentOrigin : backingFrame.origin
        let layerFrame = targetFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        let effectsFrame = surfaceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        guard borderLayer.frame != layerFrame || effects.root.frame != effectsFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = layerFrame
        effects.root.frame = effectsFrame
        CATransaction.commit()
    }

    func invalidatePlacement() {
        placedFrame = nil
    }

    func setDisplayColorSpace(_ colorSpace: CGColorSpace?) {
        guard let layerContext, appliedColorSpace !== colorSpace else { return }
        appliedColorSpace = colorSpace
        omniwm_layer_context_set_color_space(layerContext, colorSpace)
    }

    private func reassertPlacement() {
        guard let placedFrame,
              let bounds = SkyLight.shared.currentWindowBounds(UInt32(windowNumber)),
              !bounds.approximatelyEqual(
                  to: ScreenCoordinateSpace.toWindowServer(rect: placedFrame), tolerance: FrameTolerance.frameWrite
              )
        else { return }
        _ = reshapeInWindowServer(to: placedFrame)
    }

    private func placeInWindowServer(_ target: CGRect) -> Bool {
        let placed = windowServerSizeMatches(target.size)
            ? moveInWindowServer(to: target)
            : reshapeInWindowServer(to: target)
        if placed { placedFrame = target }
        return placed
    }

    private func windowServerSizeMatches(_ size: CGSize) -> Bool {
        guard placedFrame?.size == size else { return false }
        return placementIsMoving || SkyLight.shared.currentWindowBounds(UInt32(windowNumber))?.size == size
    }

    func moveInWindowServer(to target: CGRect) -> Bool {
        SkyLight.shared.moveJoiningOpenTransaction(
            UInt32(windowNumber), origin: ScreenCoordinateSpace.toWindowServer(rect: target).origin
        )
    }

    func reshapeInWindowServer(to target: CGRect) -> Bool {
        SkyLight.shared.transactionReshape(
            UInt32(windowNumber), origin: ScreenCoordinateSpace.toWindowServer(rect: target).origin, size: target.size
        )
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
        scale: CGFloat,
        cornerContour: WindowCornerContour? = nil
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effects.updateEffects(
            geometry: geometry,
            cornerRadii: cornerRadii,
            config: config,
            baseColor: baseColor,
            scale: scale,
            cornerContour: cornerContour
        )
        borderLayer.rimOpacity = config.gradient?.enabled == true || cornerContour != nil ? 0 : 1
        CATransaction.commit()
    }

    static func cgColor(_ color: SettingsColor) -> CGColor {
        BorderEffectLayers.cgColor(color)
    }
}
