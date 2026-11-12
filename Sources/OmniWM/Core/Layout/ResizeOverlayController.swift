// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class ResizeOverlayController {
    typealias ImageCapture = @MainActor (WindowToken, CGSize) async -> CGImage?

    private enum Phase {
        case idle
        case tracking
        case settling
    }

    private(set) var workspaceId: WorkspaceDescriptor.ID?
    private(set) var panels: [WindowToken: ResizeOverlayTile] = [:]
    private var hosts: [ResizeOverlayHost] = []
    private(set) var captureTasks: [WindowToken: Task<Void, Never>] = [:]
    private(set) var settlesOnLayout = false
    private var phase = Phase.idle
    private var style = ResizePreviewStyle.live
    private var pointerDriven = false
    private var watchdog: Task<Void, Never>?
    private let surfaceCoordinator: SurfaceCoordinator
    private let previews: PreviewCaptureCoordinator
    private let captureAccessAllowed: @MainActor () -> Bool
    private let captureImage: ImageCapture
    private let currentFrame: @MainActor (WindowToken) -> CGRect?
    private let monitorFrame: @MainActor (WorkspaceDescriptor.ID) -> CGRect?
    private let icon: @MainActor (WindowToken) -> NSImage?
    private let requestRelayout: @MainActor (WorkspaceDescriptor.ID) -> Void

    init(
        surfaceCoordinator: SurfaceCoordinator = .shared,
        previews: PreviewCaptureCoordinator = .shared,
        captureAccessAllowed: @escaping @MainActor () -> Bool = { ScreenCapturePermissionMonitor.shared.isGranted },
        captureImage: ImageCapture? = nil,
        currentFrame: @escaping @MainActor (WindowToken) -> CGRect?,
        monitorFrame: @escaping @MainActor (WorkspaceDescriptor.ID) -> CGRect? = { _ in nil },
        icon: @escaping @MainActor (WindowToken) -> NSImage? = { _ in nil },
        requestRelayout: @escaping @MainActor (WorkspaceDescriptor.ID) -> Void = { _ in }
    ) {
        self.surfaceCoordinator = surfaceCoordinator
        self.previews = previews
        self.captureAccessAllowed = captureAccessAllowed
        self.captureImage = captureImage ?? { token, pixelSize in
            await DragGhostController.captureWindowImage(token: token, pixelSize: pixelSize, previews: previews)
        }
        self.currentFrame = currentFrame
        self.monitorFrame = monitorFrame
        self.icon = icon
        self.requestRelayout = requestRelayout
    }

    var isActive: Bool {
        phase != .idle
    }

    func isTracking(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        phase == .tracking && self.workspaceId == workspaceId
    }

    func begin(workspaceId: WorkspaceDescriptor.ID, style: ResizePreviewStyle, pointerDriven: Bool) {
        guard style != .live else { return }
        if self.workspaceId != workspaceId || self.style != style {
            reset()
        }
        self.workspaceId = workspaceId
        self.style = style
        self.pointerDriven = pointerDriven
        settlesOnLayout = false
        phase = .tracking
        armWatchdog()
    }

    func settleOnLayout(in workspaceId: WorkspaceDescriptor.ID? = nil) {
        guard phase == .tracking, workspaceId == nil || workspaceId == self.workspaceId else { return }
        settlesOnLayout = true
        armWatchdog()
    }

    func intercept(_ plan: WorkspaceLayoutPlan) -> WorkspaceLayoutPlan? {
        guard isTracking(plan.workspaceId) else { return nil }
        update(plan.diff.frameChanges)
        if settlesOnLayout, !plan.isAnimationTick {
            finish()
            return nil
        }
        var plan = plan
        plan.diff.frameChanges.removeAll()
        return plan
    }

    func update(_ changes: [LayoutFrameChange]) {
        guard phase == .tracking else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for change in changes {
            if let panel = panels[change.token] {
                panel.updateFrame(change.frame)
            } else if let start = currentFrame(change.token),
                      !start.approximatelyEqual(to: change.frame, tolerance: FrameTolerance.frameWrite),
                      let host = host(for: start.union(change.frame))
            {
                addPanel(token: change.token, from: start, to: change.frame, in: host)
            }
        }
        CATransaction.commit()
        armWatchdog()
    }

    func finish() {
        guard phase == .tracking else { return }
        phase = .settling
        for (token, panel) in panels
            where currentFrame(token)?
            .approximatelyEqual(to: panel.targetFrame, tolerance: FrameTolerance.frameWrite) == true
        {
            retire(token)
        }
        if panels.isEmpty {
            reset()
        } else {
            armWatchdog()
        }
    }

    func frameApplied(windowId: Int) {
        guard phase == .settling, let token = panels.keys.first(where: { $0.windowId == windowId }) else { return }
        retire(token)
        if panels.isEmpty {
            reset()
        }
    }

    func reset() {
        watchdog?.cancel()
        watchdog = nil
        for token in Array(panels.keys) {
            retire(token)
        }
        let screens = NSScreen.screens.map(\.frame)
        hosts.removeAll { host in
            host.orderOut(nil)
            guard !screens.contains(host.frame) else { return false }
            host.destroy()
            return true
        }
        workspaceId = nil
        settlesOnLayout = false
        phase = .idle
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        guard phase == .settling || settlesOnLayout || !pointerDriven else { return }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            if phase == .tracking, let workspaceId {
                settlesOnLayout = true
                requestRelayout(workspaceId)
            } else {
                reset()
            }
        }
    }

    private func host(for frame: CGRect) -> ResizeOverlayHost? {
        guard let screen = workspaceId.flatMap(monitorFrame) ?? NSScreen.screen(containing: frame)?.frame,
              screen.intersects(frame)
        else { return nil }
        if let host = hosts.first(where: { $0.frame == screen }) {
            return host
        }
        let host = ResizeOverlayHost(frame: screen, surfaceCoordinator: surfaceCoordinator)
        hosts.append(host)
        return host
    }

    private func addPanel(token: WindowToken, from start: CGRect, to frame: CGRect, in host: ResizeOverlayHost) {
        let panel = ResizeOverlayTile(icon: icon(token), frame: start, in: host)
        panel.updateFrame(frame)
        panels[token] = panel
        if !host.isVisible {
            host.orderFrontRegardless()
        }
        guard style == .snapshot, captureAccessAllowed() else {
            panel.isHidden = false
            return
        }
        if let shared = previews.sharedPreview(for: token)?.frame {
            panel.setSnapshot(shared.surface, contentsRect: shared.contentsRect, holding: shared)
            panel.isHidden = false
        }
        let scale = NSScreen.screen(containing: start)?.backingScaleFactor ?? 2
        let pixelSize = CGSize(width: (start.width * scale).rounded(), height: (start.height * scale).rounded())
        captureTasks[token] = Task { [weak self, captureImage] in
            let image = await captureImage(token, pixelSize)
            guard !Task.isCancelled, let panel = self?.panels[token] else { return }
            if let image {
                panel.setSnapshot(image)
            }
            panel.isHidden = false
        }
    }

    private func retire(_ token: WindowToken) {
        captureTasks.removeValue(forKey: token)?.cancel()
        panels.removeValue(forKey: token)?.destroy()
    }
}

