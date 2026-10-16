// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import OmniWMShellCore

final class ShellSurfaceView: NSView {
    weak var surface: ShellWidgetSurface?

    override var isFlipped: Bool {
        true
    }

    init(container: CALayer) {
        super.init(frame: .zero)
        let host = CALayer()
        host.isGeometryFlipped = true
        host.addSublayer(container)
        layer = host
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        let observed = [
            (NSWindow.didChangeOcclusionStateNotification, #selector(occlusionChanged)),
            (NSWindow.didMoveNotification, #selector(moved)),
            (NSWindow.didResizeNotification, #selector(moved))
        ]
        for (name, selector) in observed {
            center.removeObserver(self, name: name, object: nil)
            if let window {
                center.addObserver(self, selector: selector, name: name, object: window)
            }
        }
        occlusionChanged()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        if let superview {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(moved),
                name: NSView.frameDidChangeNotification,
                object: superview
            )
        }
    }

    @objc private func occlusionChanged() {
        surface?.setVisible(window?.occlusionState.contains(.visible) == true)
    }

    override func layout() {
        super.layout()
        surface?.layoutTextInputs()
        surface?.realizeTextInputFocus()
    }

    @objc private func moved() {
        surface?.onMove?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit !== self { return hit }
        return surface?.hasAction(at: convert(point, from: superview)) == true ? self : nil
    }

    override var acceptsFirstResponder: Bool {
        surface?.focusAxis != nil || surface?.declaredFocus == true
    }

    override func keyDown(with event: NSEvent) {
        traceInput(event) {
            if surface?.handleDeclaredKey(event) != true,
               surface?.handleKey(event.keyCode, shift: event.modifierFlags.contains(.shift)) != true
            {
                super.keyDown(with: event)
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, surface?.hasFocusedTextInput != true { surface?.blurDeclaredFocus() }
        return resigned
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        traceInput(event) {
            let option = event.modifierFlags.contains(.option)
            if event.modifierFlags.contains(.control),
               surface?.openContextMenu(at: location(of: event), option: option) == true
            {
                return
            }
            surface?.press(at: location(of: event), event: inputEvent(event, button: .left), timestamp: event.timestamp)
            surface?.prepareResourceDrag(at: location(of: event))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        traceInput(event) {
            let point = location(of: event)
            if surface?.openContextMenu(at: point, option: event.modifierFlags.contains(.option)) != true {
                surface?.press(
                    at: point,
                    button: .right,
                    event: inputEvent(event, button: .right),
                    timestamp: event.timestamp
                )
            }
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        traceInput(event) {
            surface?.release(
                at: location(of: event),
                event: inputEvent(event, button: .right),
                timestamp: event.timestamp
            )
        }
    }

    override func scrollWheel(with event: NSEvent) {
        traceInput(event) { scroll(event) }
    }

    private func scroll(_ event: NSEvent) {
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        var scroll = ShellEvent(button: .none, modifiers: event.modifierFlags)
        scroll.dx = Double(event.scrollingDeltaX * sign)
        scroll.dy = Double(event.scrollingDeltaY * sign)
        scroll.precise = event.hasPreciseScrollingDeltas
        scroll.phase = Self.phase(event.phase)
        scroll.momentum = Self.momentum(event.momentumPhase)
        let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let content = CGPoint(x: -event.scrollingDeltaX * lines, y: -event.scrollingDeltaY * lines)
        let momentum = !event.momentumPhase.isEmpty
        if surface?.scroll(
            at: location(of: event),
            event: scroll,
            content: content,
            momentum: momentum,
            timestamp: event.timestamp
        ) != true {
            super.scrollWheel(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        traceInput(event) { surface?.press(
            at: location(of: event),
            button: .middle,
            event: inputEvent(event, button: .middle),
            timestamp: event.timestamp
        ) }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        traceInput(event) {
            surface?.release(
                at: location(of: event),
                event: inputEvent(event, button: .middle),
                timestamp: event.timestamp
            )
        }
    }

    override func mouseDragged(with event: NSEvent) {
        traceInput(event) {
            let point = location(of: event)
            if surface?.dragResources(with: event, at: point) == true { return }
            surface?.drag(to: point, screen: screenLocation(of: event), timestamp: event.timestamp)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        traceInput(event) { surface?.drag(
            to: location(of: event),
            screen: screenLocation(of: event),
            timestamp: event.timestamp
        ) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        traceInput(event) { surface?.drag(
            to: location(of: event),
            screen: screenLocation(of: event),
            timestamp: event.timestamp
        ) }
    }

    override func mouseUp(with event: NSEvent) {
        traceInput(event) {
            surface?.resourceDragTracker?.cancel()
            if surface?.endDrag(at: screenLocation(of: event)) == true {
                return
            }
            surface?.release(
                at: location(of: event),
                event: inputEvent(event, button: .left),
                timestamp: event.timestamp
            )
        }
    }

    private func inputEvent(_ event: NSEvent, button: ShellEvent.Button) -> ShellEvent {
        var input = ShellEvent(button: button, modifiers: event.modifierFlags)
        input.clicks = event.clickCount
        return input
    }

    static func phase(_ phase: NSEvent.Phase) -> ShellEvent.Phase? {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        return phase.isEmpty ? nil : .changed
    }

    static func momentum(_ phase: NSEvent.Phase) -> ShellEvent.Momentum {
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        if phase.contains(.began) { return .began }
        return phase.isEmpty ? .none : .changed
    }

    private func screenLocation(of event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        surface?.draggingResource(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        surface?.draggingResource(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        surface?.cancelResourceDrop()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        surface?.cancelResourceDrop()
        surface?.onResourceDragEnd?()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        surface?.draggingResource(sender).contains(.copy) == true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        surface?.performResourceDrop(sender) == true
    }

    override func mouseEntered(with event: NSEvent) {
        traceInput(event) { surface?.hover(at: location(of: event)) }
    }

    override func mouseMoved(with event: NSEvent) {
        traceInput(event) { surface?.hover(at: location(of: event)) }
    }

    override func mouseExited(with event: NSEvent) {
        traceInput(event) { surface?.hover(at: nil) }
    }

    private func traceInput(_ event: NSEvent, _ body: () -> Void) {
        guard var trace = ShellFrameTrace.shared.makeContext() else {
            body()
            return
        }
        trace.display = window?.screen?.displayId ?? 0
        ShellFrameTraceDisplayLink.prepare(screen: window?.screen)
        ShellFrameTrace.shared.record(.init(
            event: .input,
            context: trace,
            inputTimestamp: event.timestamp,
            detail: "type=\(event.type.rawValue)"
        ))
        ShellFrameTrace.$context.withValue(trace, operation: body)
    }

    func command(at event: NSEvent) -> String? {
        surface?.command(at: location(of: event))
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
