// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct ScratchpadAdmission: Equatable {
    let index: ScratchpadIndex
    let fallbackMode: TrackedWindowMode
}

enum ScratchpadJoinArrival: Equatable {
    case quiet(previousFocusToken: WindowToken?)
    case focused
}

extension WMController {
    func scratchpadDestination(for evaluation: WindowDecisionEvaluation) -> ScratchpadIndex? {
        guard let index = evaluation.decision.admissionHints.scratchpad else { return nil }
        guard shouldInheritTrackedParentWorkspace(for: evaluation),
              let parentId = evaluation.facts.windowServer?.parentId,
              let parent = workspaceManager.entry(forWindowId: Int(parentId))
        else {
            return index
        }
        return workspaceManager.scratchpadIndex(for: parent.token)
    }

    func scratchpadAdmission(
        for evaluation: WindowDecisionEvaluation,
        requestedMode: TrackedWindowMode
    ) -> ScratchpadAdmission? {
        scratchpadDestination(for: evaluation).map { ScratchpadAdmission(index: $0, fallbackMode: requestedMode) }
    }

    func joinScratchpadOnAdmission(
        _ token: WindowToken,
        _ admission: ScratchpadAdmission,
        observedFrame: CGRect?,
        arrival: ScratchpadJoinArrival
    ) {
        guard !ensureScratchpadMembership(
            token,
            in: admission.index,
            observedFrame: observedFrame,
            readsLiveFrame: false,
            arrival: arrival
        ) else {
            return
        }
        _ = transitionWindowMode(
            for: token,
            to: admission.fallbackMode,
            observedFrame: observedFrame,
            allowLiveFrameFallback: false
        )
    }

    @discardableResult
    func ensureScratchpadMembership(
        _ token: WindowToken,
        in index: ScratchpadIndex,
        observedFrame: CGRect? = nil,
        readsLiveFrame: Bool = true,
        arrival: ScratchpadJoinArrival = .quiet(previousFocusToken: nil),
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token),
              entry.target.hostedMetadata?.role.parent == nil
        else {
            return false
        }
        if workspaceManager.scratchpadIndex(for: token) == index { return true }

        let wasParked = workspaceManager.hiddenState(for: token)?.isScratchpad == true
        let transitionedFromTiling = entry.mode == .tiling
        guard prepareWindowForScratchpadAssignment(
            token,
            preferredMonitor: workspaceManager.monitor(for: entry.workspaceId),
            observedFrame: observedFrame,
            readsLiveFrame: readsLiveFrame
        ) else {
            return false
        }
        if workspaceManager.setScratchpadMembership(token, to: index) {
            requestWorkspaceBarRefresh()
        }
        guard let joinedEntry = workspaceManager.entry(for: token) else {
            cleanupScratchpadWindowResources(for: token)
            return false
        }
        presentJoinedScratchpadWindow(
            joinedEntry,
            in: index,
            wasParked: wasParked,
            arrival: arrival,
            focusOrigin: focusOrigin
        )

        if transitionedFromTiling {
            layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [workspaceManager.workspace(for: token) ?? joinedEntry.workspaceId]
            )
        }
        return true
    }

    @discardableResult
    func releaseScratchpadMemberForWorkspaceDestination(
        _ token: WindowToken,
        decision: WindowDecision
    ) -> Bool {
        guard decision.workspaceName != nil,
              decision.admissionHints.scratchpad == nil,
              workspaceManager.scratchpadIndex(for: token) != nil,
              let entry = workspaceManager.entry(for: token)
        else {
            return false
        }
        let wasParked = workspaceManager.hiddenState(for: token)?.isScratchpad == true
        cleanupScratchpadWindowResources(for: token)
        workspaceManager.setManualLayoutOverride(nil, for: token)
        guard wasParked else { return true }

        workspaceManager.setHiddenState(nil, for: token)
        guard !workspaceManager.isWindowSuppressedByMacOS(token),
              let frame = workspaceManager.resolvedFloatingFrame(
                  for: token,
                  preferredMonitor: workspaceManager.monitor(for: entry.workspaceId)
              )
        else {
            return true
        }
        if let axRef = entry.axRef {
            axManager.forceApplyNextFrame(for: entry.windowId)
            axManager.applyFramesParallel([.init(pid: entry.pid, window: axRef, frame: frame)])
        } else {
            shellAppWindowManager.setFrame(frame, for: token)
            shellAppWindowManager.setHidden(false, for: token)
        }
        return true
    }

    private func presentJoinedScratchpadWindow(
        _ entry: WindowState,
        in index: ScratchpadIndex,
        wasParked: Bool,
        arrival: ScratchpadJoinArrival,
        focusOrigin: ManagedFocusOrigin
    ) {
        let isRevealed = workspaceManager.revealedScratchpadIndex() == index
        if wasParked, isRevealed {
            showJoinedScratchpadWindow(entry, in: index)
        } else if !wasParked, !isRevealed {
            settleJoinedScratchpadWindow(entry, in: index, arrival: arrival, focusOrigin: focusOrigin)
        }
    }

    private func showJoinedScratchpadWindow(_ entry: WindowState, in index: ScratchpadIndex) {
        let visibleSibling = scratchpadEntries(in: index).first { sibling in
            sibling.token != entry.token && workspaceManager.hiddenState(for: sibling.token) == nil
        }
        guard let workspaceId = visibleSibling?.workspaceId ?? scratchpadTarget()?.workspaceId,
              let monitor = workspaceManager.monitor(for: workspaceId)
        else {
            return
        }
        if entry.workspaceId != workspaceId {
            reassignManagedWindow(entry.token, to: workspaceId)
        }
        _ = showScratchpadWindow(entry, on: workspaceId, monitor: monitor)
    }

    private func settleJoinedScratchpadWindow(
        _ entry: WindowState,
        in index: ScratchpadIndex,
        arrival: ScratchpadJoinArrival,
        focusOrigin: ManagedFocusOrigin
    ) {
        let monitor = workspaceManager.monitor(for: entry.workspaceId) ?? monitorForInteraction()
        if arrival == .focused,
           revealScratchpadWindow(entry.token, index: index, on: monitor?.id, focusOrigin: focusOrigin) == .executed
        {
            return
        }
        guard let monitor else { return }

        let workspaceId = workspaceManager.workspace(for: entry.token) ?? entry.workspaceId
        let holdsFocus = workspaceManager.selectedManagedToken == entry.token
            || workspaceManager.pendingFocusedToken == entry.token
            || workspaceManager.nativeManagedFocusToken == entry.token
        _ = parkScratchpadWindow(entry, monitor: monitor, captureGeometry: false)
        requestWorkspaceBarRefresh()
        guard holdsFocus else { return }

        workspaceManager.clearWorkspaceFocus(in: workspaceId)
        if case let .quiet(previousFocusToken?) = arrival,
           canRestoreFocusAfterScratchpadJoin(previousFocusToken, joinedToken: entry.token)
        {
            focusWindow(previousFocusToken, origin: focusOrigin)
            return
        }
        recoverFocusAfterScratchpadHide(
            in: workspaceId,
            excluding: [entry.token],
            on: monitor.id,
            focusOrigin: focusOrigin
        )
    }

    private func canRestoreFocusAfterScratchpadJoin(_ token: WindowToken, joinedToken: WindowToken) -> Bool {
        guard token != joinedToken, isManagedWindowDisplayable(token) else { return false }
        guard let index = workspaceManager.scratchpadIndex(for: token) else { return true }
        return workspaceManager.revealedScratchpadIndex() == index
    }
}
