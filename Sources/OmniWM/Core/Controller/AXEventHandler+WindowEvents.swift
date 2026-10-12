// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func handleCGSEvent(_ event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, spaceId):
            beginWindowSubscriptionIdentityTransition()
            WindowAdmissionTrace.record(
                .init(action: .cgsCreated, windowId: Int(windowId))
            )
            handleCGSWindowCreated(windowId: windowId, spaceId: spaceId)
            controller.spaceTracker.noteWindowSpace(windowId: Int(windowId), spaceId: spaceId)
            refreshWindowSubscriptions()

        case let .destroyed(windowId, _):
            beginWindowSubscriptionIdentityTransition()
            WindowAdmissionTrace.record(
                .init(action: .cgsDestroyed, windowId: Int(windowId), reason: "destroyed")
            )
            enqueueLifecycleQuery(windowId: windowId, kind: .spaceDestroyed)
            refreshWindowSubscriptions()

        case let .closed(windowId):
            handleCGSWindowClosed(windowId: windowId)

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            if WindowAdmissionTrace.shared.isActive, !isOwnProcessPid(pid) {
                WindowAdmissionTrace.record(
                    .init(
                        action: .frontmostObserved,
                        pid: pid,
                        bundleId: resolveBundleId(pid)
                    )
                )
            }
            handleAppActivation(pid: pid, source: .cgsFrontAppChanged)

        case let .orderChanged(windowId):
            handleWindowOrderChanged(windowId: windowId)

        case let .visibilityChanged(windowId, orderedIn):
            let entry = controller.workspaceManager.entry(forWindowId: Int(windowId))
            guard !orderedIn || entry?.observedState.isNativeWithdrawn == true || hasVisibilityQuery(windowId: windowId)
            else { return }
            enqueueLifecycleQuery(windowId: windowId, kind: .visibilityChanged)

        case let .titleChanged(windowId):
            guard case let .exact(token, windowInfo) = resolveWindowServerIdentity(windowId),
                  controller.workspaceManager.entry(for: token) != nil
            else {
                return
            }
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            controller.requestWorkspaceBarRefresh()
            updateManagedReplacementTitle(windowInfo: windowInfo, token: token)
            scheduleWindowRuleReevaluationIfNeeded(targets: [.window(token)])
        }
    }

    private func handleCGSWindowClosed(windowId: UInt32) {
        beginWindowSubscriptionIdentityTransition()
        WindowAdmissionTrace.record(.init(action: .cgsDestroyed, windowId: Int(windowId), reason: "closed"))
        cancelQueuedWindowCreation(windowId: windowId)
        cancelCGSWindowAdmission(windowId: windowId)
        enqueueLifecycleQuery(windowId: windowId, kind: .closed)
        refreshWindowSubscriptions()
    }

    private func handleWindowOrderChanged(windowId: UInt32) {
        enqueueLifecycleQuery(windowId: windowId, kind: .orderChanged)
    }

    func applyWindowOrderChanged(windowId: UInt32, windowInfo: WindowServerInfo?) {
        guard let controller,
              case let .exact(token, _) = WindowServerIdentityResolution(windowId: windowId, info: windowInfo),
              controller.workspaceManager.entry(for: token) != nil
        else { return }
        applyObservedWindowOrdering(windowInfo, token: token)
        controller.surfaceReconciler.noteRestackOccurred()
    }

    func applyWindowVisibilityChanged(windowId: UInt32, windowInfo: WindowServerInfo?) {
        guard let controller,
              case let .exact(token, _) = WindowServerIdentityResolution(windowId: windowId, info: windowInfo)
        else { return }
        guard windowInfo?.isOrderedIn != false || controller.workspaceManager.nativeManagedFocusToken != token else {
            lifecycleQueries.visibilityRechecksAfterFocusLoss.insert(token)
            return
        }
        applyObservedWindowOrdering(windowInfo, token: token)
    }

    func applyObservedWindowOrdering(
        _ windowInfo: WindowServerInfo?,
        token: WindowToken,
        appFullscreen: Bool = false,
        requestRefresh: Bool = true
    ) {
        guard let controller,
              let windowInfo,
              windowInfo.id == UInt32(exactly: token.windowId),
              managedWindowTokenUsingCachedIdentity(token, matchesObservedPid: windowInfo.pid),
              let isOrderedIn = windowInfo.isOrderedIn,
              controller.workspaceManager.entry(for: token) != nil
        else { return }
        lifecycleQueries.visibilityRechecksAfterFocusLoss.remove(token)
        if !isOrderedIn {
            let topology = controller.workspaceManager.spaceTopology
            guard !appFullscreen,
                  !topology.isWindowOnFullscreenSpace(token.windowId),
                  !topology.isWindowOnKnownInactiveSpace(token.windowId)
            else { return }
        }
        updateWindowNativeWithdrawalState(!isOrderedIn, token: token, requestRefresh: requestRefresh)
    }

    private func handleCGSWindowCreated(windowId: UInt32, spaceId: UInt64) {
        captureCreatePlacementContext(windowId: windowId, spaceId: spaceId)
        recordNiriCreateFocusTrace(.init(kind: .createSeen(windowId: windowId)))
        if shouldDeferCreateForInactiveNativeSpace(spaceId) {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    windowId: Int(windowId),
                    reason: "inactive_native_space_\(spaceId)",
                    outcome: "deferred"
                )
            )
            deferCreatedWindow(windowId)
            return
        }
        processCreatedWindow(windowId: windowId)
    }

    func shouldDeferCreateForInactiveNativeSpace(_ spaceId: UInt64) -> Bool {
        guard spaceId != 0, let controller else { return false }
        let topology = controller.workspaceManager.spaceTopology
        return topology.isKnownSpace(spaceId) && !topology.isCurrentSpace(spaceId)
    }

    func processCreatedWindow(
        windowId: UInt32,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        retryTrigger: AdmissionRetryTrigger = .create,
        retryExecution: AdmissionRetryExecution? = nil
    ) {
        guard canProcessCreatedWindow(windowId: windowId, retryExecution: retryExecution) else { return }
        enqueueLifecycleQuery(
            windowId: windowId,
            kind: .created(.init(
                placementContext: pendingCreatePlacementContext(for: Int(windowId)),
                fallbackToken: fallbackToken, fallbackAXRef: fallbackAXRef,
                placementOrigin: placementOrigin, retryTrigger: retryTrigger, retryExecution: retryExecution
            ))
        )
    }

    func canProcessCreatedWindow(windowId: UInt32, retryExecution: AdmissionRetryExecution?) -> Bool {
        guard let controller else { return false }
        if controller.isDiscoveryInProgress {
            if let retryExecution {
                suspendCreatedWindowLookupExecution(retryExecution)
            }
            deferCreateDuringDiscovery(windowId)
            return false
        }
        if controller.isOwnedWindow(windowNumber: Int(windowId)) {
            rejectOwnedCreate(windowId)
            return false
        }
        return true
    }

    func processCreatedWindowObservation(
        windowId: UInt32,
        windowInfo: WindowServerInfo?,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        retryTrigger: AdmissionRetryTrigger = .create,
        retryExecution: AdmissionRetryExecution? = nil
    ) {
        if let windowInfo, isOwnProcessPid(pid_t(windowInfo.pid)) {
            rejectOwnedCreate(windowId)
            return
        }
        prepareAndTrackCreatedWindow(
            windowId: windowId, windowInfo: windowInfo,
            fallbackToken: fallbackToken, fallbackAXRef: fallbackAXRef,
            placementOrigin: placementOrigin, retryTrigger: retryTrigger, retryExecution: retryExecution
        )
    }

    func prepareAndTrackCreatedWindow(
        windowId: UInt32,
        windowInfo: WindowServerInfo?,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        retryTrigger: AdmissionRetryTrigger = .create,
        retryExecution: AdmissionRetryExecution? = nil
    ) {
        let token = fallbackToken ?? windowInfo?.token(matching: windowId)
        let axRef = fallbackAXRef?.windowId == Int(windowId) ? fallbackAXRef : token.flatMap {
            AXWindowService.pinnedAXWindowRef(for: windowId, pid: $0.pid)
        }
        if let token, axRef == nil {
            requestCreatedWindowIdentity(token: token, execution: retryExecution)
            return
        }
        let createPlacementContext = pendingCreatePlacementContext(for: Int(windowId))
        let effectivePlacementOrigin = Self.effectivePlacementOrigin(
            placementOrigin,
            createPlacementContext: createPlacementContext
        )
        let outcome = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: fallbackToken,
            fallbackAXRef: axRef,
            allowsTrackedIdentityReplacement: retryTrigger.allowsTrackedIdentityReplacement,
            placementOrigin: effectivePlacementOrigin,
            createPlacementContext: createPlacementContext
        )
        guard let candidate = preparedCreateCandidate(
            from: outcome,
            windowId: windowId,
            trigger: retryTrigger
        ) else {
            return
        }

        if completeLiveStructuralReplacementCreate(candidate) {
            return
        }
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(candidate)
            return
        }

        trackPreparedCreate(candidate)
    }

    func deferCreateDuringDiscovery(_ windowId: UInt32) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionPending,
                windowId: Int(windowId),
                reason: "discovery_in_progress",
                outcome: "deferred"
            )
        )
        deferCreatedWindow(windowId)
    }

    private func rejectOwnedCreate(_ windowId: UInt32) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionIgnored,
                windowId: Int(windowId),
                reason: WindowAdmissionRejectionReason.ownedWindow.rawValue
            )
        )
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        rejectDeferredReplacement(windowId: windowId)
    }

    func subscribeToManagedWindows() {
        refreshWindowSubscriptions()
    }

    func liveCreateSpace(
        for windowId: UInt32,
        spaceIdsForWindow: (UInt32) -> [UInt64] = { SkyLight.shared.spacesForWindow($0) }
    ) -> UInt64 {
        guard let controller else { return 0 }
        return controller.workspaceManager.spaceTopology
            .selectWindowSpace(from: spaceIdsForWindow(windowId)) ?? 0
    }

    func completeCGSWindowDestroyed(
        windowId: UInt32,
        evidence: WindowDestroyEvidence,
        windowInfo: WindowServerInfo?
    ) {
        cancelCGSWindowAdmission(windowId: windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: nil, evidence: evidence, windowInfo: windowInfo)
    }

    private func cancelCGSWindowAdmission(windowId: UInt32) {
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        let retryRetainCount = cancelCreatedWindowRetry(windowId: windowId)
        if retryRetainCount == 0 {
            releasePreparedWindowSubscription(windowId)
        }
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        rejectDeferredReplacement(windowId: windowId)
        cancelFrameObservation(windowId: windowId)
    }

    func processDeferredCreatedWindow(
        _ windowId: UInt32, controller: WMController, spaceIdsForWindow: @escaping (UInt32) -> [UInt64]
    ) {
        if case .identityRebind = admissionRetryStateByWindowId[windowId]?.trigger {
            removeDeferredCreatedWindow(windowId)
            return
        }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else {
            rejectOwnedCreate(windowId)
            return
        }
        enqueueLifecycleQuery(
            windowId: windowId,
            kind: .created(.init(
                placementContext: pendingCreatePlacementContext(for: Int(windowId)),
                deferredSpaceQuery: spaceIdsForWindow
            ))
        )
    }

    func applyDeferredCreatedWindow(
        _ windowId: UInt32, controller: WMController, windowInfo: WindowServerInfo?,
        spaceIdsForWindow: (UInt32) -> [UInt64]
    ) {
        let retryState = admissionRetryStateByWindowId[windowId]
        let retryTrigger = retryState?.trigger ?? .create
        if case .identityRebind = retryTrigger {
            return
        }
        if controller.isOwnedWindow(windowNumber: Int(windowId)) {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            rejectDeferredReplacement(windowId: windowId)
            return
        }
        guard let windowInfo else {
            _ = scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: retryState?.expectedToken,
                axRef: retryState?.axRef,
                reason: .windowInfoMissing,
                trigger: retryTrigger
            )
            return
        }
        if isOwnProcessPid(pid_t(windowInfo.pid)) {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            rejectDeferredReplacement(windowId: windowId)
            return
        }
        if shouldDeferCreateForInactiveNativeSpace(
            liveCreateSpace(for: windowId, spaceIdsForWindow: spaceIdsForWindow)
        ) {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    pid: pid_t(windowInfo.pid),
                    windowId: Int(windowId),
                    reason: "inactive_native_space",
                    outcome: "deferred"
                )
            )
            deferCreatedWindow(windowId)
            return
        }
        admitDeferredCreatedWindow(windowId, windowInfo: windowInfo, retryState: retryState, trigger: retryTrigger)
    }

    private func admitDeferredCreatedWindow(
        _ windowId: UInt32, windowInfo: WindowServerInfo?, retryState: AdmissionRetryState?,
        trigger retryTrigger: AdmissionRetryTrigger
    ) {
        prepareAndTrackCreatedWindow(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: retryState?.expectedToken,
            fallbackAXRef: retryState?.axRef,
            placementOrigin: retryTrigger.placementOrigin,
            retryTrigger: retryTrigger
        )
    }
}
