// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    struct ScrollContext {
        let engine: NiriLayoutEngine
        let wsId: WorkspaceDescriptor.ID
        let monitor: Monitor
    }

    func applyTrackpadViewportScrollDelta(
        _ delta: CGFloat,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation,
        timestamp: TimeInterval = CACurrentMediaTime()
    ) {
        guard let controller else { return }
        let insetFrame = controller.niriWorkingFrame(for: monitor)
        let driver = controller.workspaceManager.animationDriver
        let viewportSpan = orientation == .horizontal ? insetFrame.width : insetFrame.height

        if !driver.hasGesture(in: wsId) {
            guard !engine.columns(in: wsId).isEmpty else { return }
            let semanticOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffset
            if let liveOffset = driver.liveViewOffset(in: wsId, semanticOffset: semanticOffset) {
                controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                    vstate.jumpOffset(to: liveOffset)
                }
            }
            driver.beginGesture(in: wsId, isTrackpad: true, timestamp: timestamp)
        }

        guard let gestureSessionID = driver.gestureSessionID(in: wsId) else {
            resetGestureState()
            return
        }
        state.viewportGestureSessionID = gestureSessionID

        driver.updateGesture(
            in: wsId,
            delta: Double(delta),
            timestamp: timestamp,
            isTrackpad: true,
            viewportWidth: Double(viewportSpan)
        )
        controller.layoutRefreshController.startScrollAnimation(for: wsId, forGesture: true)
    }

    func resolveScrollContext(at location: CGPoint) -> ScrollContext? {
        guard let controller,
              let engine = controller.niriEngine
        else {
            return nil
        }

        let monitors = controller.workspaceManager.monitors
        guard let monitor = location.monitorApproximation(in: monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return nil
        }

        guard supportsNiriColumnScroll(in: workspace) else { return nil }
        return ScrollContext(engine: engine, wsId: workspace.id, monitor: monitor)
    }

    func supportsNiriColumnScroll(in workspace: WorkspaceDescriptor) -> Bool {
        guard let controller, let engine = controller.niriEngine else { return false }
        switch controller.settings.workspaces.layoutType(for: workspace.name) {
        case .niri,
             .defaultLayout:
            return !engine.isAccordion(in: workspace.id)
        case .dwindle:
            return false
        }
    }

    func currentSelectionNode(
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        columns: [NiriProjectedColumn]? = nil
    ) -> NiriNode? {
        if let selectedNodeId = state.selectedNodeId,
           let selectedNode = engine.findNode(by: selectedNodeId, in: wsId)
        {
            let isExcluded = (selectedNode as? NiriWindow).map {
                engine.isExcludedFromProjection($0.token, in: wsId)
            } == true
            if !isExcluded {
                return selectedNode
            }
        }

        let columns = columns ?? engine.projectedColumns(in: wsId)
        guard !columns.isEmpty else { return nil }
        let activeColumnIndex = engine.projectedActiveColumnIndex(
            state: state,
            columns: columns,
            in: wsId
        )
        guard columns.indices.contains(activeColumnIndex) else { return nil }
        return engine.projectedActiveWindow(in: columns[activeColumnIndex])
    }

    func focusViewportSelectionAfterGesture(_ window: NiriWindow) {
        guard let controller else { return }
        guard !controller.hasFrontmostOwnedWindow else { return }
        guard controller.workspaceManager.selectedManagedToken != window.token else { return }
        controller.focusWindow(window.token, origin: .pointerHover)
    }

    func rememberViewportFocusAnchor(
        _ window: NiriWindow,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: nil,
                rememberedFocusToken: window.token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.workspaceManager.withEngineMutationScope {
            engine.updateFocusTimestamp(for: window.id, in: wsId)
        }
    }
}
