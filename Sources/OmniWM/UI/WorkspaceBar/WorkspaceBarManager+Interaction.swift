// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    func makeIslandInteraction(panel: WorkspaceBarPanel, monitorId: Monitor.ID) -> WorkspaceBarIslandInteraction {
        let interaction = WorkspaceBarIslandInteraction()
        interaction.onShowMenu = { [weak self, weak panel] target in
            guard let self, let panel else { return }
            showMenu(for: target, on: panel, at: nil)
        }
        interaction.onActivateWindow = { [weak self] workspaceId, token in
            self?.activateWindowIcon(workspaceId: workspaceId, token: token, monitorId: monitorId)
        }
        interaction.onHoverWindow = { [weak self] workspaceId, token, hovering in
            self?.windowHoverChanged(.window(workspaceId, token), hovering: hovering)
        }
        panel.interactionHandler = { [weak self] event, panel in
            self?.handlePanelEvent(event, panel: panel) ?? false
        }
        return interaction
    }

    func handlePanelEvent(_ event: NSEvent, panel: WorkspaceBarPanel) -> Bool {
        let kind: WorkspaceBarPressTracker.EventKind
        switch event.type {
        case .leftMouseDown: kind = .leftDown
        case .leftMouseDragged: kind = .leftDragged
        case .leftMouseUp: kind = .leftUp
        case .rightMouseDown: kind = .rightDown
        default: return false
        }
        guard panel.attachedSheet == nil, let context = islandContext(for: panel) else {
            pressTracker.reset()
            return false
        }
        let point = context.island.hostingView.workspaceBarLocalPoint(forWindowPoint: event.locationInWindow)
        let target = context.island.interaction.target(at: point)
        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        if kind == .leftDown || kind == .rightDown {
            dragController.cancel()
            hoverPreview?.dismiss(suppressing: target)
        }
        switch pressTracker.handle(kind, modifiers: event.modifierFlags, target: target, location: screenPoint) {
        case .passThrough:
            return false
        case .consume:
            return true
        case let .showMenu(target):
            showMenu(for: target, on: panel, at: point)
            return true
        case let .moveFocusedWindow(workspaceId):
            controller?.workspaceNavigationHandler.moveFocusedWindowFromBar(toWorkspaceId: workspaceId)
            return true
        case let .activateWindow(workspaceId, token):
            activateWindowIcon(workspaceId: workspaceId, token: token, monitorId: context.instance.monitorId)
            return true
        case let .beginDrag(workspaceId, token):
            hoverPreview?.dismiss(suppressing: target)
            beginDrag(
                workspaceId: workspaceId,
                token: token,
                snapshot: context.instance.model.snapshot,
                at: screenPoint
            )
            return true
        case .continueDrag:
            dragController.update(at: screenPoint)
            return true
        case .endDrag:
            dragController.end(at: screenPoint)
            return true
        }
    }

    func activateWindowIcon(workspaceId: WorkspaceDescriptor.ID, token: WindowToken, monitorId: Monitor.ID) {
        guard let instance = islandContexts(on: monitorId).first?.instance,
              let window = instance.model.snapshot.windowItem(workspaceId: workspaceId, token: token)
        else {
            return
        }
        if window.windowCount > 1 {
            instance.model.presentedWindowList = window.id
        } else {
            controller?.focusWindowFromBar(handle: window.handle)
        }
    }

    private func showMenu(for target: WorkspaceBarHitTarget, on panel: WorkspaceBarPanel, at point: CGPoint?) {
        hoverPreview?.dismiss(suppressing: target)
        guard let controller,
              let context = islandContext(for: panel),
              let anchor = point ?? context.island.interaction.frames[target].map({ CGPoint(x: $0.minX, y: $0.maxY) })
        else {
            return
        }
        let items = menuItems(
            for: target,
            snapshot: context.instance.model.snapshot,
            monitorId: context.instance.monitorId,
            controller: controller
        )
        guard !items.isEmpty else { return }
        let hostingView = context.island.hostingView
        let location = hostingView.isFlipped ? anchor : CGPoint(x: anchor.x, y: hostingView.bounds.height - anchor.y)
        controller.focusPolicyEngine.beginLease(
            owner: .nativeMenu,
            reason: "workspace_bar_menu",
            suppressesFocusFollowsMouse: true,
            duration: nil
        )
        let action = menuPresenter.present(items, at: location, in: hostingView)
        controller.focusPolicyEngine.endLease(owner: .nativeMenu)
        guard let action else { return }
        perform(action, monitorId: context.instance.monitorId)
    }

    private func menuItems(
        for target: WorkspaceBarHitTarget,
        snapshot: WorkspaceBarSnapshot,
        monitorId: Monitor.ID,
        controller: WMController
    ) -> [WorkspaceBarMenuItem] {
        let facts = controller.workspaceBarMenuFacts()
        switch target {
        case let .workspace(workspaceId):
            guard let menuTarget = controller.workspaceBarWorkspaceMenuTarget(for: workspaceId) else { return [] }
            return WorkspaceBarMenuBuilder.workspaceMenu(for: menuTarget, facts: facts)
        case let .window(workspaceId, token):
            guard let window = snapshot.windowItem(workspaceId: workspaceId, token: token) else { return [] }
            let targets = window.allWindows.compactMap { info in
                controller.workspaceBarWindowMenuTarget(
                    for: info.id,
                    title: info.title.isEmpty ? window.appName : info.title
                )
            }
            return WorkspaceBarMenuBuilder.windowMenu(for: targets, facts: facts)
        case let .scratchpad(index):
            guard let item = snapshot.scratchpads.first(where: { $0.index == index }),
                  let menuTarget = controller.workspaceBarScratchpadMenuTarget(for: item, barMonitorId: monitorId)
            else {
                return []
            }
            return WorkspaceBarMenuBuilder.scratchpadMenu(for: menuTarget)
        }
    }

    private func perform(_ action: WorkspaceBarMenuAction, monitorId: Monitor.ID) {
        guard case let .renameWorkspace(workspaceId) = action else {
            controller?.performWorkspaceBarMenuAction(action, barMonitorId: monitorId)
            return
        }
        beginRename(workspaceId: workspaceId, monitorId: monitorId)
    }

    private func beginRename(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) {
        guard let controller,
              let rawName = controller.workspaceManager.descriptor(for: workspaceId)?.name,
              let (instance, island) = islandContexts(on: monitorId).first(where: {
                  $0.island.interaction.frames[.workspace(workspaceId)] != nil
              }),
              let localAnchor = island.interaction.labelFrames[workspaceId]
              ?? island.interaction.frames[.workspace(workspaceId)],
              let anchor = island.hostingView.workspaceBarScreenRect(forLocalRect: localAnchor),
              let screen = island.panel.screen
        else {
            return
        }
        let panel = renamePanel ?? WorkspaceBarRenamePanel(
            ownedWindowRegistry: controller.ownedWindowRegistry,
            focusPolicyEngine: controller.focusPolicyEngine
        )
        renamePanel = panel
        panel.isExemptWindow = { [weak self] in self?.isWorkspaceBarWindow($0) == true }
        let configuredName = controller.settings.workspaces.configurations
            .first { $0.name == rawName }?.displayName
        panel.show(
            currentName: configuredName ?? "",
            placeholder: rawName,
            attachment: PopupAttachment(
                sourceFrame: island.panel.frame,
                edge: controller.settings.workspaceBar.resolved(for: instance.monitor).position.popupEdge,
                alignment: CGPoint(x: anchor.midX, y: anchor.midY)
            ),
            visibleFrame: screen.visibleFrame
        ) { [weak controller] name in
            _ = controller?.setWorkspaceDisplayName(
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                forWorkspaceNamed: rawName
            )
        }
    }
}

extension WorkspaceBarSnapshot {
    func windowItem(workspaceId: WorkspaceDescriptor.ID, token: WindowToken) -> WorkspaceBarWindowItem? {
        items.first { $0.id == workspaceId }?.windows.first { $0.id == token }
    }
}
