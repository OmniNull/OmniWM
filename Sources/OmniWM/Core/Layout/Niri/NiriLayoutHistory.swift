// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct NiriWindowSpans: Equatable {
    let height: WeightedSize
    let windowWidth: WeightedSize
    let savedHeight: WeightedSize?
    let sizingMode: SizingMode
    let restsAtTop: Bool

    init(_ window: NiriWindow, in column: NiriContainer) {
        height = window.height
        windowWidth = window.windowWidth
        savedHeight = window.savedHeight
        sizingMode = window.sizingMode
        restsAtTop = window.restsAtTop(of: column)
    }

    func restore(_ window: NiriWindow, in column: NiriContainer) {
        window.height = height
        window.windowWidth = windowWidth
        window.savedHeight = savedHeight
        window.sizingMode = sizingMode
        window.rest(atTop: restsAtTop, in: column)
    }
}

struct NiriColumnSizing: Equatable {
    let sizing: NiriContainerSizingState
    let fittedWidth: CGFloat?
    let fittedHeight: CGFloat?
    let windows: [WindowToken: NiriWindowSpans]

    init(_ column: NiriContainer, engine: NiriLayoutEngine) {
        sizing = engine.containerSizingState(for: column)
        fittedWidth = column.fittedWidth
        fittedHeight = column.fittedHeight
        windows = Dictionary(
            uniqueKeysWithValues: column.windowNodes.map { ($0.token, NiriWindowSpans($0, in: column)) }
        )
    }

    func restore(to column: NiriContainer, engine: NiriLayoutEngine) {
        engine.applyContainerSizingState(sizing, to: column)
        column.fittedWidth = fittedWidth
        column.fittedHeight = fittedHeight
        for window in column.windowNodes {
            windows[window.token]?.restore(window, in: column)
        }
    }
}

struct NiriLayoutSnapshot {
    struct Column {
        let id: NodeId
        let windows: [WindowToken]
        let sizing: NiriColumnSizing
        let displayMode: ColumnDisplay
        let activeTile: Int

        func hasSameLayout(as other: Column) -> Bool {
            windows == other.windows
                && sizing == other.sizing
                && displayMode == other.displayMode
                && (displayMode == .normal || activeTile == other.activeTile)
        }
    }

    let columns: [Column]
    let manualWidthColumnCount: Int?
    let manualHeightColumnCount: Int?
    let focused: WindowToken?
    var away: [NiriLayoutAway] = []

    static var empty: NiriLayoutSnapshot {
        NiriLayoutSnapshot(columns: [], manualWidthColumnCount: nil, manualHeightColumnCount: nil, focused: nil)
    }

    var tokens: Set<WindowToken> {
        Set(columns.flatMap(\.windows))
    }

    func hasSameLayout(as other: NiriLayoutSnapshot) -> Bool {
        columns.count == other.columns.count
            && zip(columns, other.columns).allSatisfy { $0.hasSameLayout(as: $1) }
            && manualWidthColumnCount == other.manualWidthColumnCount
            && manualHeightColumnCount == other.manualHeightColumnCount
    }
}

struct NiriLayoutAway {
    let workspaceId: WorkspaceDescriptor.ID
    let tokens: [WindowToken]
    let snapshot: NiriLayoutSnapshot
}

struct NiriLayoutTransfers {
    var bringIn: [(token: WindowToken, from: WorkspaceDescriptor.ID)] = []
    var sendAway: [NiriLayoutAway] = []

    var isEmpty: Bool {
        bringIn.isEmpty && sendAway.isEmpty
    }
}

struct NiriLayoutHistory {
    static let limit = 20

    private(set) var undoSnapshots: [NiriLayoutSnapshot] = []
    private(set) var redoSnapshots: [NiriLayoutSnapshot] = []

    mutating func record(_ before: NiriLayoutSnapshot) {
        push(before, onto: &undoSnapshots)
        redoSnapshots.removeAll()
    }

    func last(_ direction: NiriLayoutHistoryDirection) -> NiriLayoutSnapshot? {
        direction == .undo ? undoSnapshots.last : redoSnapshots.last
    }

