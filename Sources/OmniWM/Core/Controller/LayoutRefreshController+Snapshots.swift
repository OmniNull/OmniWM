// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func applyResolvedConstraints(_ fact: WindowConstraintsFact) {
        guard let controller,
              let workspaceId = controller.workspaceManager.workspace(for: fact.token)
        else { return }
        let previous = controller.workspaceManager.cachedConstraints(
            for: fact.token,
            maxAge: .greatestFiniteMagnitude
        )
        controller.workspaceManager.setCachedConstraints(fact.constraints, for: fact.token)
        if previous != fact.constraints {
            controller.workspaceManager.invalidateLayout(for: [workspaceId])
            requestRelayout(reason: .observedConstraintsChanged, affectedWorkspaceIds: [workspaceId])
        }
    }

    func buildWindowSnapshots(
        for entries: [WindowState],
        excludedTokens: Set<WindowToken>,
        resolveConstraints: Bool,
        workArea: CGSize,
        neighborAxes: MonitorNeighborAxes
    ) -> [LayoutWindowSnapshot] {
        guard let controller else { return [] }

        var snapshots: [LayoutWindowSnapshot] = []
        snapshots.reserveCapacity(entries.count)

        for entry in entries {
            let layoutReason = entry.layoutReason
            let constraints: WindowSizeConstraints
            if excludedTokens.contains(entry.token) || !resolveConstraints || layoutReason == .nativeFullscreen {
                constraints = controller.workspaceManager.cachedConstraints(for: entry.token) ?? .unconstrained
            } else if let cached = controller.workspaceManager.cachedConstraints(for: entry.token) {
                constraints = cached
            } else {
                controller.factResolver.resolveWindowConstraints(token: entry.token, axRef: entry.axRef)
                constraints = controller.workspaceManager.cachedConstraints(
                    for: entry.token,
                    maxAge: .greatestFiniteMagnitude
                ) ?? .unconstrained
            }

            var mergedConstraints = constraints
            var packingHints = ObservedPackingHints.none
            if resolveConstraints {
                packingHints = mergeObservedAndRuleConstraints(&mergedConstraints, entry: entry, controller: controller)
            }

            let hiddenState = entry.hiddenState
            let nativeFullscreenOriginalToken: WindowToken? = if layoutReason == .nativeFullscreen,
                                                                 let record = controller.workspaceManager
                                                                 .nativeFullscreenRecord(for: entry.token),
                                                                 record.currentToken == entry.token
            {
                record.originalToken
            } else {
                nil
            }

            snapshots.append(
                LayoutWindowSnapshot(
                    token: entry.token,
                    constraints: Self.overflowCappedConstraints(
                        mergedConstraints,
                        layoutReason: layoutReason,
                        workArea: workArea,
                        cappedAxes: neighborAxes
                    ),
                    packingHints: packingHints,
                    hiddenState: hiddenState,
                    layoutReason: layoutReason,
                    nativeFullscreenOriginalToken: nativeFullscreenOriginalToken
                )
            )
        }

        return snapshots
    }

    nonisolated static func overflowCappedConstraints(
        _ constraints: WindowSizeConstraints,
        layoutReason: LayoutReason,
        workArea: CGSize,
        cappedAxes: MonitorNeighborAxes
    ) -> WindowSizeConstraints {
        var effective = constraints.normalized()
        if effective.isFixed || layoutReason == .nativeFullscreen {
            return effective
        }
        if cappedAxes.horizontal {
            effective.minSize.width = min(effective.minSize.width, workArea.width)
        }
        if cappedAxes.vertical {
            effective.minSize.height = min(effective.minSize.height, workArea.height)
        }
        return effective
    }

    func buildMonitorSnapshot(
        for monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> LayoutMonitorSnapshot {
        let scale = backingScale(for: monitor)
        let layoutFrames = controller?.layoutFrames(for: monitor, scale: scale)
        return LayoutMonitorSnapshot(
            monitorId: monitor.id,
            displayId: monitor.displayId,
            frame: monitor.frame,
            visibleFrame: monitor.visibleFrame,
            workingFrame: layoutFrames?.workingFrame ?? monitor.visibleFrame,
            borderSafeFillFrame: layoutFrames?.borderSafeFillFrame ?? monitor.visibleFrame,
            fullscreenLayoutFrame: layoutFrames?.fullscreenLayoutFrame ?? monitor.visibleFrame,
            scale: scale,
            orientation: orientation ?? monitor.autoOrientation
        )
    }

    func buildRefreshInput(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        resolveConstraints: Bool,
        orientation: Monitor.Orientation? = nil,
        isActiveWorkspace: Bool
    ) -> WorkspaceRefreshInput? {
        guard let controller else { return nil }

        let monitorSnapshot = buildMonitorSnapshot(for: monitor, orientation: orientation)
        let entries = controller.workspaceManager.tiledEntries(in: workspaceId)
        let excludedTokens = Set(
            entries.lazy
                .filter { controller.workspaceManager.isWindowSuppressedByMacOS($0) }
                .map(\.token)
        )
        let windows = buildWindowSnapshots(
            for: entries,
            excludedTokens: excludedTokens,
            resolveConstraints: resolveConstraints,
            workArea: monitorSnapshot.workingFrame.size,
            neighborAxes: monitor.neighborAxes(among: controller.workspaceManager.monitors)
        )

        return WorkspaceRefreshInput(
            workspaceId: workspaceId,
            monitor: monitorSnapshot,
            windows: windows,
            excludedTokens: excludedTokens,
            plannedSeq: controller.workspaceManager.worldSeq,
            isActiveWorkspace: isActiveWorkspace
        )
    }

    func backingScale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
    }
}

extension LayoutRefreshController {
    private func mergeObservedAndRuleConstraints(
        _ mergedConstraints: inout WindowSizeConstraints,
        entry: WindowState,
        controller: WMController
    ) -> ObservedPackingHints {
        if let minW = entry.ruleEffects.minWidth {
            mergedConstraints.minSize.width = max(mergedConstraints.minSize.width, minW)
        }
        if let minH = entry.ruleEffects.minHeight {
            mergedConstraints.minSize.height = max(mergedConstraints.minSize.height, minH)
        }
        let evidence = controller.workspaceManager.observedSizeEvidence(for: entry.token)
        if let observedMin = evidence?.minSize {
            mergedConstraints.minSize.width = max(mergedConstraints.minSize.width, observedMin.width)
            mergedConstraints.minSize.height = max(mergedConstraints.minSize.height, observedMin.height)
        }
        mergedConstraints = mergedConstraints.normalized()
        return evidence?.hints ?? .none
    }
}
