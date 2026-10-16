// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore

extension ShellWidgetSurface {
    func command(at point: CGPoint) -> String? {
        let target = element(at: point) { $0.action != 0 }
        guard target.slot >= 0, let text else { return nil }
        let action = layout.core.content(of: target).action
        guard action & OMNI_ACTION_HANDLER == 0, action != OMNI_ACTION_POPOUT else { return nil }
        return text.string(action)
    }

    func hasAction(at point: CGPoint) -> Bool {
        element(at: point) { $0.acceptsPointer }.slot >= 0
    }

    func drag(to point: CGPoint, screen: CGPoint, timestamp: TimeInterval = CACurrentMediaTime()) {
        if sliding.slot >= 0 {
            slide(sliding, to: point, phase: .changed)
            return
        }
        gesturePointer = point
        if updateGesture(at: point, timestamp: timestamp, event: pressCapture?.event ?? ShellEvent()) { return }
        if let capture = pressCapture, capture.content.hasPressEffect, layout.core.contains(capture.handle) {
            let frame = CGRect(layout.core.absoluteFrame(of: capture.handle))
            let inside = frame.contains(point) && clips(
                capture.handle,
                Float(point.x - frame.minX),
                Float(point.y - frame.minY)
            )
            if inside != pressInside { setPressed(capture.handle, inside: inside) }
        }
        guard let start = dragStart, layout.core.contains(start.handle) else { return }
        guard dragging else {
            guard hypot(point.x - start.point.x, point.y - start.point.y) >= Self.dragThreshold
            else {
                return
            }
            dragging = true
            pointerGesture = nil
            finishPress(at: point, event: pressCapture?.event ?? ShellEvent(), cancelled: true)
            onDrag?(.began(target: layout.core.content(of: start.handle).target, at: screen))
            return
        }
        onDrag?(.moved(screen))
    }

    func endDrag(at screen: CGPoint) -> Bool {
        defer {
            dragStart = nil
            dragging = false
        }
        guard dragging else { return false }
        pressed = .none
        onDrag?(.ended(screen))
        return true
    }

    func targetFrames() -> [ShellTargetFrame] {
        layout.core.elements { ($0.drag || $0.drop) && $0.target != 0 }.map { handle in
            let content = layout.core.content(of: handle)
            return ShellTargetFrame(target: content.target, frame: anchor(of: handle).frame, drop: content.drop)
        }
    }

    func openContextMenu(at point: CGPoint, option: Bool) -> Bool {
        if option, openLayoutMenu() {
            return true
        }
        if openMenu(at: point) {
            return true
        }
        guard element(at: point, matching: { $0.secondaryAction != 0 }).slot < 0 else { return false }
        return openLayoutMenu()
    }

    private func openLayoutMenu() -> Bool {
        guard let onLayoutMenu else { return false }
        cancelInput()
        hideTooltip()
        onLayoutMenu(screenAnchor ?? ShellAnchor(frame: view.frame, level: .normal))
        return true
    }

    func openMenu(at point: CGPoint) -> Bool {
        let target = element(at: point) { $0.menu && $0.target != 0 }
        guard target.slot >= 0 else { return false }
        cancelInput()
        let content = layout.core.content(of: target)
        let label = layout.core.firstDescendant(of: target) { $0.target == content.target }
        onMenu?(ShellMenuEvent(
            target: content.target,
            anchor: anchor(of: target),
            label: label.slot >= 0 ? anchor(of: label).frame : nil
        ))
        return true
    }

    func press(
        at point: CGPoint,
        button: ShellEvent.Button = .left,
        event: ShellEvent? = nil,
        timestamp: TimeInterval = CACurrentMediaTime()
    ) {
        resourceDragTracker?.cancel()
        hideTooltip()
        let event = event ?? ShellEvent(button: button)
        finishPress(at: point, event: event, cancelled: true)
        _ = finishGesture(at: gesturePosition, timestamp: timestamp, cancelled: true)
        let target = element(at: point) {
            event.acts(on: $0) || $0.pressAction != 0 || $0.focusable || $0.gestureAction != 0 || $0
                .hasPressEffect || $0.dragItemsRef != 0
        }
        pressedButton = event.button
        if target.slot >= 0 {
            let capture = capture(target, event: event)
            pressCapture = capture
            setPressed(target)
            var down = event
            down.kind = .press
            down.phase = .down
            emit(capture.content.pressAction, capture: capture, point: point, event: down)
        }
        let focus = element(at: point) { $0.focusable }
        if focus.slot >= 0 { focusDeclared(focus) }
        guard event.button == .left else { return }
        if target.slot >= 0, layout.core.kind(of: target) == .slider {
            sliding = target
            slide(sliding, to: point, phase: .began)
            return
        }
        let draggable = element(at: point) { $0.drag && $0.target != 0 }
        dragStart = draggable.slot >= 0 ? (draggable, point) : nil
        dragging = false
        if draggable.slot < 0 { beginGesture(at: point, source: .pointer, timestamp: timestamp) }
    }

