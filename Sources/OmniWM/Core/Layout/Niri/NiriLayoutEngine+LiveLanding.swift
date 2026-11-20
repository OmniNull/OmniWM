// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    @discardableResult
    func placeLiveLanding(
        _ landing: LiveColumnMove.LandingSlot?,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let home = liveDraggedColumn(for: move),
              let source = findColumn(containing: window, in: move.workspaceId)
        else { return false }
        let target = landing.flatMap { liveColumn(withId: $0.columnId, in: move.workspaceId) }
        let affected = [source, target ?? home]
        retargetActiveColumn(to: home, context: context, state: &state)
        let columnsBefore = primaryPositions(context: context, state: state)
        let wasDeferred = window.deferredMinimumOrientation
        let placed = slideLiveWindows(in: affected, skipping: window, context: context) {
            clearLiveSpanOverrides(in: affected)
            window.deferredMinimumOrientation = target != nil && target !== home ? context.orientation : nil
            let hintBase = target.map { liveHintBaseSpans(in: $0, without: window, context: context) }
            restoreLiveMateHeight(&move)
            guard relocateLiveWindow(window, to: landing, from: source, move: &move, context: context) else {
                return false
            }
            shareLiveColumn(target, with: window, move: &move, context: context)
            keepLiveColumnWidths(landing: landing != nil, move: &move, context: context)
            if let hintBase, let target {
                applyLiveLandingHint(window, in: target, base: hintBase, context: context)
            }
            return true
        }
        guard placed else {
            window.deferredMinimumOrientation = wasDeferred
            return false
        }
        move.landing = landing
        animateLiveColumnChange(from: columnsBefore, anchoredOn: home, context: context, state: &state)
        return true
    }

    private func shareLiveColumn(
        _ column: NiriContainer?,
        with window: NiriWindow,
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) {
        guard let column, !column.isTabbed else { return }
        let mates = column.windowNodes.filter { $0 !== window }
        guard mates.count == 1, let mate = mates.first,
              mate.secondarySizing(orientation: context.orientation) != .default else { return }
        move.mateHeight = .init(
            windowId: mate.id,
            height: mate.secondarySizing(orientation: context.orientation),
            orientation: context.orientation
        )
        mate.setSecondarySizing(.default, orientation: context.orientation)
    }

    private func keepLiveColumnWidths(landing: Bool, move: inout LiveColumnMove, context: NiriInteractionContext) {
        let workspace = ensureState(for: move.workspaceId)
        guard landing else {
            if let kept = move.keptWidths {
                kept.restore(in: workspace)
                move.keptWidths = nil
            }
            return
        }
        if move.keptWidths == nil {
            move.keptWidths = .init(
                manualColumnCount: context.orientation == .horizontal ? workspace.manualWidthColumnCount : workspace
                    .manualHeightColumnCount,
                orientation: context.orientation
            )
        }
        let count = projectedColumns(in: move.workspaceId).filter { !$0.windows.isEmpty }.count
        if context.orientation == .horizontal { workspace.manualWidthColumnCount = count }
        else { workspace.manualHeightColumnCount = count }
    }

    private func restoreLiveMateHeight(_ move: inout LiveColumnMove) {
        guard let saved = move.mateHeight else { return }
        move.mateHeight = nil
        if let mate = findNode(by: saved.windowId, in: move.workspaceId) as? NiriWindow {
            saved.apply(to: mate)
        }
    }

    private func relocateLiveWindow(
        _ window: NiriWindow,
        to landing: LiveColumnMove.LandingSlot?,
        from source: NiriContainer,
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) -> Bool {
        guard let home = liveDraggedColumn(for: move) else { return false }
        let target = landing.flatMap { liveColumn(withId: $0.columnId, in: move.workspaceId) }
        if move.isWholeColumn, target != nil, target !== home {
            holdLiveTabs(of: home, except: window, move: &move)
        }
        let sourceActive = source !== home && source.isTabbed
            ? projectedActiveWindow(in: source, workspaceId: move.workspaceId)
            : nil
        if let landing, let target {
            guard insertLiveLanding(window, at: landing, in: target, home: home, context: context) else {
                return false
            }
            if target === home {
                move.ownWindowSizing.apply(to: window)
            }
        } else {
            returnLiveWindowHome(window, to: home, move: move, context: context)
            restoreHeldLiveTabs(to: home, around: window, move: &move, context: context)
        }
        if let sourceActive, source !== target, sourceActive.parent === source {
            activateWindow(sourceActive.id, in: move.workspaceId)
            source.setCachedPrimarySpan(0, orientation: context.orientation)
        }
        return true
    }

    private func insertLiveLanding(
        _ window: NiriWindow,
        at landing: LiveColumnMove.LandingSlot,
        in column: NiriContainer,
        home: NiriContainer,
        context: NiriInteractionContext
    ) -> Bool {
        guard let targetWindow = findNode(by: landing.targetWindowId, in: context.workspaceId) as? NiriWindow
        else { return false }
        let homeWidth = home.cachedPrimarySpan(orientation: context.orientation)
        let shownTab = column.isTabbed ? projectedActiveWindow(in: column, workspaceId: context.workspaceId) : nil
        guard stackWindow(
            window,
            beside: targetWindow,
            position: !column.isTabbed && landing.above ? .after : .before,
            removingEmptySource: false,
            in: context.workspaceId
        ) else { return false }
        if context.orientation == .vertical { window.windowWidth = .default }

        if let shownTab, shownTab.parent === column {
            activateWindow(shownTab.id, in: context.workspaceId)
            column.setCachedPrimarySpan(0, orientation: context.orientation)
        } else {
            window.isHiddenInTabbedMode = false
        }
        if projectedWindows(in: home, workspaceId: context.workspaceId).isEmpty, !home.isLiveHomeSpot {
            home.isLiveHomeSpot = true
            if context.orientation == .horizontal { home.width = .fixed(homeWidth) }
            else { home.height = .fixed(homeWidth) }
            home.setCachedPrimarySpan(0, orientation: context.orientation)
        }
        return true
    }

    private func holdLiveTabs(of home: NiriContainer, except window: NiriWindow, move: inout LiveColumnMove) {
        guard move.heldTabs.isEmpty, window.parent === home else { return }
        move.heldTabs = home.windowNodes.filter { $0 !== window }
        liveColumnMove?.heldTabs = move.heldTabs
        home.invalidateAxisSolveInputs()
    }

    private func restoreHeldLiveTabs(
        to home: NiriContainer,
        around window: NiriWindow,
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) {
        guard !move.heldTabs.isEmpty else { return }
        move.heldTabs = []
        liveColumnMove?.heldTabs = []
        activateWindow(window.id, in: move.workspaceId)
        home.invalidateAxisSolveInputs()
        home.setCachedPrimarySpan(0, orientation: context.orientation)
    }

    private func returnLiveWindowHome(
        _ window: NiriWindow,
        to home: NiriContainer,
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) {
        if let source = window.parent as? NiriContainer, source.isTabbed {
            source.setCachedPrimarySpan(0, orientation: context.orientation)
        }
        home.insertChild(window, at: min(move.homeSlotIndex, home.windowNodes.count))
        move.ownWindowSizing.apply(to: window)
        window.isHiddenInTabbedMode = false
        if move.home == .stackSlot {
            activateWindow(window.id, in: move.workspaceId)
            home.setCachedPrimarySpan(0, orientation: context.orientation)
            return
        }
        home.isLiveHomeSpot = false
        restoreLiveSizing(move.ownSizing, to: home)
    }
}
