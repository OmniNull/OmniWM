// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func executeScheduledRelayout(refresh: ScheduledRefresh, generation: UInt64) -> Bool {
        guard !layoutState.isIncrementalRefreshInProgress else { return false }
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isIncrementalRefreshInProgress = true
        defer { layoutState.isIncrementalRefreshInProgress = false }
        return executeRelayout(
            refresh: refresh,
            useScrollAnimationPath: false,
            recoverFocus: true,
            generation: generation
        )
    }

    func executeRelayout(
        refresh: ScheduledRefresh,
        useScrollAnimationPath: Bool,
        recoverFocus: Bool,
        generation: UInt64
    ) -> Bool {
        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        let currentBeforeBuild = refresh.postLayoutActions.map {
            $0.currentWorkspaces(using: controller.workspaceManager)
        }
        let pendingBeforeBuild = currentPendingPostLayoutActions()
        let buildStart = CACurrentMediaTime()
        var plan = buildRelayoutEffectPlan(
            useScrollAnimationPath: useScrollAnimationPath,
            recoverFocus: recoverFocus,
            affectedWorkspaceIds: resolvedScheduledWorkspaceIds(refresh)
        )
        recordLayoutBuild(
            seconds: CACurrentMediaTime() - buildStart,
            route: .relayout,
            workspaceCount: plan.workspacePlans.count,
            windowCount: plan.workspacePlans.reduce(0) {
                $0 + controller.workspaceManager.entries(in: $1.workspaceId).count
            }
        )
        applyRefreshMetadata(refresh, includePostLayoutActions: false, to: &plan)
        if !refresh.postLayoutActions.isEmpty || !pendingBeforeBuild.isEmpty {
            let builtSeqs = Dictionary(uniqueKeysWithValues: plan.workspacePlans.map {
                ($0.workspaceId, AcceptedSeq(
                    after: $0.sessionPatch.plannedSeq,
                    domains: .layoutCommit.union(.focusCommit)
                ))
            })
            plan.postLayoutActions += zip(refresh.postLayoutActions, currentBeforeBuild).map {
                $0.forwarded(by: builtSeqs, currentAtEntry: $1)
            }
            forwardPendingPostLayoutActions(pendingBeforeBuild, by: builtSeqs)
        }
        return executeEffectPlan(plan, generation: generation)
    }

    func executeVisibilityRefresh(refresh: ScheduledRefresh, generation: UInt64) -> Bool {
        guard let controller else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            recordVisibilityRefresh(refresh, outcome: .skipped, reason: .lockScreen)
            return false
        }

        var plan = buildVisibilityEffectPlan(
            affectedWorkspaceIds: resolvedScheduledWorkspaceIds(refresh)
                .intersection(currentActiveWorkspaceIds()),
            recoverFocus: refresh.reason.recoversFocusAfterVisibilityChange
        )
        applyRefreshMetadata(refresh, to: &plan)
        return executeEffectPlan(plan, generation: generation)
    }

    func executeImmediateRelayout(refresh: ScheduledRefresh, generation: UInt64) -> Bool {
        guard !layoutState.isImmediateLayoutInProgress else { return false }
        layoutState.isImmediateLayoutInProgress = true
        defer { layoutState.isImmediateLayoutInProgress = false }
        return executeRelayout(
            refresh: refresh,
            useScrollAnimationPath: !niriHandler.scrollAnimationByDisplay.isEmpty,
            recoverFocus: false,
            generation: generation
        )
    }

    func executeWindowRemoval(refresh: ScheduledRefresh, generation: UInt64) -> Bool {
        let payloads = refresh.windowRemovalPayloads
        guard let controller else { return false }
        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        var plan = buildWindowRemovalEffectPlan(payloads: payloads)
        applyRefreshMetadata(refresh, to: &plan)
        return executeEffectPlan(plan, generation: generation)
    }

    func executeFullRefresh(refresh: ScheduledRefresh, generation: UInt64) async throws -> Bool {
        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }

        if controller.isFrontmostAppLockScreen() || controller.isLockScreenActive {
            return false
        }

        await controller.axEventHandler.awaitPendingManagedReplacementBursts(
            for: refresh.rescanScope == .all ? nil : refresh.rescanScope.targetedPIDs
        )
        try Task.checkCancellation()
        guard isCurrentRefreshGeneration(generation) else { return false }

        layoutState.activeFullEnumerationCount += 1
        defer { layoutState.activeFullEnumerationCount -= 1 }

        var plan = try await buildFullEffectPlan(
            removalPayloads: refresh.windowRemovalPayloads,
            scope: refresh.rescanScope,
            permitsMissingRetirement: !layoutState.inventoryStabilityBarrierActive,
            relayoutWorkspaceIds: refresh.subsumesRelayout
                ? resolvedScheduledWorkspaceIds(refresh)
                : nil,
            postLayoutActions: refresh.postLayoutActions
        )
        applyRefreshMetadata(refresh, includePostLayoutActions: false, to: &plan)
        try Task.checkCancellation()
        guard isCurrentRefreshGeneration(generation) else { return false }
        return executeEffectPlan(plan, generation: generation)
    }

    func isCurrentRefreshGeneration(_ generation: UInt64) -> Bool {
        generation == layoutState.refreshGeneration
    }

    func execute(_ refresh: ScheduledRefresh, generation: UInt64) async -> Bool {
        guard isCurrentRefreshGeneration(generation) else { return false }
        do {
            switch refresh.kind {
            case .fullRescan:
                return try await executeFullRefresh(refresh: refresh, generation: generation)
            case .relayout:
                return executeScheduledRelayout(refresh: refresh, generation: generation)
            case .immediateRelayout:
                return executeImmediateRelayout(refresh: refresh, generation: generation)
            case .visibilityRefresh:
                return executeVisibilityRefresh(refresh: refresh, generation: generation)
            case .windowRemoval:
                return executeWindowRemoval(refresh: refresh, generation: generation)
            }
        } catch {
            return false
        }
    }
}
