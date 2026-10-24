// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceSwipePresentation {
    func handOff(
        from predecessor: Flight, into preparation: Preparation, toward destination: Workspace,
        using preview: WorkspaceSwipePreview
    ) -> Bool? {
        guard preview.replace(
            source: preparation.source.items,
            destination: destination.items,
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        ) else {
            trace("chain-refused-preview")
            return true
        }
        if !predecessor.committing { commit(predecessor) }
        guard isCurrent(predecessor), predecessor.committing else { return false }
        cancel(predecessor, reason: "chained", keepingPreview: true)
        return nil
    }

    func prefetchChainTargets(after flight: Flight) {
        let preparation = flight.preparation
        guard flight.motion.target == 1,
              let preview = previews[preparation.monitor.id],
              let next = makePreparation(monitorId: preparation.monitor.id, chainedSource: flight.destination)
        else { return }
        preview.prefetch(
            shown: preparation.source.items + flight.destination.items,
            upcoming: (next.previous?.items ?? []) + (next.next?.items ?? []),
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        )
    }

    func noteSwitchWithoutPresentation() {
        latestSerial += 1
    }

    func createdDestination(isNext: Bool, from preparation: Preparation) -> Workspace? {
        guard let controller, isNext,
              let created = controller.workspaceNavigationHandler.swipeTargetWorkspace(
                  isNext: true, from: preparation.source.id, on: preparation.monitor.id, createIfNeeded: true
              )
        else { return nil }
        return makeWorkspace(created.id, monitor: preparation.monitor, active: false)
    }
}
