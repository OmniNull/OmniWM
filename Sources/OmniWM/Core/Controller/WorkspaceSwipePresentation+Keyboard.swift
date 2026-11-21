// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceSwipePresentation {
    func pendingSwitchTarget(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        guard let flight = flights[monitorId], !flight.committing, flight.motion.target == 1 else { return nil }
        return flight.destination.id
    }

    func animateSwitch(
        to targetId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        isNext explicitIsNext: Bool?
    ) -> Bool {
        guard let controller, canAnimateSwitch(to: targetId, on: monitorId),
              let monitor = controller.workspaceManager.monitor(byId: monitorId)
        else { return false }
        let preview = previewSurface(controller, for: monitorId)
        guard preview.hasCaptureAccess() else { return false }
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
        if let predecessor,
           let handled = handOff(from: predecessor, into: preparation, toward: destination, using: preview)
        {
            return handled
        }
        let now = mediaTimeProvider()
        let flight = Flight(
            preparation: preparation, destination: destination,
            axis: controller.workspaceManager.descriptor(for: sourceId)
                .flatMap { controller.mouseEventHandler.workspaceSwipeAxis(for: $0, on: monitor) }
                ?? controller.settings.gestures.workspaceSwipeAxis,
            cumulative: 1, isNext: isNext, timestamp: now, recognitionMovement: nil
        )
        flight.isKeyboard = true
        guard participantsAreCurrent(flight) else {
            if predecessor != nil { preview.stop() }
            trace("keyboard-fallback-participants")
            return false
        }
        guard predecessor != nil || showKeyboardPreview(preview, for: flight) else {
            trace("keyboard-fallback-preview-unavailable")
            return false
        }
        return launch(flight, after: predecessor, at: now)
    }

    private func canAnimateSwitch(to targetId: WorkspaceDescriptor.ID, on monitorId: Monitor.ID) -> Bool {
        guard let controller, controller.motionPolicy.animationsEnabled, !controller.isOverviewOpen(),
              controller.workspaceManager.monitor(for: targetId)?.id == monitorId
        else { return false }
        guard let gesture = flight, gesture.preparation.monitor.id == monitorId else { return true }
        return gesture.motion.target != nil
    }

    private func showKeyboardPreview(_ preview: WorkspaceSwipePreview, for flight: Flight) -> Bool {
        let preparation = flight.preparation
        preview.prepare(
            source: preparation.source.items, destination: flight.destination.items,
            monitor: preparation.monitor, workingFrame: preparation.frame
        )
        return preview.begin(
            source: preparation.source.items, destination: flight.destination.items,
            monitor: preparation.monitor, workingFrame: preparation.frame
        )
    }

    private func launch(_ flight: Flight, after predecessor: Flight?, at now: TimeInterval) -> Bool {
        guard let controller else { return false }
        install(flight, after: predecessor, tracksGesture: false)
        flight.motion.animateToDestination(startTime: now, motion: controller.motionPolicy.snapshot())
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
