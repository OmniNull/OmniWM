// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension WindowModel {
    @discardableResult
    func upsert(
        window: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        admissionHints: ManagedWindowAdmissionHints = .none,
        lifetimeAuthority: ManagedWindowLifetimeAuthority = .axTopLevelInventory,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        upsert(
            target: .external(window),
            pid: pid,
            windowId: windowId,
            workspace: workspace,
            mode: mode,
            ruleEffects: ruleEffects,
            admissionHints: admissionHints,
            lifetimeAuthority: lifetimeAuthority,
            managedReplacementMetadata: managedReplacementMetadata
        )
    }

    func applyFieldMutation(_ event: WMEvent, monitors: [Monitor]) {
        switch event {
        case let .topLevelInventoryObserved(tokens, _):
            for token in tokens where entry(for: token)?.lifetimeAuthority == .directLifecycle {
                setLifetimeAuthority(.axTopLevelInventory, for: token)
            }

        case let .hostedWindowGeometryObserved(token, _, monitorId, frame, _):
            guard let entry = entry(for: token), entry.target.hostedMetadata != nil,
                  entry.mode == .floating else { return }
            let visibleFrame = monitors.first { $0.id == monitorId }?.visibleFrame ?? frame
            setFloatingState(.init(
                lastFrame: frame,
                normalizedOrigin: FloatingFrameGeometry.normalizedOrigin(for: frame, in: visibleFrame),
                referenceMonitorId: monitorId,
                restoreToFloating: entry.floatingState?.restoreToFloating ?? true
            ), for: token)

        case let .floatingGeometryUpdated(token, _, referenceMonitorId, frame, normalizedOrigin, restoreToFloating, _):
            setFloatingState(
                .init(
                    lastFrame: frame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: referenceMonitorId,
                    restoreToFloating: restoreToFloating
                ),
                for: token
            )

        case let .floatingStateChanged(token, _, state, _):
            setFloatingState(state, for: token)

        case let .manualLayoutOverrideChanged(token, _, layoutOverride, _):
            setManualLayoutOverride(layoutOverride, for: token)

        case let .niriPlacementsResolved(placements, _):
            applyNiriPlacements(placements, monitors: monitors)

        case let .dwindlePlacementsResolved(placements, _):
            applyDwindlePlacements(placements, monitors: monitors)

        case let .hiddenStateChanged(token, _, _, hiddenState, _):
            setHiddenState(hiddenState, for: token)

        case let .nativeFullscreenTransition(token, _, _, change, _):
            switch change {
            case let .suspended(reason):
                setLayoutReason(reason, for: token)
            case .restored:
                restoreFromNativeState(for: token)
            }

        case let .managedReplacementMetadataChanged(token, _, _, metadata, _):
            setManagedReplacementMetadata(metadata, for: token)

        default:
            preconditionFailure("Expected a WindowModel field mutation")
        }
    }

    func applyNiriPlacements(_ placements: [WindowToken: PersistedNiriPlacement], monitors: [Monitor]) {
        for (token, placement) in placements {
            guard let entry = self.entry(for: token), entry.mode == .tiling else { continue }
            var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            restoreIntent.niriPlacement = placement
            restoreIntent.detachedNiriContainerSizingState = nil
            guard entry.restoreIntent != restoreIntent else { continue }
            self.setRestoreIntent(restoreIntent, for: token)
        }
    }

    func applyDwindlePlacements(_ placements: [WindowToken: PersistedDwindlePlacement], monitors: [Monitor]) {
        for (token, placement) in placements {
            guard let entry = self.entry(for: token), entry.mode == .tiling else { continue }
            var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            restoreIntent.dwindlePlacement = placement
            guard entry.restoreIntent != restoreIntent else { continue }
            self.setRestoreIntent(restoreIntent, for: token)
        }
    }
}
