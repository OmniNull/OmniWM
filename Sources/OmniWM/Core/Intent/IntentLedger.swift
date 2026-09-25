// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
final class IntentLedger {
    static let capacity = 256
    static let activationSettleDeadline: Duration = .milliseconds(100)
    static let sameAppActivationHandoffDeadline: Duration = .milliseconds(40)
    static let appRevealDeadline: Duration = .seconds(2)
    private var managedFocusRetryMetricsActive = false
    private var managedFocusRetryMetrics = ManagedFocusRetryRuntimeSnapshot()

    var seqProvider: () -> UInt64 = { 0 }
    var clock: () -> ContinuousClock.Instant = { ContinuousClock().now }
    weak var deadlineWheel: DeadlineWheel?

    private(set) var entries: [Intent] = []
    private(set) var lastConfirmedManagedFocus: (token: WindowToken, origin: ManagedFocusOrigin)?
    private var nextIntentId: IntentID = 1
    private var intentIssuanceGeneration: UInt64 = 0
    private var deferredRetryRaise: (request: ManagedFocusRequest, job: RunLoopJob?)?

    var activeManagedRequest: ManagedFocusRequest? {
        entries.last { $0.phase == .pending && $0.kind.isFocusWindow }?.asManagedFocusRequest
    }

    func enableDeferredRetryRaise(for request: ManagedFocusRequest) {
        cancelDeferredRetryRaise()
        guard activeManagedRequest(requestId: request.requestId) == request else { return }
        deferredRetryRaise = (request, nil)
    }

    func defersRetryRaise(for request: ManagedFocusRequest) -> Bool {
        guard let pending = deferredRetryRaise else { return false }
        return pending.request.requestId == request.requestId
            && pending.request.token == request.token
            && pending.request.workspaceId == request.workspaceId
    }

    func beginDeferredRetryRaise(for request: ManagedFocusRequest) -> RunLoopJob? {
        guard defersRetryRaise(for: request), deferredRetryRaise?.job == nil,
              activeManagedRequest(requestId: request.requestId)?.phase == .awaitingConfirmation
        else { return nil }
        let job = RunLoopJob()
        deferredRetryRaise?.job = job
        return job
    }

    func completeDeferredRetryRaise(job: RunLoopJob) -> ManagedFocusRequest? {
        guard let pending = deferredRetryRaise, pending.job === job,
              let request = activeManagedRequest(requestId: pending.request.requestId),
              defersRetryRaise(for: request), request.phase == .awaitingConfirmation
        else { return nil }
        deferredRetryRaise?.job = nil
        return request
    }

    private func cancelDeferredRetryRaise(rearmingRequest: Bool = false) {
        if rearmingRequest, let pending = deferredRetryRaise, pending.job != nil {
            deadlineWheel?.schedule(intentId: pending.request.requestId, after: Self.activationSettleDeadline)
        }
        deferredRetryRaise?.job?.cancel()
        deferredRetryRaise = nil
    }

    @discardableResult
    func registerActivateApp(pid: pid_t) -> Intent {
        if let index = openIndex(where: { $0.kind == .activateApp(pid: pid) }) {
            intentIssuanceGeneration &+= 1
            return entries[index]
        }
        return append(kind: .activateApp(pid: pid), origin: .keyboardOrProgrammatic)
    }

    @discardableResult
    func beginAppRevealFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        handleIdentity: ObjectIdentifier,
        pendingApps: [pid_t: UInt64],
        focusFingerprint: AppRevealFocusFingerprint,
        destination: AppRevealFocusDestination = .window,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> Intent {
        for entry in entries where entry.phase == .pending {
            guard case .appRevealFocus = entry.kind else { continue }
            _ = supersede(id: entry.id)
            deadlineWheel?.cancel(intentId: entry.id)
        }

        let intent = append(
            kind: .appRevealFocus(
                AppRevealFocusPayload(
                    token: token,
                    workspaceId: workspaceId,
                    handleIdentity: handleIdentity,
                    coordinatedAppGenerations: pendingApps,
                    pendingAppPIDs: Set(pendingApps.keys),
                    focusIntentWatermark: newestFocusIntentId(),
                    focusFingerprint: focusFingerprint,
                    destination: destination
                )
            ),
            origin: origin
        )
        deadlineWheel?.schedule(intentId: intent.id, after: Self.appRevealDeadline)
        AppVisibilityTrace.record(
            .reveal,
            pid: token.pid,
            outcome: .issued,
            intentId: intent.id,
            windowId: token.windowId,
            workspaceId: workspaceId,
            intentGeneration: pendingApps[token.pid],
            destination: destination.traceDestination
        )
        return intent
    }

