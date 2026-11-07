// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
        case .cancelled:
            dragController.cancel()
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
        let surroundings = DropSurroundings(
            iconFrames: iconFrames,
            panels: ([instance.primary] + (instance.secondary.map { [$0] } ?? [])).map(\.panel).filter(\.isVisible),
            orientation: snapshot.orientation,
            controller: controller
        )
        return targets.compactMap { target in
            guard target.drop,
                  case let .workspace(workspaceId)? = resolve(target.target),
                  let item = snapshot.items.first(where: { $0.id == workspaceId })
            else {
                return nil
            }
            return dropWorkspace(item, target: target, surroundings: surroundings)
        }
    }

    private struct DropSurroundings {
        let iconFrames: [WindowToken: CGRect]
        let panels: [WorkspaceBarPanel]
        let orientation: WorkspaceBarOrientation
        let controller: WMController
    }

    private func dropWorkspace(
        _ item: WorkspaceBarItem,
        target: ShellDropTarget,
        surroundings: DropSurroundings
    ) -> WorkspaceBarDropGeometry.Workspace? {
        let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
        let panel = surroundings.panels.first { $0.frame.contains(center) }
        guard panel != nil || target.inIsland else { return nil }
        let layout = surroundings.controller.workspaceBarDropLayout(for: item.id)
        let orientation = surroundings.orientation
        let icons = item.tiledWindows.compactMap { window in
            surroundings.iconFrames[window.id].map { frame in
                WorkspaceBarDropGeometry.Icon(
                    tokens: window.allWindows.map(\.id),
                    frame: frame,
                    appName: window.appName,
                    placement: window.windowCount == 1 && !window.isAppHidden ? layout.placements[window.id] : nil
                )
            }
        }
        return WorkspaceBarDropGeometry.Workspace(
            id: item.id,
            name: item.name,
            layout: layout.layout,
            hitFrame: panel.map {
                Self.dropHitFrame(target.frame, panelFrame: $0.frame, orientation: orientation)
            } ?? icons.reduce(target.frame) { $0.union($1.frame) },
            icons: icons,
            columnCount: layout.columnCount,
            orientation: panel == nil
                ? Self.islandOrientation(mark: target.frame, icons: icons) ?? orientation
                : orientation
        )
    }

    static func islandOrientation(
        mark: CGRect,
        icons: [WorkspaceBarDropGeometry.Icon]
    ) -> WorkspaceBarOrientation? {
        icons.first.map {
            abs($0.frame.midY - mark.midY) > abs($0.frame.midX - mark.midX) ? .vertical : .horizontal
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
