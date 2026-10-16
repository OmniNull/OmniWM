// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore
import QuartzCore

struct ShellPointerCapture {
    let handle: ElementHandle
    let content: Content
    let anchor: ShellAnchor
    let origin: CGPoint
    let sequence: Int
    var event: ShellEvent
}

extension ShellWidgetSurface {
    func capture(_ handle: ElementHandle, event: ShellEvent = ShellEvent()) -> ShellPointerCapture {
        let frame = layout.core.absoluteFrame(of: handle)
        return ShellPointerCapture(
            handle: handle,
            content: layout.core.content(of: handle),
            anchor: anchor(of: handle),
            origin: CGPoint(x: CGFloat(frame.x), y: CGFloat(frame.y)),
            sequence: sequence,
            event: event
        )
    }

    func emit(_ action: UInt32, capture: ShellPointerCapture, point: CGPoint, event: ShellEvent) {
        guard action != 0 else { return }
        var event = event
        let origin = layout.core.contains(capture.handle)
            ? CGRect(layout.core.absoluteFrame(of: capture.handle)).origin : capture.origin
        event.x = Double(point.x - origin.x)
        event.y = Double(point.y - origin.y)
        onAction?(ShellClick(
            action: action,
            opensPopout: false,
            anchor: layout.core.contains(capture.handle) ? anchor(of: capture.handle) : capture.anchor,
            event: event,
            source: capture.handle,
            sequence: capture.sequence
        ))
    }

    func setPressed(_ handle: ElementHandle, inside: Bool = true) {
        let previous = pressed
        pressed = handle
        pressInside = inside
        var commands: [ShellLayerCommand] = []
        if previous != handle, layout.core.contains(previous), layout.core.content(of: previous).hasPressEffect {
            commands.append(paintCommand(previous, interactionPaint(previous), press: true))
        }
        if layout.core.contains(handle), layout.core.content(of: handle).hasPressEffect {
            commands.append(paintCommand(handle, interactionPaint(handle), press: true))
        }
        scene.submit(commands, animated: animates && motionPolicy.animationsEnabled)
    }

    func interactionPaint(_ handle: ElementHandle) -> Paint {
        let base = hovered.contains(handle) ? hoverPaint(handle) : layout.core.paint(of: handle)
        return ringed == handle ? Self.ringed(base) : base
    }

    static func pressedPaint(_ base: Paint, by content: Content) -> Paint {
        var paint = base
        if content.pressFillSpecified { paint.fill = content.pressFill }
        if content.pressScaleSpecified || content.pressScale > 0 { paint.scale = content.pressScale }
        if content.pressOpacity >= 0 { paint.opacity = content.pressOpacity }
        return paint
    }

    func finishPress(at point: CGPoint, event: ShellEvent, cancelled: Bool) {
        guard let capture = pressCapture else { setPressed(.none)
            return
        }
        pressCapture = nil
        setPressed(.none)
        var event = event
        event.kind = .press
        event.phase = cancelled ? .cancel : .up
        emit(capture.content.pressAction, capture: capture, point: point, event: event)
    }

    func cancelInput(hover: Bool = true) {
        resourceDragTracker?.cancel()
        let point = pointer ?? pressCapture?.origin ?? .zero
        if let capture = pressCapture { cancelSlider(capture: capture) }
        finishPress(at: point, event: pressCapture?.event ?? ShellEvent(), cancelled: true)
        finishGesture(at: gesturePosition, timestamp: CACurrentMediaTime(), cancelled: true)
        cancelHeldGestureTrack()
        dragStart = nil
        if dragging { onDrag?(.ended(view.window?.convertPoint(toScreen: view.convert(point, to: nil)) ?? point)) }
        dragging = false
        if hover { cancelHoverIntent(deliver: true) }
    }

    func reconcileInput() {
        reconcileResourceDrag()
        reconcileGestureTrack()
        if let captured = pressCapture {
            if !layout.core.contains(captured.handle) || !layout.core.content(of: captured.handle).acceptsPointer
                || captured.content.pressAction != 0 && layout.core.content(of: captured.handle).pressAction == 0
            {
                cancelSlider(capture: captured)
                finishPress(at: pointer ?? captured.origin, event: captured.event, cancelled: true)
            } else {
                pressCapture = capture(captured.handle, event: captured.event)
            }
        }
        if sliding.slot >= 0, !layout.core.contains(sliding) { sliding = .none }
        if let captured = gestureCapture {
            if !layout.core.contains(captured.handle) || layout.core.content(of: captured.handle)
                .gestureAction == 0 && layout.core.content(of: captured.handle).gestureTrack == 0
                || layout.core.content(of: captured.handle).gesture.axis == .none
            {
                finishGesture(at: gesturePosition, timestamp: CACurrentMediaTime(), cancelled: true)
            } else {
                gestureCapture = capture(captured.handle, event: captured.event)
            }
        }
        if let captured = hoverIntent {
            if !layout.core.contains(captured.handle) || layout.core.content(of: captured.handle).hoverAction == 0 {
                cancelHoverIntent(deliver: true)
            } else {
                hoverIntent = capture(captured.handle, event: captured.event)
            }
        }
        updateHoverIntent(at: pointer)
    }

