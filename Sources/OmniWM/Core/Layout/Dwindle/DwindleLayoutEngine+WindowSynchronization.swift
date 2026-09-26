// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    private func tokensToAdd(_ tokens: [WindowToken], excluding existingWindows: Set<WindowToken>) -> [WindowToken] {
        var queuedAdditions: Set<WindowToken> = []
        var toAdd: [WindowToken] = []
        toAdd.reserveCapacity(tokens.count)
        for token in tokens where !existingWindows.contains(token) {
            guard queuedAdditions.insert(token).inserted else { continue }
            toAdd.append(token)
        }

        return toAdd
    }

    private func insertionFrame(focusedToken: WindowToken?, in workspaceId: WorkspaceDescriptor.ID) -> CGRect? {
        var activeFrame: CGRect?
        if let focusedToken, let node = findNode(for: focusedToken, in: workspaceId) {
            activeFrame = node.cachedFrame
        }
        if activeFrame == nil {
            activeFrame = selectedNode(in: workspaceId)?.cachedFrame
                ?? existingState(for: workspaceId)?.root.descendToFirstLeaf().cachedFrame
        }

        return activeFrame
    }

    func syncWindows(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken?,
        bootstrapScreen: CGRect? = nil,
        bootstrapBorderSafeFillScreen: CGRect? = nil,
        bootstrapFullscreenScreen: CGRect? = nil,
        stackingTokens: Set<WindowToken> = []
    ) -> Set<WindowToken> {
        assertSanctionedMutation()
        let existingWindows: Set<WindowToken> = existingState(for: workspaceId).map { Set($0.leafByToken.keys) } ?? []
        let newWindows = Set(tokens)

        let toRemove = existingWindows.subtracting(newWindows)
        let toAdd = tokensToAdd(tokens, excluding: existingWindows)

        for token in toRemove {
            removeWindow(token: token, from: workspaceId)
        }

        if let state = existingState(for: workspaceId) {
            reconcileProjectedSelection(preferredToken: focusedToken, in: state)
        }

        let shouldBootstrapIncrementally = bootstrapScreen != nil
            && !tokens.isEmpty
            && currentFrames(in: workspaceId).isEmpty
        if shouldBootstrapIncrementally,
           let bootstrapScreen,
           windowCount(in: workspaceId) > 0
        {
            _ = calculateLayout(
                for: workspaceId,
                screen: bootstrapScreen,
                borderSafeFillScreen: bootstrapBorderSafeFillScreen ?? bootstrapFullscreenScreen ?? bootstrapScreen,
                fullscreenScreen: bootstrapFullscreenScreen ?? bootstrapScreen
            )
        }

        var activeFrame = insertionFrame(focusedToken: focusedToken, in: workspaceId)

        for token in toAdd {
            let newNode = addWindow(
                token: token,
                to: workspaceId,
                activeWindowFrame: activeFrame,
                joinsSelectedTile: stackingTokens.contains(token)
            )
            if shouldBootstrapIncrementally, let bootstrapScreen {
                let frames = calculateLayout(
                    for: workspaceId,
                    screen: bootstrapScreen,
                    borderSafeFillScreen: bootstrapBorderSafeFillScreen ?? bootstrapFullscreenScreen ?? bootstrapScreen,
                    fullscreenScreen: bootstrapFullscreenScreen ?? bootstrapScreen
                )
                activeFrame = frames[token]
            } else {
                activeFrame = newNode.cachedFrame
            }
        }

        if let state = existingState(for: workspaceId) {
            reconcileProjectedSelection(preferredToken: focusedToken, in: state)
        }

        return toRemove
    }
}
