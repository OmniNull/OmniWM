// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension WMController {
    func setWorkspaceDisplayName(
        _ displayName: String,
        forWorkspaceNamed rawWorkspaceID: String
    ) -> ExternalCommandResult {
        var configs = settings.workspaces.configurations
        guard let index = configs.firstIndex(where: { $0.name == rawWorkspaceID }) else { return .notFound }
        let normalized: String? = displayName.isEmpty || displayName == rawWorkspaceID ? nil : displayName
        guard configs[index].displayName != normalized else { return .noChange }

        configs[index].displayName = normalized
        settings.workspaces.configurations = configs
        requestWorkspaceBarRefresh()
        return .executed
    }

    func summonAnchorToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        let token = if let focusedToken = workspaceManager.selectedManagedToken,
                       workspaceManager.entry(for: focusedToken)?.workspaceId == workspaceId
        {
            focusedToken
        } else {
            workspaceManager.lastFocusedToken(in: workspaceId)
        }
        guard let token, workspaceManager.entry(for: token)?.workspaceId == workspaceId else { return nil }
        return token
    }

    func workspaceBarMenuFacts() -> WorkspaceBarMenuFacts {
        WorkspaceBarMenuFacts(
            displays: workspaceManager.sortedMonitors().map { monitor in
                WorkspaceBarMenuFacts.Display(
                    id: monitor.id,
                    name: monitor.name,
                    workspaces: workspaceManager.workspaces(on: monitor.id).map {
                        .init(id: $0.id, name: settings.workspaces.displayName(for: $0.name))
                    }
                )
            },
            focusedWindowWorkspaceId: workspaceManager.selectedManagedToken
                .flatMap { workspaceManager.workspace(for: $0) },
            scratchpadSlots: ScratchpadIndex.range.compactMap { rawValue in
                ScratchpadIndex(rawValue).map { index in
                    .init(
                        index: index,
                        name: settings.scratchpadLabel(for: rawValue)
                            .map { String(localized: "Scratchpad \(rawValue) — \($0)") }
                            ?? String(localized: "Scratchpad \(rawValue)")
                    )
                }
            }
        )
    }

    func workspaceBarWorkspaceMenuTarget(for workspaceId: WorkspaceDescriptor.ID) -> WorkspaceBarWorkspaceMenuTarget? {
        guard let descriptor = workspaceManager.descriptor(for: workspaceId),
              let monitorId = workspaceManager.monitorId(for: workspaceId)
        else {
            return nil
        }
        return WorkspaceBarWorkspaceMenuTarget(
            id: workspaceId,
            monitorId: monitorId,
            isConfigured: settings.workspaces.configurations.contains { $0.name == descriptor.name },
            layout: workspaceManager.activeLayoutKind(for: workspaceId)
        )
    }

    func workspaceBarWindowMenuTarget(for token: WindowToken, title: String) -> WorkspaceBarWindowMenuTarget? {
        guard let entry = workspaceManager.entry(for: token),
              let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        else {
            return nil
        }
        let canMove = entry.layoutReason == .standard
            && !workspaceManager.isWindowSuppressedByMacOS(token)
            && !isManagedWindowSuspendedForNativeFullscreen(token)
        let anchor = workspaceManager.activeWorkspace(on: monitorId).flatMap { summonAnchorToken(in: $0.id) }
        return WorkspaceBarWindowMenuTarget(
            token: token,
            title: title,
            workspaceId: entry.workspaceId,
            monitorId: monitorId,
            isFloating: entry.mode == .floating,
            canMove: canMove,
            canSummon: canMove && anchor != nil && anchor != token
        )
    }

    func performWorkspaceBarMenuAction(_ action: WorkspaceBarMenuAction, barMonitorId: Monitor.ID) {
        switch action {
        case let .focusWorkspace(workspaceId):
            focusWorkspaceFromBar(id: workspaceId)
        case let .moveFocusedWindow(workspaceId):
            workspaceNavigationHandler.moveFocusedWindowFromBar(toWorkspaceId: workspaceId)
        case .renameWorkspace:
            return
        case let .setLayout(workspaceId, layout):
            guard let name = workspaceManager.descriptor(for: workspaceId)?.name else { return }
            _ = commandHandler.setWorkspaceLayout(layout, forWorkspaceNamed: name)
        case let .moveWorkspaceToMonitor(workspaceId, monitorId):
            _ = workspaceNavigationHandler.moveWorkspaceToMonitor(workspaceId, to: monitorId, force: true)
        case let .moveWindowsToWorkspace(tokens, workspaceId):
            workspaceNavigationHandler.moveWindowsFromBar(tokens, toWorkspaceId: workspaceId)
        case let .moveWindowsToMonitor(tokens, monitorId):
            guard let workspaceId = workspaceManager.activeWorkspaceOrFirst(on: monitorId)?.id else { return }
            workspaceNavigationHandler.moveWindowsFromBar(tokens, toWorkspaceId: workspaceId)
        case let .toggleFloating(token):
            toggleWindowFloating(token, preferredMonitor: monitorOfWindow(token))
        case let .summonRight(token):
            summonWindowRightFromBar(token, barMonitorId: barMonitorId)
        case let .assignToScratchpad(token, index):
            assignWindowToScratchpad(
                token,
                to: index,
                preferredMonitor: monitorOfWindow(token),
                focusOrigin: .pointerSelection
            )
        case let .createAppRule(token):
            AppRulesWindowController.shared.show(
                settings: settings,
                controller: self,
                draft: windowDecisionDebugSnapshot(for: token).flatMap(AppRuleDraft.guided(from:))
            )
        case let .closeWindow(token):
            guard let handle = workspaceManager.handle(for: token) else { return }
            _ = windowActionHandler.closeWindow(handle: handle)
        }
    }

    private func monitorOfWindow(_ token: WindowToken) -> Monitor? {
        workspaceManager.workspace(for: token).flatMap { workspaceManager.monitor(for: $0) }
    }

    private func summonWindowRightFromBar(_ token: WindowToken, barMonitorId: Monitor.ID) {
        guard let handle = workspaceManager.handle(for: token),
              let workspaceId = workspaceManager.activeWorkspace(on: barMonitorId)?.id,
              let anchor = summonAnchorToken(in: workspaceId)
        else {
            return
        }
        windowActionHandler.summonWindowRight(
            handle: handle,
            anchorToken: anchor,
            anchorWorkspaceId: workspaceId,
            focusOrigin: .pointerSelection
        )
    }
}
