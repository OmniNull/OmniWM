// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WMController {
    func deferManagedFocusRetry(_ request: ManagedFocusRequest) -> Bool {
        if let entry = workspaceManager.entry(for: request.token), entry.axRef == nil { return false }
        guard intentLedger.defersRetryRaise(for: request) else { return false }
        dispatchRetryRaise(for: request, refronting: true)
        return true
    }

    func dispatchRetryRaise(for request: ManagedFocusRequest, refronting: Bool) {
        guard let entry = workspaceManager.entry(for: request.token),
              entry.workspaceId == request.workspaceId,
              let expectedWindow = entry.axRef,
              let handle = workspaceManager.handle(for: request.token),
              !isManagedWindowSuppressedByMacOS(request.token),
              let job = intentLedger.beginDeferredRetryRaise(for: request)
        else { return }
        let handleIdentity = ObjectIdentifier(handle)
        let applied = !refronting || applyManagedFocusRequest(
            request, entry: entry, validatesPointer: true, isRetry: true, raisesWindow: false
        )
        let completion: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            surfaceReconciler.noteRestackOccurred()
            guard let liveRequest = intentLedger.completeDeferredRetryRaise(job: job),
                  let currentEntry = workspaceManager.entry(for: liveRequest.token),
                  currentEntry.workspaceId == liveRequest.workspaceId,
                  let currentAXRef = currentEntry.axRef,
                  sameAXWindowIdentity(currentAXRef, expectedWindow),
                  workspaceManager.handle(for: liveRequest.token).map(ObjectIdentifier.init) == handleIdentity,
                  !isManagedWindowSuppressedByMacOS(liveRequest.token),
                  workspaceManager.pendingManagedFocusMatches(
                      token: liveRequest.token,
                      workspaceId: liveRequest.workspaceId,
                      requestId: liveRequest.requestId
                  )
            else { return }
            axEventHandler.handleAppActivation(
                pid: liveRequest.token.pid,
                source: liveRequest.lastActivationSource ?? .focusedWindowChanged,
                origin: .retry
            )
        }
        let allowsLayoutHiddenWindow = permitsParkedVerticalRetryRaise(for: entry)
        if !applied || job.isCancelled
            || !windowFocusOperations.enqueueRetryRaise(
                entry.pid,
                expectedWindow,
                job,
                allowsLayoutHiddenWindow,
                completion
            )
        {
            completion()
        }
    }

    private func permitsParkedVerticalRetryRaise(for entry: WindowState) -> Bool {
        guard entry.hiddenState?.offscreenSide != nil,
              workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              let monitor = workspaceManager.monitor(for: entry.workspaceId)
        else { return false }
        return settings.monitors.effectiveOrientation(for: monitor) == .vertical
    }

    func retryManagedFocusFronting(_ request: ManagedFocusRequest) {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == request.token,
              let entry = workspaceManager.entry(for: liveRequest.token),
              entry.workspaceId == request.workspaceId,
              !isManagedWindowSuppressedByMacOS(liveRequest.token)
        else {
            return
        }
        _ = applyManagedFocusRequest(
            liveRequest,
            entry: entry,
            validatesPointer: true,
            isRetry: true
        )
    }
}
