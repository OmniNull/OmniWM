// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class ParkingEdgeFinWindow: NSPanel {
    private let key: ParkingEdgeMaskKey
    private let surfaceId: String
    private let finView: ParkingEdgeFinView

    init(
        key: ParkingEdgeMaskKey,
        onHoverChange: @escaping @MainActor () -> Void,
        onActivate: @escaping @MainActor () -> Void
    ) {
        self.key = key
        surfaceId = "parking-edge-fin-\(key.monitorId.displayId)-\(key.side.rawValue)"
        finView = ParkingEdgeFinView(side: key.side, onHoverChange: onHoverChange, onActivate: onActivate)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = finView

        if windowNumber > 0 {
            SkyLight.shared.excludeFromScreencaptureWindowSelection(UInt32(windowNumber))
        }

        SurfaceCoordinator.shared.register(
            window: self,
            id: surfaceId,
            policy: SurfacePolicy(
                kind: .parkingEdgeMask,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func show(at point: CGPoint, maskFrame: CGRect, animated: Bool) {
        let targetFrame = Self.frame(at: point, maskFrame: maskFrame, side: key.side)
        guard !targetFrame.isEmpty else {
            hide()
            return
        }
        let wasVisible = isVisible
        if frame != targetFrame {
            setFrame(targetFrame, display: false)
            finView.frame = CGRect(origin: .zero, size: targetFrame.size)
        }
        if !wasVisible {
            orderFrontRegardless()
            finView.reveal(animated: animated)
        }
    }

    func setProgress(duration: CFTimeInterval?) {
        finView.setProgress(duration: duration)
    }

    func contains(_ point: CGPoint) -> Bool {
        isVisible && finView.contains(finView.convert(convertPoint(fromScreen: point), from: nil))
    }

    func hide() {
        finView.reset()
        orderOut(nil)
    }

    func destroy() {
        SurfaceCoordinator.shared.unregister(id: surfaceId)
        hide()
        close()
    }

    static func frame(at point: CGPoint, maskFrame: CGRect, side: ParkingEdgeMaskKey.Side) -> CGRect {
        guard !maskFrame.isEmpty else { return .zero }
        switch side {
        case .left,
             .right:
            let height = min(108, maskFrame.height)
            let y = min(max(point.y - height / 2, maskFrame.minY), maskFrame.maxY - height)
            let x = side == .left ? maskFrame.minX : maskFrame.maxX - 30
            return CGRect(x: x, y: y, width: 30, height: height)
        case .top,
             .bottom:
            let width = min(108, maskFrame.width)
            let x = min(max(point.x - width / 2, maskFrame.minX), maskFrame.maxX - width)
            let y = side == .bottom ? maskFrame.minY : maskFrame.maxY - 30
            return CGRect(x: x, y: y, width: width, height: 30)
        }
    }
}

@MainActor
private final class ParkingEdgeFinView: NSView {
    private let side: ParkingEdgeMaskKey.Side
    private let onHoverChange: @MainActor () -> Void
    private let onActivate: @MainActor () -> Void
    private let fill = CAShapeLayer()
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let arrow = NSImageView()
    private var tracking: NSTrackingArea?

    init(
        side: ParkingEdgeMaskKey.Side,
        onHoverChange: @escaping @MainActor () -> Void,
        onActivate: @escaping @MainActor () -> Void
    ) {
        self.side = side
        self.onHoverChange = onHoverChange
        self.onActivate = onActivate
        super.init(frame: .zero)
        wantsLayer = true

        fill.fillColor = NSColor(srgbRed: 0.082, green: 0.098, blue: 0.118, alpha: 1).cgColor
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.09).cgColor
        track.lineWidth = 1.25
        progress.fillColor = nil
        progress.strokeColor = NSColor.white.withAlphaComponent(0.86).cgColor
        progress.lineWidth = 1.5
        progress.lineCap = .round
        progress.strokeEnd = 0
        for shape in [fill, track, progress] {
            layer?.addSublayer(shape)
        }

        let symbol = switch side {
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .top: "chevron.up"
        case .bottom: "chevron.down"
        }
        arrow.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        arrow.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        arrow.imageScaling = .scaleProportionallyDown
        addSubview(arrow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 1
        for shape in [fill, track, progress] {
            shape.contentsScale = scale
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with _: NSEvent) {
        onHoverChange()
    }

    override func mouseExited(with _: NSEvent) {
        onHoverChange()
    }

    override func mouseMoved(with _: NSEvent) {
        onHoverChange()
    }

    override func mouseDown(with event: NSEvent) {
        guard contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate()
    }

    func contains(_ point: CGPoint) -> Bool {
        fill.path?.contains(point) == true
    }

    func setProgress(duration: CFTimeInterval?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.removeAnimation(forKey: "parkingEdge.dwell")
        progress.strokeEnd = duration == nil ? 0 : 1
        if let duration, duration > 0 {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            progress.add(animation, forKey: "parkingEdge.dwell")
        }
        CATransaction.commit()
    }

    func reveal(animated: Bool) {
        guard let layer, animated else { return }
        let offset: CGFloat = side == .left || side == .bottom ? -14 : 14
        let axis = side == .left || side == .right ? "x" : "y"
        let translation = CABasicAnimation(keyPath: "transform.translation.\(axis)")
        translation.fromValue = offset
        translation.toValue = 0
        translation.duration = 0.2
        translation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(translation, forKey: "parkingEdge.reveal")
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.2
        layer.add(opacity, forKey: "parkingEdge.opacity")
    }

    func reset() {
        layer?.removeAllAnimations()
        setProgress(duration: nil)
    }

    private func updateGeometry() {
        var transform = switch side {
        case .left: CGAffineTransform(scaleX: 1, y: bounds.height / 108)
        case .right: CGAffineTransform(a: -1, b: 0, c: 0, d: bounds.height / 108, tx: 30, ty: 0)
        case .bottom: CGAffineTransform(a: 0, b: 1, c: bounds.width / 108, d: 0, tx: 0, ty: 0)
        case .top: CGAffineTransform(a: 0, b: -1, c: bounds.width / 108, d: 0, tx: 0, ty: 30)
        }
        let contour = CGMutablePath()
        contour.move(to: .zero)
        contour.addCurve(to: CGPoint(x: 30, y: 54), control1: CGPoint(x: 0, y: 22), control2: CGPoint(x: 30, y: 28))
        contour.addCurve(to: CGPoint(x: 0, y: 108), control1: CGPoint(x: 30, y: 80), control2: CGPoint(x: 0, y: 86))
        contour.closeSubpath()
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 2, y: 7))
        line.addCurve(to: CGPoint(x: 27, y: 54), control1: CGPoint(x: 5, y: 25), control2: CGPoint(x: 27, y: 32))
        line.addCurve(to: CGPoint(x: 2, y: 101), control1: CGPoint(x: 27, y: 76), control2: CGPoint(x: 5, y: 83))
        let center = CGPoint(x: 15, y: 54).applying(transform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.path = contour.copy(using: &transform)
        track.path = line.copy(using: &transform)
        progress.path = track.path
        arrow.frame = CGRect(x: center.x - 7, y: center.y - 8, width: 14, height: 16)
        CATransaction.commit()
    }
}
