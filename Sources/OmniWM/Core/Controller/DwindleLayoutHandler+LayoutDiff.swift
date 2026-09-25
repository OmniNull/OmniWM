// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func layoutDiffContext(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        reassertHidden: Bool,
        animationTime: TimeInterval?
    ) -> DwindleLayoutDiffContext {
        DwindleLayoutDiffContext(
            engine: engine,
            workspaceId: snapshot.workspaceId,
            preferredHideSide: snapshot.preferredHideSide,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale,
            reassertHidden: reassertHidden,
            pendingParkWindowIds: controller?.axManager.pendingParkWindowIdsAwaitingSkyLightMove ?? [],
            animationTime: animationTime
        )
    }

    func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        context: DwindleLayoutDiffContext
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        let effectiveScale = max(context.scale, 1.0)
        let excludedTokens = context.engine.excludedTokens(in: context.workspaceId)
        for window in windows {
            let token = window.token
            let targetFrame = frames[token]
            let frame = if let animationTime = context.animationTime, targetFrame != nil {
                context.engine.presentedFrame(for: token, in: context.workspaceId, at: animationTime) ?? targetFrame
            } else {
                targetFrame
            }
            if window.isNativeFullscreenSuspended {
                if let originalToken = window.nativeFullscreenOriginalToken {
                    diff.nativeFullscreenSlots[originalToken] = nativeFullscreenSlot(
                        token: token,
                        frame: frame?.roundedToPhysicalPixels(scale: effectiveScale),
                        context: context,
                        excludedTokens: excludedTokens
                    )
                }
                continue
            }
            if excludedTokens.contains(token) {
                continue
            }
            if appendInactiveGroupVisibility(window, windows: windows, frames: frames, context: context, diff: &diff) {
                continue
            }
            let previousOffscreenSide = window.hiddenState?.offscreenSide

            if previousOffscreenSide != nil, frame != nil {
                diff.visibilityChanges.append(.show(token))
            }

            if context.canRestoreHiddenWorkspaceWindows,
               let hiddenState = window.hiddenState,
               hiddenState.workspaceInactive
            {
                diff.restoreChanges.append(
                    .init(token: token, hiddenState: hiddenState)
                )
            }
            guard let frame = frame?.roundedToPhysicalPixels(scale: effectiveScale) else { continue }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: token,
                    frame: frame,
                    forceApply: context.engine.isWindowFullscreen(token, in: context.workspaceId)
                )
            )
        }
        return diff
    }

    private func nativeFullscreenSlot(
        token: WindowToken,
        frame: CGRect?,
        context: DwindleLayoutDiffContext,
        excludedTokens: Set<WindowToken>
    ) -> NativeFullscreenSlotProjection {
        let validFrame = frame.map { !$0.isNull && !$0.isInfinite && $0.width > 1 && $0.height > 1 } == true
        return NativeFullscreenSlotProjection(
            currentToken: token,
            frame: validFrame ? frame ?? .zero : .zero,
            visible: context.canRestoreHiddenWorkspaceWindows
                && !excludedTokens.contains(token)
                && context.engine.activeTileMember(containing: token, in: context.workspaceId) == token
                && validFrame
        )
    }

    private func appendInactiveGroupVisibility(
        _ window: LayoutWindowSnapshot,
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        context: DwindleLayoutDiffContext,
        diff: inout WorkspaceLayoutDiff
    ) -> Bool {
        let token = window.token
        guard context.engine.isInactiveGroupMember(token, in: context.workspaceId) else { return false }
        let previousOffscreenSide = window.hiddenState?.offscreenSide
        let side = previousOffscreenSide ?? context.preferredHideSide
        if previousOffscreenSide == nil,
           let revealToken = context.engine.activeTileMember(containing: token, in: context.workspaceId),
           let revealWindow = windows.first(where: { $0.token == revealToken }),
           revealWindow.hiddenState?.offscreenSide != nil,
           frames[revealToken] != nil
        {
            diff.deferredHides.append(
                LayoutDeferredHide(
                    token: token,
                    side: side,
                    revealToken: revealToken
                )
            )
            return true
        }
        if previousOffscreenSide != side || context.reassertHidden
            || context.pendingParkWindowIds.contains(token.windowId)
        {
            diff.visibilityChanges.append(.hide(token, side: side))
        }
        return true
    }
}
