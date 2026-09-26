// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct WindowRuleReevaluation {
    private let controller: WMController
    private let context: WindowRuleReevaluationContext
    private let epochSeq: UInt64
    private let epochDomains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen]
    private var liveWindowsByToken: [WindowToken: AXWindowRef] = [:]
    private var topLevelInventoryTokens: Set<WindowToken> = []
    private var tokensToReevaluate: Set<WindowToken> = []
    private var resolvedAnyTarget = false
    private var relayoutNeeded = false
    private var ruleRelayoutNeeded = false
    private var evaluatedAnyWindow = false
    private var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

    init(controller: WMController, context: WindowRuleReevaluationContext) {
        self.controller = controller
        self.context = context
        epochSeq = controller.workspaceManager.worldSeq
    }

    private var isCurrent: Bool {
        !Task.isCancelled && controller.workspaceManager.isSeqEpochCurrent(epochSeq, domains: epochDomains)
    }

    private func outcome(stale: Bool) -> WindowRuleReevaluationOutcome {
        WindowRuleReevaluationOutcome(
            resolvedAnyTarget: resolvedAnyTarget,
            evaluatedAnyWindow: stale ? false : evaluatedAnyWindow,
            relayoutNeeded: stale ? false : relayoutNeeded,
            stale: stale
        )
    }

    mutating func run(for targets: Set<WindowRuleReevaluationTarget>) async -> WindowRuleReevaluationOutcome {
        let pidTargets = collectDirectTargets(targets)
        guard await collectPIDTargets(pidTargets), isCurrent else { return outcome(stale: true) }
        guard !tokensToReevaluate.isEmpty else { return outcome(stale: false) }
        let batchedWindowInfoByToken = batchedWindowServerInfo(for: tokensToReevaluate)
        for token in tokensToReevaluate.sorted(by: {
            if $0.pid == $1.pid { return $0.windowId < $1.windowId }
            return $0.pid < $1.pid
        }) {
            guard let window = prepareWindow(token, windowInfo: batchedWindowInfoByToken[token]) else { continue }
            apply(window)
        }
        finish()
        return outcome(stale: false)
    }

    private mutating func prepareWindow(
        _ token: WindowToken,
        windowInfo: WindowServerInfo?
    ) -> RuleReevaluationWindow? {
        let existingEntry = controller.workspaceManager.entry(for: token)
        let axRef = liveWindowsByToken[token] ?? existingEntry?.axRef
        guard let axRef else { return nil }
        let createPlacementContext = existingEntry == nil
            ? controller.axEventHandler.pendingCreatePlacementContext(for: token.windowId)
            : nil
        let placementOrigin: WorkspacePlacementOrigin = createPlacementContext == nil
            ? .discovery
            : .liveCreate

        evaluatedAnyWindow = true
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            windowInfo: windowInfo
        )
        let ruleEffects = evaluation.decision.disposition == .undecided
            ? existingEntry?.ruleEffects ?? evaluation.decision.ruleEffects
            : evaluation.decision.ruleEffects
        let admissionHints = evaluation.decision.disposition == .undecided
            ? existingEntry?.admissionHints ?? evaluation.decision.admissionHints
            : evaluation.decision.admissionHints

        guard let effectiveTrackedMode = controller.trackedModePreservingAutomaticFallbackState(
            decision: evaluation.decision,
            existingEntry: existingEntry,
            context: context
        ) else {
            reject(token, existingEntry: existingEntry, evaluation: evaluation)
            return nil
        }
        if effectiveTrackedMode != .tiling {
            controller.axEventHandler.cancelTrackedTilingPromotionRetry(windowId: token.windowId)
        }

        if controller.axEventHandler.deferAdmissionIfNeeded(
            evaluation: evaluation,
            axRef: axRef,
            token: token,
            mode: effectiveTrackedMode,
            existingEntry: existingEntry,
            placementOrigin: placementOrigin
        ) {
            return nil
        }

        return RuleReevaluationWindow(
            token: token, axRef: axRef, existingEntry: existingEntry,
            evaluation: evaluation, ruleEffects: ruleEffects, admissionHints: admissionHints,
            mode: effectiveTrackedMode, placementOrigin: placementOrigin,
            createPlacementContext: createPlacementContext
        )
    }

    private mutating func reject(
        _ token: WindowToken,
        existingEntry: WindowState?,
        evaluation: WMController.WindowDecisionEvaluation
    ) {
        controller.axEventHandler.cancelTrackedTilingPromotionRetry(windowId: token.windowId)
        if let existingEntry {
            affectedWorkspaceIds.insert(existingEntry.workspaceId)
            controller.axEventHandler.retireManagedWindowAfterDecisionRejection(existingEntry)
            relayoutNeeded = true
        } else if evaluation.decision.disposition != .undecided {
            controller.axEventHandler.discardCreatePlacementContext(for: token.windowId)
        }
    }

    private mutating func apply(_ window: RuleReevaluationWindow) {
        let structuralMatch = window.existingEntry == nil
            ? controller.axEventHandler.structuralReplacementMatch(
                token: window.token,
                candidate: .init(
                    bundleId: window.evaluation.facts.ax.bundleId,
                    mode: window.mode,
                    facts: window.evaluation.facts
                )
            )
            : nil
        let workspaceId = workspaceForReevaluatedWindow(window, structuralMatch: structuralMatch)

        if window.existingEntry == nil,
           let windowId = UInt32(exactly: window.token.windowId),
           let structuralMatch,
           controller.axEventHandler.rekeyStructuralManagedReplacement(
               match: structuralMatch,
               identity: .init(
                   token: window.token,
                   axRef: window.axRef
               ),
               windowId: windowId,
               candidate: .init(
                   bundleId: window.evaluation.facts.ax
                       .bundleId,
                   mode: window.mode,
                   facts: window.evaluation.facts
               ),
               admissionHints: window.admissionHints
           )
        {
            affectedWorkspaceIds.insert(workspaceId)
            relayoutNeeded = true
            ruleRelayoutNeeded = true
            return
        }

        admitIfNeeded(window, workspaceId: workspaceId)
        updateTracking(window)
        updateGeometry(window, workspaceId: workspaceId)
        updateReplacementMetadata(window)
        finishApplication(window, workspaceId: workspaceId)
    }

    private func workspaceForReevaluatedWindow(
        _ window: RuleReevaluationWindow,
        structuralMatch: AXEventHandler.StructuralReplacementMatch?
    ) -> WorkspaceDescriptor.ID {
        return controller.resolvedWorkspaceId(
            for: window.evaluation,
            axRef: window.axRef,
            existingEntry: window.existingEntry,
            structuralReplacementWorkspaceId: structuralMatch?.workspaceId,
            placementMode: window.mode,
            placementContext: WorkspacePlacementContext(
                origin: window.placementOrigin,
                createPlacementContext: window.createPlacementContext,
                fallbackWorkspaceId: controller.activeWorkspace()?.id,
                reevaluation: context
            )
        )
    }

    private func admitIfNeeded(_ window: RuleReevaluationWindow, workspaceId: WorkspaceDescriptor.ID) {
        let shouldAdmit = window.existingEntry.map {
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: $0,
                target: .init(
                    workspaceId: workspaceId,
                    mode: window.existingEntry?.mode ?? window.mode,
                    ruleEffects: window.ruleEffects
                ),
                shouldPreservePreFullscreenState: false,
                appFullscreen: false
            )
        } ?? true
        if shouldAdmit {
            if window.existingEntry == nil, window.mode == .tiling {
                controller.dwindleLayoutHandler.markIncomingWindowForStacking(window.token, in: workspaceId)
            }
            _ = controller.workspaceManager.addWindow(
                window.axRef,
                pid: window.token.pid,
                windowId: window.token.windowId,
                to: workspaceId,
                mode: window.existingEntry?.mode ?? window.mode,
                ruleEffects: window.ruleEffects,
                admissionHints: window.admissionHints,
                lifetimeAuthority: WMController.ruleReevaluationLifetimeAuthority(
                    existing: window.existingEntry?.lifetimeAuthority,
                    observedInTopLevelInventory: topLevelInventoryTokens.contains(window.token)
                ),
                allowsNativeFocusAdoption: !window.evaluation.appFullscreen,
                managedReplacementMetadata: window.admissionMetadata(workspaceId: workspaceId)
            )
        }
    }

    private func updateTracking(_ window: RuleReevaluationWindow) {
        if window.existingEntry != nil {
            _ = controller.workspaceManager.updateAdmissionHints(
                window.admissionHints,
                for: window.token
            )
        }
        if window.existingEntry == nil {
            controller.axEventHandler.discardCreatePlacementContext(for: window.token.windowId)
        }
    }

    private func updateGeometry(_ window: RuleReevaluationWindow, workspaceId: WorkspaceDescriptor.ID) {
        if let oldMode = window.existingEntry?.mode, oldMode != window.mode {
            _ = controller.transitionWindowMode(
                for: window.token,
                to: window.mode,
                preferredMonitor: controller.workspaceManager.monitor(for: workspaceId)
            )
        } else if window.mode == .floating {
            controller.seedFloatingGeometryIfNeeded(
                for: window.token,
                preferredMonitor: controller.workspaceManager.monitor(for: workspaceId)
            )
        }
    }

    private func updateReplacementMetadata(_ window: RuleReevaluationWindow) {
        if let updatedEntry = controller.workspaceManager.entry(for: window.token) {
            _ = controller.workspaceManager.setManagedReplacementMetadata(
                window.updatedMetadata(for: updatedEntry), for: window.token
            )
        }
    }

    private mutating func finishApplication(_ window: RuleReevaluationWindow, workspaceId: WorkspaceDescriptor.ID) {
        if window.existingEntry == nil
            || (window.existingEntry?.ruleEffects ?? .none) != window.ruleEffects
            || window.existingEntry?.workspaceId != workspaceId
            || window.existingEntry?.mode != window.mode
        {
            if let oldWorkspaceId = window.existingEntry?.workspaceId {
                affectedWorkspaceIds.insert(oldWorkspaceId)
            }
            affectedWorkspaceIds.insert(workspaceId)
            relayoutNeeded = true
            ruleRelayoutNeeded = true
        }
        if controller.workspaceManager.entry(for: window.token) != nil,
           let windowId = UInt32(exactly: window.token.windowId)
        {
            controller.axEventHandler.finishRuleReevaluationAfterTracking(
                windowId: windowId,
                wasNewlyManaged: window.existingEntry == nil
            )
        }
    }

    private func finish() {
        controller.workspaceManager.promoteLifetimeAuthorityForObservedTopLevelWindows(
            topLevelInventoryTokens
        )

        let evaluatedPIDs = Set(tokensToReevaluate.map(\.pid))
        controller.axManager.bindManagedWindows(
            controller.workspaceManager.allEntries().filter { evaluatedPIDs.contains($0.pid) }
        )

        if ruleRelayoutNeeded {
            controller.layoutRefreshController.requestRelayout(
                reason: .windowRuleReevaluation,
                affectedWorkspaceIds: affectedWorkspaceIds
            )
        }
    }
}