    mutating func pop(_ direction: NiriLayoutHistoryDirection) -> NiriLayoutSnapshot? {
        direction == .undo ? popUndo() : popRedo()
    }

    mutating func pushOpposite(of direction: NiriLayoutHistoryDirection, _ snapshot: NiriLayoutSnapshot) {
        direction == .undo ? pushRedo(snapshot) : pushUndo(snapshot)
    }

    mutating func popUndo() -> NiriLayoutSnapshot? {
        undoSnapshots.popLast()
    }

    mutating func popRedo() -> NiriLayoutSnapshot? {
        redoSnapshots.popLast()
    }

    mutating func pushUndo(_ snapshot: NiriLayoutSnapshot) {
        push(snapshot, onto: &undoSnapshots)
    }

    mutating func pushRedo(_ snapshot: NiriLayoutSnapshot) {
        push(snapshot, onto: &redoSnapshots)
    }

    private func push(_ snapshot: NiriLayoutSnapshot, onto list: inout [NiriLayoutSnapshot]) {
        list.append(snapshot)
        if list.count > Self.limit {
            list.removeFirst(list.count - Self.limit)
        }
    }
}

enum NiriLayoutHistoryDirection {
    case undo
    case redo
}

struct NiriLayoutHistoryStep {
    let focused: WindowToken?
}

extension NiriLayoutEngine {
    func layoutSnapshot(in workspaceId: WorkspaceDescriptor.ID, focused: WindowToken?) -> NiriLayoutSnapshot? {
        guard let root = root(for: workspaceId),
              !root.columns.contains(where: { $0.isLiveDropSpace || $0.isLiveHomeSpot })
        else { return nil }
        let workspace = ensureState(for: workspaceId)
        return NiriLayoutSnapshot(
            columns: root.columns.map { column in
                NiriLayoutSnapshot.Column(
                    id: column.id,
                    windows: column.windowNodes.map(\.token),
                    sizing: NiriColumnSizing(column, engine: self),
                    displayMode: column.displayMode,
                    activeTile: column.activeTileIdx
                )
            },
            manualWidthColumnCount: workspace.manualWidthColumnCount,
            manualHeightColumnCount: workspace.manualHeightColumnCount,
            focused: focused
        )
    }

    func recordLayoutChange(in workspaceId: WorkspaceDescriptor.ID, since before: NiriLayoutSnapshot?) {
        guard let before,
              let after = layoutSnapshot(in: workspaceId, focused: nil),
              !after.hasSameLayout(as: before)
        else { return }
        ensureState(for: workspaceId).layoutHistory.record(before)
    }

    func clearLayoutHistory(in workspaceId: WorkspaceDescriptor.ID) {
        states[workspaceId]?.layoutHistory = NiriLayoutHistory()
    }

    func stepLayoutHistory(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        focused: WindowToken?
    ) -> NiriLayoutHistoryStep? {
        let workspace = ensureState(for: workspaceId)
        var history = workspace.layoutHistory
        defer { workspace.layoutHistory = history }
        while let entry = history.last(direction) {
            guard layoutHistoryTransfers(entry, in: workspaceId).isEmpty else { return nil }
            _ = history.pop(direction)
            guard let current = layoutSnapshot(in: workspaceId, focused: focused) else { return nil }
            guard restoreLayoutSnapshot(entry, in: workspaceId),
                  let restored = layoutSnapshot(in: workspaceId, focused: nil),
                  !restored.hasSameLayout(as: current)
            else { continue }
            switch direction {
            case .undo: history.pushRedo(current)
            case .redo: history.pushUndo(current)
            }
            let present = Set(root(for: workspaceId)?.allWindows.map(\.token) ?? [])
            return NiriLayoutHistoryStep(focused: entry.focused.flatMap { present.contains($0) ? $0 : nil })
        }
        return nil
    }

