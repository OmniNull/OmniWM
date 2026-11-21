// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class OverviewWindow: NSPanel {
    private let overlayView: OverviewView
    private let monitor: Monitor

    var monitorId: Monitor.ID {
        monitor.id
    }

    var displayId: CGDirectDisplayID {
        monitor.displayId
    }

    var onWindowSelected: ((Monitor.ID, WindowHandle) -> Void)?
    var onWindowClosed: ((Monitor.ID, WindowHandle) -> Void)?
    var onNewWorkspace: ((Monitor.ID) -> Void)?
    var onTabSelected: ((Monitor.ID, WindowHandle) -> Void)?
    var onClearSearch: ((Monitor.ID) -> Void)?
    var isTabPickerOpen: Bool {
        overlayView.isTabPickerOpen
    }

    var onStripPan: ((Monitor.ID, CGPoint, CGFloat) -> Void)?
    var onWorkspaceSelected: ((Monitor.ID, WorkspaceDescriptor.ID) -> Void)?
    var onOverflowPillPressed: ((Monitor.ID, OverviewOverflowPill) -> Void)?
    var onDismiss: ((Monitor.ID) -> Void)?
    var onScroll: ((Monitor.ID, CGFloat) -> Void)?
    var onScrollEvent: ((Monitor.ID, OverviewScrollInput.Event) -> Void)?
    var onDragBegin: ((Monitor.ID, WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((Monitor.ID, CGPoint) -> Void)?
    var onDragEnd: ((Monitor.ID, CGPoint) -> Void)?
    var previewForHandle: ((WindowHandle) -> OverviewPreviewFrame?)? {
        get { overlayView.layerRenderer.previewForHandle }
        set { overlayView.layerRenderer.previewForHandle = newValue }
    }

    var wallpaperForDisplay: ((CGDirectDisplayID, Int) -> CGImage?)? {
        get { overlayView.layerRenderer.wallpaperForDisplay }
        set { overlayView.layerRenderer.wallpaperForDisplay = newValue }
    }

    init(monitor: Monitor, palette: OverviewRenderPalette = .default) {
        self.monitor = monitor
        overlayView = OverviewView(frame: .zero, displayId: monitor.displayId, palette: palette)

        super.init(
            contentRect: monitor.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        bindOverlayEvents()
    }

    private func configurePanel() {
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true

        let bounds = CGRect(origin: .zero, size: monitor.frame.size)
        let container = NSView(frame: bounds)
        let glass = NSGlassEffectView(frame: bounds)
        glass.style = .regular
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.opacity = 0
        glass.autoresizingMask = [.width, .height]
        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        container.addSubview(overlayView)
        overlayView.layerRenderer.glassLayer = glass.layer
        contentView = container
    }

    private func bindOverlayEvents() {
        bindRibbonEvents()
        overlayView.onWindowSelected = { [weak self] handle in
            guard let self else { return }
            self.onWindowSelected?(self.monitor.id, handle)
        }
        overlayView.onWindowClosed = { [weak self] handle in
            guard let self else { return }
            self.onWindowClosed?(self.monitor.id, handle)
        }
        overlayView.onWorkspaceSelected = { [weak self] workspaceId in
            guard let self else { return }
            self.onWorkspaceSelected?(self.monitor.id, workspaceId)
        }
        overlayView.onOverflowPillPressed = { [weak self] pill in
            guard let self else { return }
            self.onOverflowPillPressed?(self.monitor.id, pill)
        }
        overlayView.onDismiss = { [weak self] in
            guard let self else { return }
            self.onDismiss?(self.monitor.id)
        }
        overlayView.onScroll = { [weak self] delta in
            guard let self else { return }
            self.onScroll?(self.monitor.id, delta)
        }
        overlayView.onScrollEvent = { [weak self] event in
            guard let self else { return }
            self.onScrollEvent?(self.monitor.id, event)
        }
        overlayView.onDragBegin = { [weak self] handle, start in
            guard let self else { return }
            self.onDragBegin?(self.monitor.id, handle, start)
        }
        overlayView.onDragUpdate = { [weak self] point in
            guard let self else { return }
            self.onDragUpdate?(self.monitor.id, point)
        }
        overlayView.onDragEnd = { [weak self] point in
            guard let self else { return }
            self.onDragEnd?(self.monitor.id, point)
        }
    }

    private func bindRibbonEvents() {
        overlayView.onClearSearch = { [weak self] in
            guard let self else { return }
            self.onClearSearch?(self.monitor.id)
        }
        overlayView.onNewWorkspace = { [weak self] in
            guard let self else { return }
            self.onNewWorkspace?(self.monitor.id)
        }
        overlayView.onTabSelected = { [weak self] handle in
            guard let self else { return }
            self.onTabSelected?(self.monitor.id, handle)
        }
        overlayView.onStripPan = { [weak self] point, delta in
            guard let self else { return }
            self.onStripPan?(self.monitor.id, point, delta)
        }
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    func show(asKeyWindow: Bool) {
        setFrame(monitor.frame, display: false)
        overlayView.frame = CGRect(origin: .zero, size: monitor.frame.size)
        if asKeyWindow {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(overlayView)
        } else {
            orderFrontRegardless()
        }
    }

    func hide() {
        overlayView.closeTabPicker()
        orderOut(nil)
        overlayView.cancelAnimation()
        overlayView.clearPreviews()
    }

    func updateLayout(
        _ layout: OverviewLayout,
        state: OverviewState,
        searchQuery: String,
        selectedWindowHandle: WindowHandle?,
        palette: OverviewRenderPalette? = nil,
        animationsEnabled: Bool = true,
        selection: OverviewSelection? = nil,
        update: OverviewLayoutUpdate = .preserve
    ) {
        overlayView.updateLayout(
            layout,
            state: state,
            searchQuery: searchQuery,
            selectedWindowHandle: selectedWindowHandle,
            palette: palette,
            animationsEnabled: animationsEnabled,
            selection: selection,
            update: update
        )
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle, animated: Bool = true) {
        overlayView.updatePreview(frame, for: handle, animated: animated)
    }

    func installAnimation(_ transition: OverviewNativeTransition, completion: OverviewAnimationCompletion) -> Bool {
        overlayView.installAnimation(transition, completion: completion)
    }

    func cancelAnimation() {
        overlayView.cancelAnimation()
    }

    func presentProgress(_ progress: Double) {
        overlayView.presentProgress(progress)
    }

    func updatePalette(_ palette: OverviewRenderPalette) {
        overlayView.updatePalette(palette)
    }
}
