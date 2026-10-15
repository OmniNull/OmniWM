// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum NiriGatherWindowIssue: Equatable {
    case notFound
    case scratchpad
    case nativeFullscreen
    case appHidden
    case minimized
    case nativeWithdrawn
    case floating
    case unsupportedLayout
    case layoutConflict
    case layoutFullscreen
}

enum NiriGatherFailure: Equatable {
    case destinationNotFound
    case invalidDestination
    case unsupportedLayout
    case windows([WindowToken: NiriGatherWindowIssue])
    case doesNotFit
    case stalePlan
}

enum NiriGatherOutcome: Equatable {
    case gathered(NiriGatherPlan)
    case unchanged
    case refused(NiriGatherFailure)
}

extension NiriLayoutHandler {
    func gatherWindows(
        _ tokens: [WindowToken],
        into destinationId: WorkspaceDescriptor.ID
    ) -> NiriGatherOutcome {
        guard let controller else { return .refused(.invalidDestination) }
        let manager = controller.workspaceManager
        guard manager.descriptor(for: destinationId) != nil else { return .refused(.destinationNotFound) }
        guard manager.activeLayoutKind(for: destinationId) == .niri,
              let engine = controller.niriEngine
        else {
            return .refused(.unsupportedLayout)
        }
        guard let monitor = manager.monitor(for: destinationId) else { return .refused(.invalidDestination) }

        var issues: [WindowToken: NiriGatherWindowIssue] = [:]
        var sourceWorkspaceIds: [WindowToken: WorkspaceDescriptor.ID] = [:]
        for token in tokens {
            if let issue = gatherEligibilityIssue(for: token, manager: manager) {
                issues[token] = issue
            } else {
                sourceWorkspaceIds[token] = manager.workspace(for: token)
            }
        }
        let request = NiriGatherRequest(
            tokens: tokens.filter { issues[$0] == nil },
            sourceWorkspaceIds: sourceWorkspaceIds,
            destinationWorkspaceId: destinationId,
            geometry: NiriSizingGeometry(
                workingFrame: controller.niriWorkingFrame(for: monitor),
                gaps: controller.innerGap(for: monitor),
                orientation: resolvedOrientation(for: destinationId, monitor: monitor, engine: engine)
            )
        )

        switch manager.planNiriGather(request) {
        case .unchanged:
            return issues.isEmpty ? .unchanged : .refused(.windows(issues))
        case let .refused(.windows(engineIssues)):
            for (token, issue) in engineIssues {
                issues[token] = issue == .layoutFullscreen ? .layoutFullscreen : .layoutConflict
            }
            return .refused(.windows(issues))
        case .refused(.doesNotFit):
            return .refused(issues.isEmpty ? .doesNotFit : .windows(issues))
        case let .ready(plan):
            guard issues.isEmpty else { return .refused(.windows(issues)) }
            guard manager.commitNiriGather(plan) else { return .refused(.stalePlan) }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: Set(plan.affectedWorkspaceIds)
            )
            return .gathered(plan)
        }
    }

    private func gatherEligibilityIssue(
        for token: WindowToken,
        manager: WorkspaceManager
    ) -> NiriGatherWindowIssue? {
        guard let entry = manager.entry(for: token), manager.handle(for: token) != nil else { return .notFound }
        if manager.scratchpadIndex(for: token) != nil || entry.hiddenState?.isScratchpad == true {
            return .scratchpad
        }
        if entry.layoutReason == .nativeFullscreen || manager.nativeFullscreenRecord(for: token) != nil {
            return .nativeFullscreen
        }
        if manager.isAppHidden(pid: entry.pid) { return .appHidden }
        if entry.observedState.isMinimized { return .minimized }
        if entry.observedState.isNativeWithdrawn { return .nativeWithdrawn }
        if entry.mode == .floating { return .floating }
        if manager.activeLayoutKind(for: entry.workspaceId) != .niri { return .unsupportedLayout }
        return nil
    }
}
