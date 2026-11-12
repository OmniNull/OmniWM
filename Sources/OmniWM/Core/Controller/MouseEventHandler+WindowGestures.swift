// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func supportsColumnScroll(_ layoutType: LayoutType, in controller: WMController) -> Bool {
        switch layoutType {
        case .niri,
             .defaultLayout:
            controller.niriEngine != nil
        case .dwindle:
            false
        }
    }

    func workspaceSwipeAxis(for workspace: WorkspaceDescriptor, on monitor: Monitor) -> WorkspaceSwipeAxis? {
        guard let controller, let config = trackpadGestureConfig else { return nil }
        let layoutType = controller.settings.workspaces.layoutType(for: workspace.name)
        let columnScrollAxis = supportsColumnScroll(layoutType, in: controller)
            ? gestureColumnScrollAxis(workspaceId: workspace.id, monitor: monitor, supportsColumnScroll: true)
            : nil
        return TrackpadGestureIntent.effectiveWorkspaceSwipeAxis(config, columnScrollAxis: columnScrollAxis)
    }

    func gestureColumnScrollAxis(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        supportsColumnScroll: Bool
    ) -> WorkspaceSwipeAxis {
        guard let engine = controller?.niriEngine, supportsColumnScroll else { return .horizontal }
        return resolvedNiriOrientation(engine: engine, workspaceId: workspaceId, monitor: monitor) == .horizontal
            ? .horizontal
            : .vertical
    }

    func windowGestureTarget(
        at location: CGPoint,
        wsId: WorkspaceDescriptor.ID,
        layoutType: LayoutType
    ) -> WindowToken? {
        guard let controller else { return nil }
        switch layoutType {
        case .niri,
             .defaultLayout:
            return controller.niriEngine?.hitTestTiled(point: location, in: wsId)?.token
        case .dwindle:
            return controller.dwindleEngine?.hitTestFocusableWindow(
                point: location,
                in: wsId,
                at: controller.animationClock.now()
            )
        }
    }

    func beginGestureWindowInteraction(
        _ mode: TrackpadGestureMode,
        lockedContext: MouseInputState.LockedGestureContext
    ) -> Bool {
        guard let controller,
              let token = lockedContext.windowGestureTarget,
              let workspace = controller.workspaceManager.descriptor(for: lockedContext.workspaceId)
        else { return false }
        let wsId = lockedContext.workspaceId
        let location = lockedContext.startLocation
        let began: Bool
        switch (controller.settings.workspaces.layoutType(for: workspace.name), mode) {
        case (.dwindle, .windowMove):
            guard let engine = controller.dwindleEngine else { return false }
            began = beginDwindleMove(token: token, engine: engine, wsId: wsId, at: location, source: .trackpadGesture)
        case (.dwindle, .windowResize):
            guard let engine = controller.dwindleEngine else { return false }
            began = beginDwindleResize(
                token: token,
                engine: engine,
                wsId: wsId,
                at: location,
                edgePolicy: .nearestMovable,
                source: .trackpadGesture
            )
        case (_, .windowMove):
            guard let engine = controller.niriEngine, let window = engine.findNode(for: token, in: wsId) else {
                return false
            }
            began = beginNiriMove(window: window, engine: engine, wsId: wsId, at: location, source: .trackpadGesture)
        case (_, .windowResize):
            guard let engine = controller.niriEngine, let window = engine.findNode(for: token, in: wsId) else {
                return false
            }
            began = beginNiriResize(window: window, engine: engine, wsId: wsId, at: location, source: .trackpadGesture)
        case (_, .overview),
             (_, .columnScroll),
             (_, .workspaceSwitch):
            return false
        }
        guard began else {
            MouseTrace.record("gesture: \(mode) begin refused for \(token) at \(TraceFormat.point(location))")
            return false
        }
        MouseTrace.record(
            "gesture: \(mode) began on \(token) at \(TraceFormat.point(location))"
                + (mode == .windowResize ? " edges=\(state.currentHoveredEdges)" : "")
        )
        return true
    }

    func gestureWindowLocation(for lockedContext: MouseInputState.LockedGestureContext) -> CGPoint {
        guard let monitor = controller?.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            return lockedContext.startLocation
        }
        return TrackpadGestureIntent.windowGestureLocation(
            start: lockedContext.startLocation,
            startTouch: CGPoint(x: state.gestureStartX, y: state.gestureStartY),
            currentTouch: CGPoint(x: state.gestureLastAverageX, y: state.gestureLastAverageY),
            monitorFrame: monitor.frame,
            sensitivity: CGFloat(controller?.settings.gestures.windowGestureSensitivity ?? 1.0),
            clampToMonitor: state.activeGestureMode == .windowMove
        )
    }

    func commitGestureWindowInteraction(lockedContext: MouseInputState.LockedGestureContext) {
        guard state.gestureOwnsWindowInteraction else { return }
        let location = gestureWindowLocation(for: lockedContext)
        MouseTrace.record(
            "gesture: \(state.activeGestureMode.map { "\($0)" } ?? "") completed at \(TraceFormat.point(location))"
        )
        if state.isMoving {
            completeActiveMove(at: location)
        } else if state.isResizing {
            completeActiveResize()
        }
    }

    func cancelGestureWindowInteraction() {
        guard state.gestureOwnsWindowInteraction else { return }
        MouseTrace.record("gesture: \(state.activeGestureMode.map { "\($0)" } ?? "") cancelled")
        cancelActiveMouseInteraction()
    }
}
