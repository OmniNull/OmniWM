// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct NiriGatherRequest: Equatable {
    let tokens: [WindowToken]
    let sourceWorkspaceIds: [WindowToken: WorkspaceDescriptor.ID]
    let destinationWorkspaceId: WorkspaceDescriptor.ID
    let geometry: NiriSizingGeometry
}

enum NiriGatherIssue: Equatable {
    case layoutConflict
    case layoutFullscreen
}

enum NiriGatherRefusal: Equatable {
    case windows([WindowToken: NiriGatherIssue])
    case doesNotFit
}

struct NiriGatherPlan: Equatable {
    struct WorkspacePatch: Equatable {
        let workspaceId: WorkspaceDescriptor.ID
        let originalColumns: [[NodeId]]
        let finalColumns: [[NodeId]]
        let selectedNodeId: NodeId?
        let activeColumnIndex: Int
    }

    let request: NiriGatherRequest
    let nodeIds: [NodeId]
    let reusedColumnId: NodeId?
    let gatheredActiveTileIndex: Int
    let workspaces: [WorkspacePatch]
    let movedTokens: [WindowToken]
    let reassignedTokens: [WindowToken]

    var destinationWorkspaceId: WorkspaceDescriptor.ID {
        request.destinationWorkspaceId
    }

    var affectedWorkspaceIds: [WorkspaceDescriptor.ID] {
        workspaces.map(\.workspaceId)
    }

    func selection(in workspaceId: WorkspaceDescriptor.ID) -> NodeId? {
        workspaces.first { $0.workspaceId == workspaceId }?.selectedNodeId
    }

    func activeColumnIndex(in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        workspaces.first { $0.workspaceId == workspaceId }?.activeColumnIndex
    }
}

enum NiriGatherPlanning: Equatable {
    case unchanged
    case refused(NiriGatherRefusal)
    case ready(NiriGatherPlan)
}

extension NiriLayoutEngine {
    func planGather(
        _ request: NiriGatherRequest,
        selections: [WorkspaceDescriptor.ID: NodeId]
    ) -> NiriGatherPlanning {
        let (nodes, issues) = resolveGatherNodes(request)
        guard issues.isEmpty else { return .refused(.windows(issues)) }
        guard !nodes.isEmpty else { return .unchanged }

        let destinationId = request.destinationWorkspaceId
        let targetIds = nodes.map(\.id)
        let reusedColumn = reusableGatherColumn(in: destinationId, targetIds: Set(targetIds))
        if let reusedColumn, reusedColumn.windowNodes.map(\.id) == targetIds {
            return .unchanged
        }
        guard reusedColumn?.isTabbed == true || gatheredColumnFits(nodes, geometry: request.geometry) else {
            return .refused(.doesNotFit)
        }

        var workspaceOrder = [destinationId]
        for token in request.tokens {
            if let sourceId = request.sourceWorkspaceIds[token], !workspaceOrder.contains(sourceId) {
                workspaceOrder.append(sourceId)
            }
        }
        let workspaces = workspaceOrder.map { workspaceId in
            gatherWorkspacePatch(
                workspaceId,
                isDestination: workspaceId == destinationId,
                reusesLeadingColumn: reusedColumn != nil,
                targetIds: targetIds,
                selection: selections[workspaceId]
            )
        }

        let reusedMemberIds = reusedColumn?.windowNodes.map(\.id) ?? []
        let gatheredActiveTileIndex = workspaces[0].selectedNodeId.flatMap { targetIds.firstIndex(of: $0) }
            ?? reusedColumn?.activeWindow.flatMap { targetIds.firstIndex(of: $0.id) }
            ?? 0
        return .ready(
            NiriGatherPlan(
                request: request,
                nodeIds: targetIds,
                reusedColumnId: reusedColumn?.id,
                gatheredActiveTileIndex: gatheredActiveTileIndex,
                workspaces: workspaces,
                movedTokens: zip(request.tokens, targetIds).enumerated().compactMap { index, pair in
                    reusedMemberIds.firstIndex(of: pair.1) == index ? nil : pair.0
                },
                reassignedTokens: request.tokens.filter { request.sourceWorkspaceIds[$0] != destinationId }
            )
        )
    }

