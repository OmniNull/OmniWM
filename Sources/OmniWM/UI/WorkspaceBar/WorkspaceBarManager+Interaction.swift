// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMIPC

extension WorkspaceBarManager {
    func showShellMenu(_ request: ShellMenuRequest) {
        guard let controller,
              let instance = barsByMonitor[request.monitor],
              let target = Self.shellTarget(
                  request.target,
                  sessionToken: shellSessionToken,
                  snapshot: instance.model.snapshot,
                  workspaceId: controller.workspaceManager.workspaceId(named:)
              ),
              let window = request.view.window
        else {
            return
        }
        hoverPreview?.dismiss(suppressing: target)
        let items = menuItems(
            for: target,
            snapshot: instance.model.snapshot,
            monitorId: request.monitor,
            controller: controller
        )
        guard !items.isEmpty else { return }
        let rect = request.view.convert(window.convertFromScreen(request.anchor.frame), from: nil)
        let location = CGPoint(x: rect.minX, y: request.view.isFlipped ? rect.maxY : rect.minY)
        present(
            items,
            at: location,
            in: request.view,
            monitorId: request.monitor,
            renameAnchor: request.label ?? request.anchor.frame
        )
    }

    static func shellTarget(
        _ text: String,
        sessionToken: String,
        snapshot: WorkspaceBarSnapshot,
        workspaceId: (String) -> WorkspaceDescriptor.ID?
    ) -> WorkspaceBarHitTarget? {
        let words = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2 else { return nil }
        switch words[0] {
        case "workspace":
            return workspaceId(words[1]).map { .workspace($0) }
        case "scratchpad":
            return Int(words[1]).map { .scratchpad($0) }
        case "window":
            guard case let .valid(pid, windowId) = IPCWindowOpaqueID.validate(
                words[1],
                expectingSessionToken: sessionToken
            )
            else {
                return nil
            }
            let token = WindowToken(pid: pid, windowId: windowId)
            return snapshot.items.first { $0.windows.contains { $0.id == token } }.map { .window($0.id, token) }
        default:
            return nil
        }
    }

    private func present(
        _ items: [WorkspaceBarMenuItem],
        at location: CGPoint,
        in view: NSView,
        monitorId: Monitor.ID,
        renameAnchor: CGRect
    ) {
        guard let controller else { return }
        controller.focusPolicyEngine.beginLease(
            owner: .nativeMenu,
            reason: "workspace_bar_menu",
            suppressesFocusFollowsMouse: true,
            duration: nil
        )
        menuMonitorId = monitorId
        refreshAutoHide()
        defer {
            menuMonitorId = nil
            refreshAutoHide()
        }
        let action = menuPresenter.present(items, at: location, in: view)
        controller.focusPolicyEngine.endLease(owner: .nativeMenu)
        guard let action else { return }
        perform(action, monitorId: monitorId, renameAnchor: renameAnchor)
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

    private func perform(_ action: WorkspaceBarMenuAction, monitorId: Monitor.ID, renameAnchor: CGRect) {
        switch action {
        case let .renameWorkspace(workspaceId):
            beginRename(workspaceId: workspaceId, monitorId: monitorId, anchor: renameAnchor)
        case let .editShellWidget(name, edit):
            editShellWidget(name, edit)
        case .openBarWidgetSettings:
            controller?.statusBarController?.openSettings(section: .bar)
        default:
            controller?.performWorkspaceBarMenuAction(action, barMonitorId: monitorId)
        }
    }

    func showWidgetMenu(_ request: ShellWidgetMenuRequest) {
        guard let controller, let shellDirectory = shellHost?.shellDirectory, let window = request.view.window,
              let monitor = barsByMonitor[request.monitor]?.monitor
        else {
            return
        }
        let items = Self.widgetMenuItems(
            for: request.widget,
            layout: try? ShellBarLayout.load(shellDirectory: shellDirectory).get(),
            vertical: controller.settings.workspaceBar.resolved(for: monitor).position.isVertical
        )
        let rect = request.view.convert(window.convertFromScreen(request.anchor.frame), from: nil)
        let location = CGPoint(x: rect.minX, y: request.view.isFlipped ? rect.maxY : rect.minY)
        present(items, at: location, in: request.view, monitorId: request.monitor, renameAnchor: request.anchor.frame)
    }

    static func widgetMenuItems(for name: String, layout: ShellBarLayout?, vertical: Bool) -> [WorkspaceBarMenuItem] {
        let settings = WorkspaceBarMenuItem.action(String(localized: "Bar Widgets…"), .openBarWidgetSettings)
        guard let layout else { return [.header(ShellBarLayout.title(of: name)), settings] }
        let lane = layout.lane(of: name) ?? .trailing
        let names = layout.names(in: lane)
        let moves = ShellLane.allCases.filter { $0 != lane }.map { target in
            WorkspaceBarMenuItem.action(
                String(localized: "Move to \(ShellBarLayout.side(target, vertical: vertical))"),
                .editShellWidget(name, .lane(target))
            )
        }
        return [
            .header(ShellBarLayout.title(of: name)),
            .action(
                vertical ? String(localized: "Move Up") : String(localized: "Move Left"),
                .editShellWidget(name, .earlier),
                isEnabled: names.first != name
            ),
            .action(
                vertical ? String(localized: "Move Down") : String(localized: "Move Right"),
                .editShellWidget(name, .later),
                isEnabled: names.last != name
            )
        ] + moves + [
            .separator,
            .action(String(localized: "Remove from Bar"), .editShellWidget(name, .remove)),
            .separator,
            settings
        ]
    }

    private func editShellWidget(_ name: String, _ edit: ShellWidgetEdit) {
        Task { [self] in
            do {
                try await shellConfiguration.editBar { layout in
                    switch edit {
                    case .earlier: layout.shift(name, by: -1)
                    case .later: layout.shift(name, by: 1)
                    case let .lane(target): layout.move(name, to: target)
                    case .remove: layout.remove(name)
                    }
                }
            } catch {
                Log.shell.error("Failed to save the bar widget layout: \(error.localizedDescription)")
            }
        }
    }

    private func beginRename(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID, anchor: CGRect) {
        guard let controller,
              let rawName = controller.workspaceManager.descriptor(for: workspaceId)?.name,
              let (instance, island) = islandContexts(on: monitorId).first,
              let screen = island.panel.screen
        else {
            return
        }
        let panel = renamePanel ?? WorkspaceBarRenamePanel(
            ownedWindowRegistry: controller.ownedWindowRegistry,
            focusPolicyEngine: controller.focusPolicyEngine
        )
        renamePanel = panel
        panel.onVisibilityChanged = { [weak self] in self?.refreshAutoHide() }
        panel.isExemptWindow = { [weak self] in self?.isWorkspaceBarWindow($0) == true }
        let configuredName = controller.settings.workspaces.configurations
            .first { $0.name == rawName }?.displayName
        renameMonitorId = monitorId
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