    func drainAppRevealFocus(
        intentId: IntentID,
        pid: pid_t,
        appVisibilityGeneration: UInt64
    ) -> AppRevealFocusDrainResult? {
        guard let index = entries.firstIndex(where: { $0.id == intentId && $0.phase == .pending }),
              case var .appRevealFocus(payload) = entries[index].kind,
              payload.pendingAppPIDs.contains(pid),
              let expectedGeneration = payload.coordinatedAppGenerations[pid]
        else {
            return nil
        }
        guard appVisibilityGeneration == expectedGeneration &+ 1 else {
            _ = retire(
                id: intentId,
                phase: .cancelled,
                source: nil,
                reason: .visibilityGenerationChanged
            )
            deadlineWheel?.cancel(intentId: intentId)
            return nil
        }
        payload.pendingAppPIDs.remove(pid)
        entries[index].kind = .appRevealFocus(payload)
        return payload.pendingAppPIDs.isEmpty ? .ready : .awaitingApps
    }

    @discardableResult
    func registerReplacementFocus(_ payload: ReplacementFocusPayload) -> Intent {
        append(kind: .replacementFocus(payload), origin: .keyboardOrProgrammatic)
    }

    func updateReplacementFocus(id: IntentID, _ mutate: (inout ReplacementFocusPayload) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }),
              case var .replacementFocus(payload) = entries[index].kind
        else {
            return
        }
        mutate(&payload)
        entries[index].kind = .replacementFocus(payload)
    }

    @discardableResult
    func registerSameAppCloseProbe(_ payload: SameAppCloseProbePayload) -> Intent {
        append(kind: .sameAppCloseProbe(payload), origin: .keyboardOrProgrammatic)
    }

    @discardableResult
    func registerFocusPolicyLease(owner: FocusPolicyLeaseOwner) -> Intent {
        append(kind: .focusPolicyLease(owner: owner), origin: .keyboardOrProgrammatic)
    }

    func updateSameAppCloseProbe(id: IntentID, _ mutate: (inout SameAppCloseProbePayload) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }),
              case var .sameAppCloseProbe(payload) = entries[index].kind
        else {
            return
        }
        mutate(&payload)
        entries[index].kind = .sameAppCloseProbe(payload)
    }

    @discardableResult
    func registerAppTerminationFocusRecovery(_ payload: AppTerminationFocusRecoveryPayload) -> Intent {
        if let open = openAppTerminationFocusRecovery() {
            _ = cancel(id: open.intent.id)
            deadlineWheel?.cancel(intentId: open.intent.id)
        }
        return append(kind: .appTerminationFocusRecovery(payload), origin: .keyboardOrProgrammatic)
    }

    func updateAppTerminationFocusRecovery(
        id: IntentID,
        _ mutate: (inout AppTerminationFocusRecoveryPayload) -> Void
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }),
              case var .appTerminationFocusRecovery(payload) = entries[index].kind
        else {
            return
        }
        mutate(&payload)
        entries[index].kind = .appTerminationFocusRecovery(payload)
    }

    func issuanceWatermark() -> UInt64 {
        intentIssuanceGeneration
    }

    @discardableResult
    func confirm(id: IntentID, source: ActivationEventSource? = nil) -> Intent? {
        retire(id: id, phase: .confirmed, source: source)
    }

    @discardableResult
    func cancel(id: IntentID) -> Intent? {
        retire(id: id, phase: .cancelled, source: nil)
    }

    @discardableResult
    func supersede(id: IntentID) -> Intent? {
        retire(id: id, phase: .superseded, source: nil)
    }

    @discardableResult
    func markExpired(id: IntentID) -> Intent? {
        retire(id: id, phase: .expired, source: nil)
    }

    func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if deferredRetryRaise?.request.token == oldToken {
            cancelDeferredRetryRaise(rearmingRequest: true)
        }
        for index in entries.indices {
            switch entries[index].rekeyedKind(from: oldToken, to: newToken) {
            case .unchanged:
                continue
            case let .updated(kind):
                entries[index].kind = kind
            case let .cancel(reason):
                let intentId = entries[index].id
                _ = retire(id: intentId, phase: .cancelled, source: nil, reason: reason)
                deadlineWheel?.cancel(intentId: intentId)
            }
        }
    }

    func reset() {
        cancelDeferredRetryRaise()
        intentIssuanceGeneration &+= 1
        entries.removeAll(keepingCapacity: false)
        lastConfirmedManagedFocus = nil
    }

    private func append(
        kind: IntentKind,
        origin: ManagedFocusOrigin
    ) -> Intent {
        let intent = Intent(
            id: nextIntentId,
            kind: kind,
            origin: origin,
            issuedAtSeq: seqProvider()
        )
        nextIntentId += 1
        intentIssuanceGeneration &+= 1
        entries.append(intent)
        trim()
        return intent
    }

    private func retire(
        id: IntentID,
        phase: IntentPhase,
        source: ActivationEventSource?,
        reason: AppVisibilityTrace.Reason? = nil
    ) -> Intent? {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }) else { return nil }
        if deferredRetryRaise?.request.requestId == id {
            cancelDeferredRetryRaise()
        }
        entries[index].phase = phase
        entries[index].retiredAt = clock()
        if let source {
            entries[index].lastActivationSource = source
        }
        entries[index].recordRetirement(reason: reason)
        return entries[index]
    }

    private func openIndex(where predicate: (Intent) -> Bool) -> Int? {
        entries.lastIndex { $0.phase == .pending && predicate($0) }
    }

    private func trim() {
        guard entries.count > Self.capacity else { return }
        var overflow = entries.count - Self.capacity
        entries.removeAll { entry in
            guard overflow > 0, entry.phase.isRetired else { return false }
            overflow -= 1
            return true
        }
    }
}

