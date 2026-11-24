// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceCatalog {
    private var workspacesById: [WorkspaceDescriptor.ID: WorkspaceDescriptor] = [:]
    private var workspaceIdByName: [String: WorkspaceDescriptor.ID] = [:]
    private var cachedSortedWorkspaces: [WorkspaceDescriptor]?

    var count: Int {
        workspacesById.count
    }

    var descriptors: [WorkspaceDescriptor.ID: WorkspaceDescriptor] {
        workspacesById
    }

    func contains(_ id: WorkspaceDescriptor.ID) -> Bool {
        workspacesById.index(forKey: id) != nil
    }

    func descriptor(for id: WorkspaceDescriptor.ID) -> WorkspaceDescriptor? {
        workspacesById[id]
    }

    func name(for id: WorkspaceDescriptor.ID) -> String? {
        guard var descriptor = workspacesById[id] else { return nil }
        var name = ""
        swap(&name, &descriptor.name)
        return name
    }

    func workspaceId(named name: String) -> WorkspaceDescriptor.ID? {
        workspaceIdByName[name]
    }

    func sortedWorkspaces() -> [WorkspaceDescriptor] {
        if let cachedSortedWorkspaces { return cachedSortedWorkspaces }
        let sorted = workspacesById.values.sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
        cachedSortedWorkspaces = sorted
        return sorted
    }

    func invalidateSortedWorkspaces() {
        cachedSortedWorkspaces = nil
    }

    func storeDescriptor(_ workspace: WorkspaceDescriptor) {
        workspacesById[workspace.id] = workspace
    }

    func storeRelocatedWorkspace(_ workspace: WorkspaceDescriptor) {
        storeDescriptor(workspace)
        invalidateSortedWorkspaces()
    }

    func updateWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        update: (inout WorkspaceDescriptor) -> Void
    ) -> (previous: WorkspaceDescriptor, current: WorkspaceDescriptor)? {
        guard var workspace = workspacesById[workspaceId] else { return nil }
        let previous = workspace
        let oldName = workspace.name
        update(&workspace)
        workspacesById[workspaceId] = workspace
        if workspace.name != oldName {
            workspaceIdByName.removeValue(forKey: oldName)
            workspaceIdByName[workspace.name] = workspaceId
            cachedSortedWorkspaces = nil
        }
        return (previous, workspace)
    }

    func insertWorkspace(_ workspace: WorkspaceDescriptor) {
        workspacesById[workspace.id] = workspace
        workspaceIdByName[workspace.name] = workspace.id
        cachedSortedWorkspaces = nil
    }

    func removeDescriptors(_ ids: [WorkspaceDescriptor.ID]) {
        for id in ids { workspacesById.removeValue(forKey: id) }
    }

    func finishRemovingDescriptors(_ ids: Set<WorkspaceDescriptor.ID>) {
        cachedSortedWorkspaces = nil
        workspaceIdByName = workspaceIdByName.filter { !ids.contains($0.value) }
    }
}
