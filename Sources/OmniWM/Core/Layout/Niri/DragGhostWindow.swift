// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class DragGhostWindow: NSPanel {
    private let contentLayer = CALayer()
    private let surfaceCoordinator: SurfaceCoordinator
    private var surfaceId: String?
    private var preview: OverviewPreviewFrame?
    private var isDestroyed = false

    init(surfaceCoordinator: SurfaceCoordinator = .shared) {
        self.surfaceCoordinator = surfaceCoordinator

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        alphaValue = 0.5

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer = contentLayer
        contentLayer.contentsGravity = .resizeAspect
        contentView = view

        let surfaceId = "drag-ghost-\(ObjectIdentifier(self).hashValue)"
        self.surfaceId = surfaceId
        surfaceCoordinator.register(
            window: self,
            id: surfaceId,
            policy: SurfacePolicy(
                kind: .dragGhost,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
    }

    isolated deinit {
        destroy()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func setContents(_ contents: Any, contentsRect: CGRect, holding retained: OverviewPreviewFrame?, size: CGSize) {
        let previous = preview
        preview = retained
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        contentLayer.contents = contents
        contentLayer.contentsRect = contentsRect
        contentLayer.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        setFrame(CGRect(origin: frame.origin, size: size), display: false)
        contentView?.frame = CGRect(origin: .zero, size: size)
    }

    func moveTo(cursorLocation: CGPoint) {
        let origin = CGPoint(
            x: cursorLocation.x + 10,
            y: cursorLocation.y - frame.height - 10
        )
        setFrameOrigin(origin)
    }

    func showAt(cursorLocation: CGPoint) {
        moveTo(cursorLocation: cursorLocation)
        orderFront(nil)
    }

    func hideGhost() {
        orderOut(nil)
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        if let surfaceId {
            surfaceCoordinator.unregister(id: surfaceId)
            self.surfaceId = nil
        }
        contentLayer.contents = nil
        preview = nil
        orderOut(nil)
        close()
    }
}
