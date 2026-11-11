// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct ScratchpadAdmission: Equatable {
    let index: ScratchpadIndex
    let fallbackMode: TrackedWindowMode

    func replacementMode(for admission: WindowAdmission) -> TrackedWindowMode {
        admission.readOnlyFrame == nil ? fallbackMode : .floating
    }
}

enum ScratchpadJoinArrival: Equatable {
    case quiet(previousFocusToken: WindowToken?)
    case focused
}

struct ScratchpadParkAdmission {
    let observedFrame: CGRect?
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
        appFullscreen: Bool,
        arrival: ScratchpadJoinArrival
    ) {
        if appFullscreen {
            _ = workspaceManager.markNativeFullscreenSuspended(token, ownsNativeFocus: false)
        }
        guard !ensureScratchpadMembership(
            token,
            in: admission.index,
            observedFrame: observedFrame,
            allowLiveFrameFallback: false,
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

    func reissueScratchpadAdmissionPark(_ token: WindowToken) {
        guard let entry = workspaceManager.entry(for: token),
              let index = workspaceManager.scratchpadIndex(for: token),
              workspaceManager.revealedScratchpadIndex() != index,
              workspaceManager.hiddenState(for: token)?.isScratchpad == true,
              let monitor = workspaceManager.monitor(for: entry.workspaceId) ?? monitorForInteraction()
        else {
            return
        }
        _ = parkScratchpadWindow(
            entry,
            monitor: monitor,
            captureGeometry: false,
            admission: ScratchpadParkAdmission(observedFrame: nil)
        )
    }

    @discardableResult
    func ensureScratchpadMembership(
        _ token: WindowToken,
        in index: ScratchpadIndex,
        observedFrame: CGRect? = nil,
        allowLiveFrameFallback: Bool = true,
        arrival: ScratchpadJoinArrival = .quiet(previousFocusToken: nil)
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token),
              entry.target.hostedMetadata?.role.parent == nil
        else {
            return false
        }
        let previousIndex = workspaceManager.scratchpadIndex(for: token)
        if previousIndex == index { return true }

        let previousOverride = workspaceManager.manualLayoutOverride(for: token)
        let wasParked = workspaceManager.hiddenState(for: token)?.isScratchpad == true
        let transitionedFromTiling = entry.mode == .tiling
        guard prepareWindowForScratchpadAssignment(
            token,
            preferredMonitor: workspaceManager.monitor(for: entry.workspaceId),
            observedFrame: observedFrame,
            allowLiveFrameFallback: allowLiveFrameFallback
        ) else {
            return false
        }
        if workspaceManager.setScratchpadMembership(token, to: index) {
            requestWorkspaceBarRefresh()
        }
        guard let joinedEntry = workspaceManager.entry(for: token),
              presentJoinedScratchpadWindow(
                  joinedEntry,
                  in: index,
                  wasParked: wasParked,
                  parkAdmission: allowLiveFrameFallback ? nil : ScratchpadParkAdmission(observedFrame: observedFrame),
                  arrival: arrival
              )
        else {
            rollBackScratchpadJoin(
                token,
                previousIndex: previousIndex,
                previousOverride: previousOverride,
                restoresTiling: transitionedFromTiling
            )
            return false
        }

        if transitionedFromTiling {
            layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [workspaceManager.workspace(for: token) ?? joinedEntry.workspaceId]
            )
        }
        return true
    }

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

    private func rollBackScratchpadJoin(
        _ token: WindowToken,
        previousIndex: ScratchpadIndex?,
        previousOverride: ManualWindowOverride?,
        restoresTiling: Bool
    ) {
        if let previousIndex {
            if workspaceManager.setScratchpadMembership(token, to: previousIndex) {
                requestWorkspaceBarRefresh()
            }
        } else {
            cleanupScratchpadWindowResources(for: token)
        }
        workspaceManager.setManualLayoutOverride(previousOverride, for: token)
        guard restoresTiling,
              transitionWindowMode(for: token, to: .tiling, allowLiveFrameFallback: false),
              let workspaceId = workspaceManager.workspace(for: token)
        else {
            return
        }
        layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
    }

    private func presentJoinedScratchpadWindow(
        _ entry: WindowState,
        in index: ScratchpadIndex,
        wasParked: Bool,
        parkAdmission: ScratchpadParkAdmission?,
        arrival: ScratchpadJoinArrival
    ) -> Bool {
        let isRevealed = workspaceManager.revealedScratchpadIndex() == index
        if wasParked {
            if isRevealed {
                showJoinedScratchpadWindow(entry, in: index)
            }
            return true
        }
        guard !isRevealed else { return true }
        return settleJoinedScratchpadWindow(entry, in: index, parkAdmission: parkAdmission, arrival: arrival)
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
        parkAdmission: ScratchpadParkAdmission?,
        arrival: ScratchpadJoinArrival
    ) -> Bool {
        let monitor = workspaceManager.monitor(for: entry.workspaceId) ?? monitorForInteraction()
        if arrival == .focused,
           revealScratchpadWindow(entry.token, index: index, on: monitor?.id) == .executed
        {
            return true
        }
        guard let monitor else { return false }

        let workspaceId = workspaceManager.workspace(for: entry.token) ?? entry.workspaceId
        let holdsFocus = workspaceManager.selectedManagedToken == entry.token
            || workspaceManager.pendingFocusedToken == entry.token
            || workspaceManager.nativeManagedFocusToken == entry.token
        guard parkScratchpadWindow(entry, monitor: monitor, captureGeometry: false, admission: parkAdmission) else {
            return false
        }
        requestWorkspaceBarRefresh()
        guard holdsFocus else { return true }

        workspaceManager.clearWorkspaceFocus(in: workspaceId)
        if case let .quiet(previousFocusToken?) = arrival,
           canRestoreFocusAfterScratchpadJoin(previousFocusToken, joinedToken: entry.token)
        {
            focusWindow(previousFocusToken)
            return true
        }
        recoverFocusAfterScratchpadHide(in: workspaceId, excluding: [entry.token], on: monitor.id)
        return true
    }

    private func canRestoreFocusAfterScratchpadJoin(_ token: WindowToken, joinedToken: WindowToken) -> Bool {
        guard token != joinedToken, isManagedWindowDisplayable(token) else { return false }
        guard let index = workspaceManager.scratchpadIndex(for: token) else { return true }
        return workspaceManager.revealedScratchpadIndex() == index
    }
}
