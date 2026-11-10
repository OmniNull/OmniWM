// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class PlacementResolver {
    private struct WorkspacePlacementTarget {
        let workspaceId: WorkspaceDescriptor.ID?
        let rung: WorkspacePlacementRung
    }

    private let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func monitorForInteraction() -> Monitor? {
        if let interactionMonitorId = workspaceManager.interactionMonitorId,
           let monitor = workspaceManager.monitor(byId: interactionMonitorId)
        {
            return monitor
        }
        if let focusedToken = workspaceManager.nativeManagedFocusToken,
           let workspaceId = workspaceManager.workspace(for: focusedToken),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    func resolveWorkspacePlacement(
        window: WorkspacePlacementWindow,
        rules: WorkspacePlacementRules,
        context: WorkspacePlacementContext
    ) -> WorkspacePlacementResolution {
        let existingEntry = window.existingEntry

        if context.reevaluation == .automatic, let existingEntry {
            return WorkspacePlacementResolution(workspaceId: existingEntry.workspaceId, rung: .existingEntry)
        }

        if existingEntry == nil,
           let structuralReplacementWorkspaceId = rules.structuralReplacementWorkspaceId,
           workspaceManager.descriptor(for: structuralReplacementWorkspaceId) != nil
        {
            return WorkspacePlacementResolution(
                workspaceId: structuralReplacementWorkspaceId,
                rung: .structuralReplacement
            )
        }

        if existingEntry == nil,
           rules.inheritTrackedParentWorkspace,
           let parentWorkspaceId = workspaceForTrackedParentWindow(
               parentWindowId: window.parentWindowId,
               pid: window.pid
           )
        {
            return WorkspacePlacementResolution(workspaceId: parentWorkspaceId, rung: .trackedParent)
        }

        var ruleSkipReason: WorkspaceRuleSkipReason?
        if let workspaceName = rules.workspaceName {
            let resolvedRuleWorkspaceId = workspaceManager.workspaceId(
                for: workspaceName,
                createIfMissing: false
            )
            if !shouldApplyWorkspaceRule(pid: window.pid, context: context.reevaluation) {
                ruleSkipReason = .appAlreadyHasEntries
            } else if let resolvedRuleWorkspaceId {
                return WorkspacePlacementResolution(
                    workspaceId: resolvedRuleWorkspaceId,
                    rung: .workspaceRule
                )
            } else {
                ruleSkipReason = .workspaceNotMaterialized
            }
        }

        if let existingEntry {
            return WorkspacePlacementResolution(
                workspaceId: existingEntry.workspaceId,
                rung: .existingEntry,
                ruleSkipReason: ruleSkipReason
            )
        }

        let placementTarget = createPlacementTarget(window: window, rules: rules, context: context)

        var resolution = defaultWorkspacePlacement(placementTarget: placementTarget)
        resolution.ruleSkipReason = ruleSkipReason
        return resolution
    }

    private func workspaceForTrackedParentWindow(
        parentWindowId: UInt32?,
        pid _: pid_t?
    ) -> WorkspaceDescriptor.ID? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return workspaceManager.entry(forWindowId: Int(parentWindowId))?.workspaceId
    }

    private func shouldApplyWorkspaceRule(
        pid: pid_t?,
        context: WindowRuleReevaluationContext
    ) -> Bool {
        if context == .explicitRuleApply {
            return true
        }
        guard let pid else { return true }
        return !workspaceManager.hasEntries(forPid: pid)
    }

    func floatingSpawnMonitorId(pid: pid_t) -> Monitor.ID? {
        let tiled = workspaceManager.entries(forPid: pid).filter { $0.mode == .tiling }
        guard !tiled.isEmpty else { return nil }

        if let focused = workspaceManager.selectedManagedToken,
           let entry = tiled.first(where: { $0.token == focused }),
           let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        {
            return monitorId
        }

        if let recent = workspaceManager.lastTiledFocusedToken,
           let entry = tiled.first(where: { $0.token == recent }),
           let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        {
            return monitorId
        }

        let monitors = Set(tiled.compactMap { workspaceManager.monitorId(for: $0.workspaceId) })
        return monitors.count == 1 ? monitors.first : nil
    }

    private func defaultWorkspacePlacement(
        placementTarget: WorkspacePlacementTarget
    ) -> WorkspacePlacementResolution {
        if let workspaceId = placementTarget.workspaceId {
            return WorkspacePlacementResolution(workspaceId: workspaceId, rung: placementTarget.rung)
        }

        if let monitor = monitorForInteraction(),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementResolution(workspaceId: workspace.id, rung: .defaultWorkspace)
        }
        if let workspaceId = workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first?.id {
            return WorkspacePlacementResolution(workspaceId: workspaceId, rung: .defaultWorkspace)
        }
        if let createdWorkspaceId = workspaceManager.workspaceId(for: "1", createIfMissing: false) {
            return WorkspacePlacementResolution(workspaceId: createdWorkspaceId, rung: .defaultWorkspace)
        }
        fatal("resolveWorkspaceForNewWindow: no workspaces exist")
    }
}