    @discardableResult
    func restoreLayoutSnapshot(_ snapshot: NiriLayoutSnapshot, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        let windows = Dictionary(root.allWindows.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        let wanted = snapshot.columns.compactMap { column -> (NiriLayoutSnapshot.Column, [NiriWindow])? in
            let present = column.windows.compactMap { windows[$0] }
            return present.isEmpty ? nil : (column, present)
        }
        guard !wanted.isEmpty else { return false }

        let current = root.columns
        let existing = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let placed = wanted.map { column, present in
            (column, present, existing[column.id] ?? NiriContainer())
        }
        for (_, present, container) in placed {
            for (index, window) in present.enumerated()
                where window.parent !== container || container.children.firstIndex(where: { $0 === window }) != index
            {
                container.insertChild(window, at: index)
            }
        }

        var order = placed.map(\.2)
        let kept = Set(order.map(\.id))
        for (index, column) in current.enumerated()
            where !kept.contains(column.id) && !column.windowNodes.isEmpty
        {
            let previous = current[..<index].reversed().first { candidate in order.contains { $0 === candidate } }
            let at = previous.flatMap { previous in order.firstIndex { $0 === previous } }.map { $0 + 1 } ?? 0
            order.insert(column, at: at)
        }
        for (index, column) in order.enumerated() {
            root.insertChild(column, at: index)
        }
        for column in root.columns where column.windowNodes.isEmpty {
            column.remove()
        }

        for (column, _, container) in placed {
            column.sizing.restore(to: container, engine: self)
            container.displayMode = column.displayMode
            container.setActiveTileIdx(column.activeTile)
            updateTabbedColumnVisibility(column: container)
        }
        let workspace = ensureState(for: workspaceId)
        workspace.manualWidthColumnCount = snapshot.manualWidthColumnCount
        workspace.manualHeightColumnCount = snapshot.manualHeightColumnCount
        return true
    }
}

struct NiriDrawnLayout {
    let frames: [WindowToken: CGRect]
    let columnWidths: [(column: NiriContainer, width: CGFloat)]
    let hidden: Set<WindowToken>
}

extension NiriLayoutEngine {
    func drawnLayout(in workspaceId: WorkspaceDescriptor.ID) -> NiriDrawnLayout {
        let windows = root(for: workspaceId)?.allWindows ?? []
        return NiriDrawnLayout(
            frames: captureWindowFrames(in: workspaceId),
            columnWidths: columns(in: workspaceId).compactMap { column in
                column.cachedWidth > 0 ? (column, column.cachedWidth) : nil
            },
            hidden: Set(windows.filter(\.isHiddenInTabbedMode).map(\.token))
        )
    }

