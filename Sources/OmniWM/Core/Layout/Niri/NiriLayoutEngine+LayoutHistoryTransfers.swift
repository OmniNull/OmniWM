// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func recordLayoutChanges(
        in mainWorkspaceId: WorkspaceDescriptor.ID,
        since before: [WorkspaceDescriptor.ID: NiriLayoutSnapshot],
        coveringEveryWorkspace: Bool,
        timing: NiriLayoutStepTiming? = nil
    ) {
        if !coveringEveryWorkspace, before.count == 1, let previous = before[mainWorkspaceId] {
            recordLayoutChange(in: mainWorkspaceId, since: previous, timing: timing)
            return
        }
        let origins = workspaceByToken(in: before)
        var afters: [WorkspaceDescriptor.ID: NiriLayoutSnapshot] = [:]
        for workspaceId in before.keys {
            afters[workspaceId] = layoutSnapshot(in: workspaceId, focused: nil)
        }
        if coveringEveryWorkspace {
            for workspaceId in states.keys where before[workspaceId] == nil {
                afters[workspaceId] = layoutSnapshot(in: workspaceId, focused: nil)
            }
        }
        let locations = workspaceByToken(in: afters)
        for (workspaceId, after) in afters {
            let previous = before[workspaceId] ?? .empty
            var arrived: [WindowToken] = []
            after.columns.forEach { column in
                for token in column.windows where origins[token].map({ $0 != workspaceId }) ?? false {
                    arrived.append(token)
                }
            }
            let departed = previous.columns.contains { column in
                column.windows.contains { locations[$0].map { $0 != workspaceId } ?? false }
            }
            guard !arrived.isEmpty || departed else {
                if workspaceId == mainWorkspaceId, !after.hasSameLayout(as: previous) {
                    ensureState(for: workspaceId).layoutHistory.record(previous, after: after, timing: timing)
                }
                continue
            }
            var entry = previous
            entry.away = Dictionary(grouping: arrived) { origins[$0]! }.compactMap { origin, tokens in
                before[origin].map { NiriLayoutAway(workspaceId: origin, tokens: tokens, snapshot: $0) }
            }
            ensureState(for: workspaceId).layoutHistory.record(entry, after: after, timing: timing)
        }
    }

    private func workspaceByToken(
        in snapshots: [WorkspaceDescriptor.ID: NiriLayoutSnapshot]
    ) -> [WindowToken: WorkspaceDescriptor.ID] {
        snapshots.reduce(into: [:]) { workspaces, item in
            item.value.columns.forEach { column in
                for token in column.windows {
                    workspaces[token] = item.key
                }
            }
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

    func restoreAwayColumns(_ away: NiriLayoutAway, in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = root(for: workspaceId) else { return }
        let windows = Dictionary(root.allWindows.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        restoreAwayColumns(away, in: root, windows: windows)
    }

    func restoreAwayColumns(
        _ away: NiriLayoutAway,
        in workspaceId: WorkspaceDescriptor.ID,
        arrivals: borrowing [NiriWindow]
    ) {
        let workspace = ensureState(for: workspaceId)
        guard !arrivals.isEmpty else { return restoreAwayColumns(away, in: workspaceId) }
        let root = workspace.root
        var windows = Dictionary(root.allWindows.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        for index in arrivals.indices { windows[arrivals[index].token] = arrivals[index] }
        restoreAwayColumns(away, in: root, windows: consume windows)
        for index in arrivals.indices where arrivals[index].parent?.parent === root {
            workspace.index(arrivals[index])
        }
    }

    private func restoreAwayColumns(
        _ away: NiriLayoutAway,
        in root: NiriRoot,
        windows: consuming [WindowToken: NiriWindow]
    ) {
        let availableWindows = consume windows
        let moved = Set(away.tokens)
        let saved = away.snapshot.columns
        for (index, column) in saved.enumerated() {
            let returning = column.windows.filter(moved.contains).compactMap { availableWindows[$0] }
            guard !returning.isEmpty else { continue }
            let stayed = column.windows.lazy.filter { !moved.contains($0) }.compactMap { availableWindows[$0] }
            let container: NiriContainer
            let comesBackWhole: Bool
            if let host = stayed.first?.parent as? NiriContainer {
                container = host
                comesBackWhole = false
            } else {
                container = NiriContainer()
                comesBackWhole = true
            }
            let wanted = column.windows.compactMap { availableWindows[$0] }
                .filter { moved.contains($0.token) || $0.parent === container }
            for (position, window) in wanted.enumerated()
                where window.parent !== container || container.children.firstIndex(where: { $0 === window }) != position
            {
                container.insertChild(window, at: position)
            }
            if comesBackWhole {
                for emptied in root.columns where emptied.windowNodes.isEmpty {
                    emptied.remove()
                }
                root.insertChild(
                    container,
                    at: awayColumnIndex(index, in: root, saved: saved, moved: moved, windows: availableWindows)
                )
                column.sizing.restore(to: container, engine: self)
                container.displayMode = column.displayMode
                container.setActiveTileIdx(column.activeTile)
            } else {
                for window in returning {
                    column.sizing.windows[window.token]?.restore(window, in: container)
                }
            }
            updateTabbedColumnVisibility(column: container)
        }
        for emptied in root.columns where emptied.windowNodes.isEmpty {
            emptied.remove()
        }
    }

    private func awayColumnIndex(
        _ index: Int,
        in root: NiriRoot,
        saved: [NiriLayoutSnapshot.Column],
        moved: Set<WindowToken>,
        windows: [WindowToken: NiriWindow]
    ) -> Int {
        let current = root.columns
        func position(of column: NiriLayoutSnapshot.Column, placed: Bool) -> Int? {
            column.windows.lazy
                .filter { placed || !moved.contains($0) }
                .compactMap { windows[$0]?.parent as? NiriContainer }
                .compactMap { host in current.firstIndex { $0 === host } }
                .first
        }
        if let previous = saved[..<index].reversed().lazy.compactMap({ position(of: $0, placed: true) }).first {
            return previous + 1
        }
        if let next = saved[(index + 1)...].lazy.compactMap({ position(of: $0, placed: false) }).first {
            return next
        }
        return min(index, current.count)
    }

    func commitTransferredLayoutHistoryStep(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        inverse: NiriLayoutSnapshot
    ) -> NiriLayoutHistoryStep? {
        let workspace = ensureState(for: workspaceId)
        guard let entry = workspace.layoutHistory.pop(direction) else { return nil }
        for away in entry.away {
            restoreAwayColumns(away, in: away.workspaceId)
        }
        if !entry.columns.isEmpty {
            restoreLayoutSnapshot(entry, in: workspaceId)
        }
        workspace.layoutHistory.pushOpposite(of: direction, inverse)
        let present = Set(root(for: workspaceId)?.allWindows.map(\.token) ?? [])
        return NiriLayoutHistoryStep(focused: entry.focused.flatMap { present.contains($0) ? $0 : nil })
    }
}
