// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMLayerCorners
import QuartzCore

@MainActor
class NiriEdgePictureWindow: NSPanel, NiriEdgePictureSurface {
    private let pictureLayer = CALayer()
    private let button = NSButton()
    private var displayedContent: NiriPictureContent?
    private var visibilityChanged: (@MainActor () -> Void)?
    private var activate: (@MainActor () -> Void)?
    private var orderBelowWindowId: Int?
    private var visiblePictureFrame: CGRect?
    private var windowServerPlacement: (appKitFrame: CGRect, frame: CGRect)?
    private var laidOutPictureSize: CGSize?
    private var hasOrderedIn = false

    init() {
        omniwm_window_manager_begin_coordinator_capture()
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .normal
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        omniwm_window_manager_end_coordinator_capture()
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
            object: self
        )
        SurfaceCoordinator.shared.register(
            window: self, id: surfaceID,
            policy: SurfacePolicy(
                kind: .niriEdgePicture, hitTestPolicy: .interactive,
                capturePolicy: .excluded, suppressesManagedFocusRecovery: false
            ),
            frameProvider: { [weak self] in self?.visiblePictureFrame },
            visibilityProvider: { [weak self] in self?.hasOrderedIn == true }
        )
    }

    private var surfaceID: String {
        "niri-edge-picture-\(ObjectIdentifier(self))"
    }

    var windowId: UInt32? {
        guard windowNumber > 0 else { return nil }
        return UInt32(exactly: windowNumber)
    }

    var isVisibleForCapture: Bool {
        hasOrderedIn && occlusionState.contains(.visible)
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

    override func sendEvent(_ event: NSEvent) {
        guard !event.isWindowServerMove else { return }
        super.sendEvent(event)
    }

    private var placedFrame: CGRect {
        windowServerPlacement.flatMap { $0.appKitFrame == frame ? $0.frame : nil } ?? frame
    }

    override func convertToScreen(_ rect: NSRect) -> NSRect {
        let placed = placedFrame
        return rect.offsetBy(dx: placed.minX, dy: placed.minY)
    }

    func setOrderingTarget(_ windowId: Int?) {
        orderBelowWindowId = windowId
    }

    func update(
        geometry: NiriEdgePictureGeometry,
        content: NiriPictureContent,
        activate: @escaping @MainActor () -> Void
    ) {
        self.activate = activate
        visiblePictureFrame = geometry.visibleFrame
        let unclipped = !geometry.requiresDisplayClip
        let target = unclipped ? SurfacePanelGeometry.backingFrame(for: geometry.frame) : geometry.panelFrame
        let contentChanged = !content.matches(displayedContent)
        if unclipped, laidOutPictureSize == geometry.frame.size, placeInWindowServer(target) {
            if contentChanged { setContent(content) }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setFrameReconcilingWindowServer(target)
            laidOutPictureSize = unclipped ? geometry.frame.size : nil
            let bounds = CGRect(origin: .zero, size: target.size)
            contentView?.frame = bounds
            button.frame = unclipped ? CGRect(origin: .zero, size: geometry.frame.size) : bounds
            pictureLayer.frame = unclipped ? CGRect(origin: .zero, size: geometry.frame.size) : geometry.pictureFrame
            if contentChanged { applyContent(content) }
            CATransaction.commit()
        }
        if !hasOrderedIn {
            hasOrderedIn = true
            orderIn()
        }
    }

    func orderIn() {
        if !isVisible { orderFrontRegardless() }
        orderInWindowServer(below: orderBelowWindowId.flatMap(UInt32.init(exactly:)))
    }

    func orderInWindowServer(below target: UInt32?) {
        SkyLight.shared.orderWindow(
            UInt32(windowNumber),
            relativeTo: target ?? 0,
            order: target == nil ? .above : .below
        )
        if let target { order(.below, directlyRelativeTo: target) }
    }

    private func placeInWindowServer(_ target: CGRect) -> Bool {
        guard placedFrame != target else { return true }
        guard target.size == frame.size, staysOnItsDisplay(at: target), moveInWindowServer(to: target)
        else { return false }
        windowServerPlacement = (frame, target)
        return true
    }

    func moveInWindowServer(to target: CGRect) -> Bool {
        SkyLight.shared.transactionMove(
            UInt32(windowNumber), origin: ScreenCoordinateSpace.toWindowServer(rect: target).origin
        )
    }

    private func setFrameReconcilingWindowServer(_ target: CGRect) {
        let previous = windowServerPlacement.flatMap { $0.appKitFrame == frame ? $0.frame : nil }
        if frame != target { setFrame(target, display: false) }
        if let previous, previous != frame, !moveInWindowServer(to: target) {
            setFrame(previous, display: false)
            setFrame(target, display: false)
        }
        windowServerPlacement = nil
    }

    func setContent(_ content: NiriPictureContent) {
        guard !content.matches(displayedContent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyContent(content)
        CATransaction.commit()
    }

    private func applyContent(_ content: NiriPictureContent) {
        let previous = displayedContent
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        displayedContent = content
        pictureLayer.contents = content.layerContents
        pictureLayer.contentsRect = content.contentsRect
    }

    func observeVisibility(_ changed: (@MainActor () -> Void)?) {
        visibilityChanged = changed
    }

    @objc private func occlusionChanged() {
        visibilityChanged?()
    }

    func hide() {
        visibilityChanged = nil
        activate = nil
        visiblePictureFrame = nil
        hasOrderedIn = false
        SkyLight.shared.transactionHide(UInt32(windowNumber))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let previous = displayedContent
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        pictureLayer.contents = nil
        pictureLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        displayedContent = nil
        CATransaction.commit()
    }

    func destroy() {
        visibilityChanged = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: self
        )
        activate = nil
        SurfaceCoordinator.shared.unregister(id: surfaceID)
        orderOut(nil)
        close()
    }

    @objc private func selectPicture() {
        activate?()
    }
}