    func animateRestoredWidths(
        from drawn: NiriDrawnLayout,
        settled: [WindowToken: CGRect],
        context: NiriInteractionContext
    ) {
        guard context.orientation == .horizontal else { return }
        for column in columns(in: context.workspaceId) where column.cachedWidth > 0 {
            let target = column.cachedWidth
            let start = drawn.columnWidths.first { $0.column === column }?.width
                ?? column.windowNodes.lazy.compactMap { window -> CGFloat? in
                    guard !drawn.hidden.contains(window.token),
                          let previous = drawn.frames[window.token],
                          let landing = settled[window.token]
                    else { return nil }
                    return previous.width + target - landing.width
                }.first
            guard let start, abs(start - target) > 0.5 else { continue }
            column.cachedWidth = start
            column.animateWidthTo(
                newWidth: target,
                clock: animationClock,
                config: context.motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        }
    }

    func animateRestoredWindows(
        from drawn: NiriDrawnLayout,
        start: [WindowToken: CGRect],
        context: NiriInteractionContext
    ) {
        for window in root(for: context.workspaceId)?.allWindows ?? []
            where !window.isHiddenInTabbedMode && !drawn.hidden.contains(window.token)
        {
            guard let previous = drawn.frames[window.token], let current = start[window.token] else { continue }
            animateLiveWindow(window, from: previous, to: current, context: context)
        }
    }

    func stopWindowMoveAnimations(in workspaceId: WorkspaceDescriptor.ID) {
        for window in root(for: workspaceId)?.allWindows ?? [] {
            window.stopMoveAnimations()
        }
    }
}

extension NiriLayoutEngine {
    func recordLayoutChanges(
        in mainWorkspaceId: WorkspaceDescriptor.ID,
        since before: [WorkspaceDescriptor.ID: NiriLayoutSnapshot]
    ) {
        let origins = before.reduce(into: [WindowToken: WorkspaceDescriptor.ID]()) { origins, item in
            for token in item.value.tokens {
                origins[token] = item.key
            }
        }
        let afters = Set(before.keys).union(states.keys)
            .reduce(into: [WorkspaceDescriptor.ID: NiriLayoutSnapshot]()) { afters, workspaceId in
                afters[workspaceId] = layoutSnapshot(in: workspaceId, focused: nil)
            }
        let locations = afters.reduce(into: [WindowToken: WorkspaceDescriptor.ID]()) { locations, item in
            for token in item.value.tokens {
                locations[token] = item.key
            }
        }
        for (workspaceId, after) in afters {
            let previous = before[workspaceId] ?? .empty
            let arrived = after.columns.flatMap(\.windows).filter { origins[$0].map { $0 != workspaceId } ?? false }
            let departed = previous.tokens.contains { locations[$0].map { $0 != workspaceId } ?? false }
            guard !arrived.isEmpty || departed else {
                if workspaceId == mainWorkspaceId, !after.hasSameLayout(as: previous) {
                    ensureState(for: workspaceId).layoutHistory.record(previous)
                }
                continue
            }
            var entry = previous
            entry.away = Dictionary(grouping: arrived) { origins[$0]! }.compactMap { origin, tokens in
                before[origin].map { NiriLayoutAway(workspaceId: origin, tokens: tokens, snapshot: $0) }
            }
            ensureState(for: workspaceId).layoutHistory.record(entry)
        }
    }

    func workspaceHolding(_ token: WindowToken) -> WorkspaceDescriptor.ID? {
        states.first { $0.value.nodesByToken[token] != nil }?.key
    }

    func peekLayoutHistory(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriLayoutSnapshot? {
        states[workspaceId]?.layoutHistory.last(direction)
    }

    func layoutHistoryTransfers(
        _ entry: NiriLayoutSnapshot,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriLayoutTransfers {
        let here = Set(root(for: workspaceId)?.allWindows.map(\.token) ?? [])
        return NiriLayoutTransfers(
            bringIn: entry.columns.flatMap(\.windows).compactMap { token in
                guard !here.contains(token), let from = workspaceHolding(token), from != workspaceId else { return nil }
                return (token, from)
            },
            sendAway: entry.away.compactMap { away in
                let tokens = away.tokens.filter(here.contains)
                return tokens.isEmpty
                    ? nil
                    : NiriLayoutAway(workspaceId: away.workspaceId, tokens: tokens, snapshot: away.snapshot)
            }
        )
    }

    func awayParts(for bringIn: [(token: WindowToken, from: WorkspaceDescriptor.ID)]) -> [NiriLayoutAway] {
        Dictionary(grouping: bringIn, by: \.from).compactMap { from, items in
            layoutSnapshot(in: from, focused: nil).map {
                NiriLayoutAway(workspaceId: from, tokens: items.map(\.token), snapshot: $0)
            }
        }
    }

    func commitTransferredLayoutHistoryStep(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        inverse: NiriLayoutSnapshot
    ) -> NiriLayoutHistoryStep? {
        let workspace = ensureState(for: workspaceId)
        guard let entry = workspace.layoutHistory.pop(direction) else { return nil }
        for away in entry.away where root(for: away.workspaceId) != nil {
            restoreLayoutSnapshot(away.snapshot, in: away.workspaceId)
        }
        if !entry.columns.isEmpty {
            restoreLayoutSnapshot(entry, in: workspaceId)
        }
        workspace.layoutHistory.pushOpposite(of: direction, inverse)
        let present = Set(root(for: workspaceId)?.allWindows.map(\.token) ?? [])
        return NiriLayoutHistoryStep(focused: entry.focused.flatMap { present.contains($0) ? $0 : nil })
    }
}
