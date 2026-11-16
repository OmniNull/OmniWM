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

struct DwindleLayoutAway {
    let workspaceId: WorkspaceDescriptor.ID
    let tokens: [WindowToken]
    let snapshot: DwindleLayoutSnapshot

    init(workspaceId: WorkspaceDescriptor.ID, tokens: [WindowToken], snapshot: consuming DwindleLayoutSnapshot) {
        self.workspaceId = workspaceId
        self.tokens = tokens
        self.snapshot = snapshot
    }
}

struct DwindleLayoutTransfer {
    private enum Peers {
        case dwindle([DwindleLayoutAway])
        case mixed([DwindleLayoutAway], [NiriLayoutAway])
    }

    let departed: [WindowToken]
    private let peers: Peers

    init(
        departed: consuming[WindowToken],
        away: consuming[DwindleLayoutAway],
        niriAway: consuming[NiriLayoutAway]?
    ) {
        self.departed = departed
        if let niriAway = consume niriAway {
            peers = .mixed(away, niriAway)
        } else {
            peers = .dwindle(away)
        }
    }

    var away: [DwindleLayoutAway] {
        _read {
            switch peers {
            case let .dwindle(away),
                 let .mixed(away, _): yield away
            }
        }
    }

    var niriAway: [NiriLayoutAway]? {
        switch peers {
        case .dwindle: nil
        case let .mixed(_, away): away
        }
    }

    var hasNiriAway: Bool {
        if case .mixed = peers { true } else { false }
    }
}

struct DwindleLayoutHistoryEntry {
    let snapshot: DwindleLayoutSnapshot
    let transfer: DwindleLayoutTransfer?

    init(
        snapshot: consuming DwindleLayoutSnapshot,
        departed: consuming[WindowToken] = [],
        away: consuming[DwindleLayoutAway] = [],
        niriAway: consuming[NiriLayoutAway]? = nil
    ) {
        self.snapshot = snapshot
        if departed.isEmpty, away.isEmpty, niriAway == nil {
            transfer = nil
        } else {
            transfer = DwindleLayoutTransfer(departed: departed, away: away, niriAway: niriAway)
        }
    }

    var hasTransfers: Bool {
        transfer != nil
    }
}

struct DwindleLayoutHistoryStack: ~Copyable {
    private var entries: [DwindleLayoutHistoryEntry?] = []
    private var start = 0
    private(set) var size = 0

    private var isEmpty: Bool {
        size == 0
    }

    var hasTransfers: Bool {
        guard !isEmpty else { return false }
        return entries[(start + size - 1) % DwindleLayoutHistory.limit]?.hasTransfers == true
    }

    func withTransferEntry<Result>(_ body: (borrowing DwindleLayoutHistoryEntry) -> Result) -> Result? {
        guard hasTransfers else { return nil }
        return body(entries[(start + size - 1) % DwindleLayoutHistory.limit]!)
    }

    mutating func push(_ entry: consuming DwindleLayoutHistoryEntry) {
        if entries.isEmpty { entries.reserveCapacity(DwindleLayoutHistory.limit) }
        let index = (start + size) % DwindleLayoutHistory.limit
        if index == entries.count {
            entries.append(entry)
        } else {
            entries[index] = entry
        }
        if size == DwindleLayoutHistory.limit {
            start = (start + 1) % DwindleLayoutHistory.limit
        } else {
            size += 1
        }
    }

    mutating func pop() -> DwindleLayoutHistoryEntry? {
        guard !isEmpty else { return nil }
        size -= 1
        let index = (start + size) % DwindleLayoutHistory.limit
        var result: DwindleLayoutHistoryEntry?
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
        record(DwindleLayoutHistoryEntry(snapshot: snapshot))
    }

    mutating func record(_ entry: consuming DwindleLayoutHistoryEntry) {
        undo.push(entry)
        redo.clear()
    }

    func hasTransfers(_ direction: DwindleLayoutHistoryDirection) -> Bool {
        switch direction {
        case .undo: undo.hasTransfers
        case .redo: redo.hasTransfers
        }
    }

    func withTransferEntry<Result>(
        _ direction: DwindleLayoutHistoryDirection,
        _ body: (borrowing DwindleLayoutHistoryEntry) -> Result
    ) -> Result? {
        switch direction {
        case .undo: undo.withTransferEntry(body)
        case .redo: redo.withTransferEntry(body)
        }
    }

    mutating func pop(_ direction: DwindleLayoutHistoryDirection) -> DwindleLayoutHistoryEntry? {
        switch direction {
        case .undo: undo.pop()
        case .redo: redo.pop()
        }
    }

    mutating func pushOpposite(
        of direction: DwindleLayoutHistoryDirection,
        _ snapshot: consuming DwindleLayoutSnapshot
    ) {
        pushOpposite(of: direction, DwindleLayoutHistoryEntry(snapshot: snapshot))
    }

    mutating func pushOpposite(
        of direction: DwindleLayoutHistoryDirection,
        _ entry: consuming DwindleLayoutHistoryEntry
    ) {
        switch direction {
        case .undo: redo.push(entry)
        case .redo: undo.push(entry)
        }
    }

    mutating func clear() {
        undo.clear()
        redo.clear()
    }
}

extension DwindleLayoutEngine {
    func recordForeignLayoutHistory(
        entry: consuming DwindleLayoutHistoryEntry,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        assertSanctionedMutation()
        ensureState(for: workspaceId).layoutHistory.record(entry)
    }

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
        while !state.layoutHistory.hasTransfers(direction), let entry = state.layoutHistory.pop(direction) {
            guard let current = layoutSnapshot(in: workspaceId, focused: focused) else { return nil }
            restoreLayoutSnapshot(entry.snapshot, in: workspaceId, at: time)
            guard state.preselection != current.preselection || !current.matches(state.root) else { continue }
            state.layoutHistory.pushOpposite(of: direction, current)
            var focus: WindowToken?
            if let token = entry.snapshot.focused, state.leafByToken[token] != nil { focus = token }
            return DwindleLayoutHistoryStep(focused: focus)
        }
        return nil
    }
}