extension IntentLedger {
    func beginManagedRequest(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> ManagedFocusRequest {
        if let index = openIndex(where: {
            guard case let .focusWindow(currentToken, currentWorkspaceId, _) = $0.kind else {
                return false
            }
            return currentToken == token && currentWorkspaceId == workspaceId
        }) {
            cancelDeferredRetryRaise(rearmingRequest: true)
            intentIssuanceGeneration &+= 1
            entries[index].origin = entries[index].origin.merged(with: origin)
            if entries[index].origin != .focusFollowsMouse,
               case .focusWindow(token, workspaceId, .awaitingSameAppActivation) = entries[index].kind
            {
                entries[index].kind = .focusWindow(
                    token: token,
                    workspaceId: workspaceId,
                    phase: .awaitingConfirmation
                )
                deadlineWheel?.schedule(intentId: entries[index].id, after: Self.activationSettleDeadline)
            }
            return entries[index].asManagedFocusRequest!
        }

        for entry in entries where entry.phase == .pending && entry.kind.isFocusWindow {
            _ = supersede(id: entry.id)
            deadlineWheel?.cancel(intentId: entry.id)
        }

        let intent = append(
            kind: .focusWindow(token: token, workspaceId: workspaceId),
            origin: origin
        )
        deadlineWheel?.schedule(intentId: intent.id, after: Self.activationSettleDeadline)
        return intent.asManagedFocusRequest!
    }

    @discardableResult
    func retargetManagedRequest(
        requestId: IntentID,
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedFocusRequest? {
        guard let index = entries.firstIndex(where: { $0.id == requestId && $0.phase == .pending }),
              case let .focusWindow(currentToken, _, requestPhase) = entries[index].kind,
              currentToken == token
        else {
            return nil
        }
        if deferredRetryRaise?.request.requestId == requestId {
            cancelDeferredRetryRaise(rearmingRequest: true)
        }
        entries[index].kind = .focusWindow(
            token: token,
            workspaceId: workspaceId,
            phase: requestPhase
        )
        return entries[index].asManagedFocusRequest
    }

    func beginSameAppActivationHandoff(
        requestId: IntentID,
        sourceToken: WindowToken,
        isRetry: Bool = false
    ) -> ManagedFocusRequest? {
        guard let index = entries.firstIndex(where: { $0.id == requestId && $0.phase == .pending }),
              case let .focusWindow(token, workspaceId, requestPhase) = entries[index].kind,
              token.pid == sourceToken.pid,
              token != sourceToken,
              entries[index].origin == .focusFollowsMouse
        else {
            return nil
        }
        let phase = ManagedFocusRequest.Phase.awaitingSameAppActivation(
            sourceToken: sourceToken,
            isRetry: isRetry
        )
        guard requestPhase != phase else { return entries[index].asManagedFocusRequest }
        entries[index].kind = .focusWindow(
            token: token,
            workspaceId: workspaceId,
            phase: phase
        )
        deadlineWheel?.schedule(intentId: requestId, after: Self.sameAppActivationHandoffDeadline)
        return entries[index].asManagedFocusRequest
    }

    func completeSameAppActivationHandoff(requestId: IntentID) -> ManagedFocusRequest? {
        guard let index = entries.firstIndex(where: { $0.id == requestId && $0.phase == .pending }),
              case let .focusWindow(token, workspaceId, .awaitingSameAppActivation) = entries[index].kind
        else {
            return nil
        }
        entries[index].kind = .focusWindow(
            token: token,
            workspaceId: workspaceId,
            phase: .awaitingConfirmation
        )
        deadlineWheel?.schedule(intentId: requestId, after: Self.activationSettleDeadline)
        return entries[index].asManagedFocusRequest
    }

    func recordRetry(
        requestId: UInt64,
        source: ActivationEventSource,
        retryLimit: Int
    ) -> ManagedFocusRequest? {
        guard let index = entries.firstIndex(where: { $0.id == requestId && $0.phase == .pending }) else {
            return nil
        }
        guard case .focusWindow(_, _, .awaitingConfirmation) = entries[index].kind else {
            return nil
        }
        if managedFocusRetryMetricsActive {
            managedFocusRetryMetrics.attempts += 1
            if let lastSource = entries[index].lastActivationSource, lastSource != source {
                managedFocusRetryMetrics.sourceChanges += 1
            }
        }
        let nextAttempt = entries[index].retryCount + 1
        guard nextAttempt <= retryLimit else {
            if managedFocusRetryMetricsActive {
                managedFocusRetryMetrics.exhaustions += 1
            }
            return nil
        }

        entries[index].retryCount = nextAttempt
        entries[index].lastActivationSource = source
        deadlineWheel?.schedule(intentId: requestId, after: Self.activationSettleDeadline)
        if managedFocusRetryMetricsActive {
            managedFocusRetryMetrics.deadlineRearms += 1
        }
        return entries[index].asManagedFocusRequest
    }

    func beginManagedFocusRetryRuntimeCapture() {
        managedFocusRetryMetrics = ManagedFocusRetryRuntimeSnapshot()
        managedFocusRetryMetricsActive = true
    }

    func endManagedFocusRetryRuntimeCapture() {
        managedFocusRetryMetricsActive = false
    }

    func managedFocusRetryRuntimeSnapshot() -> ManagedFocusRetryRuntimeSnapshot {
        managedFocusRetryMetrics
    }

    @discardableResult
    func confirmManagedRequest(
        token: WindowToken,
        source: ActivationEventSource
    ) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.token == token else { return nil }
        if request.phase != .awaitingConfirmation,
           let index = entries.firstIndex(where: { $0.id == request.requestId }),
           case let .focusWindow(token, workspaceId, _) = entries[index].kind
        {
            entries[index].kind = .focusWindow(
                token: token,
                workspaceId: workspaceId,
                phase: .awaitingConfirmation
            )
        }
        guard let confirmed = confirm(id: request.requestId, source: source) else { return nil }
        deadlineWheel?.cancel(intentId: confirmed.id)
        lastConfirmedManagedFocus = (token: token, origin: confirmed.origin)
        return confirmed.asManagedFocusRequest
    }

    func rekeyManagedRequest(from oldToken: WindowToken, to newToken: WindowToken) {
        rekey(from: oldToken, to: newToken)
        if let lastConfirmedManagedFocus, lastConfirmedManagedFocus.token == oldToken {
            self.lastConfirmedManagedFocus = (token: newToken, origin: lastConfirmedManagedFocus.origin)
        }
    }

    func discardPendingFocus(_ token: WindowToken) {
        if deferredRetryRaise?.request.token == token {
            cancelDeferredRetryRaise()
        }
        if lastConfirmedManagedFocus?.token == token {
            lastConfirmedManagedFocus = nil
        }
    }
}
