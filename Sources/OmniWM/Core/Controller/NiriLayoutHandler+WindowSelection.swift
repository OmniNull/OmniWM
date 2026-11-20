// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
            containerSizingStates: containerSizingStates,
            unpositionedPlacements: unpositionedPlacements(pass: pass)
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
            if let kept = keptPrimarySpanSizingState(for: token, pass: pass) {
                state = kept
            } else if let detached = controller.workspaceManager.restoreIntent(for: token)?
                .detachedNiriContainerSizingState
            {
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

    private func keptPrimarySpanSizingState(
        for token: WindowToken,
        pass: NiriLayoutPass
    ) -> NiriContainerSizingState? {
        guard let controller else { return nil }
        return keptPrimarySpanSizingState(
            for: token, engine: pass.engine, in: pass.wsId,
            geometry: NiriSizingGeometry(workingFrame: pass.insetFrame, gaps: pass.gap, orientation: pass.orientation),
            controller: controller
        )
    }

    func keptPrimarySpanSizingState(
        for token: WindowToken,
        engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        geometry: NiriSizingGeometry,
        controller: WMController
    ) -> NiriContainerSizingState? {
        guard controller.settings.niri.readsObservedWindowWidths else { return nil }
        let opening = engine.takeOpeningWindow(token)
        guard engine.keepsEnteringWindowWidth(
                  opening: opening,
                  hasRuleWidth: controller.workspaceManager.admissionHints(for: token)?
                      .initialNiriContainerPrimarySpan != nil,
                  keepsExistingWidth: controller.settings.niri.keepExistingWindowWidth,
                  in: workspaceId
              ),
              let entry = controller.workspaceManager.entry(for: token),
              let frame = controller.axEventHandler.observedFrame(for: entry)
        else { return nil }
        return engine.keptContainerSizingState(
            primarySpan: geometry.orientation == .horizontal ? frame.width : frame.height,
            in: workspaceId,
            workingSpan: geometry.orientation == .horizontal ? geometry.workingFrame.width : geometry.workingFrame
                .height,
            gaps: geometry.gaps,
            orientation: geometry.orientation
        )
    }

    private func unpositionedPlacements(
        pass: NiriLayoutPass
    ) -> [WindowToken: PersistedNiriPlacement]? {
        guard let controller else { return nil }

        var placements: [WindowToken: PersistedNiriPlacement]?
        for token in pass.windowTokens where pass.engine.findNode(for: token, in: pass.wsId) == nil {
            guard let placement = controller.workspaceManager.restoreIntent(for: token)?.niriPlacement,
                  !placement.hasColumnPosition
            else { continue }
            if placements == nil {
                placements = [:]
            }
            placements?[token] = placement
        }
        return placements
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
        if usesSingleWindowFit,
           !state.preservesGestureOffset || removal.removedColumn
           || pass.engine.effectiveSettings(in: pass.wsId).edgeOverscroll == .disabled
        {
            if state.viewOffset != 0 || state.activeColumnIndex != 0 {
                MouseTrace.record("niri single-window viewport reset ws=\(pass.wsId)")
            }
            resetViewportForSingleWindowFit(state: &state)
        }

        let viewportNeedsRecalc = controller?.mouseEventHandler.holdsSelectionScroll(in: pass.wsId) == true
            ? removal.removalResult.viewportNeedsRecalc
            : reconcileSelectionVisibility(
                pass: pass, state: &state, removal: removal, snapshot: snapshot,
                usesSingleWindowFit: usesSingleWindowFit
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

    func resetViewportForSingleWindowFit(state: inout ViewportState) {
        state.preservesGestureOffset = false
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
            let neighbour = neighbourAfterExclusion(
                of: selectedWindow,
                pass: pass,
                excludedTokens: snapshot.excludedTokens
            )
            state.selectedNodeId = neighbour?.id
            if let neighbour {
                NiriLayoutTrace.record(.viewport, workspaceId: pass.wsId, {
                    "neighbour-after-exclusion from=\(selectedWindow.token.windowId) to=\(neighbour.token.windowId)"
                }())
            }
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

    private func neighbourAfterExclusion(
        of window: NiriWindow,
        pass: NiriLayoutPass,
        excludedTokens: Set<WindowToken>
    ) -> NiriWindow? {
        guard let column = pass.engine.column(of: window) else { return nil }
        let isShown: (NiriWindow) -> Bool = { !excludedTokens.contains($0.token) }
        let stack = column.windowNodes
        if let index = stack.firstIndex(where: { $0 === window }),
           let mate = stack[(index + 1)...].first(where: isShown) ?? stack[..<index].reversed().first(where: isShown)
        {
            return mate
        }
        let columns = pass.engine.columns(in: pass.wsId)
        guard let columnIndex = columns.firstIndex(where: { $0 === column }) else { return nil }
        let shownWindow: (NiriContainer) -> NiriWindow? = { $0.shownWindow(excluding: excludedTokens) }
        return columns[(columnIndex + 1)...].lazy.compactMap(shownWindow).first
            ?? columns[..<columnIndex].reversed().lazy.compactMap(shownWindow).first
    }

    private func reconcileSelectionVisibility(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot,
        usesSingleWindowFit: Bool
    ) -> Bool {
        var viewportNeedsRecalc = removal.removalResult.viewportNeedsRecalc

        let controller = controller
        let isGestureOrAnimation = controller?.workspaceManager.animationDriver.hasMotion(in: pass.wsId) == true

        resolvePrimaryContainerSpansIfNeeded(pass: pass)

        let preservesGesture = state.preservesGestureOffset
            && pass.engine.effectiveSettings(in: pass.wsId).edgeOverscroll != .disabled
            && !removal.removedColumn && removal.removalResult.removedTokens.isEmpty
        let keepsClickedSelectionOffscreen = state.clickFocusedNodeId != nil
            && state.clickFocusedNodeId == state.selectedNodeId
            && controller?.settings.focus.clickFocusWithoutScrolling == true
        if !usesSingleWindowFit,
           !preservesGesture,
           !isGestureOrAnimation,
           !keepsClickedSelectionOffscreen,
           snapshot.isActiveWorkspace,
           let selectedId = state.selectedNodeId,
           let selectedNode = pass.engine.findNode(by: selectedId, in: pass.wsId),
           !removal.removalResult.visibilityWasCorrected,
           removal.removalResult.removedTokens.isEmpty || removal.removalResult.fromIndexForVisibility != nil,
           scrollSelectionIntoView(
               selectedNode,
               from: removal.removalResult.fromIndexForVisibility,
               projected: !snapshot.excludedTokens.isEmpty,
               pass: pass,
               state: &state
           )
        {
            viewportNeedsRecalc = true
        }

        let correctionNeedsRecalc = correctViewportAfterSelection(
            pass: pass, state: &state, removal: removal, snapshot: snapshot,
            usesSingleWindowFit: usesSingleWindowFit
        )
        return viewportNeedsRecalc || correctionNeedsRecalc
    }

    private func scrollSelectionIntoView(
        _ selectedNode: NiriNode,
        from fromContainerIndex: Int?,
        projected: Bool,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) -> Bool {
        let offsetBefore = state.viewOffset
        let rebaseDeltaBefore = state.offsetTransition.rebaseDelta
        if projected {
            pass.engine.ensureProjectedSelectionVisible(
                node: selectedNode,
                context: pass.interactionContext,
                state: &state,
                animationConfig: nil,
                fromContainerIndex: fromContainerIndex
            )
        } else {
            pass.engine.ensureSelectionVisible(
                node: selectedNode,
                context: pass.interactionContext,
                state: &state,
                fromContainerIndex: fromContainerIndex
            )
        }
        let liveOffsetDelta = state.hasPendingOffsetAnimation
            ? state.offsetTransition.rebaseDelta - rebaseDeltaBefore
            : state.viewOffset - offsetBefore
        guard abs(liveOffsetDelta) > 1 else { return false }
        MouseTrace.record(
            "niri selection scroll ws=\(pass.wsId) delta=\(Int(liveOffsetDelta)) active=\(state.activeColumnIndex)"
        )
        return true
    }

    private func correctViewportAfterSelection(
        pass: NiriLayoutPass,
        state: inout ViewportState,
        removal: RemovalContext,
        snapshot: NiriWorkspaceSnapshot,
        usesSingleWindowFit: Bool
    ) -> Bool {
        var viewportNeedsRecalc = false
        if usesSingleWindowFit,
           pass.engine.correctSingleWindowGestureOffset(
               context: pass.interactionContext,
               state: &state,
               workingArea: WorkingAreaContext(
                   workingFrame: pass.insetFrame,
                   singleWindowFrame: snapshot.monitor.workingFrame,
                   borderSafeFillFrame: snapshot.monitor.borderSafeFillFrame,
                   fullscreenLayoutFrame: snapshot.fullscreenLayoutFrame,
                   viewFrame: snapshot.monitor.frame,
                   scale: snapshot.monitor.scale
               )
           )
        {
            viewportNeedsRecalc = true
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
}
