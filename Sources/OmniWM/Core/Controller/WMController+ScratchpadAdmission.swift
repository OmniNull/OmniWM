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
    case intoRevealedSlot
}

struct ScratchpadParkAdmission {
    let observedFrame: CGRect?
}

struct ScratchpadMemberRelease {
    let token: WindowToken
    let previousOverride: ManualWindowOverride?
}

extension WMController {
    func scratchpadAdmission(
        for evaluation: WindowDecisionEvaluation,
        requestedMode: TrackedWindowMode
    ) -> ScratchpadAdmission? {
        evaluation.decision.admissionHints.scratchpad.map {
            ScratchpadAdmission(index: $0, fallbackMode: requestedMode)
        }
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
        let previousRevealedIndex = workspaceManager.revealedScratchpadIndex()
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
                previousRevealedIndex: previousRevealedIndex,
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

    func beginScratchpadMemberRelease(
        _ token: WindowToken,
        decision: WindowDecision
    ) -> ScratchpadMemberRelease? {
        guard decision.isResolved,
              let workspaceName = decision.workspaceName,
              workspaceManager.workspaceId(for: workspaceName, createIfMissing: false) != nil,
              decision.admissionHints.scratchpad == nil,
              workspaceManager.scratchpadIndex(for: token) != nil,
              workspaceManager.entry(for: token) != nil
        else {
            return nil
        }
        let release = ScratchpadMemberRelease(
            token: token,
            previousOverride: workspaceManager.manualLayoutOverride(for: token)
        )
        workspaceManager.setManualLayoutOverride(nil, for: token)
        return release
    }

    func cancelScratchpadMemberRelease(_ release: ScratchpadMemberRelease) {
        workspaceManager.setManualLayoutOverride(release.previousOverride, for: release.token)
    }

    func completeScratchpadMemberRelease(_ release: ScratchpadMemberRelease) {
        let token = release.token
        guard let entry = workspaceManager.entry(for: token) else { return }
        let wasParked = workspaceManager.hiddenState(for: token)?.isScratchpad == true
        cleanupScratchpadWindowResources(for: token)
        guard wasParked else { return }

        workspaceManager.setHiddenState(nil, for: token)
        guard !workspaceManager.isWindowSuppressedByMacOS(token),
              let frame = workspaceManager.resolvedFloatingFrame(
                  for: token,
                  preferredMonitor: workspaceManager.monitor(for: entry.workspaceId)
              )
        else {
            return
        }
        if let axRef = entry.axRef {
            axManager.forceApplyNextFrame(for: entry.windowId)
            axManager.applyFramesParallel([.init(pid: entry.pid, window: axRef, frame: frame)])
        } else {
            shellAppWindowManager.setFrame(frame, for: token)
            shellAppWindowManager.setHidden(false, for: token)
        }
    }

    private func rollBackScratchpadJoin(
        _ token: WindowToken,
        previousIndex: ScratchpadIndex?,
        previousOverride: ManualWindowOverride?,
        previousRevealedIndex: ScratchpadIndex?,
        restoresTiling: Bool
    ) {
        if let previousIndex {
            if workspaceManager.setScratchpadMembership(token, to: previousIndex) {
                requestWorkspaceBarRefresh()
            }
        } else {
            cleanupScratchpadWindowResources(for: token)
        }
        if workspaceManager.setRevealedScratchpad(previousRevealedIndex) {
            requestWorkspaceBarRefresh()
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
            return !isRevealed || showJoinedScratchpadWindow(entry, in: index)
        }
        guard !isRevealed else { return true }
        if arrival == .intoRevealedSlot,
           workspaceManager.revealedScratchpadIndex() == nil,
           workspaceManager.setRevealedScratchpad(index)
        {
            requestWorkspaceBarRefresh()
            return true
        }
        return settleJoinedScratchpadWindow(entry, in: index, parkAdmission: parkAdmission, arrival: arrival)
    }

    private func showJoinedScratchpadWindow(_ entry: WindowState, in index: ScratchpadIndex) -> Bool {
        let visibleSibling = scratchpadEntries(in: index).first { sibling in
            sibling.token != entry.token && workspaceManager.hiddenState(for: sibling.token) == nil
        }
        guard let workspaceId = visibleSibling?.workspaceId ?? scratchpadTarget()?.workspaceId,
              let monitor = workspaceManager.monitor(for: workspaceId)
        else {
            return false
        }
        if entry.workspaceId != workspaceId {
            reassignManagedWindow(entry.token, to: workspaceId)
        }
        guard showScratchpadWindow(entry, on: workspaceId, monitor: monitor) else {
            if entry.workspaceId != workspaceId {
                reassignManagedWindow(entry.token, to: entry.workspaceId)
            }
            return false
        }
        return true
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
