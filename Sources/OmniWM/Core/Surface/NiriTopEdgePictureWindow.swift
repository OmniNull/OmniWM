// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class NiriTopEdgePictureWindow: NSPanel, NiriTopEdgePictureSurface {
    private let pictureLayer = CALayer()
    private let button = NSButton()
    private var activate: (@MainActor () -> Void)?
    private let orderBelowWindowId: Int?
    private var hasOrderedIn = false

    init(orderBelowWindowId: Int? = nil) {
        self.orderBelowWindowId = orderBelowWindowId
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = false
        isOpaque = false
        backgroundColor = .clear
        level = .normal
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.masksToBounds = true
        root.layer?.addSublayer(pictureLayer)
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = #selector(selectPicture)
        button.sendAction(on: .leftMouseUp)
        root.addSubview(button)
        contentView = root
        SurfaceCoordinator.shared.register(
            window: self,
            id: "niri-top-picture-\(ObjectIdentifier(self))",
            policy: SurfacePolicy(
                kind: .niriTopEdgePicture,
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

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    func update(geometry: NiriTopEdgePictureGeometry, image: CGImage, activate: @escaping @MainActor () -> Void) {
        self.activate = activate
        setFrame(geometry.visibleFrame, display: false)
        let bounds = CGRect(origin: .zero, size: geometry.visibleFrame.size)
        contentView?.frame = bounds
        button.frame = bounds
        pictureLayer.frame = geometry.pictureFrame
        pictureLayer.contents = image
        if !hasOrderedIn {
            hasOrderedIn = true
            orderFrontRegardless()
            if let target = orderBelowWindowId.flatMap(UInt32.init(exactly:)) {
                SkyLight.shared.orderWindow(UInt32(windowNumber), relativeTo: target, order: .below)
            }
        }
    }

    func destroy() {
        activate = nil
        SurfaceCoordinator.shared.unregister(window: self)
        orderOut(nil)
        close()
    }

    @objc private func selectPicture() {
        activate?()
    }
}
