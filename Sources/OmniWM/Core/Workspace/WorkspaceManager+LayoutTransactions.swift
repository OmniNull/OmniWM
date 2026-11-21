// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func withEngineMutationScope<T>(
        in workspaceId: WorkspaceDescriptor.ID? = nil,
        label: String = "engine_mutation",
        source: WMEventSource = .command,
        _ body: () -> T
    ) -> T {
        var result: T?
        commitWorldScope(in: workspaceId, label: label, source: source) { result = body() }
        return result!
    }

    @discardableResult
    func withBatchedLayoutBuild(_ build: () -> [WorkspaceLayoutPlan]) -> [WorkspaceLayoutPlan] {
        var plans: [WorkspaceLayoutPlan] = []
        commitWorldScope(in: nil, label: "layout_build", source: .layoutRefresh) {
            plans = build()
            for index in plans.indices {
                guard let viewportState = plans[index].sessionPatch.viewportState else { continue }
                self.applyViewportInBatch(viewportState, for: plans[index].workspaceId)
                plans[index].sessionPatch.viewportState = nil
            }
            let committedSeq = self.worldSeq
            for index in plans.indices {
                plans[index].sessionPatch.plannedSeq = committedSeq
            }
        }
        return plans
    }

    @discardableResult
    func withBatchedWorkspaceMove(
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        _ engineMove: (inout ViewportState, inout ViewportState)
            -> (result: NiriLayoutEngine.WorkspaceMoveResult, tokens: [WindowToken])?
    ) -> NiriLayoutEngine.WorkspaceMoveResult? {
        var sourceState = niriViewportState(for: sourceWorkspaceId)
        var targetState = niriViewportState(for: targetWorkspaceId)
        var captured: NiriLayoutEngine.WorkspaceMoveResult?
        commitWorldEvent(
            .userCommand(workspaceId: nil, label: "workspace_move", source: .command),
            monitors: monitors,
            preMutate: {
                guard let moved = engineMove(&sourceState, &targetState) else { return }
                captured = moved.result
                self.normalizeNiriRefreshRate(&sourceState, for: sourceWorkspaceId)
                self.normalizeNiriRefreshRate(&targetState, for: targetWorkspaceId)
                self.applyViewportInBatch(sourceState, for: sourceWorkspaceId)
                self.applyViewportInBatch(targetState, for: targetWorkspaceId)
                for token in moved.tokens {
                    self.setWorkspace(for: token, to: targetWorkspaceId)
                }
                self.captureLiveNiriPlacements(containing: moved.tokens, in: targetWorkspaceId)
            },
            resolvePlan: { plan, _, _ in plan }
        )
        return captured
    }

    func withBatchedNiriSourceMutation(
        workspaceId: WorkspaceDescriptor.ID,
        _ engineMutation: (inout ViewportState) -> Void
    ) {
        var sourceState = niriViewportState(for: workspaceId)
        commitWorldEvent(
            .userCommand(workspaceId: nil, label: "niri_source_mutation", source: .command),
            monitors: monitors,
            preMutate: {
                engineMutation(&sourceState)
                self.normalizeNiriRefreshRate(&sourceState, for: workspaceId)
                self.applyViewportInBatch(sourceState, for: workspaceId)
            },
            resolvePlan: { plan, _, _ in plan }
        )
    }

    func invalidateNiriCachedPrimarySpans() {
        guard let niriEngine else { return }
        withEngineMutationScope(label: "gap_settings_changed") {
            niriEngine.invalidateCachedPrimarySpans()
        }
    }
}
