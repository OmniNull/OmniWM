// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ConfigScriptColumnIndex {
    private var numbers: [WindowToken: UInt16] = [:]

    func number(of token: WindowToken) -> UInt16 {
        numbers[token] ?? 0
    }

    mutating func index(_ engine: NiriLayoutEngine?, in workspaceId: WorkspaceDescriptor.ID, windows: Int) {
        numbers.removeAll(keepingCapacity: true)
        guard let engine, let root = engine.root(for: workspaceId) else { return }
        numbers.reserveCapacity(windows)
        let membership = engine.projectionMembership(in: workspaceId)
        if membership.admitsEveryWindow {
            index(root.projectedColumns)
        } else if let projected = root.cachedProjectedColumns {
            index(projected, of: engine, admitting: membership)
        } else {
            index(root.columns, of: engine, admitting: membership)
        }
    }

    private mutating func index(_ columns: [NiriProjectedColumn]) {
        for slot in columns.indices {
            guard let number = UInt16(exactly: slot + 1) else { return }
            _ = index(columns[slot].windows, as: number, admitting: nil)
        }
    }

    private mutating func index(
        _ columns: [NiriProjectedColumn], of engine: NiriLayoutEngine, admitting membership: NiriProjectionMembership
    ) {
        let home = engine.liveHomeColumnId
        var count = 0
        for slot in columns.indices {
            guard let number = UInt16(exactly: count + 1) else { return }
            if index(columns[slot].windows, as: number, admitting: membership)
                || engine.holdsLiveSpace(columns[slot].column, home: home)
            {
                count += 1
            }
        }
    }

    private mutating func index(
        _ columns: [NiriContainer], of engine: NiriLayoutEngine, admitting membership: NiriProjectionMembership
    ) {
        let home = engine.liveHomeColumnId
        var count = 0
        for slot in columns.indices {
            guard let number = UInt16(exactly: count + 1) else { return }
            if index(columns[slot].windowNodes, as: number, admitting: membership)
                || engine.holdsLiveSpace(columns[slot], home: home)
            {
                count += 1
            }
        }
    }

    private mutating func index(
        _ windows: [NiriWindow], as number: UInt16, admitting membership: NiriProjectionMembership?
    ) -> Bool {
        var admitted = false
        windows.withUnsafeBufferPointer { members in
            for member in members.indices {
                let token = members[member].token
                guard membership?.admits(token) ?? true else { continue }
                numbers[token] = number
                admitted = true
            }
        }
        return admitted
    }
}
