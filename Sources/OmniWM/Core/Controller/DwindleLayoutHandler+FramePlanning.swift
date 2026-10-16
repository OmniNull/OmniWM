// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func buildOnDemandLayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        let frames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            borderSafeFillScreen: snapshot.monitor.borderSafeFillFrame,
            fullscreenScreen: snapshot.monitor.fullscreenLayoutFrame,
            calculationSettings: calculationSettings(snapshot.settings, from: engine)
        )
        var diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            context: layoutDiffContext(snapshot: snapshot, engine: engine, reassertHidden: true, animationTime: nil)
        )
        let isInteractiveResize = engine.interactiveResize?.workspaceId == snapshot.workspaceId
        if isInteractiveResize, let axManager = controller?.axManager {
            diff.frameChanges = diff.frameChanges.map(axManager.animationFrameChange)
        }

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            isInteractiveResize: isInteractiveResize,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    func buildAnimationPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        session: AnimationSession,
        targetTime: TimeInterval,
        isAnimationTick: Bool
    ) -> WorkspaceLayoutPlan {
        var diff = layoutDiff(
            windows: snapshot.windows,
            frames: session.targetFrames,
            context: layoutDiffContext(
                snapshot: snapshot,
                engine: engine,
                reassertHidden: !isAnimationTick,
                animationTime: targetTime
            )
        )
        if let axManager = controller?.axManager {
            for index in diff.frameChanges.indices {
                diff.frameChanges[index] = isAnimationTick
                    ? axManager.animationFrameChange(diff.frameChanges[index])
                    : axManager.enforcedSizeFrameChange(diff.frameChanges[index])
            }
        }
        diff.tabRailGeometryCommands = dwindleTabRailGeometryCommands(
            engine: engine,
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            targetTime: targetTime
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            isAnimationTick: isAnimationTick,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }
}
