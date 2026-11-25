// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension DwindleLayoutHandler {
    func replaceTree(_ request: DwindleTreeRequest, seed: Hasher) -> DwindleTreeReplacement {
        guard let controller, let engine = controller.dwindleEngine else { return .refused(.wrongWorkspace) }
        let manager = controller.workspaceManager
        guard let workspace = controller.interactionWorkspaceProjection().workspace,
              workspace.id == request.workspaceId, manager.activeLayoutKind(for: workspace.id) == .dwindle,
              let monitor = manager.monitor(for: workspace.id)
        else { return .refused(.wrongWorkspace) }
        if let refusal = liveTreeRefusal(
            request,
            seed: seed,
            engine: engine,
            workspaceId: workspace.id,
            monitor: monitor
        ) {
            return .refused(refusal)
        }
        let state = engine.existingState(for: workspace.id)
        guard !request.nodes.isEmpty else {
            guard request.members.isEmpty, state?.leafByToken.isEmpty ?? true else { return .refused(.membership) }
            guard state?.preselection != request.preselection else { return .unchanged }
            commitReplacement(in: workspace.id, engine: engine) {
                engine.setPreselection(request.preselection, in: workspace.id)
            }
            return .replaced
        }
        guard let state else { return .refused(request.members.isEmpty ? .invalid : .membership) }
        let focused = manager.selectedManagedToken
        guard let candidate = engine.replacementSnapshot(
            request, state: state, selected: engine.selectedNode(in: workspace.id)?.windowToken, focused: focused
        ) else { return .refused(.invalid) }
        guard state.preselection != request.preselection || !candidate.matches(state.root) else { return .unchanged }
        if let refusal = memberRefusal(request, state: state, workspaceId: workspace.id, engine: engine)
            ?? focusRefusal(candidate, state: state, focused: focused)
            ?? fitRefusal(candidate, engine: engine, monitor: monitor)
        {
            return .refused(refusal)
        }
        let now = controller.animationClock.now()
        commitReplacement(in: workspace.id, engine: engine) {
            engine.restoreLayoutSnapshot(candidate, in: workspace.id, at: now)
        }
        return .replaced
    }

    private func commitReplacement(
        in workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine,
        _ change: () -> Void
    ) {
        guard let controller else { return }
        let focused = controller.workspaceManager.selectedManagedToken
        controller.workspaceManager.recordLayoutOperation(.treeReplaced, in: workspaceId) {
            let before = engine.layoutSnapshot(in: workspaceId, focused: focused)
            change()
            engine.recordLayoutChange(in: workspaceId, since: before)
        }
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
    }

    private func liveTreeRefusal(
        _ request: DwindleTreeRequest,
        seed: Hasher,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> DwindleTreeRefusal? {
        guard let controller else { return .busy }
        let manager = controller.workspaceManager
        guard engine.interactiveResize == nil, engine.interactiveMove == nil,
              controller.layoutRefreshController.workspaceSwipe.flights[monitor.id] == nil
        else { return .busy }
        switch manager.dwindleTreeAccess(for: workspaceId) {
        case .unavailable: return .busy
        case .tooLarge: return .invalid
        case .ready: break
        }
        let windows = manager.windowQueries
        let live = engine.readTree(
            in: workspaceId, hasher: seed, admission: { windows.tiledAdmission(of: $0, in: workspaceId) },
            split: { _, _ in true }, leaf: { _, _ in true }
        )
        guard case let .read(_, revision) = live else { return .busy }
        return revision == request.revision ? nil : .staleRevision
    }

    private func memberRefusal(
        _ request: DwindleTreeRequest,
        state: DwindleWorkspaceState,
        workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine
    ) -> DwindleTreeRefusal? {
        guard let manager = controller?.workspaceManager else { return .busy }
        var seen = Set<WindowToken>(minimumCapacity: request.members.count)
        for token in request.members {
            guard let entry = manager.entry(for: token) else { return .unknownWindow }
            guard entry.workspaceId == workspaceId, entry.mode == .tiling, state.leafByToken[token] != nil,
                  seen.insert(token).inserted
            else { return .membership }
            if state.excludedTokens.contains(token) || engine.isWindowFullscreen(token, in: workspaceId)
                || manager.scratchpadIndex(for: token) != nil || entry.layoutReason != .standard
                || manager.nativeFullscreenRecord(for: token) != nil || manager.isWindowSuppressedByMacOS(entry)
                || manager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
            {
                return .ineligible
            }
        }
        return seen.count == state.leafByToken.count ? nil : .membership
    }

    private func focusRefusal(
        _ candidate: borrowing DwindleLayoutSnapshot,
        state: DwindleWorkspaceState,
        focused: WindowToken?
    ) -> DwindleTreeRefusal? {
        let pending = controller?.workspaceManager.focusSessionSnapshot.pendingManagedFocus.token
        for token in [focused, pending].compactMap(\.self) where state.leafByToken[token] != nil {
            guard isActive(token, in: candidate) else { return .focusConflict }
        }
        return nil
    }

    private func fitRefusal(
        _ candidate: borrowing DwindleLayoutSnapshot,
        engine: DwindleLayoutEngine,
        monitor: Monitor
    ) -> DwindleTreeRefusal? {
        guard let controller else { return .busy }
        let refresh = controller.layoutRefreshController
        let frames = refresh.buildMonitorSnapshot(for: monitor)
        let bounds = (
            workArea: frames.workingFrame.size,
            cappedAxes: monitor.neighborAxes(among: controller.workspaceManager.monitors)
        )
        let probe = DwindleLayoutEngine()
        probe.tabRailWidth = engine.tabRailWidth
        for member in candidate.members {
            probe.updateWindowConstraints(
                for: member.token, constraints: refresh.cachedLayoutConstraints(for: member.token, bounds: bounds)
            )
        }
        let settings = controller.resolvedDwindleSettings(for: monitor)
        let minimum = probe.computeProjectedMinSizeForSubtree(
            probe.detachedReplacementRoot(candidate), boundaryEdges: .all, excludedTokens: [],
            innerGap: settings.innerGap
        )
        let area = candidate.nodes.count == 1 && settings.singleWindowFit.usesFullscreenLayoutFrame
            ? frames.borderSafeFillFrame.size : bounds.workArea
        return minimum.width <= area.width && minimum.height <= area.height ? nil : .doesNotFit
    }

    private func isActive(_ token: WindowToken, in candidate: borrowing DwindleLayoutSnapshot) -> Bool {
        for node in candidate.nodes where node.orientation == nil {
            for index in node.members where candidate.members[index].token == token {
                return node.active == token
            }
        }
        return false
    }
}
