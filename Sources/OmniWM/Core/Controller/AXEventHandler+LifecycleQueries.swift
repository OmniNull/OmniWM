// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension AXEventHandler {
    enum LifecycleQueryError: Error {
        case unavailable
    }

    enum LifecycleQueryKind {
        case created(LifecycleCreateRequest)
        case spaceDestroyed
        case closed
        case orderChanged
        case visibilityChanged
        case activation(ActivationFacts)
    }

    struct LifecycleCreateRequest {
        var placementContext: WindowCreatePlacementContext?
        var fallbackToken: WindowToken?
        var fallbackAXRef: AXWindowRef?
        var placementOrigin: WorkspacePlacementOrigin = .liveCreate
        var retryTrigger: AdmissionRetryTrigger = .create
        var retryExecution: AdmissionRetryExecution?
        var deferredSpaceQuery: ((UInt32) -> [UInt64])?
    }

    struct LifecycleQuery {
        let sequence: UInt64
        let windowId: UInt32
        let kind: LifecycleQueryKind
        var destructionIdentity: LifecycleIdentity?
    }

    struct LifecycleIdentity {
        let handle: WindowHandle?
        let token: WindowToken?
        let axRef: AXWindowRef?
        var retryGeneration: UInt64?
        let hiddenState: HiddenState?
    }

    struct LifecycleQueries {
        var query: @MainActor (UInt32) async throws -> WindowServerInfo? = {
            guard let result = try await SkyLight.shared.queryWindowInfoDeferred(
                windowIds: [$0], includeOrderedIn: true
            ) else {
                throw LifecycleQueryError.unavailable
            }
            return result[$0]
        }

        var pending: [LifecycleQuery] = []
        var active: LifecycleQuery?
        var nextSequence: UInt64 = 1
        var task: Task<Void, Never>?
        var deferredCloseProbeExpiration: IntentID?
        var visibilityRechecksAfterFocusLoss: Set<WindowToken> = []
    }

    func enqueueLifecycleQuery(windowId: UInt32, kind: LifecycleQueryKind) {
        guard let controller, !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        guard !coalescePendingLifecycleQuery(windowId: windowId, kind: kind) else { return }
        if case let .created(create) = kind,
           let previous = lifecycleQueries.pending.last(where: { $0.windowId == windowId })
           ?? lifecycleQueries.active.flatMap({ $0.windowId == windowId ? $0 : nil }),
           case let .created(previousCreate) = previous.kind,
           create.retryExecution == previousCreate.retryExecution,
           create.fallbackToken == previousCreate.fallbackToken,
           create.fallbackAXRef == nil && previousCreate.fallbackAXRef == nil
           || create.fallbackAXRef != nil && previousCreate.fallbackAXRef != nil
           && CFEqual(create.fallbackAXRef?.element, previousCreate.fallbackAXRef?.element),
           create.placementOrigin == previousCreate.placementOrigin,
           (create.deferredSpaceQuery == nil) == (previousCreate.deferredSpaceQuery == nil)
        {
            return
        }
        let destructionIdentity: LifecycleIdentity? = switch kind {
        case .closed,
             .spaceDestroyed: lifecycleIdentity(windowId: windowId)
        case .created,
             .orderChanged,
             .visibilityChanged,
             .activation: nil
        }
        let query = LifecycleQuery(
            sequence: lifecycleQueries.nextSequence, windowId: windowId,
            kind: kind, destructionIdentity: destructionIdentity
        )
        lifecycleQueries.nextSequence &+= 1
        lifecycleQueries.pending.append(query)
        guard lifecycleQueries.task == nil else { return }
        lifecycleQueries.task = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, !self.lifecycleQueries.pending.isEmpty {
                let request = self.lifecycleQueries.pending.removeFirst()
                self.lifecycleQueries.active = request
                await self.performLifecycleQuery(request)
            }
            guard !Task.isCancelled else { return }
            self?.lifecycleQueries.task = nil
        }
    }

    private func coalescePendingLifecycleQuery(windowId: UInt32, kind: LifecycleQueryKind) -> Bool {
        switch kind {
        case .activation:
            lifecycleQueries.pending.removeAll {
                guard $0.windowId == windowId else { return false }
                if case .activation = $0.kind { return true }
                return false
            }
        case .orderChanged,
             .visibilityChanged:
            return lifecycleQueries.pending.contains {
                guard $0.windowId == windowId else { return false }
                switch ($0.kind, kind) {
                case (.orderChanged, .orderChanged),
                     (.visibilityChanged, .visibilityChanged): return true
                default: return false
                }
            }
        default:
            break
        }
        return false
    }

    func cancelQueuedWindowCreation(windowId: UInt32) {
        lifecycleQueries.pending.removeAll {
            guard $0.windowId == windowId else { return false }
            if case .created = $0.kind { return true }
            return false
        }
        if let active = lifecycleQueries.active, active.windowId == windowId,
           case .created = active.kind
        {
            lifecycleQueries.active = nil
        }
    }

    func cancelLifecycleQueries() {
        lifecycleQueries.task?.cancel()
        lifecycleQueries.task = nil
        lifecycleQueries.active = nil
        lifecycleQueries.pending.removeAll()
        lifecycleQueries.deferredCloseProbeExpiration = nil
        lifecycleQueries.visibilityRechecksAfterFocusLoss.removeAll()
    }

    func recheckVisibilityAfterFocusLoss() {
        guard let controller, !lifecycleQueries.visibilityRechecksAfterFocusLoss.isEmpty else { return }
        let focusedToken = controller.workspaceManager.nativeManagedFocusToken
        let unfocused = lifecycleQueries.visibilityRechecksAfterFocusLoss.filter { $0 != focusedToken }
        lifecycleQueries.visibilityRechecksAfterFocusLoss.subtract(unfocused)
        for token in unfocused where controller.workspaceManager.entry(for: token) != nil {
            guard let windowId = UInt32(exactly: token.windowId) else { continue }
            enqueueLifecycleQuery(windowId: windowId, kind: .visibilityChanged)
        }
    }

    private func performLifecycleQuery(_ request: LifecycleQuery) async {
        defer { finishLifecycleQuery(request) }
        guard let controller, isCurrentLifecycleCreate(request) else { return }
        let identity = request.destructionIdentity ?? lifecycleIdentity(windowId: request.windowId)
        let observedAtSeq = controller.workspaceManager.worldSeq
        let info: WindowServerInfo?
        do {
            info = try await lifecycleQueries.query(request.windowId)
        } catch {
            guard !Task.isCancelled, lifecycleQueries.active?.sequence == request.sequence else { return }
            DiagnosticsEventRecorder.shared.recordLifecycle(name: "cgs.windowQuery.failed.\(request.windowId)")
            guard case .created = request.kind else { return }
            info = nil
        }
        guard !Task.isCancelled, lifecycleQueries.active?.sequence == request.sequence else { return }
        guard isCurrentLifecycleCreate(request) else { return }
        let appliedIdentity = lifecycleQueries.active?.destructionIdentity ?? identity
        lifecycleQueries.active = nil
        applyLifecycleObservation(request, identity: appliedIdentity, observedAtSeq: observedAtSeq, windowInfo: info)
    }

    private func applyLifecycleObservation(
        _ request: LifecycleQuery, identity: LifecycleIdentity, observedAtSeq: UInt64, windowInfo: WindowServerInfo?
    ) {
        guard let controller, !controller.isOwnedWindow(windowNumber: Int(request.windowId)) else { return }
        let current = controller.workspaceManager.entry(forWindowId: Int(request.windowId))
        guard current?.token == identity.token,
              current.flatMap({ controller.workspaceManager.handle(for: $0.token) }) === identity.handle,
              current.map({ CFEqual($0.axRef.element, identity.axRef?.element) }) ?? (identity.axRef == nil)
        else { return }

        let retryGeneration = admissionRetryStateByWindowId[request.windowId]?.generation
        defer { advanceLifecycleRetryGeneration(windowId: request.windowId, from: retryGeneration) }

        switch request.kind {
        case .created:
            guard retryGeneration == identity.retryGeneration else { return }
            applyLifecycleCreate(request, windowInfo: windowInfo)
        case .spaceDestroyed,
             .closed:
            guard admissionRetryStateByWindowId[request.windowId]?.generation == identity.retryGeneration
            else { return }
            if case .spaceDestroyed = request.kind {
                guard current?.hiddenState == identity.hiddenState else { return }
                guard windowInfo == nil else { return }
                cancelFrameObservation(windowId: request.windowId)
                guard current?.hiddenState == nil else { return }
            }
            if case .closed = request.kind {
                handleWindowDestroyed(
                    windowId: request.windowId, pidHint: nil, evidence: .windowClosed, windowInfo: windowInfo
                )
            } else {
                completeCGSWindowDestroyed(
                    windowId: request.windowId, evidence: .transientLifecycle, windowInfo: windowInfo
                )
            }
        case .orderChanged,
             .visibilityChanged:
            applyLifecycleOrdering(request, current: current, observedAtSeq: observedAtSeq, windowInfo: windowInfo)
        case let .activation(facts):
            applyLifecycleActivation(facts, current: current, observedAtSeq: observedAtSeq, windowInfo: windowInfo)
        }
    }

    private func applyLifecycleOrdering(
        _ request: LifecycleQuery, current: WindowState?, observedAtSeq: UInt64, windowInfo: WindowServerInfo?
    ) {
        guard let controller else { return }
        let isCurrent = current.map {
            controller.workspaceManager.isSeqCurrent(observedAtSeq, for: $0.workspaceId, domains: .layoutCommit)
        } ?? false
        if case .visibilityChanged = request.kind {
            guard let current else { return }
            guard isCurrent, !hasPendingLifecycleDestruction(current.token) else {
                enqueueLifecycleQuery(windowId: request.windowId, kind: .visibilityChanged)
                return
            }
            applyWindowVisibilityChanged(windowId: request.windowId, windowInfo: windowInfo)
        } else if isCurrent {
            applyWindowOrderChanged(windowId: request.windowId, windowInfo: windowInfo)
        } else {
            controller.surfaceReconciler.noteRestackOccurred()
        }
    }

    private func applyLifecycleActivation(
        _ facts: ActivationFacts,
        current: WindowState?,
        observedAtSeq: UInt64,
        windowInfo: WindowServerInfo?
    ) {
        guard let controller else { return }
        guard isCurrentActivationFacts(facts, controller: controller),
              let current,
              controller.workspaceManager.isSeqCurrent(
                  observedAtSeq, for: current.workspaceId, domains: .layoutCommit
              ),
              let focusedWindow = facts.focusedWindow,
              CFEqual(current.axRef.element, focusedWindow.axRef.element)
              || isKnownAXIdentityAlias(windowId: current.windowId, axRef: focusedWindow.axRef)
        else { return }
        applyObservedWindowOrdering(
            windowInfo, token: current.token, appFullscreen: focusedWindow.isFullscreen
        )
        if windowInfo?.isOrderedIn == true,
           controller.workspaceManager.entry(for: current.token)?.observedState.isNativeWithdrawn == false
        {
            handleActivationFactsResolved(facts)
        }
    }

    private func isCurrentLifecycleCreate(_ request: LifecycleQuery) -> Bool {
        guard case let .created(create) = request.kind else { return true }
        let state = admissionRetryStateByWindowId[request.windowId]
        if let execution = create.retryExecution {
            return state?.generation == execution.generation
                && state?.executionPhase == .running(execution.executionOwner)
        }
        if case .running = state?.executionPhase { return false }
        return true
    }

    func advanceLifecycleRetryGeneration(windowId: UInt32, from previous: UInt64?) {
        let generation = admissionRetryStateByWindowId[windowId]?.generation
        guard generation != previous else { return }
        if lifecycleQueries.active?.windowId == windowId,
           lifecycleQueries.active?.destructionIdentity?.retryGeneration == previous
        {
            lifecycleQueries.active?.destructionIdentity?.retryGeneration = generation
        }
        for index in lifecycleQueries.pending.indices
            where lifecycleQueries.pending[index].windowId == windowId
            && lifecycleQueries.pending[index].destructionIdentity?.retryGeneration == previous
        {
            lifecycleQueries.pending[index].destructionIdentity?.retryGeneration = generation
        }
    }

    private func applyLifecycleCreate(_ request: LifecycleQuery, windowInfo: WindowServerInfo?) {
        guard case let .created(create) = request.kind else { return }
        if let context = create.placementContext { createPlacementContextsByWindowId[request.windowId] = context }
        if create.deferredSpaceQuery != nil { removeDeferredCreatedWindow(request.windowId) }
        guard canProcessCreatedWindow(windowId: request.windowId, retryExecution: create.retryExecution) else { return }
        if let spaceQuery = create.deferredSpaceQuery, let controller {
            applyDeferredCreatedWindow(
                request.windowId, controller: controller, windowInfo: windowInfo, spaceIdsForWindow: spaceQuery
            )
        } else {
            processCreatedWindowObservation(
                windowId: request.windowId, windowInfo: windowInfo,
                fallbackToken: create.fallbackToken, fallbackAXRef: create.fallbackAXRef,
                placementOrigin: create.placementOrigin, retryTrigger: create.retryTrigger,
                retryExecution: create.retryExecution
            )
        }
    }

    private func lifecycleIdentity(windowId: UInt32) -> LifecycleIdentity {
        let entry = controller?.workspaceManager.entry(forWindowId: Int(windowId))
        return LifecycleIdentity(
            handle: entry.flatMap { controller?.workspaceManager.handle(for: $0.token) },
            token: entry?.token,
            axRef: entry?.axRef,
            retryGeneration: admissionRetryStateByWindowId[windowId]?.generation,
            hiddenState: entry?.hiddenState
        )
    }

    func hasVisibilityQuery(windowId: UInt32) -> Bool {
        func matches(_ request: LifecycleQuery) -> Bool {
            guard request.windowId == windowId, case .visibilityChanged = request.kind else { return false }
            return true
        }
        return lifecycleQueries.active.map(matches) == true || lifecycleQueries.pending.contains(where: matches)
    }

    func hasPendingLifecycleDestruction(_ token: WindowToken) -> Bool {
        guard let controller, let entry = controller.workspaceManager.entry(for: token) else { return false }
        let handle = controller.workspaceManager.handle(for: token)
        func matches(_ request: LifecycleQuery) -> Bool {
            guard let identity = request.destructionIdentity else { return false }
            return identity.token == token && identity.handle === handle
                && CFEqual(identity.axRef?.element, entry.axRef.element)
        }
        return lifecycleQueries.active.map(matches) == true || lifecycleQueries.pending.contains(where: matches)
    }

    private func finishLifecycleQuery(_ request: LifecycleQuery) {
        guard !Task.isCancelled else { return }
        if case let .created(create) = request.kind, let execution = create.retryExecution {
            suspendCreatedWindowLookupExecution(execution)
        }
        if lifecycleQueries.active?.sequence == request.sequence { lifecycleQueries.active = nil }
        guard let intentId = lifecycleQueries.deferredCloseProbeExpiration,
              let open = controller?.intentLedger.openSameAppCloseProbe(), open.intent.id == intentId
        else {
            lifecycleQueries.deferredCloseProbeExpiration = nil
            return
        }
        guard !hasPendingLifecycleDestruction(open.payload.focusedToken) else { return }
        lifecycleQueries.deferredCloseProbeExpiration = nil
        handleIntentExpired(intentId)
    }
}
