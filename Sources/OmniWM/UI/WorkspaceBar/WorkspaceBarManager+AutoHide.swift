// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    func isPointerRevealed(on monitorId: Monitor.ID) -> Bool {
        autoHideMonitor.state.revealed.contains(monitorId)
    }

    func refreshAutoHide() {
        autoHideMonitor.refresh()
    }

    func applyVisibility(_ visible: Bool, on monitorId: Monitor.ID) {
        guard let instance = barsByMonitor[monitorId] else { return }
        let panels = [instance.primary.panel, instance.secondary?.panel].compactMap { $0 }
        for panel in panels where panel.isVisible != visible {
            if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        if !visible { controller?.dismissSystemStatsPopup(anchoredTo: monitorId) }
    }

    func autoHideTargets() -> [WorkspaceBarAutoHideTarget] {
        guard let controller else { return [] }
        let popupFrames = controller.ownedWindowRegistry.visibleSurfaceInfos().filter {
            [.systemStats, .hiddenBarPanel, .statusPanel].contains($0.kind)
        }.compactMap(\.frame)
        return barsByMonitor.values.compactMap { instance in
            let resolved = controller.settings.workspaceBar.resolved(for: instance.monitor)
            guard controller.canAutoHideWorkspaceBar(on: instance.monitor, resolved: resolved) else { return nil }
            let panels = [instance.primary.panel, instance.secondary?.panel].compactMap { $0 }
            return WorkspaceBarAutoHideTarget(
                monitor: instance.monitor,
                frames: panels.map(\.frame),
                resolved: resolved,
                isVisible: instance.primary.panel.isVisible,
                isPinned: dragController.isDragging
                    || (menuPresenter.isTracking && menuMonitorId == instance.monitorId)
                    || (renamePanel?.isVisible == true && renameMonitorId == instance.monitorId)
                    || hoverPreview?.visibleTarget.map { instance.monitor.frame.contains($0.attachment.anchor) } == true
                    || panels.contains { $0.attachedSheet != nil }
                    || popupFrames.contains { instance.monitor.frame.contains($0.center) }
            )
        }
    }
}