    private func cancelSlider(capture: ShellPointerCapture) {
        guard sliding == capture.handle else { return }
        sliding = .none
        var event = capture.event
        event.kind = .slider
        event.phase = .cancelled
        emit(capture.content.action, capture: capture, point: pointer ?? capture.origin, event: event)
    }

    func updateInputDeclarations() {
        hasHoverHandlers = false
        outsidePressTargets.removeAll(keepingCapacity: true)
        var recipes: [UInt32: ShellGestureTrackRecipe] = [:]
        var resourceDrops = false
        for handle in layout.core
            .elements(matching: {
                $0.hoverAction != 0 || $0.outsidePressAction != 0 || $0.gestureTrack != 0 || $0.resourceAccepts != 0
            })
        {
            let content = layout.core.content(of: handle)
            hasHoverHandlers = hasHoverHandlers || content.hoverAction != 0
            resourceDrops = resourceDrops || content
                .resourceAccepts != 0 && (content.resourceDropAction != 0 || content.resourceHoverAction != 0)
            if content.outsidePressAction != 0 { outsidePressTargets.append(handle) }
            if content.gestureTrack != 0, recipes[content.gestureTrack] == nil, let text {
                let source = text.string(content.gestureTrack)
                let existing = gestureTrackRecipes[content.gestureTrack]
                recipes[content.gestureTrack] = existing?.source == source ? existing
                    : ShellGestureTrackRecipe(source: source, track: ShellGestureTrack(source))
            }
        }
        gestureTrackRecipes = recipes
        updateResourceDropRegistration(resourceDrops)
    }

    func updateHoverIntent(at point: CGPoint?) {
        guard hasHoverHandlers || hoverIntent != nil else { return }
        let target = hasHoverHandlers ? element(at: point, matching: { $0.hoverAction != 0 }) : .none
        if target == hoverIntent?.handle {
            if let point { hoverPoint = point }
            if hoverEnding {
                hoverTimer?.cancel()
                hoverTimer = nil
                hoverEnding = false
            }
            return
        }
        if target.slot >= 0 {
            cancelHoverIntent(deliver: true)
            hoverIntent = capture(target)
            hoverPoint = point ?? .zero
            scheduleHoverIntent(after: Double(layout.core.content(of: target).hoverDelay), ending: false)
        } else if let intent = hoverIntent, !hoverEnding {
            if hoverActive {
                scheduleHoverIntent(after: Double(intent.content.hoverGrace), ending: true)
            } else {
                cancelHoverIntent(deliver: false)
            }
        }
    }

    private func scheduleHoverIntent(after delay: TimeInterval, ending: Bool) {
        hoverTimer?.cancel()
        hoverEnding = ending
        guard let capture = hoverIntent else { return }
        if delay <= 0 {
            advanceHoverIntent(ending: ending, capture: capture)
            return
        }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, let current = hoverIntent, current.handle == capture.handle,
                  hoverEnding == ending else { return }
            advanceHoverIntent(ending: ending, capture: current)
        }
        hoverTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    func advanceHoverIntent(ending: Bool, capture: ShellPointerCapture) {
        guard hoverIntent?.handle == capture.handle, hoverIntent?.sequence == capture.sequence,
              hoverEnding == ending else { return }
        hoverTimer?.cancel()
        hoverTimer = nil
        if ending {
            cancelHoverIntent(deliver: true)
        } else if !hoverActive, layout.core.contains(capture.handle) {
            hoverActive = true
            var event = ShellEvent(button: .none)
            event.kind = .hover
            event.phase = .began
            if var trace = ShellFrameTrace.shared.makeContext(parent: event.trace) {
                trace.display = view.window?.screen?.displayId ?? 0
                ShellFrameTraceDisplayLink.prepare(screen: view.window?.screen)
                ShellFrameTrace.shared.record(.init(
                    event: .input, context: trace, inputTimestamp: CACurrentMediaTime(), detail: "hover_dwell"
                ))
                event.trace = trace
            }
            emit(capture.content.hoverAction, capture: capture, point: hoverPoint, event: event)
        }
    }

    func cancelHoverIntent(deliver: Bool) {
        hoverTimer?.cancel()
        hoverTimer = nil
        let capture = hoverIntent
        let active = hoverActive
        hoverIntent = nil
        hoverActive = false
        hoverEnding = false
        if deliver, active, let capture {
            var event = ShellEvent(button: .none)
            event.kind = .hover
            event.phase = .ended
            emit(capture.content.hoverAction, capture: capture, point: hoverPoint, event: event)
        }
    }
}
