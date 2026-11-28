// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class OverviewView: NSView {
    private(set) var layout: OverviewLayout = .init()
    private(set) var searchQuery: String = ""
    private(set) var palette: OverviewRenderPalette
    private(set) var selection: OverviewSelection?
    var selectedWindowHandle: WindowHandle? {
        selection?.windowHandle
    }

    private(set) var presentationProgress: Double = 0

    private let displayId: CGDirectDisplayID

    var onWindowSelected: ((WindowHandle) -> Void)?
    var onWindowClosed: ((WindowHandle) -> Void)?
    var onNewWorkspace: (() -> Void)?
    var onTabSelected: ((WindowHandle) -> Void)?
    var onClearSearch: (() -> Void)?
    var onStripPan: ((CGPoint, CGFloat) -> Void)?
    var onWorkspaceSelected: ((WorkspaceDescriptor.ID) -> Void)?
    var onOverflowPillPressed: ((OverviewOverflowPill) -> Void)?
    var onDismiss: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onScrollEvent: ((OverviewScrollInput.Event) -> Void)?
    var onDragBegin: ((WindowHandle, CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?

    private var camera: OverviewPinchCamera {
        layerRenderer.camera
    }

    private var trackingArea: NSTrackingArea?
    private var rightDragPoint: CGPoint?
    private var dragCandidateHandle: WindowHandle?
    private var dragStartPoint: CGPoint = .zero
    private var isDragging: Bool = false
    private var hoveredWindowHandle: WindowHandle?
    private var closeButtonHovered = false
    private var tabPicker: OverviewTabPicker?
    var isTabPickerOpen: Bool {
        tabPicker != nil
    }

    let layerRenderer: OverviewLayerRenderer
    private let dragThreshold: CGFloat = 6.0

    init(
        frame: NSRect,
        displayId: CGDirectDisplayID = CGMainDisplayID(),
        palette: OverviewRenderPalette = .default
    ) {
        self.displayId = displayId
        self.palette = palette
        layerRenderer = OverviewLayerRenderer(displayId: displayId)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(layerRenderer.root)
    }

    required init?(coder _: NSCoder) {
        nil
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
        self.layout = layout
        camera.updateLayout(layout, state: state, animationsEnabled: animationsEnabled)
        self.searchQuery = searchQuery
        self.selection = selection ?? selectedWindowHandle.map(OverviewSelection.window)
        if let tabPicker,
           !state.isOpen || state.isAnimating || layout.window(for: tabPicker.handle)?.isDisplayed != true
        {
            closeTabPicker()
        }
        if let hoveredWindowHandle,
           layout.window(for: hoveredWindowHandle)?.matchesSearch != true
        {
            self.hoveredWindowHandle = nil
            closeButtonHovered = false
        }
        switch state {
        case .closed:
            cancelAnimation()
            presentationProgress = 0
        case .open:
            if layerRenderer.activeTransition != nil { cancelAnimation() }
            presentationProgress = 1
        case .opening,
             .closing:
            break
        }
        if let palette {
            self.palette = palette
        }
        layerRenderer.updateLayout(
            layout,
            state: renderState,
            caretAnimated: !state.isAnimating && state.isOpen && animationsEnabled,
            update: update,
            animationsEnabled: animationsEnabled
        )
        needsDisplay = true
    }

    @discardableResult
    func installAnimation(_ transition: OverviewNativeTransition, completion: OverviewAnimationCompletion) -> Bool {
        if layerRenderer.root.bounds.isEmpty { updateLayer() }
        presentationProgress = transition.target
        needsDisplay = false
        guard window != nil, transition.duration > 0 else {
            cancelAnimation()
            updateLayer()
            return false
        }
        layerRenderer.installAnimation(transition, layout: layout, state: renderState, completion: completion)
        return true
    }

    func cancelAnimation() {
        camera.reset()
        layout = layerRenderer.freezingReflow(in: layout)
        layerRenderer.cancelAnimation()
    }

    func presentProgress(_ progress: Double) {
        presentationProgress = progress
        needsDisplay = true
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle, animated: Bool = true) {
        layerRenderer.updatePreview(frame, for: handle, animated: animated)
    }

    func clearPreviews() {
        layerRenderer.clearPreviews()
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layerRenderer.updateContentsScale(window?.backingScaleFactor ?? 1)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layerRenderer.updateContentsScale(window?.backingScaleFactor ?? 1)
    }

    func updatePalette(_ palette: OverviewRenderPalette) {
        self.palette = palette
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoverState(at: camera.scenePoint(at: point))
    }

    func magnify(with event: NSEvent, at point: CGPoint) {
        guard dragCandidateHandle == nil, rightDragPoint == nil, !isTabPickerOpen else { return }
        if let handle = camera.magnify(with: event, at: point, hitTest: pinchTarget) {
            onWindowSelected?(handle)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !camera.isTracking else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = camera.scenePoint(at: viewPoint)
        camera.reset()
        if !searchQuery.isEmpty, layout.searchClearFrame.contains(viewPoint) {
            onClearSearch?()
            return
        }
        let layoutPoint = layerRenderer.layoutPoint(at: point, layout: layout)
        if let pill = layout.overflowPill(at: layoutPoint) {
            onOverflowPillPressed?(pill)
            return
        }
        if let control = layerRenderer.tabControl(at: point, layout: layout) {
            if let handle = control.steppedHandle(at: point) {
                onTabSelected?(handle)
            } else if control.frame(for: .picker).contains(point) {
                showTabPicker(control)
            }
            return
        }
        let adjustedPoint = CGPoint(x: layoutPoint.x, y: layoutPoint.y + layout.scrollOffset)
        if layout.newWorkspaceTarget?.frame.contains(adjustedPoint) == true {
            onNewWorkspace?()
            return
        }
        let hit = layerRenderer.windowHit(at: point, layout: layout)

        if let hit, hit.isCloseButton {
            onWindowClosed?(hit.window.handle)
            return
        }

        if let window = hit?.window {
            dragCandidateHandle = window.handle
            dragStartPoint = viewPoint
            isDragging = false
            return
        }

        if let section = layout.ribbonSection(at: layoutPoint) {
            onWorkspaceSelected?(section.workspaceId)
            return
        }

        onDismiss?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = dragCandidateHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y)

        if !isDragging {
            guard distance >= dragThreshold else { return }
            closeTabPicker()
            layerRenderer.cancelReflow()
            isDragging = true
            onDragBegin?(handle, dragStartPoint)
        }

        onDragUpdate?(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let handle = dragCandidateHandle else { return }
        let dragged = isDragging
        cancelDragState()
        if dragged {
            onDragEnd?(convert(event.locationInWindow, from: nil))
        } else {
            onWindowSelected?(handle)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !camera.isTracking else { return }
        camera.reset()
        rightDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let previous = rightDragPoint else { return }
        onStripPan?(layerRenderer.layoutPoint(at: point, layout: layout), point.x - previous.x)
        rightDragPoint = point
    }

    override func rightMouseUp(with event: NSEvent) {
        rightDragPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard !camera.isTracking else { return }
        if let onScrollEvent {
            let point = camera.scenePoint(at: convert(event.locationInWindow, from: nil))
            onScrollEvent(OverviewScrollInput.Event(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                modifiers: event.modifierFlags,
                isPrecise: event.hasPreciseScrollingDeltas,
                location: layerRenderer.layoutPoint(at: point, layout: layout),
                phase: event.phase,
                momentumPhase: event.momentumPhase
            ))
        } else {
            onScroll?(OverviewScrollInput.dominantDelta(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY))
        }
    }

    override func updateLayer() {
        let traceActive = OverviewFrameTrace.shared.isActive
        let start = traceActive ? CACurrentMediaTime() : 0
        layerRenderer.updatePresentation(layout, state: renderState)
        if traceActive {
            let end = CACurrentMediaTime()
            OverviewFrameTrace.shared.record(OverviewFrameTrace.Record(
                event: .layerApply,
                mediaTime: end,
                displayId: displayId,
                generation: layerRenderer.activeTransition?.generation ?? 0,
                sequence: 0,
                progress: presentationProgress,
                durationMs: (end - start) * 1000,
                waitMs: 0,
                targetLeadMs: 0,
                pendingInvalidations: 0,
                endpointScheduled: false,
                sessionCompleted: false
            ))
        }
    }
}

extension OverviewView {
    func closeTabPicker() {
        tabPicker?.cancel()
        tabPicker = nil
    }

    private func cancelDragState() {
        dragCandidateHandle = nil
        isDragging = false
    }

    private func updateHoverState(at point: CGPoint) {
        let hit = layerRenderer.windowHit(at: point, layout: layout)
        let nextHoveredHandle = hit?.window.handle
        let nextCloseButtonHovered = hit?.isCloseButton ?? false
        guard nextHoveredHandle != hoveredWindowHandle
            || nextCloseButtonHovered != closeButtonHovered
        else { return }
        let previous = hoveredWindowHandle
        hoveredWindowHandle = nextHoveredHandle
        closeButtonHovered = nextCloseButtonHovered
        layerRenderer.updateHover(from: previous, layout: layout, state: renderState)
    }

    private func pinchTarget(at point: CGPoint) -> WindowHandle? {
        guard bounds.contains(point) else { return nil }
        let scene = camera.scenePoint(at: point)
        let layoutPoint = layerRenderer.layoutPoint(at: scene, layout: layout)
        let contentPoint = CGPoint(x: layoutPoint.x, y: layoutPoint.y + layout.scrollOffset)
        guard layout.newWorkspaceTarget?.frame.contains(contentPoint) != true,
              !layout.searchBarFrame.contains(point),
              layerRenderer.tabControl(at: scene, layout: layout) == nil,
              layout.overflowPill(at: layoutPoint) == nil,
              let hit = layerRenderer.windowHit(at: scene, layout: layout), !hit.isCloseButton
        else { return nil }
        return hit.window.handle
    }

    private func showTabPicker(_ control: OverviewTabControl) {
        let members = layout.tabMembers(for: control.handle)
        guard members.count > 1 else { return }
        let picker = OverviewTabPicker(handle: control.handle, members: members) { [weak self] handle in
            guard let self,
                  self.layout.tabMembers(for: control.handle).contains(where: { $0.handle == handle }) else { return }
            self.onTabSelected?(handle)
        }
        tabPicker = picker
        defer { if tabPicker === picker { tabPicker = nil } }
        picker.menu.popUp(
            positioning: nil,
            at: CGPoint(x: control.frame.minX, y: control.frame.minY),
            in: self
        )
    }

    private var renderState: OverviewRenderState {
        OverviewRenderState(
            searchQuery: searchQuery,
            selectedWindowHandle: selectedWindowHandle,
            hoveredWindowHandle: hoveredWindowHandle,
            closeButtonHovered: closeButtonHovered,
            progress: presentationProgress,
            bounds: bounds,
            palette: palette,
            selection: selection
        )
    }
}
