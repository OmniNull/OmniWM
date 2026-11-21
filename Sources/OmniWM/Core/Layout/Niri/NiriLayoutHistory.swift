// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct NiriWindowSpans: Equatable {
    let height: WeightedSize
    let windowWidth: WeightedSize
    let savedHeight: WeightedSize?
    let sizingMode: SizingMode

    init(_ window: NiriWindow, in column: NiriContainer) {
        height = window.height
        windowWidth = window.windowWidth
        savedHeight = window.savedHeight
        sizingMode = window.sizingMode
    }

    func restore(_ window: NiriWindow, in column: NiriContainer) {
        window.height = height
        window.windowWidth = windowWidth
        window.savedHeight = savedHeight
        window.sizingMode = sizingMode
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
        let nodes = column.windowNodes
        windows = nodes.reduce(into: [WindowToken: NiriWindowSpans](minimumCapacity: nodes.count)) { spans, node in
            let replaced = spans.updateValue(NiriWindowSpans(node, in: column), forKey: node.token)
            precondition(replaced == nil)
        }
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

        func hasSameHeights(as other: Column) -> Bool {
            sizing.windows.mapValues(\.height) == other.sizing.windows.mapValues(\.height)
        }
    }

    let columns: [Column]
    let manualWidthColumnCount: Int?
    let manualHeightColumnCount: Int?
    let focused: WindowToken?
    var away: [NiriLayoutAway] = []
    var foreignTransfer: NiriForeignTransfer?

    static var empty: NiriLayoutSnapshot {
        NiriLayoutSnapshot(columns: [], manualWidthColumnCount: nil, manualHeightColumnCount: nil, focused: nil)
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

struct NiriForeignTransfer {
    let departed: [WindowToken]
    let away: [DwindleLayoutAway]
}

struct NiriLayoutTransfers {
    var bringIn: [(token: WindowToken, from: WorkspaceDescriptor.ID)] = []
    var sendAway: [NiriLayoutAway] = []

    var isEmpty: Bool {
        bringIn.isEmpty && sendAway.isEmpty
    }
}

struct NiriLayoutStepTiming {
    let startedAt: TimeInterval
    let recordedAt: TimeInterval
    let sizesAtStart: [WindowToken: CGSize]
    let userActionCountAtStart: UInt64
}

struct NiriNewestLayoutStep {
    let timing: NiriLayoutStepTiming
    let before: NiriLayoutSnapshot
    let after: NiriLayoutSnapshot
}

struct NiriLayoutHistory {
    static let limit = 20

    private(set) var undoSnapshots: [NiriLayoutSnapshot] = []
    private(set) var redoSnapshots: [NiriLayoutSnapshot] = []
    private var newest: (timing: NiriLayoutStepTiming, after: NiriLayoutSnapshot)?

    var newestStep: NiriNewestLayoutStep? {
        guard let newest, let before = undoSnapshots.last else { return nil }
        return NiriNewestLayoutStep(timing: newest.timing, before: before, after: newest.after)
    }

    mutating func record(
        _ before: NiriLayoutSnapshot,
        after: NiriLayoutSnapshot? = nil,
        timing: NiriLayoutStepTiming? = nil
    ) {
        Self.push(before, onto: &undoSnapshots)
        redoSnapshots.removeAll()
        newest = timing.flatMap { timing in after.map { (timing, $0) } }
    }

    func last(_ direction: NiriLayoutHistoryDirection) -> NiriLayoutSnapshot? {
        direction == .undo ? undoSnapshots.last : redoSnapshots.last
    }

    func hasForeignEntry(_ direction: NiriLayoutHistoryDirection) -> Bool {
        switch direction {
        case .undo:
            guard !undoSnapshots.isEmpty else { return false }
            return undoSnapshots[undoSnapshots.count - 1].foreignTransfer != nil
        case .redo:
            guard !redoSnapshots.isEmpty else { return false }
            return redoSnapshots[redoSnapshots.count - 1].foreignTransfer != nil
        }
    }

    func withForeignEntry<Result>(
        _ direction: NiriLayoutHistoryDirection,
        _ body: (borrowing NiriLayoutSnapshot) -> Result
    ) -> Result? {
        guard hasForeignEntry(direction) else { return nil }
        switch direction {
        case .undo: return body(undoSnapshots[undoSnapshots.count - 1])
        case .redo: return body(redoSnapshots[redoSnapshots.count - 1])
        }
    }

    mutating func recordForeign(_ snapshot: consuming NiriLayoutSnapshot) {
        Self.pushOwned(snapshot, onto: &undoSnapshots)
        redoSnapshots.removeAll()
        newest = nil
    }

    mutating func pushForeign(
        _ snapshot: consuming NiriLayoutSnapshot,
        onto direction: NiriLayoutHistoryDirection
    ) {
        switch direction {
        case .undo: Self.pushOwned(snapshot, onto: &undoSnapshots)
        case .redo: Self.pushOwned(snapshot, onto: &redoSnapshots)
        }
    }

    private static func pushOwned(_ snapshot: consuming NiriLayoutSnapshot, onto list: inout [NiriLayoutSnapshot]) {
        list.append(snapshot)
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
    }

    mutating func pop(_ direction: NiriLayoutHistoryDirection) -> NiriLayoutSnapshot? {
        direction == .undo ? popUndo() : popRedo()
    }

    mutating func pushOpposite(of direction: NiriLayoutHistoryDirection, _ snapshot: NiriLayoutSnapshot) {
        if direction == .undo {
            pushRedo(snapshot)
        } else {
            pushUndo(snapshot)
        }
    }

    mutating func popUndo() -> NiriLayoutSnapshot? {
        newest = nil
        return undoSnapshots.popLast()
    }

    mutating func popRedo() -> NiriLayoutSnapshot? {
        newest = nil
        return redoSnapshots.popLast()
    }

    mutating func pushUndo(_ snapshot: NiriLayoutSnapshot) {
        Self.push(snapshot, onto: &undoSnapshots)
    }

    mutating func pushRedo(_ snapshot: NiriLayoutSnapshot) {
        Self.push(snapshot, onto: &redoSnapshots)
    }

    private static func push(_ snapshot: NiriLayoutSnapshot, onto list: inout [NiriLayoutSnapshot]) {
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
            columns: root.columns.map(layoutSnapshotColumn),
            manualWidthColumnCount: workspace.manualWidthColumnCount,
            manualHeightColumnCount: workspace.manualHeightColumnCount,
            focused: focused
        )
    }

    func layoutSnapshotColumn(_ column: NiriContainer) -> NiriLayoutSnapshot.Column {
        NiriLayoutSnapshot.Column(
            id: column.id,
            windows: column.windowNodes.map(\.token),
            sizing: NiriColumnSizing(column, engine: self),
            displayMode: column.displayMode,
            activeTile: column.activeTileIdx
        )
    }

    func newestLayoutStep(in workspaceId: WorkspaceDescriptor.ID) -> NiriNewestLayoutStep? {
        states[workspaceId]?.layoutHistory.newestStep
    }

    func windowSizes(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: CGSize] {
        let windows = root(for: workspaceId)?.allWindows ?? []
        return windows.reduce(into: [WindowToken: CGSize](minimumCapacity: windows.count)) { sizes, window in
            sizes[window.token] = window.frame?.size
        }
    }

    func recordLayoutChange(
        in workspaceId: WorkspaceDescriptor.ID,
        since before: NiriLayoutSnapshot?,
        timing: NiriLayoutStepTiming? = nil
    ) {
        guard let before,
              let after = layoutSnapshot(in: workspaceId, focused: nil),
              !after.hasSameLayout(as: before)
        else { return }
        ensureState(for: workspaceId).layoutHistory.record(before, after: after, timing: timing)
    }

    func forgetLastRedo(in workspaceId: WorkspaceDescriptor.ID) {
        _ = states[workspaceId]?.layoutHistory.popRedo()
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
            guard entry.foreignTransfer == nil else { return nil }
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
        return restoreLayoutSnapshot(snapshot, in: workspaceId, root: root, windows: windows)
    }

    @discardableResult
    func restoreLayoutSnapshot(
        _ snapshot: NiriLayoutSnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        arrivals: borrowing [NiriWindow]
    ) -> Bool {
        let workspace = ensureState(for: workspaceId)
        let root = workspace.root
        guard !arrivals.isEmpty else { return restoreLayoutSnapshot(snapshot, in: workspaceId) }
        var windows = Dictionary(root.allWindows.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        for index in arrivals.indices { windows[arrivals[index].token] = arrivals[index] }
        let restored = restoreLayoutSnapshot(snapshot, in: workspaceId, root: root, windows: consume windows)
        for index in arrivals.indices where arrivals[index].parent?.parent === root { workspace.index(arrivals[index]) }
        return restored
    }

    private func restoreLayoutSnapshot(
        _ snapshot: NiriLayoutSnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        root: NiriRoot,
        windows: consuming [WindowToken: NiriWindow]
    ) -> Bool {
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
