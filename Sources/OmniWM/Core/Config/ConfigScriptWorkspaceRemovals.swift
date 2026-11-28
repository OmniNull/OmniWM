// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
struct ConfigScriptWorkspaceRemovals {
    private struct Row {
        let id: WorkspaceDescriptor.ID
        let name: String
        let monitorId: Monitor.ID?
        let monitorName: String?
    }

    private var rows = ConfigScriptCatalogBuffer<Row?>(repeating: nil)
    private var count = 0

    init() {
        precondition(rows.count == ConfigScriptCallbackQueue.edgeCapacity)
    }

    mutating func append(id: WorkspaceDescriptor.ID, name: String, in manager: WorkspaceManager) {
        if count < rows.count {
            let monitor = manager.configCatalogMonitor(for: id)
            rows[count] = Row(id: id, name: name, monitorId: monitor?.id, monitorName: monitor?.name)
        }
        count += 1
    }

    mutating func publish(to observer: ConfigScriptEventObservers, in manager: WorkspaceManager) {
        let kept = min(count, rows.count)
        for index in 0 ..< kept {
            guard let row = rows[index].take() else { continue }
            observer.publishNative(.workspaceRemoved, .init(
                id: .workspace(row.id), name: row.name, edge: .monitor(id: row.monitorId, name: row.monitorName)
            ), in: manager)
        }
        if count > kept { observer.recordMissedEdges(count - kept, kind: .workspaceRemoved) }
    }
}
