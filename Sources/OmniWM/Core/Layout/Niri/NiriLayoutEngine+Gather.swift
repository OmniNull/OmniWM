// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct NiriGatherRequest: Equatable {
    let tokens: [WindowToken]
    let sourceWorkspaceIds: [WindowToken: WorkspaceDescriptor.ID]
    let destinationWorkspaceId: WorkspaceDescriptor.ID
    let geometry: NiriSizingGeometry
    let nativeFocusToken: WindowToken?
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
    enum Placement: Equatable {
        case reuse(NodeId)
        case newColumn(after: NodeId?)

        var reusedColumnId: NodeId? {
            if case let .reuse(columnId) = self { columnId } else { nil }
        }
    }

    struct WorkspacePatch: Equatable {
        let workspaceId: WorkspaceDescriptor.ID
        let finalColumns: [[NodeId]]
        let selectedNodeId: NodeId?

        var activeColumnIndex: Int {
            selectedNodeId.flatMap { selected in finalColumns.firstIndex { $0.contains(selected) } } ?? 0
        }
    }

    let request: NiriGatherRequest
    let placement: Placement
    let gatheredActiveTileIndex: Int
    let workspaces: [WorkspacePatch]
    let movedTokens: [WindowToken]

    var destinationWorkspaceId: WorkspaceDescriptor.ID {
        request.destinationWorkspaceId
    }

    var affectedWorkspaceIds: [WorkspaceDescriptor.ID] {
        workspaces.map(\.workspaceId)
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
        let targetIdSet = Set(targetIds)
        let placement = gatherPlacement(in: destinationId, anchor: selections[destinationId], targetIds: targetIdSet)
        let destinationColumns = gatheredDestinationColumns(
            in: destinationId,
            placement: placement,
            targetIds: targetIds
        )
        guard destinationColumns != columns(in: destinationId).map({ $0.windowNodes.map(\.id) }) else {
            return .unchanged
        }
        let reusedColumn = placement.reusedColumnId.flatMap { gatherColumn($0, in: destinationId) }
        guard reusedColumn?.isTabbed == true || gatheredColumnFits(nodes, geometry: request.geometry) else {
            return .refused(.doesNotFit)
        }

        let nativeFocusIndex = request.nativeFocusToken.flatMap { request.tokens.firstIndex(of: $0) }
        let destinationSelection = nativeFocusIndex.map { targetIds[$0] }
            ?? selections[destinationId].flatMap { selected in
                destinationColumns.contains { $0.contains(selected) } ? selected : nil
            }
            ?? targetIds.first
        let destinationPatch = NiriGatherPlan.WorkspacePatch(
            workspaceId: destinationId,
            finalColumns: destinationColumns,
            selectedNodeId: destinationSelection
        )
        let reusedMemberIds = reusedColumn?.windowNodes.map(\.id) ?? []
        return .ready(
            NiriGatherPlan(
                request: request,
                placement: placement,
                gatheredActiveTileIndex: destinationSelection.flatMap { targetIds.firstIndex(of: $0) }
                    ?? reusedColumn?.activeWindow.flatMap { targetIds.firstIndex(of: $0.id) }
                    ?? 0,
                workspaces: [destinationPatch] + gatherSourcePatches(
                    request,
                    removing: targetIdSet,
                    selections: selections
                ),
                movedTokens: zip(request.tokens, targetIds).enumerated().compactMap { index, pair in
                    reusedMemberIds.firstIndex(of: pair.1) == index ? nil : pair.0
                }
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
        let reusedColumn = plan.placement.reusedColumnId.map { liveGatherColumn($0, in: destinationId) }
        let keptSizing = keepsWindowWidths
            ? nodes.first.flatMap { containerSizingState(for: $0.0.token, in: $0.1) }
            : nil

        detachGatheredNodes(nodes, keeping: reusedColumn, into: destinationState, destinationId: destinationId)
        let gatheredColumn = reusedColumn ?? insertGatheredColumn(
            for: plan.placement,
            into: destinationState,
            destinationId: destinationId,
            sizing: keptSizing
        )
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

    private func gatherPlacement(
        in destinationId: WorkspaceDescriptor.ID,
        anchor anchorId: NodeId?,
        targetIds: Set<NodeId>
    ) -> NiriGatherPlan.Placement {
        guard let anchorId,
              let anchor = findNode(by: anchorId, in: destinationId) as? NiriWindow,
              let anchorColumn = findColumn(containing: anchor, in: destinationId)
        else {
            return .newColumn(after: nil)
        }
        guard targetIds.contains(anchorId) else { return .newColumn(after: anchorColumn.id) }
        if anchorColumn.windowNodes.allSatisfy({ targetIds.contains($0.id) }) {
            return .reuse(anchorColumn.id)
        }
        let precedingSurvivor = columns(in: destinationId)
            .prefix { $0 !== anchorColumn }
            .last { Self.gatherSurvivors(of: $0.windowNodes.map(\.id), removing: targetIds) != nil }
        return .newColumn(after: precedingSurvivor?.id)
    }

    private func gatheredDestinationColumns(
        in destinationId: WorkspaceDescriptor.ID,
        placement: NiriGatherPlan.Placement,
        targetIds: [NodeId]
    ) -> [[NodeId]] {
        let targetIdSet = Set(targetIds)
        var finalColumns: [[NodeId]] = []
        var insertionIndex = 0
        for column in columns(in: destinationId) {
            if placement == .reuse(column.id) {
                finalColumns.append(targetIds)
            } else if let survivors = Self.gatherSurvivors(of: column.windowNodes.map(\.id), removing: targetIdSet) {
                finalColumns.append(survivors)
                if placement == .newColumn(after: column.id) {
                    insertionIndex = finalColumns.count
                }
            }
        }
        guard placement.reusedColumnId == nil else { return finalColumns }
        guard !finalColumns.allSatisfy(\.isEmpty) else { return [targetIds] }
        finalColumns.insert(targetIds, at: insertionIndex)
        return finalColumns
    }

    private func gatherSourcePatches(
        _ request: NiriGatherRequest,
        removing targetIds: Set<NodeId>,
        selections: [WorkspaceDescriptor.ID: NodeId]
    ) -> [NiriGatherPlan.WorkspacePatch] {
        var sourceIds: [WorkspaceDescriptor.ID] = []
        for sourceId in request.tokens.compactMap({ request.sourceWorkspaceIds[$0] })
            where sourceId != request.destinationWorkspaceId && !sourceIds.contains(sourceId)
        {
            sourceIds.append(sourceId)
        }
        return sourceIds.map { workspaceId in
            let originalColumns = columns(in: workspaceId).map { $0.windowNodes.map(\.id) }
            let finalColumns = originalColumns.compactMap { Self.gatherSurvivors(of: $0, removing: targetIds) }
            let selection = selections[workspaceId]
            let selectedNodeId: NodeId? = if let selection, finalColumns.contains(where: { $0.contains(selection) }) {
                selection
            } else {
                selection.flatMap {
                    Self.gatherSurvivorSelection(replacing: $0, in: originalColumns, removing: targetIds)
                }
            }
            return NiriGatherPlan.WorkspacePatch(
                workspaceId: workspaceId,
                finalColumns: finalColumns,
                selectedNodeId: selectedNodeId
            )
        }
    }

    private func gatherColumn(_ columnId: NodeId, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer? {
        columns(in: workspaceId).first { $0.id == columnId }
    }

    private func liveGatherColumn(_ columnId: NodeId, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer {
        guard let column = gatherColumn(columnId, in: workspaceId) else {
            preconditionFailure("applyGather requires its placement column in the live tree")
        }
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
        for placement: NiriGatherPlan.Placement,
        into destinationState: NiriWorkspaceState,
        destinationId: WorkspaceDescriptor.ID,
        sizing: NiriContainerSizingState?
    ) -> NiriContainer {
        let root = destinationState.root
        removeEmptyColumnsIfWorkspaceEmpty(in: root)
        let column = NiriContainer()
        initializeNewContainerSizing(column, in: destinationId, initialState: sizing)
        if case let .newColumn(after: precedingColumnId?) = placement {
            root.insertAfter(column, reference: liveGatherColumn(precedingColumnId, in: destinationId))
        } else if let leadingColumn = root.columns.first {
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

    private static func gatherSurvivors(of column: [NodeId], removing removed: Set<NodeId>) -> [NodeId]? {
        let survivors = column.filter { !removed.contains($0) }
        return !column.isEmpty && survivors.isEmpty ? nil : survivors
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
