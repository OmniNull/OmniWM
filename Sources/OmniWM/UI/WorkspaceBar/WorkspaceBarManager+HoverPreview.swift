// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    func configureHoverPreview(controller: WMController) {
        guard hoverPreview == nil else { return }
        let preview = WorkspaceBarHoverPreviewController(
            capture: OverviewThumbnailCapture(
                environment: OverviewEnvironment(),
                ownedWindowRegistry: controller.ownedWindowRegistry,
                maximumRetainedBytes: 24 * 1_024 * 1_024
            ),
            makePanel: { [weak controller] in
                controller.map { WorkspaceBarPreviewPanel(ownedWindowRegistry: $0.ownedWindowRegistry) }
            }
        )
        preview.onSelect = { [weak controller] handle in
            controller?.focusWindowFromBar(handle: handle)
        }
        hoverPreview = preview
    }

    func windowHoverChanged(_ key: WorkspaceBarHitTarget, hovering: Bool) {
        guard let hoverPreview else { return }
        guard hovering else {
            hoverPreview.hoverEnded(key)
            return
        }
        guard !dragController.isDragging, !menuPresenter.isTracking, let target = hoverTarget(for: key) else { return }
        hoverPreview.hoverBegan(target)
    }

    func hoverTarget(for key: WorkspaceBarHitTarget) -> WorkspaceBarHoverTarget? {
        guard let settings = controller?.settings, case let .window(workspaceId, token) = key else { return nil }
        for instance in barsByMonitor.values {
            guard let window = instance.model.snapshot.windowItem(workspaceId: workspaceId, token: token) else {
                continue
            }
            for island in [instance.primary] + (instance.secondary.map { [$0] } ?? []) {
                guard island.panel.isVisible, island.panel.attachedSheet == nil,
                      let local = island.interaction.frames[key],
                      let anchor = island.hostingView.workspaceBarScreenRect(forLocalRect: local),
                      let screen = island.panel.screen
                else {
                    continue
                }
                guard island.panel.frame.intersects(anchor) else { continue }
                return WorkspaceBarHoverTarget(
                    key: key,
                    windows: window.allWindows.map {
                        .init(
                            handle: $0.handle,
                            title: $0.title.isEmpty ? window.appName : $0.title,
                            appName: window.appName,
                            icon: window.icon
                        )
                    },
                    attachment: PopupAttachment(
                        sourceFrame: island.panel.frame,
                        edge: settings.workspaceBar.resolved(for: instance.monitor).position.popupEdge,
                        alignment: CGPoint(x: anchor.midX, y: anchor.midY)
                    ),
                    visibleFrame: screen.visibleFrame,
                    level: island.panel.level
                )
            }
        }
        return nil
    }
}