extension WindowRuleReevaluation {
    private mutating func collectDirectTargets(_ targets: Set<WindowRuleReevaluationTarget>) -> Set<pid_t> {
        var pidTargets: Set<pid_t> = []
        for target in targets {
            switch target {
            case let .window(token):
                let existingEntry = controller.workspaceManager.entry(for: token)
                if let axRef = resolveAXWindowRef(for: token) {
                    resolvedAnyTarget = true
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                } else if existingEntry != nil {
                    resolvedAnyTarget = true
                    tokensToReevaluate.insert(token)
                }
            case let .pid(pid):
                pidTargets.insert(pid)
            }
        }

        return pidTargets
    }

    private mutating func collectPIDTargets(_ pidTargets: Set<pid_t>) async -> Bool {
        for pid in pidTargets {
            let managedEntries = controller.workspaceManager.entries(forPid: pid)
            if !managedEntries.isEmpty {
                resolvedAnyTarget = true
            }
            if let app = NSRunningApplication(processIdentifier: pid) {
                let windows = await controller.axManager.windowsForApp(app)
                guard isCurrent
                else {
                    return false
                }
                if !windows.isEmpty {
                    resolvedAnyTarget = true
                }
                for axRef in windows {
                    let token = WindowToken(pid: pid, windowId: axRef.windowId)
                    tokensToReevaluate.insert(token)
                    liveWindowsByToken[token] = axRef
                    topLevelInventoryTokens.insert(token)
                }
            }

            for entry in managedEntries {
                tokensToReevaluate.insert(entry.token)
            }
        }

        return true
    }

    private func batchedWindowServerInfo(
        for tokens: Set<WindowToken>
    ) -> [WindowToken: WindowServerInfo] {
        let windowIds = Set(tokens.compactMap { UInt32(exactly: $0.windowId) })
        guard windowIds.count > 1 else { return [:] }
        let infoByWindowId = controller.axEventHandler.resolveWindowInfo(windowIds)
        return tokens.reduce(into: [:]) { result, token in
            guard let windowId = UInt32(exactly: token.windowId),
                  let info = WMController.exactWindowServerInfo(infoByWindowId[windowId], for: token)
            else {
                return
            }
            result[token] = info
        }
    }

    private func resolveAXWindowRef(for token: WindowToken) -> AXWindowRef? {
        controller.workspaceManager.entry(for: token)?.axRef
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
    }
}