    func applyGather(_ plan: NiriGatherPlan) {
        assertSanctionedMutation()
        let request = plan.request
        let destinationId = request.destinationWorkspaceId
        let sourceIds = plan.affectedWorkspaceIds.filter { $0 != destinationId }
        let wasSingleWindow = Dictionary(uniqueKeysWithValues: sourceIds.map {
            ($0, singleWindowLayoutContext(in: $0) != nil)
        })
        let nodes = request.tokens.map { token -> (NiriWindow, WorkspaceDescriptor.ID) in
            guard let sourceId = request.sourceWorkspaceIds[token],
                  let node = findNode(for: token, in: sourceId)
            else {
                preconditionFailure("applyGather requires a plan revalidated against the live tree")
            }
            return (node, sourceId)
        }
        let destinationState = ensureState(for: destinationId)
        let reusedColumn = plan.reusedColumnId.flatMap { columnId in
            columns(in: destinationId).first { $0.id == columnId }
        }

        detachGatheredNodes(nodes, keeping: reusedColumn, into: destinationState, destinationId: destinationId)
        let gatheredColumn = reusedColumn ?? insertGatheredColumn(into: destinationState, destinationId: destinationId)
        for (index, (node, _)) in nodes.enumerated() {
            gatheredColumn.insertChild(node, at: index)
        }
        gatheredColumn.setActiveTileIdx(plan.gatheredActiveTileIndex)
        updateTabbedColumnVisibility(column: gatheredColumn)

        for sourceId in sourceIds {
            clearManualSpanOverridesOnSingleWindowEntry(
                in: sourceId,
                wasSingleWindow: wasSingleWindow[sourceId] ?? false
            )
        }
    }

    private func resolveGatherNodes(
        _ request: NiriGatherRequest
    ) -> (nodes: [NiriWindow], issues: [WindowToken: NiriGatherIssue]) {
        var issues: [WindowToken: NiriGatherIssue] = [:]
        var nodes: [NiriWindow] = []
        var seenTokens = Set<WindowToken>()
        for token in request.tokens {
            guard seenTokens.insert(token).inserted,
                  let sourceId = request.sourceWorkspaceIds[token],
                  workspaceIds(containing: token) == [sourceId],
                  let node = findNode(for: token, in: sourceId),
                  findColumn(containing: node, in: sourceId) != nil
            else {
                issues[token] = .layoutConflict
                continue
            }
            if node.isFullscreen {
                issues[token] = .layoutFullscreen
                continue
            }
            nodes.append(node)
        }
        return (nodes, issues)
    }

    private func reusableGatherColumn(
        in workspaceId: WorkspaceDescriptor.ID,
        targetIds: Set<NodeId>
    ) -> NiriContainer? {
        guard let column = columns(in: workspaceId).first else { return nil }
        let members = column.windowNodes
        guard !members.isEmpty, members.allSatisfy({ targetIds.contains($0.id) }) else { return nil }
        return column
    }

    private func detachGatheredNodes(
        _ nodes: [(NiriWindow, WorkspaceDescriptor.ID)],
        keeping reusedColumn: NiriContainer?,
        into destinationState: NiriWorkspaceState,
        destinationId: WorkspaceDescriptor.ID
    ) {
        var touchedColumns: [NiriContainer] = []
        for (node, sourceId) in nodes {
            cancelInteractions(for: [node.id], in: sourceId)
            guard let column = findColumn(containing: node, in: sourceId), column !== reusedColumn else { continue }
            column.adjustActiveTileIdxForRemoval(of: node)
            node.detach()
            resetMovedWindowColumnLocalSizing(node)
            if sourceId != destinationId {
                states[sourceId]?.unindex(node)
                destinationState.index(node)
            }
            if !touchedColumns.contains(where: { $0 === column }) {
                touchedColumns.append(column)
            }
        }
        for column in touchedColumns {
            if column.children.isEmpty {
                column.remove()
            } else if column.isTabbed {
                column.clampActiveTileIdx()
                updateTabbedColumnVisibility(column: column)
            }
        }
    }

