// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension WorldStore {
    func hostedFamilyEvents(for event: WMEvent, monitors: [Monitor]) -> [WMEvent] {
        let propagates = if case .workspaceAssigned = event {
            true
        } else if case .windowMinimizedChanged = event {
            true
        } else if case .hiddenStateChanged = event {
            true
        } else {
            false
        }
        guard propagates, let root = event.token,
              windows.entry(for: root)?.target.hostedMetadata?.role == .main else { return [] }
        return windows.hostedFamilyTokens(for: root).dropFirst().compactMap { token in
            guard let entry = windows.entry(for: token) else { return nil }
            if case let .workspaceAssigned(_, _, destination, monitorId, source) = event {
                return .workspaceAssigned(
                    token: token, from: entry.workspaceId, to: destination, monitorId: monitorId, source: source
                )
            }
            if case let .windowMinimizedChanged(_, _, minimized, source) = event {
                return .windowMinimizedChanged(
                    token: token, workspaceId: entry.workspaceId, minimized: minimized, source: source
                )
            }
            if case let .hiddenStateChanged(_, _, monitorId, hidden, source) = event {
                return .hiddenStateChanged(
                    token: token, workspaceId: entry.workspaceId, monitorId: monitorId,
                    hiddenState: inheritedHiddenState(hidden, for: entry, monitors: monitors), source: source
                )
            }
            return nil
        }
    }

    func applyHostedFamilyEvents(
        _ events: [WMEvent],
        monitors: [Monitor],
        snapshot: () -> ReconcileSnapshot,
        plan: inout ActionPlan
    ) {
        guard !events.isEmpty else { return }
        let previousFocus = focus
        for event in events {
            guard let token = event.token else { continue }
            applyWindowMutationBeforePlan(event, monitors: monitors)
            guard let entry = windows.entry(for: token) else { continue }
            let normalized = EventNormalizer.normalize(event: event, existingEntry: entry, monitors: monitors)
            let childPlan = StateReducer.reduce(
                event: normalized, existingEntry: entry, currentSnapshot: snapshot(), monitors: monitors
            )
            if let focusSession = childPlan.focusSession { applyFocusSession(focusSession) }
            _ = applyWindowStateAndRefreshRestoreIntent(childPlan, to: token, monitors: monitors)
        }
        if focus != previousFocus { plan.focusSession = focus }
    }

    private func inheritedHiddenState(
        _ hidden: HiddenState?, for entry: WindowState, monitors: [Monitor]
    ) -> HiddenState? {
        guard let hidden else { return nil }
        if let previous = entry.hiddenState {
            return HiddenState(
                proportionalPosition: previous.proportionalPosition,
                referenceMonitorId: previous.referenceMonitorId, reason: hidden.reason
            )
        }
        let frame = entry.floatingState?.lastFrame ?? entry.observedState.frame
        let monitor = frame?.center.monitorApproximation(in: monitors)
            ?? monitors.first { $0.id == hidden.referenceMonitorId }
        let position = if let frame, let monitor {
            HiddenState.proportionalPosition(topLeft: frame.topLeftCorner, in: monitor.frame)
        } else {
            entry.floatingState?.normalizedOrigin ?? hidden.proportionalPosition
        }
        return HiddenState(
            proportionalPosition: position, referenceMonitorId: monitor?.id ?? hidden.referenceMonitorId,
            reason: hidden.reason
        )
    }
}