extension PlacementResolver {
    private func createPlacementTarget(
        window: WorkspacePlacementWindow,
        rules: WorkspacePlacementRules,
        context: WorkspacePlacementContext
    ) -> WorkspacePlacementTarget {
        let axRef = window.axRef
        let placementMode = window.placementMode
        let createPlacementContext = context.createPlacementContext

        let preferManagedFocusPlacement = placementMode == .tiling
        let nativeSpaceTarget = nativeSpacePlacement(context.createPlacementContext)
        let floatingSpawnTarget = floatingSpawnPlacement(window: window, rules: rules)

        if let target = initialCreatePlacement(
            context: context, preferManagedFocusPlacement: preferManagedFocusPlacement,
            nativeSpaceTarget: nativeSpaceTarget, floatingSpawnTarget: floatingSpawnTarget
        ) { return target }

        if preferManagedFocusPlacement {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId,
                rung: .focusedContext
            ) {
                return target
            }
        }

        if let nativeSpaceTarget {
            return nativeSpaceTarget
        }

        if let floatingSpawnTarget {
            return floatingSpawnTarget
        }

        if preferManagedFocusPlacement,
           let target = liveManagedFocusPlacementTarget()
        {
            return target
        }

        if let monitor = monitorForAppKitFrame(window.appKitFrame),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .frame
            )
        }

        if workspaceManager.monitors.count > 1,
           let axRef,
           let monitor = monitorForAppKitFrame(AXWindowService.framePreferFast(axRef)),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .axFrame
            )
        }

        return fallbackCreatePlacement(context: context, preferManagedFocusPlacement: preferManagedFocusPlacement)
    }

    private func nativeSpacePlacement(_ createPlacementContext: WindowCreatePlacementContext?)
        -> WorkspacePlacementTarget?
    {
        return if let monitorId = createPlacementContext?
            .nativeSpaceMonitorId,
            let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .nativeSpace
            )
        } else {
            nil
        }
    }

    private func floatingSpawnPlacement(
        window: WorkspacePlacementWindow,
        rules: WorkspacePlacementRules
    ) -> WorkspacePlacementTarget? {
        let allowsFloatingSpawnPlacement = rules.allowsFloatingSpawnPlacement
        let preferManagedFocusPlacement = window.placementMode == .tiling
        let pid = window.pid
        return if allowsFloatingSpawnPlacement,
                  !preferManagedFocusPlacement,
                  let pid,
                  let monitorId = floatingSpawnMonitorId(pid: pid),
                  let workspace = workspaceManager.activeWorkspaceOrFirst(
                      on: monitorId
                  )
        {
            WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .floatingSpawn
            )
        } else {
            nil
        }
    }

    private func initialCreatePlacement(
        context: WorkspacePlacementContext, preferManagedFocusPlacement: Bool,
        nativeSpaceTarget: WorkspacePlacementTarget?, floatingSpawnTarget: WorkspacePlacementTarget?
    ) -> WorkspacePlacementTarget? {
        let origin = context.origin
        let createPlacementContext = context.createPlacementContext
        if origin == .liveCreate {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.pendingFocusedWorkspaceId,
                createPlacementContext?.pendingFocusedMonitorId,
                rung: .pendingFocusContext
            ) {
                return target
            }

            if let floatingSpawnTarget {
                if let nativeSpaceTarget {
                    return nativeSpaceTarget
                }
                return floatingSpawnTarget
            }

            if let target = capturedInteractionPlacementTarget(createPlacementContext) {
                return target
            }

            if let target = liveInteractionPlacementTarget() {
                return target
            }
        } else if preferManagedFocusPlacement,
                  let target = managedFocusPlacementTarget(
                      createPlacementContext?.pendingFocusedWorkspaceId,
                      createPlacementContext?.pendingFocusedMonitorId,
                      rung: .pendingFocusContext
                  )
        {
            return target
        }

        return nil
    }

    private func fallbackCreatePlacement(
        context: WorkspacePlacementContext, preferManagedFocusPlacement: Bool
    ) -> WorkspacePlacementTarget {
        let origin = context.origin
        let createPlacementContext = context.createPlacementContext
        let fallbackWorkspaceId = context.fallbackWorkspaceId
        if !preferManagedFocusPlacement {
            if origin == .discovery,
               let target = managedFocusPlacementTarget(
                   createPlacementContext?.pendingFocusedWorkspaceId,
                   createPlacementContext?.pendingFocusedMonitorId,
                   rung: .pendingFocusContext
               )
            {
                return target
            }

            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId,
                rung: .focusedContext
            ) {
                return target
            }
        }

        if origin == .discovery,
           let target = capturedInteractionPlacementTarget(createPlacementContext)
        {
            return target
        }

        if let fallbackWorkspaceId,
           workspaceManager.descriptor(for: fallbackWorkspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: fallbackWorkspaceId,
                rung: .fallbackWorkspace
            )
        }

        return WorkspacePlacementTarget(
            workspaceId: nil,
            rung: .defaultWorkspace
        )
    }

    private func capturedInteractionPlacementTarget(
        _ context: WindowCreatePlacementContext?
    ) -> WorkspacePlacementTarget? {
        if let workspaceId = context?.interactionWorkspaceId,
           workspaceManager.descriptor(for: workspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: workspaceId,
                rung: .interactionWorkspace
            )
        }

        if let monitorId = context?.interactionMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .interactionMonitor
            )
        }

        return nil
    }

    private func liveInteractionPlacementTarget() -> WorkspacePlacementTarget? {
        guard let monitorId = workspaceManager.interactionMonitorId,
              let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        else {
            return nil
        }
        return WorkspacePlacementTarget(
            workspaceId: workspace.id,
            rung: .interactionMonitor
        )
    }

    private func liveManagedFocusPlacementTarget() -> WorkspacePlacementTarget? {
        let candidates: [WindowToken?]
        switch workspaceManager.nativeFocusOwner {
        case let .managed(token):
            candidates = [token, workspaceManager.lastTiledFocusedToken]
        case .external,
             .ownedSurface:
            return nil
        case .none:
            candidates = [workspaceManager.lastTiledFocusedToken]
        }
        for token in candidates {
            guard let token,
                  let entry = workspaceManager.entry(for: token),
                  let target = managedFocusPlacementTarget(entry.workspaceId, nil, rung: .liveManagedFocus)
            else {
                continue
            }
            return target
        }
        return nil
    }

    private func managedFocusPlacementTarget(
        _ workspaceId: WorkspaceDescriptor.ID?,
        _ monitorId: Monitor.ID?,
        rung: WorkspacePlacementRung
    ) -> WorkspacePlacementTarget? {
        if let workspaceId,
           workspaceManager.descriptor(for: workspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: workspaceId,
                rung: rung
            )
        }

        if let monitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: rung
            )
        }

        return nil
    }

    func monitorForAppKitFrame(_ frame: CGRect?) -> Monitor? {
        guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
        return frame.center.monitorApproximation(in: workspaceManager.monitors)
    }
}
