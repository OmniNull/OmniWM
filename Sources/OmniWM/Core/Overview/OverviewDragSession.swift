// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class OverviewDragAutoScroll: NSObject {
    private var link: CADisplayLink?
    private(set) var monitorId: Monitor.ID?
    var pointer: CGPoint = .zero
    var velocity: CGFloat = 0
    var horizontalVelocity: CGFloat = 0
    var stripWorkspaceId: WorkspaceDescriptor.ID?
    var onTick: ((Monitor.ID, CGFloat) -> Void)?
    var onStripTick: ((Monitor.ID, WorkspaceDescriptor.ID, CGFloat) -> Void)?

    func update(
        monitorId: Monitor.ID,
        pointer: CGPoint,
        velocity: CGFloat,
        horizontalVelocity: CGFloat = 0,
        stripWorkspaceId: WorkspaceDescriptor.ID? = nil
    ) {
        self.pointer = pointer
        guard velocity != 0 || horizontalVelocity != 0 else {
            stop()
            return
        }
        if self.monitorId != monitorId || link == nil {
            stop()
            guard let screen = NSScreen.screens.first(where: { $0.displayId == monitorId.displayId }) else { return }
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            self.monitorId = monitorId
        }
        self.velocity = velocity
        self.horizontalVelocity = horizontalVelocity
        self.stripWorkspaceId = stripWorkspaceId
    }

    func stop() {
        link?.invalidate()
        link = nil
        monitorId = nil
        velocity = 0
        horizontalVelocity = 0
        stripWorkspaceId = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        advance(by: link.targetTimestamp - link.timestamp)
    }

    func advance(by duration: CFTimeInterval) {
        guard let monitorId, velocity != 0 || horizontalVelocity != 0 else { return }
        if velocity != 0 {
            onTick?(monitorId, velocity * CGFloat(duration))
        }
        if let stripWorkspaceId, horizontalVelocity != 0 {
            onStripTick?(monitorId, stripWorkspaceId, horizontalVelocity * CGFloat(duration))
        }
    }
}

@MainActor
final class OverviewDragSession {
    private weak var overview: OverviewController?
    private let projection: OverviewViewportProjection
    private let overviewSnapshot: OverviewSnapshot
    private let windowSession: OverviewWindowSession
    private let structuralActions: OverviewStructuralActions
    private let mutationSession: OverviewMutationSession
    private var dragSession: OverviewStructuralActions.DragSession?
    let autoScroll = OverviewDragAutoScroll()

    private var state: OverviewState {
        overview?.state ?? .closed
    }

    private var windowFacts: OverviewWindowFacts {
        structuralActions.windowFacts
    }

    var isActive: Bool {
        dragSession != nil
    }

    var draggedHandle: WindowHandle? {
        dragSession?.handle
    }

    init(
        projection: OverviewViewportProjection,
        snapshot: OverviewSnapshot,
        windowSession: OverviewWindowSession,
        structuralActions: OverviewStructuralActions,
        mutationSession: OverviewMutationSession
    ) {
        self.projection = projection
        overviewSnapshot = snapshot
        self.windowSession = windowSession
        self.structuralActions = structuralActions
        self.mutationSession = mutationSession
    }

    func connect(overview: OverviewController) {
        self.overview = overview
        autoScroll.onTick = { [weak self] monitorId, delta in
            self?.autoScrollStep(on: monitorId, by: delta)
        }
        autoScroll.onStripTick = { [weak self] monitorId, workspaceId, delta in
            self?.autoScrollStripStep(on: monitorId, workspaceId: workspaceId, by: delta)
        }
    }

    func reset() {
        autoScroll.stop()
        dragSession = nil
        windowSession.endDragPreview()
        NSCursor.arrow.set()
    }

    private func autoScrollStep(on monitorId: Monitor.ID, by delta: CGFloat) {
        guard dragSession != nil, case .open = state,
              let before = projection.layoutsByMonitor[monitorId]?.scrollOffset
        else {
            autoScroll.stop()
            return
        }
        projection.adjustScrollOffset(by: delta, on: monitorId)
        guard projection.layoutsByMonitor[monitorId]?.scrollOffset != before else {
            autoScroll.velocity = 0
            if autoScroll.horizontalVelocity == 0 {
                autoScroll.stop()
            }
            return
        }
        updateAutoScrollDragResolution(on: monitorId)
    }

    private func autoScrollStripStep(
        on monitorId: Monitor.ID,
        workspaceId: WorkspaceDescriptor.ID,
        by delta: CGFloat
    ) {
        guard dragSession != nil, case .open = state else {
            autoScroll.stop()
            return
        }
        let panned = projection.panStrip(workspaceId, by: -delta, on: monitorId)
        guard panned else {
            autoScroll.horizontalVelocity = 0
            if autoScroll.velocity == 0 {
                autoScroll.stop()
            }
            return
        }
        updateAutoScrollDragResolution(on: monitorId)
    }

    private func updateAutoScrollDragResolution(on monitorId: Monitor.ID) {
        let stripScroll = stripAutoScrollParameters(at: autoScroll.pointer, on: monitorId)
        autoScroll.horizontalVelocity = stripScroll.velocity
        autoScroll.stripWorkspaceId = stripScroll.workspaceId
        let resolution = resolveDragTarget(at: autoScroll.pointer, on: monitorId)
        projection.setDragTarget(resolution.target, for: monitorId)
        updateFeedback(resolution)
        updateWindowDisplays()
    }

    private func updateWindowDisplays() {
        windowSession.updateWindowDisplays(state: state, update: .immediate)
    }

