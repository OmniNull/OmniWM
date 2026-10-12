// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func makeWorkspaceSnapshot(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        resolveConstraints: Bool,
        isActiveWorkspace: Bool
    ) -> DwindleWorkspaceSnapshot? {
        guard let controller else { return nil }

        guard let refreshInput = controller.layoutRefreshController.buildRefreshInput(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: resolveConstraints,
            isActiveWorkspace: isActiveWorkspace
        ) else {
            return nil
        }
        return DwindleWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            excludedTokens: refreshInput.excludedTokens,
            plannedSeq: refreshInput.plannedSeq,
            preferredFocusToken: controller.workspaceManager.rememberedTiledFocusToken(in: wsId),
            preferredHideSide: controller.layoutRefreshController.preferredHideSide(for: monitor),
            settings: controller.resolvedDwindleSettings(for: monitor, scale: refreshInput.monitor.scale),
            isActiveWorkspace: refreshInput.isActiveWorkspace
        )
    }

    func buildRelayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)
        engine.setExcludedTokens(
            snapshot.excludedTokens,
            authoritativeTokens: Set(snapshot.windows.lazy.map(\.token)),
            in: snapshot.workspaceId
        )

        let now = controller?.animationClock.now() ?? CACurrentMediaTime()
        let transition = prepareRelayoutTransition(snapshot: snapshot, engine: engine, now: now)
        let newFrames = transition.newFrames

        let rememberedFocusToken = engine.projectedActiveToken(in: snapshot.workspaceId)

        let animationsActive = startRelayoutAnimations(transition, snapshot: snapshot, engine: engine, now: now)
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: newFrames,
            context: layoutDiffContext(
                snapshot: snapshot,
                engine: engine,
                reassertHidden: true,
                animationTime: animationsActive ? now : nil
            )
        )
        let directives: [AnimationDirective] = animationsActive
            ? [.startDwindleAnimation(workspaceId: snapshot.workspaceId, monitorId: snapshot.monitor.monitorId)]
            : []
        let targetDisposition = animationTargetDisposition(
            snapshot: snapshot,
            engine: engine,
            frames: newFrames,
            active: animationsActive
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                rememberedFocusToken: rememberedFocusToken,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            dwindleRestorePlacements: engine.persistedPlacements(in: snapshot.workspaceId),
            animationDirectives: directives,
            dwindleAnimationTargetDisposition: targetDisposition,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }
}
