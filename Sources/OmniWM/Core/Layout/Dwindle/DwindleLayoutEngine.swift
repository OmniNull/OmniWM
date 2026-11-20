// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

final class DwindleLayoutEngine {
    struct LayoutCalculation {
        let tilingArea: CGRect
        let fullscreenArea: CGRect
        let excludedTokens: Set<WindowToken>
        let settings: DwindleSettings

        func frame(for member: DwindleTileMember, in rect: CGRect) -> CGRect {
            if member.isFullscreen {
                return fullscreenArea
            }
            return DwindleGapCalculator.applyGaps(
                nodeRect: rect,
                tilingArea: tilingArea,
                settings: settings
            )
        }
    }

    private var states: [WorkspaceDescriptor.ID: DwindleWorkspaceState] = [:]
    private var windowConstraints: [WindowToken: WindowSizeConstraints] = [:]

    var settings: DwindleSettings = DwindleSettings()
    var tabRailWidth: CGFloat = 12
    var animationClock: AnimationClock?
    var isMutationSanctioned = true

    var interactiveResize: DwindleInteractiveResize?
    var interactiveMove: DwindleInteractiveMove?
    var liveMove: DwindleLiveMove?

    func assertSanctionedMutation(_ operation: StaticString = #function) {
        assert(
            isMutationSanctioned,
            "\(operation) mutated the Dwindle layout tree outside a sanctioned WorldStore scope"
        )
    }

    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        assertSanctionedMutation()
        windowConstraints[token] = constraints.normalized()
    }

    func constraints(for token: WindowToken) -> WindowSizeConstraints {
        windowConstraints[token] ?? .unconstrained
    }

    var windowMovementAnimationConfig: CubicConfig = .hyprlandDwindle

    func existingState(for workspaceId: WorkspaceDescriptor.ID) -> DwindleWorkspaceState? {
        states[workspaceId]
    }

    func root(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        states[workspaceId]?.root
    }

    func ensureState(for workspaceId: WorkspaceDescriptor.ID) -> DwindleWorkspaceState {
        if let existing = states[workspaceId] {
            return existing
        }
        let state = DwindleWorkspaceState()
        states[workspaceId] = state
        return state
    }

    func removeLayout(for workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        if liveMove?.workspaceId == workspaceId {
            liveMove = nil
        }
        guard let state = states.removeValue(forKey: workspaceId) else { return }
        if interactiveResize?.workspaceId == workspaceId {
            clearInteractiveResize()
        }
        if interactiveMove?.workspaceId == workspaceId {
            interactiveMoveCancel()
        }
        for token in state.leafByToken.keys {
            releaseConstraintsIfUntracked(token)
        }
    }

    func releaseConstraintsIfUntracked(_ token: WindowToken) {
        guard states.values.allSatisfy({ $0.leafByToken[token] == nil }) else { return }
        windowConstraints.removeValue(forKey: token)
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard oldToken != newToken,
              let state = states[workspaceId],
              state.leafByToken[newToken] == nil,
              let leaf = state.leafByToken[oldToken],
              let tile = leaf.tile
        else {
            return false
        }

        guard tile.rekey(from: oldToken, to: newToken) else { return false }
        state.leafByToken.removeValue(forKey: oldToken)
        state.leafByToken[newToken] = leaf
        if let seed = state.pendingMovementFrameSeeds.removeValue(forKey: oldToken) {
            state.pendingMovementFrameSeeds[newToken] = seed
        }
        if let constraints = windowConstraints[oldToken] {
            windowConstraints[newToken] = constraints
        }
        if state.excludedTokens.remove(oldToken) != nil {
            state.excludedTokens.insert(newToken)
        }
        releaseConstraintsIfUntracked(oldToken)
        return true
    }

    @discardableResult
    func summonWindowRight(
        _ token: WindowToken,
        beside anchorToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard token != anchorToken,
              let sourceNode = findNode(for: token, in: workspaceId),
              let anchorNode = findNode(for: anchorToken, in: workspaceId),
              sourceNode.isLeaf,
              anchorNode.isLeaf
        else {
            return false
        }

        let preservedConstraints = windowConstraints[token]
        let preservedFullscreen = isWindowFullscreen(token, in: workspaceId)

        removeWindow(token: token, from: workspaceId)

        guard let updatedAnchorNode = findNode(for: anchorToken, in: workspaceId) else {
            return false
        }

        setSelectedNode(updatedAnchorNode, in: workspaceId)
        setPreselection(.right, in: workspaceId)

        let reinsertedLeaf = addWindow(
            token: token,
            to: workspaceId,
            activeWindowFrame: updatedAnchorNode.cachedFrame
        )

        if let preservedConstraints {
            updateWindowConstraints(for: token, constraints: preservedConstraints)
        }
        if preservedFullscreen {
            reinsertedLeaf.tile?.setFullscreen(true, for: token)
        }

        return true
    }
}