    private func insertGatheredColumn(
        into destinationState: NiriWorkspaceState,
        destinationId: WorkspaceDescriptor.ID
    ) -> NiriContainer {
        let root = destinationState.root
        removeEmptyColumnsIfWorkspaceEmpty(in: root)
        let column = NiriContainer()
        initializeNewContainerSizing(column, in: destinationId)
        if let leadingColumn = root.columns.first {
            root.insertBefore(column, reference: leadingColumn)
        } else {
            root.appendChild(column)
        }
        return column
    }

    private func gatheredColumnFits(_ nodes: [NiriWindow], geometry: NiriSizingGeometry) -> Bool {
        let axisSpace = geometry.orientation == .horizontal
            ? geometry.workingFrame.height
            : geometry.workingFrame.width
        let minimumSum = nodes.reduce(CGFloat.zero) { sum, node in
            let minSize = node.constraints.normalized().minSize
            return sum + (geometry.orientation == .horizontal ? minSize.height : minSize.width)
        }
        return minimumSum + geometry.gaps * CGFloat(nodes.count + 1) <= axisSpace + 0.5
    }

    private func gatherWorkspacePatch(
        _ workspaceId: WorkspaceDescriptor.ID,
        isDestination: Bool,
        reusesLeadingColumn: Bool,
        targetIds: [NodeId],
        selection: NodeId?
    ) -> NiriGatherPlan.WorkspacePatch {
        let targetIdSet = Set(targetIds)
        let originalColumns = columns(in: workspaceId).map { $0.windowNodes.map(\.id) }
        var finalColumns = originalColumns.compactMap { column -> [NodeId]? in
            let survivors = column.filter { !targetIdSet.contains($0) }
            return !column.isEmpty && survivors.isEmpty ? nil : survivors
        }
        if isDestination {
            if !reusesLeadingColumn, finalColumns.allSatisfy(\.isEmpty) {
                finalColumns = []
            }
            finalColumns.insert(targetIds, at: 0)
        }

        let selectedNodeId: NodeId? = if let selection, finalColumns.contains(where: { $0.contains(selection) }) {
            selection
        } else if isDestination {
            targetIds.first
        } else {
            selection.flatMap {
                Self.gatherSurvivorSelection(replacing: $0, in: originalColumns, removing: targetIdSet)
            }
        }
        return NiriGatherPlan.WorkspacePatch(
            workspaceId: workspaceId,
            originalColumns: originalColumns,
            finalColumns: finalColumns,
            selectedNodeId: selectedNodeId,
            activeColumnIndex: selectedNodeId.flatMap { selected in
                finalColumns.firstIndex { $0.contains(selected) }
            } ?? 0
        )
    }

    private static func gatherSurvivorSelection(
        replacing selected: NodeId,
        in columns: [[NodeId]],
        removing removed: Set<NodeId>
    ) -> NodeId? {
        guard let columnIndex = columns.firstIndex(where: { $0.contains(selected) }),
              let tileIndex = columns[columnIndex].firstIndex(of: selected)
        else {
            return nil
        }
        let column = columns[columnIndex]
        if let next = column[(tileIndex + 1)...].first(where: { !removed.contains($0) }) {
            return next
        }
        if let previous = column[..<tileIndex].last(where: { !removed.contains($0) }) {
            return previous
        }
        let firstSurvivor: ([NodeId]) -> NodeId? = { $0.first { !removed.contains($0) } }
        if let previousColumn = columns[..<columnIndex].reversed().lazy.compactMap(firstSurvivor).first {
            return previousColumn
        }
        return columns[(columnIndex + 1)...].lazy.compactMap(firstSurvivor).first
    }
}
