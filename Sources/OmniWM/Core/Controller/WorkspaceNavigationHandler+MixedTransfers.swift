// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceNavigationHandler {
    private struct MixedWindowTransferResult {
        var firstMoved: WindowToken?
        var selectedMoved: WindowToken?
        var sourceFocus: WindowToken?
    }

    func transferMixedWindow(
        _ token: WindowToken,
        from source: WorkspaceDescriptor.ID,
        to target: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowTransferResult {
        let result = transferMixedWindows(CollectionOfOne(token), from: source, to: target, controller: controller)
        return WindowTransferResult(succeeded: result.firstMoved != nil, newSourceFocusToken: result.sourceFocus)
    }

    func moveMixedWindowsFromBar(
        _ tokens: [WindowToken],
        to target: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> Bool? {
        let manager = controller.workspaceManager
        guard let first = tokens.first, let source = manager.workspace(for: first), source != target,
              manager.activeLayoutKind(for: source) != manager.activeLayoutKind(for: target),
              tokens.allSatisfy({ manager.workspace(for: $0) == source && manager.windowMode(for: $0) == .tiling })
        else { return nil }
        let result = transferMixedWindows(tokens, from: source, to: target, controller: controller)
        guard let firstMoved = result.firstMoved else { return false }
        let selected = result.selectedMoved ?? firstMoved
        let viewport = transferredWindowNiriViewportState(token: selected, workspaceId: target)
        applySessionPatch(workspaceId: target, viewportState: viewport, rememberedFocusToken: selected)
        controller.recoverSourceFocusAfterMove(in: source, preferredToken: result.sourceFocus)
        let follows = result.selectedMoved != nil || controller.settings.focus.followsWindowToMonitor
        finishWorkspaceMove(
            StructuralMutation(
                sourceWorkspaceId: source, destinationWorkspaceId: target,
                selectedHandle: WindowHandle(id: selected),
                scrollWorkspaceId: viewport?.hasPendingOffsetAnimation == true ? target : nil
            ),
            focusPolicy: follows ? .configured : .retainCurrent,
            focusOrigin: .pointerSelection
        )
        return true
    }

    private func transferMixedWindows<Tokens: Collection>(
        _ tokens: Tokens,
        from source: WorkspaceDescriptor.ID,
        to target: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> MixedWindowTransferResult where Tokens.Element == WindowToken {
        guard let niri = controller.niriEngine, let dwindle = controller.dwindleEngine,
              let monitor = controller.workspaceManager.monitor(for: target)
        else { return MixedWindowTransferResult() }
        let manager = controller.workspaceManager
        let selected = manager.selectedManagedToken
        let sourceIsNiri = manager.activeLayoutKind(for: source) == .niri
        let niriId = sourceIsNiri ? source : target
        var result = MixedWindowTransferResult()
        manager.withBatchedCrossWorkspaceDrop(into: target, niriWorkspaceIds: [niriId]) { states in
            guard let capture = controller.mixedLayoutHistoryStart(from: source, to: target) else { return [] }
            let bootstrap = sourceIsNiri ? prepareMixedDwindleTarget(target, on: monitor, controller: controller) : nil
            var state = states[niriId, default: manager.niriViewportState(for: niriId)]
            var assignments: [CrossWorkspaceDropAssignment] = []
            for token in tokens {
                guard let entry = manager.entry(for: token), entry.workspaceId == source, entry.mode == .tiling,
                      entry.target.hostedMetadata?.role.parent == nil, !manager.isWindowSuppressedByMacOS(token),
                      moveMixedToken(token, capture: capture, controller: controller, state: &state)
                else { continue }
                if let bootstrap { calculateMixedDwindleTarget(bootstrap, in: target, engine: dwindle) }
                assignments.append(CrossWorkspaceDropAssignment(token: token, workspaceId: target))
                if result.firstMoved == nil { result.firstMoved = token }
                if token == selected { result.selectedMoved = token }
            }
            states[niriId] = state
            if result.firstMoved != nil {
                controller.recordMixedLayoutTransfer(consume capture)
                result.sourceFocus = sourceIsNiri
                    ? state.selectedNodeId.flatMap { niri.findNode(by: $0, in: source) as? NiriWindow }?.token
                    : dwindle.projectedActiveToken(in: source)
            }
            return assignments
        }
        return result
    }

    private func moveMixedToken(
        _ token: WindowToken,
        capture: borrowing MixedLayoutHistoryCapture,
        controller: WMController,
        state: inout ViewportState
    ) -> Bool {
        guard let niri = controller.niriEngine, let dwindle = controller.dwindleEngine else { return false }
        let manager = controller.workspaceManager
        let niriId = capture.niriWorkspaceId
        let dwindleId = capture.dwindleWorkspaceId
        if let window = niri.findNode(for: token, in: niriId) {
            manager.captureDetachedNiriPlacement(for: token, in: niriId)
            _ = niri.detachWindowForTransfer(window, from: niriId, sourceState: &state)
            dwindle.updateWindowConstraints(for: token, constraints: window.constraints)
            let activeFrame = dwindle.selectedNode(in: dwindleId)?.cachedFrame
                ?? dwindle.root(for: dwindleId)?.descendToFirstLeaf().cachedFrame
            dwindle.attachTransferredTile(
                DwindleTransferredTile(token: token), placement: .defaultPlacement,
                in: dwindleId, activeWindowFrame: activeFrame
            )
        } else {
            guard let monitor = manager.monitor(for: niriId),
                  dwindle.detachForHistoryTransfer(token: token, wholeTile: false, from: dwindleId) != nil
            else { return false }
            let keptSizing = controller.niriLayoutHandler.keptPrimarySpanSizingState(
                for: token, engine: niri, in: niriId,
                geometry: controller.niriSizingGeometry(for: monitor), controller: controller
            )
            let window = niri.addWindow(
                token: token, to: niriId, afterSelection: state.selectedNodeId,
                focusedToken: manager.lastFocusedToken(in: niriId),
                containerSizingState: keptSizing ?? controller.admittedNiriContainerSizing(for: token)
            )
            restoreMixedNiriWindowState(window, engine: niri, controller: controller)
            window.constraints = controller.layoutRefreshController.destinationConstraints(for: token, on: monitor)
            dwindle.releaseConstraintsIfUntracked(token)
        }
        return true
    }

    private func restoreMixedNiriWindowState(
        _ window: NiriWindow,
        engine: NiriLayoutEngine,
        controller: WMController
    ) {
        guard let placement = controller.workspaceManager.restoreIntent(for: window.token)?.niriPlacement,
              !placement.hasColumnPosition
        else { return }
        engine.applyPersistedWindowState(placement.window, to: window)
        if let column = window.parent as? NiriContainer {
            column.displayMode = placement.column.displayMode
            engine.updateTabbedColumnVisibility(column: column)
        }
    }

    private func prepareMixedDwindleTarget(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitor: Monitor,
        controller: WMController
    ) -> LayoutMonitorSnapshot? {
        guard let engine = controller.dwindleEngine else { return nil }
        controller.dwindleLayoutHandler.applyResolvedSettings(
            controller.resolvedDwindleSettings(for: monitor),
            to: engine
        )
        guard !engine.hasCurrentFrames(in: workspaceId) else { return nil }
        let bootstrap = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor)
        if engine.windowCount(in: workspaceId) > 0 {
            calculateMixedDwindleTarget(bootstrap, in: workspaceId, engine: engine)
        }
        return bootstrap
    }

    private func calculateMixedDwindleTarget(
        _ monitor: LayoutMonitorSnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine
    ) {
        _ = engine.calculateLayout(
            for: workspaceId, screen: monitor.workingFrame,
            borderSafeFillScreen: monitor.borderSafeFillFrame, fullscreenScreen: monitor.fullscreenLayoutFrame
        )
    }
}
