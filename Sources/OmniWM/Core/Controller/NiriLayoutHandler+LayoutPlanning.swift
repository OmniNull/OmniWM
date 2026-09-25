// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

        let shouldResolveConstraints = viewportState == nil
        let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)
        guard let refreshInput = controller.layoutRefreshController.buildRefreshInput(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: shouldResolveConstraints,
            orientation: orientation,
            isActiveWorkspace: isActiveWorkspace
        ) else {
            return nil
        }

        let effectiveViewportState = viewportState ?? controller.workspaceManager.niriViewportState(for: wsId)

        return NiriWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            excludedTokens: refreshInput.excludedTokens,
            plannedSeq: refreshInput.plannedSeq,
            viewportState: effectiveViewportState,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            hasCompletedInitialRefresh: controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh,
            useScrollAnimationPath: useScrollAnimationPath,
            removalSeed: removalSeed,
            gap: controller.innerGap(for: monitor, scale: refreshInput.monitor.scale),
            displayRefreshRate: controller.layoutRefreshController.layoutState
                .refreshRateByDisplay[monitor.displayId] ?? 60.0,
            isActiveWorkspace: refreshInput.isActiveWorkspace
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
                state: snapshot.viewportState,
                driver: $0.workspaceManager.animationDriver,
                engine: engine,
                workspaceId: snapshot.workspaceId
            )
        } == true)
        let (frames, hiddenHandles) = calculateOnDemandFrames(
            snapshot: snapshot, engine: engine, monitor: monitor,
            sampledAnimationTime: sampledAnimationTime, isSettled: isSettled
        )

        var diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            hiddenHandles: hiddenHandles,
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
        enforceOnDemandFrameSizes(&diff, animated: sampledAnimationTime != nil)
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
                workspaceId: snapshot.workspaceId,
                viewportState: nil,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            isAnimationTick: sampledAnimationTime != nil,
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

        let removal = processWindowRemovals(
            pass: pass,
            state: &state,
            currentSelection: currentSelection,
            removalSeed: snapshot.removalSeed
        )

        let viewOriginBeforeInsertion = currentViewOrigin(pass: pass, state: state)

        restoreInitialNiriPlacementsIfNeeded(pass: pass)

        let insertion = syncAndInsert(
            pass: pass,
            state: &state,
            removal: removal,
            preferredFocusToken: snapshot.preferredFocusToken,
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

        return plan
    }

    private func restoreInitialNiriPlacementsIfNeeded(
        pass: NiriLayoutPass
    ) {
        guard let controller else { return }

        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(pass.windowTokens.count)

        for token in pass.windowTokens {
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
        preferredFocusToken: WindowToken?,
        viewOriginBeforeInsertion: CGFloat?
    ) -> InsertionContext {
        let currentSelection = state.selectedNodeId
        syncWindowsAndInstallConstraints(
            pass: pass,
            selectedNodeId: currentSelection,
            preferredFocusToken: preferredFocusToken
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
                    total + data.col[keyPath: pass.primarySpanKeyPath] + pass.gap
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

        return InsertionContext(
            newTokens: visibleNewTokens,
            tabLocalTokens: tabLocalTokens,
            viewOriginBeforeInsertion: viewOriginBeforeInsertion
        )
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
            insetFrame: snapshot.monitor.workingFrame,
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
        isSettled: Bool
    ) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
        let gaps = LayoutGaps(
            horizontal: snapshot.gap,
            vertical: snapshot.gap
        )

        let area = WorkingAreaContext(
            workingFrame: snapshot.monitor.workingFrame,
            borderSafeFillFrame: snapshot.monitor.borderSafeFillFrame,
            fullscreenLayoutFrame: snapshot.monitor.fullscreenLayoutFrame,
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        return engine.calculateCombinedLayoutUsingPools(
            in: snapshot.workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: snapshot.viewportState,
            workingArea: area,
            animationTime: sampledAnimationTime,
            viewOffsetOverride: controller?.workspaceManager.animationDriver.liveViewOffset(
                in: snapshot.workspaceId,
                semanticOffset: snapshot.viewportState.viewOffset,
                at: sampledAnimationTime ?? CACurrentMediaTime()
            ),
            settledVisibilityOffset: controller?.workspaceManager.animationDriver.settledVisibilityOffset(
                in: snapshot.workspaceId,
                semanticOffset: snapshot.viewportState.viewOffset
            ),
            isSettled: isSettled,
            excludedTokens: snapshot.excludedTokens
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
