// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceSwipePresentation {
    func warmPreviews() {
        guard flight == nil, preparation == nil,
              let controller, controller.hasStartedServices,
              controller.motionPolicy.animationsEnabled, controller.settings.gestures.workspaceSwipeEnabled,
              !controller.isOverviewOpen(),
              let monitor = controller.monitorForInteraction(),
              let preparation = makePreparation(monitorId: monitor.id)
        else { return }
        previewSurface(controller).warm(
            source: preparation.source.items,
            destination: (preparation.previous?.items ?? []) + (preparation.next?.items ?? []),
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        )
    }

    func handleInvalidation(workspaceId: WorkspaceDescriptor.ID?, domains: InvalidationDomain) {
        guard let flight else { return }
        if flight.committing {
            if !participantsAreCurrent(flight) { cancel(reason: "commit-superseded") }
        } else if !domains.isDisjoint(with: .layoutCommit),
                  workspaceId == nil || workspaceId == flight.preparation.source.id || workspaceId == flight.destination
                  .id
        {
            cancel(reason: "world-invalidated")
        }
    }

    func makePreparation(monitorId: Monitor.ID) -> Preparation? {
        guard let controller, let monitor = controller.workspaceManager.monitor(byId: monitorId),
              let current = controller.workspaceManager.activeWorkspaceOrFirst(on: monitorId),
              let source = makeWorkspace(current.id, monitor: monitor, active: true)
        else { return nil }
        let wm = controller.workspaceManager
        let skipEmpty = controller.workspaceNavigationHandler.skipsEmptyWorkspaces(on: monitorId)
        let previous = wm.previousWorkspaceInOrder(
            on: monitorId,
            from: current.id,
            wrapAround: true,
            skipEmpty: skipEmpty
        )
        .flatMap { makeWorkspace($0.id, monitor: monitor, active: false) }
        let next = wm.nextWorkspaceInOrder(on: monitorId, from: current.id, wrapAround: true, skipEmpty: skipEmpty)
            .flatMap { makeWorkspace($0.id, monitor: monitor, active: false) }
        return Preparation(
            monitor: monitor,
            frame: monitor.visibleFrame,
            source: source,
            previous: previous,
            next: next
        )
    }

    private func makeWorkspace(_ id: WorkspaceDescriptor.ID, monitor: Monitor, active: Bool) -> Workspace? {
        guard let controller, let refreshController else { return nil }
        let entries = controller.workspaceManager.entries(in: id).filter {
            !controller.workspaceManager.isWindowSuppressedByMacOS($0.token)
        }
        guard entries.allSatisfy({ $0.layoutReason == .standard }) else { return nil }
        let frames: [WindowToken: CGRect] = controller.workspaceManager.withEngineMutationScope {
            if controller.workspaceManager.activeLayoutKind(for: id) == .niri {
                return refreshController.niriHandler.settledFrames(in: id, visibleOnly: true) ?? [:]
            }
            guard let engine = controller.dwindleEngine,
                  let snapshot = refreshController.dwindleHandler.makeWorkspaceSnapshot(
                      workspaceId: id, monitor: monitor, resolveConstraints: false, isActiveWorkspace: active
                  ) else { return [:] }
            let plan = refreshController.dwindleHandler.buildOnDemandLayoutPlan(snapshot: snapshot, engine: engine)
            return Dictionary(
                plan.diff.frameChanges.map { ($0.token, $0.frame) },
                uniquingKeysWith: { _, last in last }
            )
        }
        var items: [WorkspaceSwipePreview.Item] = []
        for entry in entries {
            guard let handle = controller.workspaceManager.handle(for: entry.token) else { return nil }
            let frame: CGRect?
            if entry.mode == .floating {
                frame = active ? controller.liveFrame(for: entry)
                    : controller.workspaceManager.resolvedFloatingFrame(for: entry.token, preferredMonitor: monitor)
            } else if let projected = frames[entry.token] {
                frame = active ? (controller.liveFrame(for: entry) ?? projected) : projected
            } else {
                continue
            }
            guard let frame, !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { return nil }
            if frame.intersects(monitor.visibleFrame) { items.append(.init(handle: handle, frame: frame)) }
        }
        return Workspace(id: id, items: items)
    }

    func participantsAreCurrent(_ flight: Flight) -> Bool {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(byId: flight.preparation.monitor.id),
              monitor.frame == flight.preparation.monitor.frame,
              monitor.visibleFrame == flight.preparation.monitor.visibleFrame,
              !controller.isOverviewOpen(),
              let activeId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              activeId == (flight.committing ? flight.destination.id : flight.preparation.source.id)
              || (flight.phase == .committing && activeId == flight.preparation.source.id)
        else { return false }
        for workspace in [flight.preparation.source, flight.destination] {
            guard controller.workspaceManager.monitor(for: workspace.id)?.id == monitor.id else { return false }
            for item in workspace.items {
                guard item.handle.token == item.token,
                      let entry = controller.workspaceManager.entry(for: item.handle),
                      entry.workspaceId == workspace.id, entry.layoutReason == .standard,
                      !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token)
                else { return false }
            }
        }
        return true
    }
}
