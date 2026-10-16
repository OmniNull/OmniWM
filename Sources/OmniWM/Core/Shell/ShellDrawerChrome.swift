// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class ShellDrawerChrome {
    private static let surfaceId = "shell-drawer"

    let panel: ShellFocusPanel
    private let drawer: HiddenBarDrawerView
    private let background: NSHostingView<HiddenBarPanelBackground>
    private let content: NSView
    private let motion: MotionPolicy
    private let onJoin: @MainActor (HiddenBarPanelPlacement.Join?) -> Void
    private(set) var placement: HiddenBarPanelPlacement
    private var size: CGSize = .zero
    private var shown = false
    private var closing: (@MainActor () -> Void)?
    var onKeyboardFocus: (@MainActor (Bool) -> Void)?

    init(
        content: NSView,
        placement: HiddenBarPanelPlacement,
        motion: MotionPolicy,
        onJoin: @escaping @MainActor (HiddenBarPanelPlacement.Join?) -> Void
    ) {
        self.content = content
        self.placement = placement
        self.motion = motion
        self.onJoin = onJoin
        panel = ShellFocusPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 200, height: 60)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        background = NSHostingView(rootView: HiddenBarPanelBackground(
            layout: HiddenBarPanelLayout(frame: .zero, body: .zero, seam: nil, hasEars: false),
            placement: nil
        ))
        background.sizingOptions = []
        background.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(background)
        container.addSubview(content)
        drawer = HiddenBarDrawerView(contentView: container)
        panel.contentView = drawer
    }

    func show(size: CGSize, level: NSWindow.Level, duration: CFTimeInterval? = nil) {
        self.size = size
        panel.level = level
        layout()
        guard !shown else { return }
        shown = true
        if !panel.isVisible {
            drawer.setVisible(false, edge: placement.attachment.edge, motion: .disabled)
        }
        panel.ignoresMouseEvents = false
        register(interactive: true)
        panel.orderFrontRegardless()
        onKeyboardFocus?(true)
        drawer.setVisible(true, edge: placement.attachment.edge, motion: motion.snapshot(), duration: duration)
    }

    var isShown: Bool {
        shown
    }

    func move(to placement: HiddenBarPanelPlacement) {
        guard placement != self.placement else { return }
        self.placement = placement
        if shown {
            layout()
        }
    }

    func close(
        animated: Bool,
        duration: CFTimeInterval? = nil,
        onClosed: @escaping @MainActor () -> Void = {}
    ) {
        guard shown else {
            onClosed()
            return
        }
        shown = false
        panel.ignoresMouseEvents = true
        onKeyboardFocus?(false)
        register(interactive: false)
        let finish: @MainActor () -> Void = { [self] in
            closing = nil
            if !shown {
                OwnedWindowRegistry.shared.unregister(panel)
                panel.orderOut(nil)
                onJoin(nil)
            }
            onClosed()
        }
        closing = finish
        drawer.setVisible(
            false,
            edge: placement.attachment.edge,
            motion: animated ? motion.snapshot() : .disabled,
            duration: animated ? duration : nil,
            completion: finish
        )
    }

    func finishClose() {
        guard let closing else { return }
        drawer.setVisible(false, edge: placement.attachment.edge, motion: .disabled, completion: closing)
    }

    func contains(screenPoint point: CGPoint) -> Bool {
        drawer.containsContent(at: drawer.convert(panel.convertPoint(fromScreen: point), from: nil))
    }

    private func register(interactive: Bool) {
        OwnedWindowRegistry.shared.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .hiddenBarPanel,
                hitTestPolicy: interactive ? .interactive : .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: interactive
            )
        )
    }

    private func layout() {
        let layout = placement.layout(size: size)
        let appearance = NSApp.appearance
        panel.appearance = appearance
        drawer.appearance = appearance
        panel.hasShadow = placement.workspaceBar == nil
        panel.setFrame(layout.frame, display: true)
        background.rootView = HiddenBarPanelBackground(layout: layout, placement: placement)
        content.frame = CGRect(
            x: (layout.body.midX - size.width / 2).rounded(),
            y: (layout.frame.height - layout.body.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        drawer.setRevealShape(
            layout.contour(edge: placement.attachment.edge).cgPath,
            spread: layout.seam == nil ? 0 : HiddenBarPanelPlacement.liftMargin
        )
        onJoin(layout.squaresBar ? placement.join : nil)
    }
}
