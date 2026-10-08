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
        guard needsAutoHideMouseMoves || !autoHideState.revealed.isEmpty else { return }
        let desired = autoHideState.desired(targets: autoHideTargets, pointer: pointer)
        var changed = false
        for id in desired.union(autoHideState.revealed).union(autoHideDelays.pendingIds) {
            let reveals = desired.contains(id)
            guard reveals != autoHideState.revealed.contains(id) else {
                autoHideDelays.cancel(id)
                continue
            }
            let delay = autoHideDelayMilliseconds(revealing: reveals, for: id)
            guard delay <= 0 else {
                autoHideDelays.schedule(revealing: reveals, for: id, afterMilliseconds: delay) { [weak self] in
                    self?.completeAutoHideDelay(for: id)
                }
                continue
            }
            autoHideDelays.cancel(id)
            autoHideState.setRevealed(reveals, for: id)
            changed = true
        }
        if changed {
            controller?.requestWorkspaceBarRefresh()
        }
    }

    private func autoHideDelayMilliseconds(revealing: Bool, for id: Monitor.ID) -> Double {
        guard let settings = controller?.settings.workspaceBar,
              let target = autoHideTargets.first(where: { $0.id == id })
        else { return 0 }
        guard revealing else { return settings.autoHideHideDelayMilliseconds }
        return target.isVisible ? 0 : settings.autoHideRevealDelayMilliseconds
    }

    private func completeAutoHideDelay(for id: Monitor.ID) {
        guard let controller else { return }
        let reveals = autoHideState.desired(targets: autoHideTargets, pointer: controller.currentMouseLocation())
            .contains(id)
        guard reveals != autoHideState.revealed.contains(id) else { return }
        autoHideState.setRevealed(reveals, for: id)
        controller.requestWorkspaceBarRefresh()
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