    func scroll(
        at point: CGPoint,
        event: ShellEvent,
        content delta: CGPoint = .zero,
        momentum: Bool = false,
        timestamp: TimeInterval = CACurrentMediaTime()
    ) -> Bool {
        let momentum = momentum || event.momentum != .none
        if !momentum, scrollGesture(at: point, event: event, timestamp: timestamp) { return true }
        let target = element(at: point) { $0.scrollAction != 0 }
        if target.slot < 0 {
            if momentum,
               element(
                   at: point,
                   matching: { ($0.gestureAction != 0 || $0.gestureTrack != 0) && $0.gesture.source != .pointer }
               ).slot >= 0
            {
                return true
            }
            return scrollContent(at: point, by: delta)
        }
        let content = layout.core.content(of: target)
        guard !momentum || content.scrollMomentum else { return true }
        var event = event
        event.kind = .scroll
        emit(content.scrollAction, capture: capture(target), point: point, event: event)
        return true
    }

    func slide(_ handle: ElementHandle, to point: CGPoint, phase: ShellEvent.Phase) {
        guard layout.core.contains(handle) else {
            sliding = .none
            return
        }
        let frame = layout.core.absoluteFrame(of: handle)
        let knob = CGFloat(frame.height)
        let track = max(CGFloat(frame.width) - knob, 1)
        var event = ShellEvent(button: .left)
        event.kind = .slider
        event.x = Double(point.x - CGFloat(frame.x))
        event.y = Double(point.y - CGFloat(frame.y))
        event.value = Double(min(max((point.x - CGFloat(frame.x) - knob / 2) / track, 0), 1))
        event.phase = phase
        pressCapture?.event = event
        onAction?(ShellClick(
            action: layout.core.content(of: handle).action,
            opensPopout: false,
            anchor: anchor(of: handle),
            event: event,
            source: handle
        ))
    }

    private func scrollContent(at point: CGPoint, by delta: CGPoint) -> Bool {
        let container = element(at: point) { $0.scrolls }
        guard container.slot >= 0 else { return false }
        let vertical = layout.core.layoutStyle(of: container).axis == .column
        guard let offset = layout.scroll(container, by: Float(vertical ? delta.y : delta.x)) else { return true }
        var commands: [ShellLayerCommand] = [
            .scroll(slot: container.slot, origin: Self.scrollOrigin(offset, vertical: vertical))
        ]
        updateHover(into: &commands, reapply: false)
        scene.submit(commands, animated: false)
        layoutTextInputs()
        onMove?()
        return true
    }

    func release(at point: CGPoint, event: ShellEvent = ShellEvent(), timestamp: TimeInterval = CACurrentMediaTime()) {
        if pointerGesture?.source == .pointer,
           finishGesture(at: point, timestamp: timestamp, event: event) { return }
        if sliding.slot >= 0, event.button == .left {
            slide(sliding, to: point, phase: .ended)
            sliding = .none
            finishPress(at: point, event: event, cancelled: false)
            return
        }
        let target = element(at: point) { event.acts(on: $0) }
        let capture = pressCapture
        let inside = capture.map {
            guard layout.core.contains($0.handle) else { return false }
            let frame = CGRect(layout.core.absoluteFrame(of: $0.handle))
            return frame.contains(point) && clips($0.handle, Float(point.x - frame.minX), Float(point.y - frame.minY))
        } ?? false
        let wasPressed = pressed
        finishPress(at: point, event: event, cancelled: !inside || pressedButton != event.button)
        guard target.slot >= 0, target == wasPressed, pressedButton == event.button else { return }
        let content = layout.core.content(of: target)
        let frame = layout.core.absoluteFrame(of: target)
        var event = event
        event.x = Double(point.x - CGFloat(frame.x))
        event.y = Double(point.y - CGFloat(frame.y))
        onAction?(ShellClick(
            action: event.action(of: content),
            opensPopout: event.button == .left && content.opensPopout,
            anchor: anchor(of: target),
            event: event,
            target: content.target,
            source: target
        ))
    }

    var screenAnchor: ShellAnchor? {
        guard let window = view.window, window.isVisible else { return nil }
        return ShellAnchor(
            frame: window.convertToScreen(view.convert(view.bounds, to: nil)),
            level: window.level,
            container: window.frame
        )
    }

