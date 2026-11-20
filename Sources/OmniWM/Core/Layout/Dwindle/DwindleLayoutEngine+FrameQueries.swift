// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func hasCurrentFrames(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let state = existingState(for: workspaceId) else { return false }
        for leaf in state.leafByToken.values {
            if leaf.cachedContentFrame != nil || leaf.cachedFrame != nil,
               visibleMember(in: leaf.tile, excluding: state.excludedTokens) != nil
            {
                return true
            }
        }
        return false
    }

    func currentFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: CGRect] {
        guard let state = existingState(for: workspaceId) else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        collectCurrentFrames(
            node: state.root,
            excludedTokens: state.excludedTokens,
            into: &frames
        )
        return frames
    }

    private func collectCurrentFrames(
        node: DwindleNode,
        excludedTokens: Set<WindowToken>,
        into frames: inout [WindowToken: CGRect]
    ) {
        if let tile = node.tile,
           let member = visibleMember(in: tile, excluding: excludedTokens),
           let frame = node.cachedContentFrame ?? node.cachedFrame
        {
            frames[member.token] = frame
        }
        for child in node.children {
            collectCurrentFrames(node: child, excludedTokens: excludedTokens, into: &frames)
        }
    }

    func presentedFrames(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> [WindowToken: CGRect] {
        guard let state = existingState(for: workspaceId) else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        collectPresentedFrames(
            node: state.root,
            at: time,
            excludedTokens: state.excludedTokens,
            into: &frames
        )
        return frames
    }

    func presentedFrame(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> CGRect? {
        existingState(for: workspaceId)?.leafByToken[token]?.presentedFrame(at: time)
    }

    private func collectPresentedFrames(
        node: DwindleNode,
        at time: TimeInterval,
        excludedTokens: Set<WindowToken>,
        into frames: inout [WindowToken: CGRect]
    ) {
        if let tile = node.tile,
           let member = visibleMember(in: tile, excluding: excludedTokens),
           let frame = node.presentedFrame(at: time)
        {
            frames[member.token] = frame
        }
        for child in node.children {
            collectPresentedFrames(
                node: child,
                at: time,
                excludedTokens: excludedTokens,
                into: &frames
            )
        }
    }

    func hitTestFocusableWindow(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> WindowToken? {
        guard let state = existingState(for: workspaceId) else { return nil }

        var firstVisibleMatch: WindowToken?
        return hitTestFocusableWindow(
            point: point,
            at: time,
            in: state.root,
            excludedTokens: state.excludedTokens,
            firstVisibleMatch: &firstVisibleMatch
        ) ?? firstVisibleMatch
    }

    private func hitTestFocusableWindow(
        point: CGPoint,
        at time: TimeInterval,
        in node: DwindleNode,
        excludedTokens: Set<WindowToken>,
        firstVisibleMatch: inout WindowToken?
    ) -> WindowToken? {
        if let tile = node.tile,
           let member = visibleMember(in: tile, excluding: excludedTokens),
           let frame = presentedFrame(for: node, at: time),
           frame.contains(point)
        {
            if member.isFullscreen {
                return member.token
            }

            if firstVisibleMatch == nil {
                firstVisibleMatch = member.token
            }
            return nil
        }

        for child in node.children {
            if let fullscreenMatch = hitTestFocusableWindow(
                point: point,
                at: time,
                in: child,
                excludedTokens: excludedTokens,
                firstVisibleMatch: &firstVisibleMatch
            ) {
                return fullscreenMatch
            }
        }

        return nil
    }

    func presentedFrame(for node: DwindleNode, at time: TimeInterval) -> CGRect? {
        node.presentedFrame(at: time)
    }
}
