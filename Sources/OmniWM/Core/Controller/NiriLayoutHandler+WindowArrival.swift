// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutHandler {
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
            if pass.engine.isLiveColumnMoveActive(in: pass.wsId) {
                MouseTrace.record("niri arrival during live drag ws=\(pass.wsId) token=\(TraceFormat.token(newToken))")
            }
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