@MainActor
final class ResizeOverlayHost: NSPanel {
    private let surfaceCoordinator: SurfaceCoordinator
    private var surfaceId: String?

    init(frame: CGRect, surfaceCoordinator: SurfaceCoordinator = .shared) {
        self.surfaceCoordinator = surfaceCoordinator

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(frame, display: false)

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        contentView = root

        let surfaceId = "resize-overlay-\(ObjectIdentifier(self).hashValue)"
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

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    func destroy() {
        if let surfaceId {
            surfaceCoordinator.unregister(id: surfaceId)
            self.surfaceId = nil
        }
        orderOut(nil)
        close()
    }
}

@MainActor
final class ResizeOverlayTile: NSView {
    private static let cornerRadius: CGFloat = 10
    private let content = NSView()
    private let iconView = NSImageView()
    private let snapshotView = NSView()
    private var preview: OverviewPreviewFrame?
    private(set) var targetFrame: CGRect = .zero

    var showsSnapshot: Bool {
        !snapshotView.isHidden
    }

    var isVisible: Bool {
        !isHidden && window?.isVisible == true
    }

    init(icon: NSImage?, frame: CGRect, in host: ResizeOverlayHost) {
        super.init(frame: .zero)
        isHidden = true
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1.5
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        addSubview(content)

        let glassView = NSGlassEffectView(frame: CGRect(origin: .zero, size: host.frame.size))
        glassView.style = .regular
        content.addSubview(glassView)

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(iconView)

        snapshotView.wantsLayer = true
        snapshotView.layer?.contentsGravity = .resize
        snapshotView.isHidden = true
        content.addSubview(snapshotView)

        host.contentView?.addSubview(self)
        updateFrame(frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSnapshot(
        _ contents: Any,
        contentsRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        holding retained: OverviewPreviewFrame? = nil
    ) {
        let previous = preview
        preview = retained
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        snapshotView.layer?.contents = contents
        snapshotView.layer?.contentsRect = contentsRect
        snapshotView.isHidden = false
        CATransaction.commit()
    }

    func updateFrame(_ frame: CGRect) {
        targetFrame = frame
        let origin = window?.frame.origin ?? .zero
        let bounds = CGRect(origin: .zero, size: frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame.offsetBy(dx: -origin.x, dy: -origin.y)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        content.frame = bounds
        snapshotView.frame = bounds
        let iconSize: CGFloat = min(96, min(frame.width, frame.height) * 0.4)
        iconView.frame = CGRect(
            x: (frame.width - iconSize) / 2,
            y: (frame.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        CATransaction.commit()
    }

    func destroy() {
        snapshotView.layer?.contents = nil
        preview = nil
        removeFromSuperview()
    }
}
