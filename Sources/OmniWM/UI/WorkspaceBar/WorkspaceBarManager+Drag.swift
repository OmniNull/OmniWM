// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    func configureDragController(controller: WMController) {
        dragController.onDraggingChanged = { [weak self] in
            self?.refreshAutoHide()
            self?.refreshShellDrag()
        }
        dragController.geometryProvider = { [weak self] in
            self?.dropGeometry() ?? WorkspaceBarDropGeometry(workspaces: [])
        }
        dragController.geometryVersion = { [weak self] in
            self?.dropGeometryVersion() ?? 0
        }
        dragController.commit = { [weak controller] action, source in
            controller?.commitWorkspaceBarDrop(action, source: source) ?? false
        }
        dragController.makeGhost = { [weak controller] icon in
            controller.map { WorkspaceBarDragGhost(icon: icon, ownedWindowRegistry: $0.ownedWindowRegistry) }
        }
        dragController.sourceIsValid = { [weak controller] source in
            guard let controller else { return false }
            return source.tokens
                .allSatisfy { controller.workspaceManager.entry(for: $0)?.workspaceId == source.workspaceId }
        }
    }

    func beginDrag(
        workspaceId: WorkspaceDescriptor.ID,
        token: WindowToken,
        snapshot: WorkspaceBarSnapshot,
        at point: CGPoint
    ) {
        guard let controller,
              let item = snapshot.items.first(where: { $0.id == workspaceId }),
              let window = item.windows.first(where: { $0.id == token })
        else {
            return
        }
        let tokens = window.allWindows.map(\.id).filter { controller.canDragWorkspaceBarWindow($0) }
        guard !tokens.isEmpty else { return }
        dragController.begin(
            source: WorkspaceBarDragSource(
                tokens: tokens,
                workspaceId: workspaceId,
                isFloating: item.floatingWindows.contains { $0.id == token }
            ),
            icon: window.icon,
            at: point
        )
    }

    func shellDragChanged(_ request: ShellDragRequest) {
        switch request {
        case let .began(monitor, target, point):
            guard let controller,
                  let instance = barsByMonitor[monitor],
                  case let .window(workspaceId, token)? = Self.shellTarget(
                      target,
                      sessionToken: shellSessionToken,
                      snapshot: instance.model.snapshot,
                      workspaceId: controller.workspaceManager.workspaceId(named:)
                  )
            else {
                return
            }
            hoverPreview?.dismiss()
            beginDrag(workspaceId: workspaceId, token: token, snapshot: instance.model.snapshot, at: point)
        case let .moved(point):
            dragController.update(at: point)
        case let .ended(point):
            _ = dragController.end(at: point)
        }
        refreshShellDrag()
    }

    func refreshShellDrag() {
        let presentation = dragController.presentation
        let next = ShellDragState(sources: presentation.sourceTokens, highlights: presentation.highlights)
        guard next != shellDrag else { return }
        shellDrag = next
        shellHost?.updateBars()
    }

    func dropGeometryVersion() -> UInt64 {
        shellHost?.layoutGeneration ?? 0
    }

    func dropGeometry() -> WorkspaceBarDropGeometry {
        guard let controller else { return WorkspaceBarDropGeometry(workspaces: []) }
        var workspaces: [WorkspaceBarDropGeometry.Workspace] = []
        for instance in barsByMonitor.values {
            workspaces += shellDropWorkspaces(of: instance, controller: controller)
        }
        return WorkspaceBarDropGeometry(workspaces: workspaces)
    }

    private func shellDropWorkspaces(
        of instance: WorkspaceBarInstance,
        controller: WMController
    ) -> [WorkspaceBarDropGeometry.Workspace] {
        guard let targets = shellHost?.dropTargets(on: instance.monitor.id), !targets.isEmpty else { return [] }
        let snapshot = instance.model.snapshot
        let resolve = { (text: String) in
            Self.shellTarget(
                text,
                sessionToken: self.shellSessionToken,
                snapshot: snapshot,
                workspaceId: controller.workspaceManager.workspaceId(named:)
            )
        }
        var iconFrames: [WindowToken: CGRect] = [:]
        for target in targets where !target.drop {
            if case let .window(_, token)? = resolve(target.target) {
                iconFrames[token] = target.frame
            }
        }
        let panels = ([instance.primary] + (instance.secondary.map { [$0] } ?? [])).map(\.panel).filter(\.isVisible)
        return targets.compactMap { target in
            let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
            guard target.drop,
                  case let .workspace(workspaceId)? = resolve(target.target),
                  let item = snapshot.items.first(where: { $0.id == workspaceId }),
                  let panel = panels.first(where: { $0.frame.contains(center) })
            else {
                return nil
            }
            let layout = controller.workspaceBarDropLayout(for: workspaceId)
            return WorkspaceBarDropGeometry.Workspace(
                id: workspaceId,
                name: item.name,
                layout: layout.layout,
                hitFrame: Self.dropHitFrame(target.frame, panelFrame: panel.frame, orientation: snapshot.orientation),
                icons: item.tiledWindows.compactMap { window in
                    iconFrames[window.id].map { frame in
                        WorkspaceBarDropGeometry.Icon(
                            tokens: window.allWindows.map(\.id),
                            frame: frame,
                            appName: window.appName,
                            placement: window.windowCount == 1 && !window.isAppHidden ? layout
                                .placements[window.id] : nil
                        )
                    }
                },
                columnCount: layout.columnCount,
                orientation: snapshot.orientation
            )
        }
    }

    static func dropHitFrame(
        _ frame: CGRect,
        panelFrame: CGRect,
        orientation: WorkspaceBarOrientation
    ) -> CGRect {
        CGRect(
            x: orientation.isVertical ? panelFrame.minX : frame.minX - 4,
            y: orientation.isVertical ? frame.minY - 4 : panelFrame.minY,
            width: orientation.isVertical ? panelFrame.width : frame.width + 8,
            height: orientation.isVertical ? frame.height + 8 : panelFrame.height
        ).intersection(panelFrame)
    }
}
