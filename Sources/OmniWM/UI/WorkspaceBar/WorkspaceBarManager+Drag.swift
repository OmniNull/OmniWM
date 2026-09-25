// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    func configureDragController(controller: WMController) {
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

    func dropGeometryVersion() -> UInt64 {
        barsByMonitor.values.reduce(0) { version, instance in
            ([instance.primary] + (instance.secondary.map { [$0] } ?? [])).reduce(version) {
                $0 &+ $1.interaction.generation
            }
        }
    }

    func dropGeometry() -> WorkspaceBarDropGeometry {
        guard let controller else { return WorkspaceBarDropGeometry(workspaces: []) }
        var workspaces: [WorkspaceBarDropGeometry.Workspace] = []
        for instance in barsByMonitor.values {
            for island in [instance.primary] + (instance.secondary.map { [$0] } ?? []) {
                workspaces += dropWorkspaces(
                    in: island,
                    items: island.slice.items(in: instance.model.snapshot),
                    controller: controller
                )
            }
        }
        return WorkspaceBarDropGeometry(workspaces: workspaces)
    }

    private func dropWorkspaces(
        in island: WorkspaceBarIslandPanel,
        items: [WorkspaceBarItem],
        controller: WMController
    ) -> [WorkspaceBarDropGeometry.Workspace] {
        let interaction = island.interaction
        let panelFrame = island.panel.frame
        return items.compactMap { item in
            guard let local = interaction.frames[.workspace(item.id)],
                  let frame = island.hostingView.workspaceBarScreenRect(forLocalRect: local)
            else {
                return nil
            }
            let layout = controller.workspaceBarDropLayout(for: item.id)
            let icons = item.tiledWindows.compactMap { window -> WorkspaceBarDropGeometry.Icon? in
                guard let localIcon = interaction.frames[.window(item.id, window.id)],
                      let iconFrame = island.hostingView.workspaceBarScreenRect(forLocalRect: localIcon)
                else {
                    return nil
                }
                let isPositional = window.windowCount == 1 && !window.isAppHidden
                return WorkspaceBarDropGeometry.Icon(
                    tokens: window.allWindows.map(\.id),
                    frame: iconFrame,
                    appName: window.appName,
                    placement: isPositional ? layout.placements[window.id] : nil
                )
            }
            return WorkspaceBarDropGeometry.Workspace(
                id: item.id,
                name: item.name,
                layout: layout.layout,
                hitFrame: CGRect(
                    x: frame.minX - 4,
                    y: panelFrame.minY,
                    width: frame.width + 8,
                    height: panelFrame.height
                ),
                icons: icons,
                columnCount: layout.columnCount
            )
        }
    }
}
