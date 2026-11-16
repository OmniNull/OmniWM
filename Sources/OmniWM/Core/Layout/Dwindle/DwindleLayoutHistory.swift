// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum DwindleLayoutHistoryDirection {
    case undo
    case redo
}

struct DwindleLayoutHistoryStep {
    let focused: WindowToken?
}

struct DwindleLayoutHistoryStack: ~Copyable {
    private var entries: [DwindleLayoutSnapshot?] = []
    private var start = 0
    private(set) var size = 0

    private var isEmpty: Bool {
        size == 0
    }

    mutating func push(_ snapshot: consuming DwindleLayoutSnapshot) {
        if entries.isEmpty { entries.reserveCapacity(DwindleLayoutHistory.limit) }
        let index = (start + size) % DwindleLayoutHistory.limit
        if index == entries.count {
            entries.append(snapshot)
        } else {
            entries[index] = snapshot
        }
        if size == DwindleLayoutHistory.limit {
            start = (start + 1) % DwindleLayoutHistory.limit
        } else {
            size += 1
        }
    }

    mutating func pop() -> DwindleLayoutSnapshot? {
        guard !isEmpty else { return nil }
        size -= 1
        let index = (start + size) % DwindleLayoutHistory.limit
        var result: DwindleLayoutSnapshot?
        swap(&result, &entries[index])
        return result
    }

    mutating func clear() {
        for offset in 0 ..< size {
            entries[(start + offset) % DwindleLayoutHistory.limit] = nil
        }
        start = 0
        size = 0
    }
}

struct DwindleLayoutHistory: ~Copyable {
    static let limit = 20
    private var undo = DwindleLayoutHistoryStack()
    private var redo = DwindleLayoutHistoryStack()

    var counts: (undo: Int, redo: Int) {
        (undo.size, redo.size)
    }

    mutating func record(_ snapshot: consuming DwindleLayoutSnapshot) {
        undo.push(snapshot)
        redo.clear()
    }

    mutating func pop(_ direction: DwindleLayoutHistoryDirection) -> DwindleLayoutSnapshot? {
        switch direction {
        case .undo: undo.pop()
        case .redo: redo.pop()
        }
    }

    mutating func pushOpposite(
        of direction: DwindleLayoutHistoryDirection,
        _ snapshot: consuming DwindleLayoutSnapshot
    ) {
        switch direction {
        case .undo: redo.push(snapshot)
        case .redo: undo.push(snapshot)
        }
    }

    mutating func clear() {
        undo.clear()
        redo.clear()
    }
}

extension DwindleLayoutEngine {
    func recordLayoutChange(
        in workspaceId: WorkspaceDescriptor.ID,
        since before: consuming DwindleLayoutSnapshot?
    ) {
        guard let before = consume before, let state = existingState(for: workspaceId),
              state.preselection != before.preselection || !before.matches(state.root)
        else { return }
        state.layoutHistory.record(before)
    }

    func layoutHistoryCounts(in workspaceId: WorkspaceDescriptor.ID) -> (undo: Int, redo: Int) {
        guard let state = existingState(for: workspaceId) else { return (0, 0) }
        return state.layoutHistory.counts
    }

    func clearLayoutHistory(in workspaceId: WorkspaceDescriptor.ID) {
        existingState(for: workspaceId)?.layoutHistory.clear()
    }

    func stepLayoutHistory(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        focused: WindowToken? = nil,
        at time: TimeInterval? = nil
    ) -> DwindleLayoutHistoryStep? {
        assertSanctionedMutation()
        guard interactiveResize == nil, interactiveMove == nil,
              let state = existingState(for: workspaceId)
        else { return nil }
        while let entry = state.layoutHistory.pop(direction) {
            guard let current = layoutSnapshot(in: workspaceId, focused: focused) else { return nil }
            restoreLayoutSnapshot(entry, in: workspaceId, at: time)
            guard state.preselection != current.preselection || !current.matches(state.root) else { continue }
            state.layoutHistory.pushOpposite(of: direction, current)
            var focus: WindowToken?
            if let token = entry.focused, state.leafByToken[token] != nil { focus = token }
            return DwindleLayoutHistoryStep(focused: focus)
        }
        return nil
    }
}
