// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

/// Slides between workspaces for a keyboard or command switch, with the spring that moves the view
/// when focus changes between windows. The switch commits at once, so focus and further switches
/// don't wait for the slide, and the preview stays up until both the slide and window placement finish.
extension WorkspaceSwipePresentation {
    /// Where a released swipe still settling will land, so a relative switch made meanwhile steps on
    /// from there rather than from the workspace it is leaving.
    func pendingSwitchTarget(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        guard let flight = flights[monitorId], !flight.committing, flight.motion.target == 1 else { return nil }
        return flight.destination.id
    }

    /// Switches to `targetId` on `monitorId` and slides over to it. Returns false, having changed
    /// nothing, when it can't animate (animations off, a finger on the trackpad, previews of the
    /// destination not captured yet); the caller then switches instantly.
    func animateSwitch(to targetId: WorkspaceDescriptor.ID, on monitorId: Monitor.ID, isNext explicitIsNext: Bool?) -> Bool {
        guard let controller, controller.motionPolicy.animationsEnabled, !controller.isOverviewOpen(),
              let monitor = controller.workspaceManager.monitor(byId: monitorId),
              controller.workspaceManager.monitor(for: targetId)?.id == monitorId
        else { return false }
        if let gesture = flight, gesture.preparation.monitor.id == monitorId, gesture.motion.target == nil {
            return false
        }
        let existing = flights[monitorId]
        let predecessor = existing.flatMap { $0.committing || $0.motion.target == 1 ? $0 : nil }
        if let existing, predecessor == nil { cancel(existing, reason: "keyboard") }

        guard let sourceId = predecessor?.destination.id
            ?? controller.workspaceManager.activeWorkspaceOrFirst(on: monitorId)?.id,
            sourceId != targetId,
            let source = predecessor?.destination ?? makeWorkspace(sourceId, monitor: monitor, active: true),
            let destination = makeWorkspace(targetId, monitor: monitor, active: false)
        else {
            return predecessor.map { fallBackWithoutAnimation(from: $0) } ?? false
        }
        let isNext = explicitIsNext ?? isAfter(targetId, sourceId, on: monitorId)
        let preparation = Preparation(
            monitor: monitor, frame: monitor.visibleFrame, source: source,
            previous: isNext ? nil : destination, next: isNext ? destination : nil
        )
        let preview = previewSurface(controller, for: monitorId)
        if let predecessor,
           let handled = handOff(from: predecessor, into: preparation, toward: destination, using: preview)
        {
            return handled
        }
        let now = mediaTimeProvider()
        let flight = Flight(
            preparation: preparation, destination: destination,
            axis: controller.settings.gestures.effectiveWorkspaceSwipeAxis,
            cumulative: 1, isNext: isNext, timestamp: now, recognitionMovement: nil
        )
        flight.isKeyboard = true
        guard participantsAreCurrent(flight) else {
            if predecessor != nil { preview.stop() }
            trace("keyboard-fallback-participants")
            return false
        }
        if predecessor == nil {
            preview.prepare(
                source: source.items, destination: destination.items,
                monitor: monitor, workingFrame: preparation.frame
            )
            guard show(preview, for: flight) else {
                trace("keyboard-fallback-preview-unavailable")
                return false
            }
        }
        install(flight, after: predecessor, tracksGesture: false)
        flight.motion.animateToDestination(
            startTime: now, config: controller.motionPolicy.snapshot().scaled(.niriHorizontalViewMovement)
        )
        flight.phase = .settling
        guard activateDisplayLink(for: flight) else {
            cancel(flight, reason: "display-link-unavailable")
            return false
        }
        controller.surfaceReconciler.reconcileNow()
        present(flight, at: now)
        commit(flight)
        guard isCurrent(flight), flight.committing else { return false }
        prefetchChainTargets(after: flight)
        return true
    }

    func finishKeyboardMotion(_ flight: Flight) {
        flight.motionFinished = true
        if let reason = flight.deferredFinishReason {
            cancel(flight, reason: reason)
        } else {
            refreshController?.stopDisplayLinkIfIdle(for: flight.preparation.monitor.displayId)
        }
    }

    private func isAfter(
        _ targetId: WorkspaceDescriptor.ID, _ sourceId: WorkspaceDescriptor.ID, on monitorId: Monitor.ID
    ) -> Bool {
        guard let ordered = controller?.workspaceManager.workspaces(on: monitorId),
              let target = ordered.firstIndex(where: { $0.id == targetId }),
              let source = ordered.firstIndex(where: { $0.id == sourceId })
        else { return true }
        return target > source
    }
}
