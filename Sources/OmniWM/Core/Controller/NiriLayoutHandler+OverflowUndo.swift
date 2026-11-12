// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct UnshownOverflowMessage {
    let message: ColumnModeToastController.Message
    let workspaceId: WorkspaceDescriptor.ID
    let undoneAt: TimeInterval
}

extension NiriLayoutHandler {
    private enum OverflowVerdict {
        case undo(columnId: NodeId, joined: WindowToken?, asked: CGFloat, shown: CGFloat, age: TimeInterval)
        case keep(String)
    }

    func reportSizeTaken(
        pid: pid_t,
        windowId: Int,
        asked: CGRect,
        taken: CGRect,
        expectedWindow: AXWindowRef? = nil
    ) {
        guard let controller,
              controller.settings.niri.macOSFusion,
              let entry = controller.workspaceManager.entry(forPid: pid, windowId: windowId),
              let axRef = entry.axRef,
              expectedWindow.map({ sameAXWindowIdentity(axRef, $0) }) ?? true,
              entry.mode == .tiling,
              entry.layoutReason == .standard,
              entry.hiddenState == nil,
              !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token),
              !controller.isSizeAnimating(entry.token, in: entry.workspaceId),
              let column = controller.niriEngine?.findNode(for: entry.token, in: entry.workspaceId)?
                  .parent as? NiriContainer,
              !column.isTabbed,
              column.windowNodes.count > 1,
              let stacking = stackingExtent(in: entry.workspaceId),
              stacking(taken) > stacking(asked) + AXRecentFrameWriteFailure.maxAcceptedSizeSnap
        else { return }
        overflowReports[entry.token] = layoutStepClock()
        scheduleOverflowCheck()
    }

    func scheduleOverflowCheck() {
        guard !overflowReports.isEmpty, !isOverflowCheckScheduled else { return }
        isOverflowCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isOverflowCheckScheduled = false
                self?.checkOverflowReports()
            }
        }
    }

    func checkOverflowReports() {
        guard let controller, let engine = controller.niriEngine, !isLayoutStepUnderway(engine: engine) else { return }
        let reports = overflowReports.sorted { $0.value < $1.value }
        overflowReports.removeAll()
        var undone: Set<WorkspaceDescriptor.ID> = []
        for (token, reportedAt) in reports {
            guard let workspaceId = controller.workspaceManager.entry(for: token)?.workspaceId,
                  !undone.contains(workspaceId)
            else { continue }
            switch overflowVerdict(for: token, reportedAt: reportedAt, in: workspaceId, engine: engine) {
            case let .keep(reason):
                MouseTrace.record("overflow-kept win=\(token.windowId) \(reason)")
            case let .undo(columnId, joined, asked, shown, age):
                guard stepLayoutHistory(.undo, in: workspaceId, keepingFocus: true) else {
                    MouseTrace.record("overflow-kept win=\(token.windowId) undo-refused")
                    continue
                }
                MouseTrace.record(
                    "overflow-undo win=\(token.windowId) asked=\(Int(asked.rounded())) "
                        + "shown=\(Int(shown.rounded())) age=\(String(format: "%.2f", age))"
                )
                engine.forgetLastRedo(in: workspaceId)
                undone.insert(workspaceId)
                showOverflowMessage(.overflowUndone(columnId: columnId, window: joined), from: workspaceId)
            }
        }
    }

    private func isLayoutStepUnderway(engine: NiriLayoutEngine) -> Bool {
        guard let controller else { return false }
        let mouse = controller.mouseEventHandler.state
        return engine.liveColumnMove != nil
            || engine.liveStackDrop != nil
            || engine.interactiveResize != nil
            || mouse.isResizing
            || mouse.nativeResizeStart?.wasDragged == true
            || controller.layoutRefreshController.isRefreshQueued
    }

    private func overflowVerdict(
        for token: WindowToken,
        reportedAt: TimeInterval,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine
    ) -> OverflowVerdict {
        guard isShownOnADisplay(workspaceId) else { return .keep("rule=not-shown") }
        guard let step = engine.newestLayoutStep(in: workspaceId) else { return .keep("rule=no-newest-step") }
        let age = layoutStepClock() - step.timing.recordedAt
        guard age < MoveConfiguration.overflowUndoWindow, reportedAt >= step.timing.startedAt else {
            return .keep("rule=step-not-recent")
        }
        guard let window = engine.findNode(for: token, in: workspaceId),
              let column = window.parent as? NiriContainer,
              let after = step.after.columns.first(where: { $0.id == column.id })
        else { return .keep("rule=column-changed") }
        let now = engine.layoutSnapshotColumn(column)
        guard now.windows == after.windows, now.displayMode == after.displayMode, now.hasSameHeights(as: after) else {
            return .keep("rule=column-changed")
        }
        guard let before = step.before.columns.first(where: { $0.id == column.id }) else {
            return .keep("rule=column-new")
        }
        let joined = after.windows.filter { !before.windows.contains($0) }
        let stacked = before.displayMode == .tabbed && after.displayMode == .normal
        let resized = before.windows == after.windows && !before.hasSameHeights(as: after)
        guard !joined.isEmpty || stacked || resized else { return .keep("rule=not-put-together") }
        guard let stacking = stackingExtent(in: workspaceId),
              let askedFrame = window.frame,
              let startSize = step.timing.sizesAtStart[token]
        else { return .keep("rule=not-squeezed") }
        let asked = stacking(askedFrame)
        guard asked < stacking(CGRect(origin: .zero, size: startSize)) - 1 else {
            return .keep("rule=not-squeezed")
        }
        guard let controller,
              let axRef = controller.workspaceManager.entry(for: token)?.axRef,
              let shownFrame = controller.mouseEventHandler.nativeWindowFrameProvider(axRef),
              stacking(shownFrame) > asked + AXRecentFrameWriteFailure.maxAcceptedSizeSnap
        else { return .keep("rule=fits-now") }
        return .undo(columnId: column.id, joined: joined.first, asked: asked, shown: stacking(shownFrame), age: age)
    }

    private func stackingExtent(in workspaceId: WorkspaceDescriptor.ID) -> ((CGRect) -> CGFloat)? {
        guard let controller, let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return nil }
        return controller.settings.monitors.effectiveOrientation(for: monitor) == .horizontal ? \.height : \.width
    }

    private func showOverflowMessage(
        _ message: ColumnModeToastController.Message,
        from workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let engine = controller?.niriEngine, let followed = message.followed else { return }
        let shownIn = followed.window.flatMap(engine.workspaceHolding) ?? workspaceId
        unshownOverflowMessage = UnshownOverflowMessage(
            message: message,
            workspaceId: shownIn,
            undoneAt: layoutStepClock()
        )
        followOverflowMessage(in: shownIn)
    }

    func followOverflowMessage(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller, let engine = controller.niriEngine else { return }
        if let unshown = unshownOverflowMessage, unshown.workspaceId == workspaceId {
            guard layoutStepClock() - unshown.undoneAt < MoveConfiguration.overflowUndoWindow else {
                unshownOverflowMessage = nil
                return
            }
            guard !hasPendingNiriAnimationWork(
                      state: controller.workspaceManager.niriViewportState(for: workspaceId),
                      driver: controller.workspaceManager.animationDriver,
                      engine: engine,
                      workspaceId: workspaceId
                  ),
                  let followed = unshown.message.followed,
                  toastFrame(of: overflowMessageColumn(followed, in: workspaceId, engine: engine)) != nil
            else { return }
            unshownOverflowMessage = nil
            showToast(
                unshown.message,
                over: overflowMessageColumn(followed, in: workspaceId, engine: engine),
                in: workspaceId,
                motion: controller.motionPolicy.snapshot()
            )
            return
        }
        guard let message = controller.columnModeToast.message,
              let followed = message.followed,
              controller.columnModeToast.source?.workspaceId == workspaceId
        else { return }
        guard let frame = toastFrame(of: overflowMessageColumn(followed, in: workspaceId, engine: engine)),
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            controller.columnModeToast.hide()
            return
        }
        controller.columnModeToast.move(columnFrame: frame, visibleFrame: monitor.visibleFrame)
    }

    private func overflowMessageColumn(
        _ followed: (columnId: NodeId, window: WindowToken?),
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine
    ) -> NiriContainer? {
        followed.window.flatMap { engine.findNode(for: $0, in: workspaceId)?.parent as? NiriContainer }
            ?? engine.liveColumn(withId: followed.columnId, in: workspaceId)
    }
}
