// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    struct ShellPreview {
        let key: WorkspaceBarHitTarget
        let monitor: Monitor.ID
        let anchor: ShellAnchor
    }

    struct HoverPlacement {
        let attachment: PopupAttachment
        let visibleFrame: CGRect
        let level: NSWindow.Level
    }
}

extension WorkspaceBarManager {
    func syncHoverPreview(controller: WMController, settings: SettingsStore) {
        guard settings.workspaceBar.enabled && settings.workspaceBar.resolvedHoverPreviewsEnabled else {
            hoverPreview?.shutdown()
            hoverPreview = nil
            return
        }
        guard hoverPreview == nil else { return }
        let preview = WorkspaceBarHoverPreviewController(
            capture: OverviewThumbnailCapture(
                consumer: .workspaceBarHover,
                maximumRetainedBytes: 24 * 1_024 * 1_024
            ),
            makePanel: { [weak controller] in
                controller.map { WorkspaceBarPreviewPanel(ownedWindowRegistry: $0.ownedWindowRegistry) }
            }
        )
        preview.onSelect = { [weak controller] handle in
            controller?.focusWindowFromBar(handle: handle)
        }
        preview.onVisibilityChanged = { [weak self] in self?.refreshAutoHide() }
        hoverPreview = preview
    }

    func shellPreviewChanged(_ request: ShellPreviewRequest) {
        let key = shellPreviewKey(request)
        if let key, let anchor = request.anchor, let current = shellPreview, current.key == key,
           current.monitor == request.monitor
        {
            shellPreview = ShellPreview(key: key, monitor: request.monitor, anchor: anchor)
            hoverPreview?.targetsDidChange { [weak self] key in
                self?.shellHoverTarget(for: key)
            }
            return
        }
        if let previous = shellPreview {
            shellPreview = nil
            hoverPreview?.hoverEnded(previous.key)
        }
        guard let key, let anchor = request.anchor else { return }
        shellPreview = ShellPreview(key: key, monitor: request.monitor, anchor: anchor)
        guard !dragController.isDragging, !menuPresenter.isTracking, let target = shellHoverTarget(for: key) else {
            return
        }
        hoverPreview?.hoverBegan(target)
    }

    private func shellPreviewKey(_ request: ShellPreviewRequest) -> WorkspaceBarHitTarget? {
        guard let text = request.target,
              request.anchor != nil,
              let controller,
              let instance = barsByMonitor[request.monitor],
              let key = Self.shellTarget(
                  text,
                  sessionToken: shellSessionToken,
                  snapshot: instance.model.snapshot,
                  workspaceId: controller.workspaceManager.workspaceId(named:)
              ),
              case .window = key
        else {
            return nil
        }
        return key
    }

    func shellHoverTarget(for key: WorkspaceBarHitTarget) -> WorkspaceBarHoverTarget? {
        guard let shellPreview, shellPreview.key == key,
              let instance = barsByMonitor[shellPreview.monitor],
              case let .window(workspaceId, token) = key,
              let window = instance.model.snapshot.windowItem(workspaceId: workspaceId, token: token),
              let placement = hoverPlacement(for: shellPreview.anchor, instance: instance)
        else {
            return nil
        }
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
            attachment: placement.attachment,
            visibleFrame: placement.visibleFrame,
            level: placement.level
        )
    }

    func hoverPlacement(for anchor: ShellAnchor, instance: WorkspaceBarInstance) -> HoverPlacement? {
        let frame = anchor.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let panels = ([instance.primary] + (instance.secondary.map { [$0] } ?? [])).map(\.panel)
        guard let panel = panels.first(where: { $0.isVisible && $0.frame.contains(center) }) else {
            return HoverPlacement(
                attachment: PopupAttachment(
                    sourceFrame: frame,
                    edge: .away(from: frame, in: instance.monitor.frame),
                    alignment: center
                ),
                visibleFrame: instance.monitor.visibleFrame,
                level: anchor.level
            )
        }
        guard let settings = controller?.settings, panel.attachedSheet == nil, let screen = panel.screen else {
            return nil
        }
        return HoverPlacement(
            attachment: PopupAttachment(
                sourceFrame: panel.frame,
                edge: settings.workspaceBar.resolved(for: instance.monitor).position.popupEdge,
                alignment: center
            ),
            visibleFrame: screen.visibleFrame,
            level: panel.level
        )
    }
}
