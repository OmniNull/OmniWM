// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func syncWindowsAndInstallConstraints(
        pass: NiriLayoutPass,
        selectedNodeId: NodeId?,
        preferredFocusToken: WindowToken?
    ) {
        let containerSizingStates = containerSizingStatesForMissingWindows(pass: pass)
        _ = pass.engine.syncWindows(
            pass.windowTokens,
            in: pass.wsId,
            selectedNodeId: selectedNodeId,
            focusedToken: preferredFocusToken,
            containerSizingStates: containerSizingStates
        )
        for window in pass.windows {
            pass.engine.updateWindowConstraints(
                for: window.token,
                constraints: window.constraints,
                packingHints: window.packingHints,
                in: pass.wsId,
                motion: controller?.motionPolicy.snapshot() ?? .enabled
            )
        }
    }

    private func containerSizingStatesForMissingWindows(
        pass: NiriLayoutPass
    ) -> [WindowToken: NiriContainerSizingState]? {
        guard let controller else { return nil }

        var states: [WindowToken: NiriContainerSizingState]?
        for token in pass.windowTokens where pass.engine.findNode(for: token, in: pass.wsId) == nil {
            let state: NiriContainerSizingState?
            if let detached = controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState {
                state = detached
            } else if let initial = controller.workspaceManager.admissionHints(for: token)?
                .initialNiriContainerPrimarySpan
            {
                state = pass.engine.initialContainerSizingState(for: CGFloat(initial))
            } else {
                state = nil
            }

            guard let state else { continue }
            if states == nil {
                states = [:]
            }
            states?[token] = state
        }
        return states
    }

    func resolveSelection(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot
    ) -> (viewportNeedsRecalc: Bool, rememberedFocusToken: WindowToken?) {
        selectSurvivingWindow(pass: pass, state: &state, removal: removal, snapshot: snapshot)

        let usesSingleWindowFit = pass.engine.singleWindowLayoutContext(
            in: pass.wsId,
            excluding: snapshot.excludedTokens
        ) != nil
        if usesSingleWindowFit {
            resetViewportForSingleWindowFit(state: &state)
        }

        let viewportNeedsRecalc = reconcileSelectionVisibility(
            pass: pass, state: &state, removal: removal, snapshot: snapshot, usesSingleWindowFit: usesSingleWindowFit
        )

        let rememberedFocusToken: WindowToken?
        if let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId, in: pass.wsId) as? NiriWindow,
           !snapshot.excludedTokens.contains(selectedNode.token)
        {
            rememberedFocusToken = selectedNode.token
        } else {
            rememberedFocusToken = nil
        }

        return (viewportNeedsRecalc, rememberedFocusToken)
    }

    func handleNewWindowArrival(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        insertion: InsertionContext,
        existingHandleIds: Set<WindowToken>,
        snapshot: NiriWorkspaceSnapshot
    ) -> ArrivalContext {
        let wasEmpty = existingHandleIds.subtracting(snapshot.excludedTokens).isEmpty
        let newTokens = insertion.newTokens.filter { !snapshot.quietArrivalTokens.contains($0) }
        let nativeArrival = nativeArrivalToken(in: newTokens)

        var arrival = ArrivalContext(
            activateWindowToken: nil, rememberedFocusToken: nil,
            hasNewWindowArrival: false, shouldStartScrollForNewWindow: false
        )
        if snapshot.hasCompletedInitialRefresh,
           let newToken = nativeArrival ?? newTokens.last,
           let newNode = pass.engine.findNode(for: newToken, in: pass.wsId),
           snapshot.isActiveWorkspace
        {
            let isTabLocalArrival = insertion.tabLocalTokens.contains(newToken)
            state.selectedNodeId = newNode.id

            if wasEmpty {
                activateFirstArrival(newNode, pass: pass, state: &state, excludedTokens: snapshot.excludedTokens)
            } else if isTabLocalArrival {
                activateTabLocalWindow(
                    newNode,
                    pass: pass,
                    state: &state,
                    viewOrigin: insertion.viewOriginBeforeInsertion
                )
            } else if let newCol = pass.engine.column(of: newNode),
                      let newColIdx = pass.engine.columnIndex(of: newCol, in: pass.wsId)
            {
                resolvePrimaryContainerSpansIfNeeded(pass: pass)

                let shouldRestorePrevOffset = newColIdx == state.activeColumnIndex + 1
                let offsetBeforeActivation = state.viewOffset

                pass.engine.ensureSelectionVisible(
                    node: newNode,
                    context: pass.interactionContext,
                    state: &state,
                    fromContainerIndex: state.activeColumnIndex
                )

                if shouldRestorePrevOffset {
                    state.activatePrevColumnOnRemoval = offsetBeforeActivation
                }
            }
            arrival.rememberedFocusToken = newToken
            pass.engine.updateFocusTimestamp(for: newNode.id, in: pass.wsId)
            arrival.activateWindowToken = newToken
            arrival.hasNewWindowArrival = true
            arrival.shouldStartScrollForNewWindow = !isTabLocalArrival
        }

        animateNewWindowArrivals(pass: pass, state: state, insertion: insertion, snapshot: snapshot)

        return arrival
    }

    private func activateTabLocalWindow(
        _ node: NiriNode,
        pass: NiriLayoutPass,
        state: inout ViewportState,
        viewOrigin: CGFloat?
    ) {
        guard let column = pass.engine.column(of: node),
              let columnIndex = pass.engine.columnIndex(of: column, in: pass.wsId)
        else { return }

        if let window = node as? NiriWindow,
           let tileIndex = column.windowNodes.firstIndex(where: { $0 === window })
        {
            column.setActiveTileIdx(tileIndex)
            pass.engine.updateTabbedColumnVisibility(column: column)
        }

        state.activeColumnIndex = columnIndex
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil

        if let viewOrigin {
            restoreViewOrigin(viewOrigin, pass: pass, state: &state)
        } else {
            state.jumpOffset(to: state.viewOffset)
        }
    }

    func resolvePrimaryContainerSpansIfNeeded(pass: NiriLayoutPass) {
        pass.engine.resolvePrimaryContainerSpans(
            in: pass.wsId,
            workingFrame: pass.insetFrame,
            gaps: pass.gap,
            orientation: pass.orientation,
            motion: pass.motion
        )
    }

    func currentViewOrigin(pass: NiriLayoutPass, state: ViewportState) -> CGFloat? {
        let columns = pass.engine.columns(in: pass.wsId)
        guard !columns.isEmpty else { return nil }
        resolvePrimaryContainerSpansIfNeeded(pass: pass)
        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        return state.containerPosition(
            at: activeIndex,
            containers: columns,
            gap: pass.gap,
            sizeKeyPath: pass.primarySpanKeyPath
        ) + state.viewOffset
    }

    private func restoreViewOrigin(_ viewOrigin: CGFloat, pass: NiriLayoutPass, state: inout ViewportState) {
        let columns = pass.engine.columns(in: pass.wsId)
        guard !columns.isEmpty else { return }
        resolvePrimaryContainerSpansIfNeeded(pass: pass)
        let activeColumnIndex = state.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        state.activeColumnIndex = activeColumnIndex
        let activeContainerPosition = state.containerPosition(
            at: activeColumnIndex,
            containers: columns,
            gap: pass.gap,
            sizeKeyPath: pass.primarySpanKeyPath
        )
        state.jumpOffset(to: viewOrigin - activeContainerPosition)
    }

    func resetViewportForSingleWindowFit(state: inout ViewportState) {
        state.activeColumnIndex = 0
        state.jumpOffset(to: 0)
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil
    }

    private func selectSurvivingWindow(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot
    ) {
        state.displayRefreshRate = snapshot.displayRefreshRate
        let visibleWindowTokens = pass.windowTokens.filter { !snapshot.excludedTokens.contains($0) }

        if let finalSelectionId = removal.removalResult.finalSelectionId {
            state.selectedNodeId = finalSelectionId
        } else if let selectedId = state.selectedNodeId,
                  pass.engine.findNode(by: selectedId, in: pass.wsId) == nil
        {
            state.selectedNodeId = pass.engine.validateSelection(selectedId, in: pass.wsId)
        }

        if let selectedNodeId = state.selectedNodeId,
           let selectedWindow = pass.engine.findNode(by: selectedNodeId, in: pass.wsId) as? NiriWindow,
           snapshot.excludedTokens.contains(selectedWindow.token)
        {
            state.selectedNodeId = nil
        }

        if state.selectedNodeId == nil {
            let fallbackToken = snapshot.preferredFocusToken.flatMap {
                visibleWindowTokens.contains($0) ? $0 : nil
            } ?? visibleWindowTokens.first
            if let firstToken = fallbackToken,
               let firstNode = pass.engine.findNode(for: firstToken, in: pass.wsId)
            {
                state.selectedNodeId = firstNode.id
            }
        }
    }

    private func activateFirstArrival(
        _ newNode: NiriWindow,
        pass: NiriLayoutPass,
        state: inout ViewportState,
        excludedTokens: Set<WindowToken>
    ) {
        if pass.engine.singleWindowLayoutContext(
            in: pass.wsId,
            excluding: excludedTokens
        ) != nil {
            resetViewportForSingleWindowFit(state: &state)
            if let column = pass.engine.column(of: newNode),
               let durableIndex = pass.engine.columnIndex(of: column, in: pass.wsId)
            {
                state.activeColumnIndex = durableIndex
            }
        } else {
            pass.engine.ensureSelectionVisible(
                node: newNode,
                context: .init(
                    workspaceId: pass.wsId,
                    motion: .disabled,
                    workingFrame: pass.insetFrame,
                    gaps: pass.gap,
                    orientation: pass.orientation
                ),
                state: &state
            )
        }
    }

    private func animateNewWindowArrivals(
        pass: NiriLayoutPass,
        state: ViewportState,
        insertion: InsertionContext,
        snapshot: NiriWorkspaceSnapshot
    ) {
        let animatedNewTokens = insertion.newTokens.filter { !insertion.tabLocalTokens.contains($0) }
        if snapshot.hasCompletedInitialRefresh,
           snapshot.isActiveWorkspace,
           !animatedNewTokens.isEmpty
        {
            for token in animatedNewTokens {
                guard let window = pass.engine.findNode(for: token, in: pass.wsId),
                      !window.isHiddenInTabbedMode else { continue }

                window.animateMoveFrom(
                    displacement: CGPoint(x: 0, y: -16),
                    clock: pass.engine.animationClock,
                    config: pass.motion.scaled(pass.engine.windowMovementAnimationConfig),
                    displayRefreshRate: state.displayRefreshRate,
                    animated: pass.motion.animationsEnabled
                )
            }
        }
    }

    private func reconcileSelectionVisibility(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot,
        usesSingleWindowFit: Bool
    ) -> Bool {
        let offsetBefore = state.viewOffset
        let rebaseDeltaBefore = state.offsetTransition.rebaseDelta
        var viewportNeedsRecalc = removal.removalResult.viewportNeedsRecalc

        let isGestureOrAnimation = controller?.workspaceManager.animationDriver.hasMotion(in: pass.wsId) == true

        resolvePrimaryContainerSpansIfNeeded(pass: pass)

        if !usesSingleWindowFit,
           !isGestureOrAnimation,
           snapshot.isActiveWorkspace,
           let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId, in: pass.wsId),
           !removal.removalResult.visibilityWasCorrected,
           removal.removalResult.removedTokens.isEmpty || removal.removalResult.fromIndexForVisibility != nil
        {
            if snapshot.excludedTokens.isEmpty {
                pass.engine.ensureSelectionVisible(
                    node: selectedNode,
                    context: pass.interactionContext,
                    state: &state,
                    fromContainerIndex: removal.removalResult.fromIndexForVisibility
                )
            } else {
                pass.engine.ensureProjectedSelectionVisible(
                    node: selectedNode,
                    context: pass.interactionContext,
                    state: &state,
                    animationConfig: nil,
                    fromContainerIndex: removal.removalResult.fromIndexForVisibility
                )
            }
            let liveOffsetDelta = state.hasPendingOffsetAnimation
                ? state.offsetTransition.rebaseDelta - rebaseDeltaBefore
                : state.viewOffset - offsetBefore
            if abs(liveOffsetDelta) > 1 {
                viewportNeedsRecalc = true
            }
        }

        if !usesSingleWindowFit,
           snapshot.excludedTokens.isEmpty,
           removal.removalResult.removedColumnIndicesBefore.isEmpty,
           pass.engine.correctViewportAfterColumnRemoval(
               context: pass.interactionContext,
               state: &state,
               preservesCenteredView: !removal.removedColumn
           )
        {
            viewportNeedsRecalc = true
        }

        return viewportNeedsRecalc
    }

    private func nativeArrivalToken(in newTokens: [WindowToken]) -> WindowToken? {
        guard let controller else { return nil }
        guard controller.workspaceManager.pendingFocusedToken == nil,
              controller.intentLedger.activeManagedRequest == nil,
              let token = controller.workspaceManager.nativeManagedFocusToken,
              newTokens.contains(token)
        else { return nil }
        return token
    }
}