    func liveAnchor(of handle: ElementHandle) -> ShellAnchor? {
        guard handle != .none else { return screenAnchor }
        return layout.core.contains(handle) ? anchor(of: handle) : nil
    }

    func anchor(of handle: ElementHandle) -> ShellAnchor {
        let frame = view.convert(CGRect(layout.core.absoluteFrame(of: handle)), to: nil)
        guard let window = view.window else { return ShellAnchor(frame: frame, level: .popUpMenu) }
        return ShellAnchor(frame: window.convertToScreen(frame), level: window.level, container: window.frame)
    }

    func hover(at point: CGPoint?) {
        pointer = point
        updateHoverIntent(at: point)
        updatePreview()
        var commands: [ShellLayerCommand] = []
        updateHover(into: &commands, reapply: false)
        scene.submit(commands, animated: animates && motionPolicy.animationsEnabled)
        updateTooltip(at: point)
    }

    func updatePreview() {
        let target = element(at: pointer) { $0.preview && $0.target != 0 }
        let frame = target.slot >= 0 ? layout.core.absoluteFrame(of: target) : nil
        guard target != previewed || frame != previewFrame else { return }
        previewed = target
        previewFrame = frame
        onPreview?(target.slot >= 0
            ? ShellPreviewEvent(target: layout.core.content(of: target).target, anchor: anchor(of: target))
            : ShellPreviewEvent(target: 0, anchor: nil))
    }

    private func updateTooltip(at point: CGPoint?) {
        let target = element(at: point) { $0.help != 0 }
        guard target != tooltipTarget else { return }
        hideTooltip()
        tooltipTarget = target
        guard target.slot >= 0, let point else { return }
        let text = layout.core.content(of: target).help
        let location = view.window.map { $0.convertPoint(toScreen: view.convert(point, to: nil)) } ?? point
        let timer = DispatchWorkItem { [weak self] in
            guard let self, tooltipTarget == target, layout.core.contains(target) else { return }
            onTooltip?(ShellTooltipEvent(text: text, location: location))
        }
        tooltipTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tooltipDelay, execute: timer)
    }

    func hideTooltip() {
        tooltipTimer?.cancel()
        tooltipTimer = nil
        if tooltipTarget.slot >= 0 {
            tooltipTarget = .none
            onTooltip?(nil)
        }
    }

    static func scrollOrigin(_ offset: Float, vertical: Bool) -> CGPoint {
        vertical ? CGPoint(x: 0, y: CGFloat(offset)) : CGPoint(x: CGFloat(offset), y: 0)
    }

    static let dragThreshold: CGFloat = 6

    private static var tooltipDelay: TimeInterval {
        let milliseconds = UserDefaults.standard.double(forKey: "NSInitialToolTipDelay")
        return milliseconds > 0 ? milliseconds / 1000 : 1
    }

    func element(at point: CGPoint?, matching predicate: (Content) -> Bool) -> ElementHandle {
        guard let point else { return .none }
        return layout.core.hitTest(x: Float(point.x), y: Float(point.y), matching: predicate, clip: clips)
    }

    func updateHover(into commands: inout [ShellLayerCommand], reapply: Bool) {
        var targets = hoverScratch
        hoverScratch = []
        targets.removeAll(keepingCapacity: true)
        if let pointer {
            layout.core.hitPath(
                x: Float(pointer.x),
                y: Float(pointer.y),
                matching: { $0.hasHoverEffect },
                clip: clips,
                into: &targets
            )
        }
        let focus = focusPath()
        targets += focus.filter { !targets.contains($0) }
        let ring = focusRingTarget(in: focus)
        for handle in hovered where !targets.contains(handle) && handle != ring && layout.core.contains(handle) {
            commands.append(paintCommand(handle, layout.core.paint(of: handle), hover: true))
        }
        if ringed != ring, !targets.contains(ringed), !hovered.contains(ringed), layout.core.contains(ringed) {
            commands.append(paintCommand(ringed, layout.core.paint(of: ringed), hover: true))
        }
        for handle in targets where reapply || !hovered.contains(handle) || (handle == ring) != (handle == ringed) {
            let paint = hoverPaint(handle)
            commands.append(paintCommand(handle, handle == ring ? Self.ringed(paint) : paint, hover: true))
        }
        if ring.slot >= 0, !targets.contains(ring), reapply || ring != ringed {
            commands.append(paintCommand(ring, Self.ringed(layout.core.paint(of: ring)), hover: true))
        }
        hoverScratch = hovered
        hovered = targets
        ringed = ring
    }
}
