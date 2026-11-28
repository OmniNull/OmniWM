// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class OverviewPinchCamera {
    let layer = CALayer()
    private static let config = SpatialCameraConfig(
        minScale: 1, maxScale: 2, overviewScale: 1, rubberBandResistance: 0, snapToFocusThreshold: 1.5
    )
    private static let returnKey = "overview.cameraReturn"
    private var gesture: (viewport: SpatialCameraViewport, target: WindowHandle)?
    private var overviewIsSettledOpen = false
    private var animationsEnabled = true

    var isTracking: Bool {
        gesture != nil
    }

    init() {
        layer.anchorPoint = .zero
    }

    func updateLayout(_ layout: OverviewLayout, state: OverviewState, animationsEnabled: Bool) {
        overviewIsSettledOpen = state.isOpen && !state.isAnimating
        self.animationsEnabled = animationsEnabled
        guard let gesture else { return }
        let target = layout.window(for: gesture.target)
        if !overviewIsSettledOpen || target?.isDisplayed != true || target?.matchesSearch != true { reset() }
    }

    func magnify(with event: NSEvent, at point: CGPoint, hitTest: (CGPoint) -> WindowHandle?) -> WindowHandle? {
        guard overviewIsSettledOpen else { return nil }
        switch event.phase {
        case .began:
            guard let target = hitTest(point) else {
                reset()
                return nil
            }
            let transform = displayedTransform
            let viewport = SpatialCameraViewport(config: Self.config, initial: transform)
            viewport.beginGesture(anchor: transform.unproject(point: point))
            gesture = (viewport, target)
            layer.removeAnimation(forKey: Self.returnKey)
        case .changed,
             .ended:
            break
        case .cancelled:
            if isTracking { reset(animated: animationsEnabled) }
            return nil
        default:
            return nil
        }
        guard let gesture else { return nil }
        gesture.viewport.updateMagnify(delta: event.magnification)
        keepGridInView(gesture.viewport)
        OverviewRenderer.withoutAnimation { layer.transform = gesture.viewport.current.caTransform3D }
        guard event.phase == .ended else { return nil }
        let focus = gesture.viewport.endGesture() == .focusedWindow && hitTest(point) === gesture.target
        reset(animated: animationsEnabled)
        return focus ? gesture.target : nil
    }

    private func keepGridInView(_ viewport: SpatialCameraViewport) {
        guard viewport.current.translation != .zero, let bounds = layer.superlayer?.bounds else { return }
        let grid = viewport.current.project(rect: bounds)
        viewport.updatePan(delta: CGPoint(
            x: min(0, bounds.minX - grid.minX) + max(0, bounds.maxX - grid.maxX),
            y: min(0, bounds.minY - grid.minY) + max(0, bounds.maxY - grid.maxY)
        ))
    }

    func scenePoint(at point: CGPoint) -> CGPoint {
        displayedTransform.unproject(point: point)
    }

    private var displayedTransform: SpatialCameraTransform {
        if let gesture { return gesture.viewport.current }
        guard let spring = layer.animation(forKey: Self.returnKey) as? CABasicAnimation else { return .identity }
        let from = (spring.fromValue as? NSValue)?.caTransform3DValue ?? CATransform3DIdentity
        let transform = layer.presentation()?.affineTransform() ?? CATransform3DGetAffineTransform(from)
        return SpatialCameraTransform(scale: transform.a, translation: CGPoint(x: transform.tx, y: transform.ty))
    }

    func reset(animated: Bool = false) {
        guard isTracking || layer.animation(forKey: Self.returnKey) != nil else { return }
        gesture = nil
        let from = layer.transform
        OverviewRenderer.withoutAnimation {
            layer.removeAnimation(forKey: Self.returnKey)
            layer.transform = CATransform3DIdentity
        }
        guard animated, !CATransform3DIsIdentity(from) else { return }
        let now = CACurrentMediaTime()
        let transition = OverviewNativeTransition(generation: 0, startTime: now, from: 0, to: 1)
        let spring = transition.makeAnimation(keyPath: "transform")
        spring.beginTime = layer.convertTime(now, from: nil)
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(spring, forKey: Self.returnKey)
    }
}
