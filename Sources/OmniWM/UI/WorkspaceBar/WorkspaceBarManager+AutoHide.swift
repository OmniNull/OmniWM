// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    var needsAutoHideMouseMoves: Bool {
        !autoHideTargets.isEmpty
    }

    func isPointerRevealed(on monitorId: Monitor.ID) -> Bool {
        autoHideState.revealed.contains(monitorId)
    }

    func handleAutoHideMouseMoved(at pointer: CGPoint) {
        let previous = autoHideState.revealed
        autoHideState.update(targets: autoHideTargets, pointer: pointer)
        if previous != autoHideState.revealed {
            controller?.requestWorkspaceBarRefresh()
        }
    }

    func refreshAutoHide() {
        guard let controller, needsAutoHideMouseMoves else { return }
        let popupFrames = controller.ownedWindowRegistry.visibleSurfaceInfos().filter {
            [.systemStats, .hiddenBarPanel, .statusPanel].contains($0.kind)
        }.compactMap(\.frame)
        for index in autoHideTargets.indices {
            guard let instance = barsByMonitor[autoHideTargets[index].id] else { continue }
            let panels = [instance.primary.panel, instance.secondary?.panel].compactMap { $0 }
            autoHideTargets[index].isVisible = instance.primary.panel.isVisible
            autoHideTargets[index].isPinned = dragController.isDragging
                || menuMonitorId == instance.monitorId
                || (renamePanel?.isVisible == true && renameMonitorId == instance.monitorId)
                || hoverPreview?.visibleTarget.map { instance.monitor.frame.contains($0.attachment.anchor) } == true
                || panels.contains { $0.hasPresentedSheet }
                || popupFrames.contains { instance.monitor.frame.contains($0.center) }
        }
        handleAutoHideMouseMoved(at: controller.currentMouseLocation())
    }

    func rebuildAutoHideTargets() {
        guard let controller else { return }
        autoHideTargets = barsByMonitor.values.compactMap { instance in
            let resolved = controller.settings.workspaceBar.resolved(for: instance.monitor)
            guard controller.canAutoHideWorkspaceBar(on: instance.monitor, resolved: resolved) else { return nil }
            let panels = [instance.primary.panel, instance.secondary?.panel].compactMap { $0 }
            return WorkspaceBarAutoHideTarget(
                monitor: instance.monitor,
                frames: panels.map(\.frame),
                resolved: resolved,
                isVisible: instance.primary.panel.isVisible,
                isPinned: false
            )
        }
        controller.mouseEventHandler.reconcileMouseMoveSubscription()
        if needsAutoHideMouseMoves {
            refreshAutoHide()
        } else {
            handleAutoHideMouseMoved(at: controller.currentMouseLocation())
        }
    }

    func applyVisibility(_ visible: Bool, on monitorId: Monitor.ID) {
        guard let instance = barsByMonitor[monitorId] else { return }
        let panels = [instance.primary.panel, instance.secondary?.panel].compactMap { $0 }
        for panel in panels where panel.isVisible != visible {
            if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        if !visible { controller?.dismissSystemStatsPopup(anchoredTo: monitorId) }
    }
}
