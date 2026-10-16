// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

struct ShellIslandGeometry: Equatable, Sendable {
    let frame: CGRect
    let notch: CGRect?

    init(monitor: Monitor, size: CGSize) {
        let width = min(max(size.width, 1), monitor.frame.width)
        let height = min(max(size.height, 1), monitor.frame.height)
        let frame = CGRect(
            x: monitor.frame.midX - width / 2,
            y: monitor.frame.maxY - height,
            width: width,
            height: height
        )
        self.frame = frame
        notch = monitor.hasNotch ? monitor.notchRange.map {
            CGRect(
                x: $0.lowerBound - frame.minX,
                y: 0,
                width: $0.upperBound - $0.lowerBound,
                height: monitor.notchHeight
            )
        } : nil
    }

    func screenRect(_ rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    func localPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }
}

@MainActor
final class ShellIslandPanel: ShellFocusPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = content
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    @discardableResult
    func setEnvelope(_ frame: CGRect) -> Bool {
        guard self.frame != frame else { return false }
        setFrame(frame, display: false)
        return true
    }
}

@MainActor
final class ShellIsland {
    private struct OutsidePress {
        let capture: ShellPointerCapture
        let rect: CGRect
    }

    let surface: ShellWidgetSurface
    let panel: ShellIslandPanel
    private(set) var geometry: ShellIslandGeometry
    private(set) var regions: [CGRect] = []
    var onFocusChange: ((Bool) -> Void)?
    var onBlur: (() -> Void)?
    var onInputChange: (() -> Void)?
    private let registry: OwnedWindowRegistry
    private let surfaceID: String
    private var outsidePresses: [OutsidePress] = []

    var hasOutsidePress: Bool {
        !outsidePresses.isEmpty
    }

    init(
        surface: ShellWidgetSurface,
        monitor: Monitor,
        size: CGSize,
        registry: OwnedWindowRegistry = .shared
    ) {
        self.surface = surface
        self.registry = registry
        surfaceID = "shell-island-\(monitor.displayId)"
        geometry = ShellIslandGeometry(monitor: monitor, size: size)
        panel = ShellIslandPanel(content: surface.view)
        surface.drawsRootMaterial = true
        surface.view.layer?.masksToBounds = true
        let onMove = surface.onMove
        surface.onMove = { [weak self] in
            onMove?()
            self?.updateRegions()
        }
        surface.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
        surface.onResourceDropRegistrationChange = { [weak self] in self?.onInputChange?() }
        panel.onBlur = { [weak self] in self?.onBlur?() }
        register()
        panel.setEnvelope(geometry.frame)
        updateStage()
        layoutSurface()
    }

    func update(monitor: Monitor, size: CGSize, visible: Bool, level: NSWindow.Level) {
        let next = ShellIslandGeometry(monitor: monitor, size: size)
        if geometry != next {
            geometry = next
            panel.setEnvelope(next.frame)
            updateStage()
            layoutSurface()
        }
        if panel.level != level {
            panel.level = level
        }
        surface.setVisible(visible)
        if visible, !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !visible, panel.isVisible {
            panel.orderOut(nil)
        }
        surface.realizeTextInputFocus()
        onInputChange?()
    }

    func setKeyboardActive(_ active: Bool) {
        guard panel.acceptsDeclaredFocus != active else { return }
        panel.acceptsDeclaredFocus = active
        register()
        if !active, panel.isKeyWindow, !panel.isResigningKey {
            panel.resignKey()
        }
    }

    func contains(screenPoint: CGPoint) -> Bool {
        panel.isVisible && regions.contains { $0.contains(screenPoint) }
    }

    func acceptsFocus(at screenPoint: CGPoint) -> Bool {
        guard panel.isVisible else { return false }
        let point = geometry.localPoint(screenPoint)
        return surface.layout.core.hitTest(
            x: Float(point.x), y: Float(point.y), matching: { $0.focusable }, clip: surface.clips
        ) != .none
    }

    func outsidePress(at screenPoint: CGPoint, event: ShellEvent) {
        guard panel.isVisible else { return }
        let point = geometry.localPoint(screenPoint)
        for press in outsidePresses where !press.rect.contains(point) {
            surface.emit(press.capture.content.outsidePressAction, capture: press.capture, point: point, event: event)
        }
    }

    func layoutSurface() {
        surface.setRootLimit(geometry.frame.size)
        let bounds = CGRect(origin: .zero, size: geometry.frame.size)
        if surface.view.frame != bounds {
            surface.view.frame = bounds
        }
        updateRegions()
    }

    private func register() {
        registry.register(
            panel,
            surfaceId: surfaceID,
            policy: SurfacePolicy(
                kind: .shellIsland,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: panel.acceptsDeclaredFocus
            ),
            regionProvider: { [weak self] in self?.regions ?? [] }
        )
    }

    private func updateStage() {
        let bounds = CGRect(origin: .zero, size: geometry.frame.size)
        surface.setStage(ShellShaderStage(
            anchor: CGPoint(x: bounds.midX, y: geometry.notch?.height ?? 0),
            content: bounds
        ))
    }

    private func updateRegions() {
        regions = surface.islandRegions().map(geometry.screenRect)
        let hadOutsidePress = hasOutsidePress
        outsidePresses = surface.outsidePressTargets.compactMap { handle in
            var rect = CGRect(surface.layout.core.absoluteFrame(of: handle)).intersection(surface.view.bounds)
            var opacity: Float = 1
            var current = handle
            while surface.layout.core.contains(current) {
                opacity *= surface.layout.core.paint(of: current).opacity
                if surface.layout.core.content(of: current).scrolls {
                    rect = rect.intersection(CGRect(surface.layout.core.absoluteFrame(of: current)))
                }
                current = surface.layout.core.parent(of: current)
            }
            guard opacity > 0, !rect.isNull, !rect.isEmpty else { return nil }
            return OutsidePress(capture: surface.capture(handle), rect: rect)
        }
        if hadOutsidePress != hasOutsidePress { onInputChange?() }
    }

    func close() {
        surface.blurDeclaredFocus()
        surface.onFocusChange = nil
        surface.onResourceDropRegistrationChange = nil
        surface.onResourceDragEnd = nil
        surface.onMove = nil
        panel.onBlur = nil
        surface.setVisible(false)
        outsidePresses.removeAll()
        registry.unregister(panel)
        panel.close()
        onInputChange?()
        onFocusChange = nil
        onBlur = nil
        onInputChange = nil
    }
}
