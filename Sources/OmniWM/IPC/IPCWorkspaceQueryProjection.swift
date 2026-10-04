// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCWorkspaceQueryProjection {
    private let controller: WMController
    private let sessionToken: String
    private let selectors: IPCQuerySelectors
    private let fields: Set<String>?
    private let focusedWindowToken: WindowToken?
    private let focusedWorkspaceId: WorkspaceDescriptor.ID?
    private let currentWorkspaceId: WorkspaceDescriptor.ID?
    private let visibleWorkspaceIds: Set<WorkspaceDescriptor.ID>

    init(controller: WMController, sessionToken: String, request: IPCQueryRequest) {
        self.controller = controller
        self.sessionToken = sessionToken
        selectors = request.selectors
        fields = IPCQuerySelection.requestedFieldSet(from: request)
        focusedWindowToken = controller.workspaceManager.nativeManagedFocusToken
        focusedWorkspaceId = controller.workspaceManager.nativeManagedFocusToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        currentWorkspaceId = controller.interactionWorkspaceProjection().workspace?.id
        visibleWorkspaceIds = controller.workspaceManager.visibleWorkspaceIds()
    }

    func result() -> IPCWorkspacesQueryResult {
        let workspaces = IPCQuerySelection.orderedWorkspaces(controller: controller)
            .filter { descriptor in
                matchesWorkspaceQuery(descriptor)
            }
            .map { descriptor in
                workspaceSnapshot(from: descriptor)
            }

        return IPCWorkspacesQueryResult(workspaces: workspaces)
    }

    private func workspaceSnapshot(from descriptor: WorkspaceDescriptor) -> IPCWorkspaceQuerySnapshot {
        let monitor = controller.workspaceManager.monitor(for: descriptor.id)
        let entries = controller.workspaceManager.entries(in: descriptor.id)
        let floatingCount = entries.filter { $0.mode == .floating }.count
        let scratchpadCount = entries.filter { controller.workspaceManager.isScratchpadToken($0.token) }.count
        let counts = IPCWorkspaceWindowCounts(
            total: entries.count,
            tiled: entries.filter { $0.mode == .tiling }.count,
            floating: floatingCount,
            scratchpad: scratchpadCount
        )
        let focusedWindowId = focusedWindowToken
            .flatMap { controller.workspaceManager.entry(for: $0) }
            .flatMap { entry in
                entry.workspaceId == descriptor.id ? IPCWindowOpaqueID.encode(
                    token: entry.token,
                    sessionToken: sessionToken
                ) : nil
            }

        return IPCWorkspaceQuerySnapshot(
            id: IPCQuerySelection.include("id", in: fields) ? descriptor.id.uuidString : nil,
            rawName: IPCQuerySelection.include("raw-name", in: fields) ? descriptor.name : nil,
            displayName: IPCQuerySelection.include("display-name", in: fields) ? controller.settings
                .workspaces.displayName(for: descriptor.name) : nil,
            number: IPCQuerySelection.include("number", in: fields) ? WorkspaceIDPolicy
                .workspaceNumber(from: descriptor.name) : nil,
            layout: IPCQuerySelection.include("layout", in: fields) ?
                IPCWorkspaceLayout(layout: controller.settings.workspaces.layoutType(for: descriptor.name)) : nil,
            display: IPCQuerySelection.include("display", in: fields) ? monitor.map(IPCDisplayRef.init(monitor:)) : nil,
            isFocused: IPCQuerySelection
                .include("is-focused", in: fields) ? (focusedWorkspaceId == descriptor.id) : nil,
            isVisible: IPCQuerySelection.include("is-visible", in: fields) ? visibleWorkspaceIds
                .contains(descriptor.id) : nil,
            isCurrent: IPCQuerySelection
                .include("is-current", in: fields) ? (currentWorkspaceId == descriptor.id) : nil,
            counts: IPCQuerySelection.include("window-counts", in: fields) ? counts : nil,
            focusedWindowId: IPCQuerySelection.include("focused-window-id", in: fields) ? focusedWindowId : nil,
            columns: IPCQuerySelection.include("columns", in: fields)
                ? controller.niriLayoutHandler.columnSummary(for: descriptor.id)?.viewport?.enumerated().map {
                    IPCWorkspaceColumn(index: $0.offset + 1, viewport: IPCColumnViewport(relation: $0.element))
                }
                : nil
        )
    }

    private func matchesWorkspaceQuery(_ descriptor: WorkspaceDescriptor) -> Bool {
        if let workspaceSelector = selectors.workspace,
           !IPCQuerySelection.matchesWorkspaceSelector(
               workspaceId: descriptor.id,
               candidate: workspaceSelector,
               controller: controller
           )
        {
            return false
        }

        if let displaySelector = selectors.display,
           !IPCQuerySelection.matchesDisplaySelector(
               monitor: controller.workspaceManager.monitor(for: descriptor.id),
               candidate: displaySelector
           )
        {
            return false
        }

        if selectors.current == true, descriptor.id != currentWorkspaceId {
            return false
        }

        if selectors.visible == true, !visibleWorkspaceIds.contains(descriptor.id) {
            return false
        }

        if selectors.focused == true, descriptor.id != focusedWorkspaceId {
            return false
        }

        return true
    }
}
