// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    struct SnapshotOptions {
        let viewportState: ViewportState?
        let useScrollAnimationPath: Bool
        let removalSeed: NiriWindowRemovalSeed?
        let isActiveWorkspace: Bool
    }

    func layoutWithNiriEngine(
        activeWorkspaces: Set<WorkspaceDescriptor.ID>,
        useScrollAnimationPath: Bool = false,
        removalSeeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]
    ) -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.niriEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        let workspaceIds = activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString })
        for wsId in workspaceIds {
            guard let workspace = controller.workspaceManager.descriptor(for: wsId),
                  let monitor = controller.workspaceManager.monitor(for: wsId)
            else { continue }

            let layoutType = controller.settings.workspaces.layoutType(for: workspace.name)
            if layoutType == .dwindle { continue }
            let isActiveWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId

            guard let snapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                options: SnapshotOptions(
                    viewportState: nil,
                    useScrollAnimationPath: useScrollAnimationPath,
                    removalSeed: removalSeeds[wsId],
                    isActiveWorkspace: isActiveWorkspace
                )
            ) else { continue }

            plans.append(
                buildRelayoutPlan(
                    snapshot: snapshot,
                    engine: engine,
                    monitor: monitor
                )
            )
        }

        return plans
    }

    func makeWorkspaceSnapshot(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        options: SnapshotOptions
    ) -> NiriWorkspaceSnapshot? {
        guard let controller else { return nil }
        let viewportState = options.viewportState
        let useScrollAnimationPath = options.useScrollAnimationPath
        let removalSeed = options.removalSeed
        let isActiveWorkspace = options.isActiveWorkspace

        let isRelayoutSnapshot = viewportState == nil
        let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)
        guard let refreshInput = controller.layoutRefreshController.buildRefreshInput(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: isRelayoutSnapshot,
            orientation: orientation,
            isActiveWorkspace: isActiveWorkspace
        ) else {
            return nil
        }

        let effectiveViewportState = viewportState ?? controller.workspaceManager.niriViewportState(for: wsId)
        let gap = controller.innerGap(for: monitor, scale: refreshInput.monitor.scale)
        let pictures = edgePictureState(for: refreshInput)

        return NiriWorkspaceSnapshot(
            workspaceId: wsId, monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            excludedTokens: refreshInput.excludedTokens,
            plannedSeq: refreshInput.plannedSeq,
            viewportState: effectiveViewportState,
            preferredFocusToken: picturePreferredFocus(
                in: wsId, state: effectiveViewportState, pictures: pictures, isRelayout: isRelayoutSnapshot
            ),
            hasCompletedInitialRefresh: controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh,
            useScrollAnimationPath: useScrollAnimationPath,
            removalSeed: removalSeed,
            gap: gap,
            niriWorkingFrame: controller.niriWorkingFrame(
                refreshInput.monitor.workingFrame, roomGapLimits: refreshInput.monitor.roomGapLimits, gap: gap
            ),
            fullscreenLayoutFrame: controller.niriFullscreenLayoutFrame(
                refreshInput.monitor.fullscreenLayoutFrame,
                workingFrame: refreshInput.monitor.workingFrame,
                roomGapLimits: refreshInput.monitor.roomGapLimits,
                monitor: monitor,
                gap: gap
            ),
            displayRefreshRate: controller.layoutRefreshController.layoutState
                .refreshRateByDisplay[monitor.displayId] ?? 60.0,
            isActiveWorkspace: refreshInput.isActiveWorkspace,
            quietArrivalTokens: isRelayoutSnapshot
                ? controller.workspaceManager.quietArrivalTokens.intersection(refreshInput.windows.map(\.token))
                : [],
            edgePictures: pictures
        )
    }

    func buildOnDemandLayoutPlan(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval?,
        settlesAnimation: Bool
    ) -> WorkspaceLayoutPlan {
        let sampledAnimationTime = settlesAnimation ? nil : animationTime
        let isSettled = settlesAnimation || (animationTime == nil && controller.map {
            !hasPendingNiriAnimationWork(
                state: snapshot.viewportState, driver: $0.workspaceManager.animationDriver,
                engine: engine, workspaceId: snapshot.workspaceId
            )
        } == true)
        let (frames, hiddenHandles) = calculateOnDemandFrames(
            snapshot: snapshot, engine: engine, monitor: monitor,
            sampledAnimationTime: sampledAnimationTime, isSettled: isSettled, recordsPresentationGeometry: true
        )

        var diff = layoutDiff(
            windows: snapshot.windows, frames: frames, hiddenHandles: hiddenHandles,
            context: NiriLayoutDiffContext(
                engine: engine,
                workspaceId: snapshot.workspaceId,
                canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
                reassertHidden: animationTime == nil || settlesAnimation,
                excludedTokens: snapshot.excludedTokens,
                pendingParkWindowIds: controller?.axManager.pendingParkWindowIdsAwaitingSkyLightMove ?? [],
                settledContext: isSettled ? (snapshot.monitor, snapshot.viewportState) : nil
            )
        )
        diff.edgeHiddenFrames = edgeHiddenFrames(engine: engine, snapshot: snapshot)
        if shouldPreparePictures(snapshot: snapshot, animationTime: sampledAnimationTime) {
            diff.picturePreparation = picturePreparation(
                engine: engine, snapshot: snapshot, state: snapshot.viewportState,
                isSettled: isSettled, time: sampledAnimationTime ?? CACurrentMediaTime()
            )
        }
        let isInteractiveResize = animationTime == nil && engine.interactiveResize?.workspaceId == snapshot.workspaceId
        enforceOnDemandFrameSizes(&diff, animated: sampledAnimationTime != nil || isInteractiveResize)
        if animationTime != nil {
            diff.tabRailGeometryCommands = niriTabRailGeometryCommands(
                engine: engine,
                workspaceId: snapshot.workspaceId,
                monitor: snapshot.monitor
            )
        }

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId, viewportState: nil, plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            isAnimationTick: sampledAnimationTime != nil,
            isInteractiveResize: isInteractiveResize,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    private func buildRelayoutPlan(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor
    ) -> WorkspaceLayoutPlan {
        let motion = controller?.motionPolicy.snapshot() ?? .enabled
        var state = snapshot.viewportState
        let pass = makeLayoutPass(snapshot: snapshot, engine: engine, monitor: monitor, motion: motion)
        let currentSelection = state.selectedNodeId
        pass.engine.setProjectionExclusions(snapshot.excludedTokens, in: pass.wsId)
        let previousExclusions = laidOutExclusions.updateValue(snapshot.excludedTokens, forKey: pass.wsId)
        slideAroundExclusionChanges(from: previousExclusions, pass: pass, state: &state, snapshot: snapshot)

        let removal = processWindowRemovals(
            pass: pass,
            state: &state,
            currentSelection: currentSelection,
            removalSeed: snapshot.removalSeed
        )

        let viewOriginBeforeInsertion = currentViewOrigin(pass: pass, state: state)

        restoreInitialNiriPlacementsIfNeeded(pass: pass, ignoring: snapshot.quietArrivalTokens)

        let insertion = syncAndInsert(
            pass: pass,
            state: &state,
            removal: removal,
            snapshot: snapshot,
            viewOriginBeforeInsertion: viewOriginBeforeInsertion
        )

        let selection = resolveSelection(
            pass: pass,
            state: &state,
            removal: removal,
            snapshot: snapshot
        )

        let arrival = handleNewWindowArrival(
            pass: pass,
            state: &state,
            insertion: insertion,
            existingHandleIds: removal.existingHandleIds,
            snapshot: snapshot
        )

        var plan = computeLayoutPlan(
            pass: pass,
            state: state,
            selection: selection,
            arrival: arrival,
            snapshot: snapshot
        )
        plan.niriRestorePlacements = pass.engine.persistedPlacements(in: pass.wsId)
        plan.quietArrivalTokens = snapshot.quietArrivalTokens

        return plan
    }

    private func restoreInitialNiriPlacementsIfNeeded(
        pass: NiriLayoutPass,
        ignoring quietArrivalTokens: Set<WindowToken>
    ) {
        guard let controller else { return }

        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(pass.windowTokens.count)

        for token in pass.windowTokens where !quietArrivalTokens.contains(token) {
            if let placement = controller.workspaceManager.restoreIntent(for: token)?.niriPlacement {
                placements[token] = placement
            }
        }

        pass.engine.restoreInitialPlacements(placements, matching: pass.windowTokens, in: pass.wsId)
    }

    private func processWindowRemovals(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        currentSelection: NodeId?,
        removalSeed: NiriWindowRemovalSeed?
    ) -> RemovalContext {
        let removedNodeIds = removalSeed?.removedNodeIds ?? []
        let externallyRemovedColumn = removalSeed?.removedColumn == true
        let existingHandleIds = pass.engine.root(for: pass.wsId)?.windowIdSet ?? []
        let removedHandleIds = existingHandleIds.subtracting(Set(pass.windowTokens))
        let wasEmptyBeforeSync = pass.engine.columns(in: pass.wsId).isEmpty

        let removalResult = pass.engine.removeWindows(
            removedHandleIds,
            context: pass.interactionContext,
            state: &state,
            selectedNodeId: currentSelection,
            removedNodeIds: removedNodeIds
        )

        return RemovalContext(
            existingHandleIds: existingHandleIds,
            wasEmptyBeforeSync: wasEmptyBeforeSync,
            removalResult: removalResult,
            externallyRemovedColumn: externallyRemovedColumn
        )
    }

    private func syncAndInsert(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot,
        viewOriginBeforeInsertion: CGFloat?
    ) -> InsertionContext {
        let currentSelection = state.selectedNodeId
        syncWindowsAndInstallConstraints(
            pass: pass,
            selectedNodeId: currentSelection,
            preferredFocusToken: snapshot.preferredFocusToken
        )
        let newTokens = pass.windowTokens.filter { !removal.existingHandleIds.contains($0) }
        let visibleNewTokens = newTokens.filter {
            !pass.engine.isExcludedFromProjection($0, in: pass.wsId)
        }
        var tabLocalTokens = Set<WindowToken>()

        let columns = pass.engine.columns(in: pass.wsId)
        resolvePrimaryContainerSpansIfNeeded(pass: pass)

        if !removal.wasEmptyBeforeSync, !visibleNewTokens.isEmpty {
            let newTokenSet = Set(visibleNewTokens)
            let preexistingSurvivingTokens = Set(pass.windowTokens).intersection(removal.existingHandleIds)
            let newColumnData = insertedColumns(
                in: columns, newTokens: newTokenSet, survivingTokens: preexistingSurvivingTokens,
                tabLocalTokens: &tabLocalTokens
            )

            let originalActiveIdx = state.activeColumnIndex
            let insertedBeforeActive = newColumnData.filter { $0.colIdx <= originalActiveIdx }
            if !insertedBeforeActive.isEmpty, !removal.removedColumn {
                let totalInsertedSpan = insertedBeforeActive.reduce(CGFloat(0)) { total, data in
                    let isQuiet = data.col.windowNodes.allSatisfy { snapshot.quietArrivalTokens.contains($0.token) }
                    return isQuiet ? total : total + data.col[keyPath: pass.primarySpanKeyPath] + pass.gap
                }
                state.rebaseOffset(by: -totalInsertedSpan)
                state.activeColumnIndex = originalActiveIdx + insertedBeforeActive.count
            }

            let sortedNewColumns = newColumnData.sorted { $0.colIdx < $1.colIdx }
            for addedData in sortedNewColumns {
                pass.engine.animateColumnsForAddition(
                    columnIndex: addedData.colIdx,
                    context: pass.interactionContext,
                    state: state
                )
            }
        }
        pass.engine.glideIntoStrip(visibleNewTokens, context: pass.interactionContext, state: state)

        return InsertionContext(
            newTokens: visibleNewTokens,
            tabLocalTokens: tabLocalTokens,
            viewOriginBeforeInsertion: viewOriginBeforeInsertion
        )
    }

    private func slideAroundExclusionChanges(
        from previousExclusions: Set<WindowToken>?,
        pass: NiriLayoutPass,
        state: inout ViewportState,
        snapshot: NiriWorkspaceSnapshot
    ) {
        let exclusions = snapshot.excludedTokens
        guard controller?.settings.niri.macOSFusion == true,
              snapshot.hasCompletedInitialRefresh,
              snapshot.isActiveWorkspace,
              let previousExclusions,
              previousExclusions != exclusions
        else { return }
        let columns = pass.engine.columns(in: pass.wsId)
        let columnIds = columns.map(\.id)
        let widths = columns.map(\.width)
        let liveColumnIds = Set(columnIds)
        viewsBeforeExclusion[pass.wsId] = viewsBeforeExclusion[pass.wsId]?.filter { liveColumnIds.contains($0.key) }
        let showsWindow: (NiriContainer, Set<WindowToken>) -> Bool = { $0.shownWindow(excluding: $1) != nil }
        let hidden = columns.indices.filter {
            showsWindow(columns[$0], previousExclusions) && !showsWindow(columns[$0], exclusions)
        }
        let shown = columns.indices.filter {
            !showsWindow(columns[$0], previousExclusions) && showsWindow(columns[$0], exclusions)
                && !columns[$0].windowNodes.isEmpty
        }
        let changedStacks = columns.filter { column in
            showsWindow(column, previousExclusions) && showsWindow(column, exclusions)
                && column.windowNodes.contains {
                    previousExclusions.contains($0.token) != exclusions.contains($0.token)
                }
        }
        if !changedStacks.isEmpty {
            var frames: [WindowToken: CGRect] = [:]
            for window in changedStacks.flatMap(\.windowNodes) where !previousExclusions.contains(window.token) {
                if let frame = window.frame {
                    frames[window.token] = frame
                }
            }
            stackFramesBeforeExclusion[pass.wsId] = frames
        }
        guard !hidden.isEmpty || !shown.isEmpty else { return }
        NiriLayoutTrace.record(.viewport, workspaceId: pass.wsId, {
            let ids: ([Int]) -> String = { indices in
                indices.map { columns[$0].traceWindowIds }.joined(separator: ",")
            }
            return "exclusion-slide hidden=[\(ids(hidden))] shown=[\(ids(shown))] "
                + "active=\(state.activeColumnIndex) scrollPath=\(snapshot.useScrollAnimationPath)"
        }())
        for index in hidden {
            viewsBeforeExclusion[pass.wsId, default: [:]][columns[index].id] = ExcludedColumnView(
                before: viewPosition(state, columns: columns, exclusions: previousExclusions, pass: pass),
                columnIds: columnIds,
                widths: widths
            )
            if index == state.activeColumnIndex {
                reanchorView(
                    awayFrom: index,
                    columns: columns,
                    previousExclusions: previousExclusions,
                    exclusions: exclusions,
                    pass: pass,
                    state: &state
                )
            }
            pass.engine.animateColumnsAroundRemoval(
                columns: columns,
                removedIdx: index,
                activeIdx: state.activeColumnIndex,
                offset: columns[index][keyPath: pass.primarySpanKeyPath] + pass.gap,
                context: pass.interactionContext
            )
        }
        var undoing: [(index: Int, before: CGFloat)] = []
        var opening: [Int] = []
        for index in shown {
            let remembered = viewsBeforeExclusion[pass.wsId]?.removeValue(forKey: columns[index].id)
            let undoes = remembered.map { view in
                view.columnIds == columnIds && view.widths == widths
            } == true
            NiriLayoutTrace.record(.viewport, workspaceId: pass.wsId, {
                "exclusion-undo column=\(index) undo=\(undoes ? "yes" : remembered == nil ? "no(none)" : "no(changed)")"
            }())
            if undoes, let before = remembered?.before {
                undoing.append((index, before))
            } else {
                opening.append(index)
            }
        }
        if let first = undoing.first {
            restoreView(
                to: first.before,
                returning: undoing.map(\.index),
                columns: columns,
                previousExclusions: previousExclusions,
                exclusions: exclusions,
                pass: pass,
                state: &state
            )
        }
        for index in opening {
            if index < state.activeColumnIndex {
                anchorView(
                    on: columns[index],
                    at: index,
                    columns: columns,
                    exclusions: exclusions,
                    pass: pass,
                    state: &state
                )
            }
            slideAside(
                columns[(index + 1)...],
                by: columns[index][keyPath: pass.primarySpanKeyPath] + pass.gap,
                pass: pass
            )
        }
    }

    private func stripPositions(
        _ columns: [NiriContainer],
        exclusions: Set<WindowToken>,
        pass: NiriLayoutPass
    ) -> [CGFloat] {
        var positions: [CGFloat] = []
        positions.reserveCapacity(columns.count + 1)
        var total: CGFloat = 0
        for column in columns {
            positions.append(total)
            if column.shownWindow(excluding: exclusions) != nil {
                total += column[keyPath: pass.primarySpanKeyPath] + pass.gap
            }
        }
        positions.append(total)
        return positions
    }

    private func viewPosition(
        _ state: ViewportState,
        columns: [NiriContainer],
        exclusions: Set<WindowToken>,
        pass: NiriLayoutPass
    ) -> CGFloat {
        viewPosition(state, in: stripPositions(columns, exclusions: exclusions, pass: pass))
    }

    private func viewPosition(_ state: ViewportState, in positions: [CGFloat]) -> CGFloat {
        positions[min(max(state.activeColumnIndex, 0), positions.count - 1)] + state.viewOffset
    }

    private func restoreView(
        to before: CGFloat,
        returning returningIndices: [Int],
        columns: [NiriContainer],
        previousExclusions: Set<WindowToken>,
        exclusions: Set<WindowToken>,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        let positionsNow = stripPositions(columns, exclusions: previousExclusions, pass: pass)
        let viewNow = viewPosition(state, in: positionsNow)
        resolvePrimaryContainerSpansIfNeeded(pass: pass)
        guard let index = returningIndices.first else { return }
        let positionsThen = stripPositions(columns, exclusions: exclusions, pass: pass)
        state.rebaseOffset(by: before - positionsThen[index] - state.viewOffset)
        state.activeColumnIndex = index
        if let window = columns[index].shownWindow(excluding: exclusions) {
            state.selectedNodeId = window.id
        }
        for (other, column) in columns.enumerated() where !returningIndices.contains(other)
            && column.shownWindow(excluding: exclusions) != nil
        {
            let shift = (positionsNow[other] - viewNow) - (positionsThen[other] - before)
            slide(column, from: shift, pass: pass)
        }
    }

    private func reanchorView(
        awayFrom index: Int,
        columns: [NiriContainer],
        previousExclusions: Set<WindowToken>,
        exclusions: Set<WindowToken>,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        let isShown: (Int) -> Bool = { candidate in
            columns[candidate].shownWindow(excluding: exclusions) != nil
        }
        guard let anchor = (0 ..< index).reversed().first(where: isShown)
            ?? ((index + 1) ..< columns.count).first(where: isShown)
        else { return }
        let positions = stripPositions(columns, exclusions: previousExclusions, pass: pass)
        state.rebaseOffset(by: viewPosition(state, in: positions) - positions[anchor] - state.viewOffset)
        state.activeColumnIndex = anchor
    }

    private func anchorView(
        on column: NiriContainer,
        at index: Int,
        columns: [NiriContainer],
        exclusions: Set<WindowToken>,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        let positions = stripPositions(columns, exclusions: exclusions, pass: pass)
        state.rebaseOffset(by: positions[state.activeColumnIndex] - positions[index + 1])
        state.activeColumnIndex = index
        if let window = column.shownWindow(excluding: exclusions) {
            state.selectedNodeId = window.id
        }
    }

    private func slideAside(_ columns: ArraySlice<NiriContainer>, by offset: CGFloat, pass: NiriLayoutPass) {
        for column in columns {
            slide(column, from: -offset, pass: pass)
        }
    }

    private func slide(_ column: NiriContainer, from shift: CGFloat, pass: NiriLayoutPass) {
        guard abs(shift) > 0.5, !column.offsetMoveAnimCurrent(shift, orientation: pass.orientation) else { return }
        pass.engine.animateReorderedColumn(column, displacement: shift, context: pass.interactionContext)
    }

    private func makeLayoutPass(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        motion: MotionSnapshot
    ) -> NiriLayoutPass {
        return NiriLayoutPass(
            motion: motion,
            wsId: snapshot.workspaceId,
            engine: engine,
            monitor: monitor,
            orientation: snapshot.monitor.orientation,
            insetFrame: snapshot.niriWorkingFrame,
            gap: snapshot.gap,
            windows: snapshot.windows,
            windowTokens: snapshot.windows.map(\.token)
        )
    }

    func settledFrames(in workspaceId: WorkspaceDescriptor.ID, visibleOnly: Bool = false) -> [WindowToken: CGRect]? {
        guard let controller,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let snapshot = makeWorkspaceSnapshot(
                  workspaceId: workspaceId,
                  monitor: monitor,
                  options: SnapshotOptions(
                      viewportState: controller.workspaceManager.niriViewportState(for: workspaceId),
                      useScrollAnimationPath: false,
                      removalSeed: nil,
                      isActiveWorkspace: controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
                          == workspaceId
                  )
              )
        else {
            return nil
        }
        let result = calculateOnDemandFrames(
            snapshot: snapshot,
            engine: engine,
            monitor: monitor,
            sampledAnimationTime: nil,
            isSettled: true
        )
        return visibleOnly ? result.frames.filter { result.hiddenHandles[$0.key] == nil } : result.frames
    }

    private func calculateOnDemandFrames(
        snapshot: NiriWorkspaceSnapshot,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        sampledAnimationTime: TimeInterval?,
        isSettled: Bool,
        recordsPresentationGeometry: Bool = false
    ) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
        let gaps = LayoutGaps(
            horizontal: snapshot.gap,
            vertical: snapshot.gap
        )

        let area = WorkingAreaContext(
            workingFrame: snapshot.niriWorkingFrame,
            singleWindowFrame: snapshot.monitor.workingFrame,
            borderSafeFillFrame: snapshot.monitor.borderSafeFillFrame,
            fullscreenLayoutFrame: snapshot.fullscreenLayoutFrame,
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        let offsets = controller?.workspaceManager.animationDriver.renderOffsets(
            in: snapshot.workspaceId,
            semanticOffset: snapshot.viewportState.viewOffset,
            at: sampledAnimationTime ?? CACurrentMediaTime()
        )

        return engine.calculateCombinedLayoutUsingPools(
            in: snapshot.workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: snapshot.viewportState,
            workingArea: area,
            animationTime: sampledAnimationTime,
            viewOffsetOverride: offsets?.liveOffset,
            settledVisibilityOffset: offsets?.settledVisibilityOffset,
            isSettled: isSettled,
            excludedTokens: snapshot.excludedTokens, edgePictures: snapshot.edgePictures,
            recordsPresentationGeometry: recordsPresentationGeometry
        )
    }

    private func enforceOnDemandFrameSizes(_ diff: inout WorkspaceLayoutDiff, animated: Bool) {
        if let axManager = controller?.axManager {
            for index in diff.frameChanges.indices {
                diff.frameChanges[index] = !animated
                    ? axManager.enforcedSizeFrameChange(diff.frameChanges[index])
                    : axManager.animationFrameChange(diff.frameChanges[index])
            }
        }
    }

    private func insertedColumns(
        in columns: [NiriContainer],
        newTokens: Set<WindowToken>,
        survivingTokens: Set<WindowToken>,
        tabLocalTokens: inout Set<WindowToken>
    ) -> [(col: NiriContainer, colIdx: Int)] {
        var newColumnData: [(col: NiriContainer, colIdx: Int)] = []

        for (colIdx, col) in columns.enumerated() {
            var columnNewTokens: [WindowToken] = []
            var hasPreexistingToken = false
            for window in col.windowNodes {
                if newTokens.contains(window.token) {
                    columnNewTokens.append(window.token)
                }
                if survivingTokens.contains(window.token) {
                    hasPreexistingToken = true
                }
            }
            guard !columnNewTokens.isEmpty else { continue }

            if hasPreexistingToken {
                if col.displayMode == .tabbed {
                    tabLocalTokens.formUnion(columnNewTokens)
                }
            } else {
                newColumnData.append((col, colIdx))
            }
        }

        return newColumnData
    }
}
