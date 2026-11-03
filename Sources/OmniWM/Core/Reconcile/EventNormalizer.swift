// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum EventNormalizer {
    static func normalize(
        event: WMEvent,
        existingEntry: WindowState?,
        monitors _: [Monitor]
    ) -> WMEvent {
        switch event {
        case .windowAdmitted,
             .windowRekeyed,
             .windowRemoved:
            normalizeAdmission(event, existingEntry: existingEntry)
        case .workspaceAssigned,
             .windowModeChanged,
             .floatingGeometryUpdated,
             .hostedWindowGeometryObserved:
            normalizePlacement(event, existingEntry: existingEntry)
        case .hiddenStateChanged,
             .nativeFullscreenTransition,
             .managedReplacementMetadataChanged:
            normalizeVisibility(event, existingEntry: existingEntry)
        case let .topologyChanged(displays, source): normalizedTopology(displays, source: source)
        case let .focusLeaseChanged(lease, source): normalizedFocusLease(lease, source: source)
        default:
            event
        }
    }

    private static func normalizeAdmission(_ event: WMEvent, existingEntry: WindowState?) -> WMEvent {
        switch event {
        case let .windowAdmitted(
            token,
            workspaceId,
            monitorId,
            mode,
            target,
            ruleEffects,
            admissionHints,
            lifetimeAuthority,
            adoptNativeFocus,
            metadata,
            source,
            initialFrame
        ):
            return .windowAdmitted(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                mode: mode,
                target: target,
                ruleEffects: ruleEffects,
                admissionHints: admissionHints,
                lifetimeAuthority: lifetimeAuthority,
                adoptNativeFocus: adoptNativeFocus,
                managedReplacementMetadata: metadata,
                source: source,
                initialFrame: initialFrame
            )
        case let .windowRekeyed(from, to, workspaceId, monitorId, reason, newAXRef, metadata, source):
            return .windowRekeyed(
                from: from,
                to: to,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                reason: reason,
                newAXRef: newAXRef,
                managedReplacementMetadata: metadata,
                source: source
            )
        case let .windowRemoved(token, workspaceId, source):
            return .windowRemoved(
                token: token,
                workspaceId: workspaceId ?? existingEntry?.workspaceId,
                source: source
            )
        default:
            return event
        }
    }

    private static func normalizePlacement(_ event: WMEvent, existingEntry: WindowState?) -> WMEvent {
        switch event {
        case let .workspaceAssigned(token, from, to, monitorId, source):
            return .workspaceAssigned(
                token: token,
                from: from ?? existingEntry?.workspaceId,
                to: to,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                source: source
            )
        case let .windowModeChanged(token, workspaceId, monitorId, mode, source):
            return .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                mode: mode,
                source: source
            )
        case let .hostedWindowGeometryObserved(token, workspaceId, monitorId, frame, source):
            return .hostedWindowGeometryObserved(
                token: token, workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                frame: frame, source: source
            )
        case let .floatingGeometryUpdated(
            token,
            workspaceId,
            referenceMonitorId,
            frame,
            normalizedOrigin,
            restoreToFloating,
            source
        ):
            return .floatingGeometryUpdated(
                token: token,
                workspaceId: workspaceId,
                referenceMonitorId: referenceMonitorId
                    ?? existingEntry?.floatingState?.referenceMonitorId
                    ?? existingEntry?.desiredState.monitorId
                    ?? existingEntry?.observedState.monitorId,
                frame: frame,
                normalizedOrigin: normalizedOrigin,
                restoreToFloating: restoreToFloating,
                source: source
            )
        default:
            return event
        }
    }

    private static func normalizeVisibility(_ event: WMEvent, existingEntry: WindowState?) -> WMEvent {
        switch event {
        case let .hiddenStateChanged(token, workspaceId, monitorId, hiddenState, source):
            return .hiddenStateChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                hiddenState: hiddenState,
                source: source
            )
        case let .nativeFullscreenTransition(token, workspaceId, monitorId, change, source):
            return .nativeFullscreenTransition(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                change: change,
                source: source
            )
        case let .managedReplacementMetadataChanged(token, workspaceId, monitorId, metadata, source):
            return .managedReplacementMetadataChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                metadata: metadata,
                source: source
            )
        default:
            return event
        }
    }

    private static func normalizeReason(_ reason: String?) -> String? {
        guard let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func normalizeDisplays(_ displays: [DisplayFingerprint]) -> [DisplayFingerprint] {
        Array(Set(displays)).sorted { lhs, rhs in
            if lhs.anchorPoint.y != rhs.anchorPoint.y {
                return lhs.anchorPoint.y < rhs.anchorPoint.y
            }
            if lhs.anchorPoint.x != rhs.anchorPoint.x {
                return lhs.anchorPoint.x < rhs.anchorPoint.x
            }
            if lhs.name != rhs.name {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.displayId < rhs.displayId
        }
    }

    private static func normalizeLease(_ lease: FocusPolicyLease?) -> FocusPolicyLease? {
        guard let lease else { return nil }
        return FocusPolicyLease(
            owner: lease.owner,
            reason: normalizeReason(lease.reason) ?? lease.reason,
            suppressesFocusFollowsMouse: lease.suppressesFocusFollowsMouse,
            expiresAt: lease.expiresAt
        )
    }

    private static func normalizedTopology(_ displays: [DisplayFingerprint], source: WMEventSource) -> WMEvent {
        .topologyChanged(displays: normalizeDisplays(displays), source: source)
    }

    private static func normalizedFocusLease(_ lease: FocusPolicyLease?, source: WMEventSource) -> WMEvent {
        .focusLeaseChanged(lease: normalizeLease(lease), source: source)
    }
}