    func beginDrag(on monitorId: Monitor.ID, handle: WindowHandle, startPoint: CGPoint) {
        guard case .open = state,
              !mutationSession.isTransferring
        else {
            return
        }
        guard let entry = windowFacts.visibleManagedEntry(for: handle),
              windowFacts.isStructurallyMutable(entry)
        else { return }

        projection.activeInteractionMonitorId = monitorId
        dragSession = OverviewStructuralActions.DragSession(
            handle: handle,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            monitorId: monitorId,
            startPoint: startPoint
        )

        if let frame = overviewSnapshot.windows[handle]?.frame {
            windowSession.beginDragPreview(
                for: handle,
                originalFrame: frame,
                cursorLocation: projection.globalPoint(from: startPoint, on: monitorId)
            )
        }
        updateDrag(on: monitorId, at: startPoint)
    }

    private func stripAutoScrollParameters(
        at point: CGPoint,
        on monitorId: Monitor.ID
    ) -> (velocity: CGFloat, workspaceId: WorkspaceDescriptor.ID?) {
        guard let layout = projection.layoutsByMonitor[monitorId],
              let stripSection = layout.workspaceSection(at: point),
              !stripSection.ribbonFrame.isEmpty
        else { return (0, nil) }
        let velocity = OverviewLayoutCalculator.dragStripAutoScrollVelocity(
            pointer: point,
            stripFrame: stripSection.ribbonFrame,
            orientation: stripSection.orientation
        )
        return (velocity, stripSection.workspaceId)
    }

    func updateDrag(on originMonitorId: Monitor.ID, at originPoint: CGPoint) {
        guard case .open = state else {
            cancelDrag()
            return
        }
        guard dragSession != nil else { return }
        let (monitorId, point) = projection.pointerLocation(from: originPoint, on: originMonitorId)
        let previousMonitorId = projection.activeInteractionMonitorId
        projection.activeInteractionMonitorId = monitorId
        windowSession.updateDragPreviewPosition(cursorLocation: projection.globalPoint(from: point, on: monitorId))

        let resolution = resolveDragTarget(at: point, on: monitorId)
        updateFeedback(resolution)
        let currentTarget = projection.layoutsByMonitor[monitorId]?.dragTarget
        if previousMonitorId != monitorId || resolution.target != currentTarget {
            projection.setDragTarget(resolution.target, for: monitorId)
            updateWindowDisplays()
        }
        let stripScroll = stripAutoScrollParameters(at: point, on: monitorId)
        autoScroll.update(
            monitorId: monitorId,
            pointer: point,
            velocity: OverviewLayoutCalculator.dragAutoScrollVelocity(
                pointerY: point.y,
                viewportFrame: projection.viewportFrame(for: monitorId),
                scale: projection.layoutsByMonitor[monitorId]?.scale ?? 1
            ),
            horizontalVelocity: stripScroll.velocity,
            stripWorkspaceId: stripScroll.workspaceId
        )
    }

    func endDrag(on originMonitorId: Monitor.ID, at originPoint: CGPoint) {
        guard case .open = state else {
            cancelDrag()
            return
        }
        guard let session = dragSession else { return }
        autoScroll.stop()
        let (monitorId, point) = projection.pointerLocation(from: originPoint, on: originMonitorId)
        projection.activeInteractionMonitorId = monitorId
        windowSession.updateDragPreviewPosition(cursorLocation: projection.globalPoint(from: point, on: monitorId))

        let resolution = resolveDragTarget(at: point, on: monitorId)
        projection.clearDragTargets()
        dragSession = nil
        windowSession.endDragPreview()
        NSCursor.arrow.set()

        guard let target = resolution.target else {
            updateWindowDisplays()
            return
        }

        let outcome = structuralActions.performDragAction(
            session: session,
            target: target
        )
        switch outcome {
        case let .changed(mutation):
            mutationSession.completeStructuralMutation(mutation)
        case let .placedFloating(mutation, frame):
            mutationSession.completeStructuralMutation(mutation, floatingPlacement: frame)
        case let .awaitingAdmission(mutation, deferredTarget):
            mutationSession.completeDeferredDragMutation(mutation, target: deferredTarget)
        case .unchanged:
            updateWindowDisplays()
        }
    }

    func cancelDrag() {
        autoScroll.stop()
        projection.clearDragTargets()
        dragSession = nil
        windowSession.endDragPreview()
        NSCursor.arrow.set()
        updateWindowDisplays()
    }

    private func updateFeedback(_ resolution: OverviewDropResolution) {
        let isValid = resolution.target != nil
        windowSession.updateDragPreviewFeedback(resolution.label, isValid: isValid)
        (isValid ? NSCursor.closedHand : NSCursor.operationNotAllowed).set()
    }

    private func resolveDragTarget(at point: CGPoint, on monitorId: Monitor.ID) -> OverviewDropResolution {
        guard let session = dragSession,
              let entry = windowFacts.visibleManagedEntry(for: session.handle),
              entry.workspaceId == session.workspaceId,
              windowFacts.isStructurallyMutable(entry),
              let monitor = structuralActions.wmController?.workspaceManager.monitor(byId: monitorId),
              let layout = projection.layoutsByMonitor[monitorId]
        else { return .invalid }
        let floatingSize = entry.mode == .floating
            ? (windowFacts.floatingPreviewFrame(for: entry) ?? overviewSnapshot.windows[session.handle]?.frame)?.size
            : nil
        guard entry.mode != .floating || floatingSize != nil else { return .invalid }
        return layout.resolveDrop(
            at: point, draggedHandle: session.handle, sourceWorkspaceId: session.workspaceId,
            floatingSize: floatingSize, monitor: monitor
        )
    }
}
