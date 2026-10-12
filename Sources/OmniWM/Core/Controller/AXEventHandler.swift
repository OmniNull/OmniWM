// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class AXEventHandler {
    static let stabilizationRetryDelay: Duration = .milliseconds(100)
    static let createdWindowRetryLimit = 5
    static let createPlacementContextTTL: TimeInterval = 15
    static let activationRetryLimit = 5
    private static let windowCloseFocusRecoveryDuration: TimeInterval = 0.6
    static let sameAppCloseProbeDelay: Duration = .milliseconds(80)
    static let appTerminationFocusRecoveryTimeout: Duration = .milliseconds(600)
    static let mouseFocusIntentDuration: TimeInterval = 0.35

    weak var controller: WMController?
    var deferredCreatedWindowIds: Set<UInt32> = []
    private var deferredCreatedWindowOrder: [UInt32] = []
    var deferredReplacementProtectionsByWindowId: [UInt32: DeferredReplacementProtection] = [:]
    var activeIdentityRebindsByHandle: [WindowHandle: UInt64] = [:]
    var createPlacementContextsByWindowId: [UInt32: WindowCreatePlacementContext] = [:]
    private var pendingManagedReplacementBursts: [ManagedReplacementKey: PendingManagedReplacementBurst] = [:]
    private var pendingManagedReplacementTasks: [ManagedReplacementKey: Task<Void, Never>] = [:]
    private let ruleReevaluation: WindowRuleReevaluationScheduler
    var admissionRetryStateByWindowId: [UInt32: AdmissionRetryState] = [:]
    var nextAdmissionRetryGeneration: UInt64 = 1
    var nextAdmissionRetryExecutionOwner: UInt64 = 1
    private var nextActivationObservationGeneration: UInt64 = 1
    private var latestActivationObservationGeneration: UInt64 = 0
    var latestNativeActivationPID: pid_t?
    var terminalFrameFailureStateByWindowId: [Int: TerminalFrameFailureState] = [:]
    var admissionQuarantineByWindowId: [Int: AdmissionQuarantine] = [:]
    var identityAliasesByWindowId: [Int: WindowIdentityAliasHistory] = [:]
    var previouslyFocusedManagedToken: WindowToken?
    private var windowCloseFocusRecoveryContext: WindowCloseFocusRecoveryContext?
    private var recentMouseFocusIntent: RecentMouseFocusIntent?
    var recentUnmanagedPointerClickExpiresAt: Date?
    private var diagnostics = AXEventDiagnostics()
    private var nextManagedReplacementEventSequence: UInt64 = 0
    var visibleWindowInfoProvider: () -> [WindowServerInfo]
    var windowInfoProvider: (UInt32) -> WindowServerInfo?
    var windowInfoBatchProvider: (Set<UInt32>) async throws -> [UInt32: WindowServerInfo]?
    var createdWindowAXRefProvider: (WindowToken) async throws -> AXWindowRef? = lookupCreatedWindowIdentity
    var frameObservations = FrameObservations()
    var lifecycleQueries = LifecycleQueries()
    var windowSubscriptionProvider: ([UInt32]) -> Bool
    var preparedWindowSubscriptionRetainCounts: [UInt32: Int] = [:]
    var windowSubscriptionIdentityRevision: UInt64 = 0
    var lastSuccessfulWindowSubscriptionIds: [UInt32] = []
    var lastSuccessfulWindowSubscriptionRevision: UInt64?
    var lastWindowSubscriptionFailureRevision: UInt64?
    var managedWindowIdentityRebindAcknowledgementProvider:
        ((AXManagedWindowIdentity, AXManagedWindowIdentity) async -> Bool)?
    var managedWindowIdentityRebindFinalizationProvider:
        ((AXManagedWindowIdentity, AXManagedWindowIdentity) async -> Bool)?
    var managedWindowIdentityRebindTargetIsAliveProvider: ((pid_t) -> Bool)?
    var frontmostApplicationPIDProvider: () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    var applicationIsHiddenProvider: @MainActor (pid_t) -> Bool = AXEventHandler.nativeApplicationIsHidden

    var applicationIsTerminatedProvider: (pid_t) -> Bool = { pid in
        if AppAXContextRegistry.contexts[pid]?.nsApp.isTerminated == true {
            return true
        }
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return true
        }
        return application.isTerminated
    }

    init(
        controller: WMController,
        visibleWindowInfoProvider: @escaping () -> [WindowServerInfo] = {
            SkyLight.shared.queryAllVisibleWindows()
        },
        windowInfoProvider: @escaping (UInt32) -> WindowServerInfo? = {
            SkyLight.shared.queryWindowInfo($0)
        },
        windowInfoBatchProvider: @escaping (Set<UInt32>) async throws -> [UInt32: WindowServerInfo]? = {
            try await SkyLight.shared.queryWindowInfoDeferred(windowIds: $0)
        },
        windowSubscriptionProvider: @escaping ([UInt32]) -> Bool = {
            CGSEventObserver.shared.subscribeToWindows($0)
        }
    ) {
        self.controller = controller
        ruleReevaluation = WindowRuleReevaluationScheduler(controller: controller)
        self.visibleWindowInfoProvider = visibleWindowInfoProvider
        self.windowInfoProvider = windowInfoProvider
        self.windowInfoBatchProvider = windowInfoBatchProvider
        self.windowSubscriptionProvider = windowSubscriptionProvider
    }

    func cleanup() {
        cancelLifecycleQueries()
        cancelFrameObservations()
        resetCreatePlacementContextState()
        resetManagedReplacementState()
        endWindowCloseFocusRecovery(reason: "cleanup")
        cancelSameAppCloseProbe(reason: "cleanup")
        resetCreatedWindowRetryState()
        terminalFrameFailureStateByWindowId.removeAll()
        admissionQuarantineByWindowId.removeAll()
        identityAliasesByWindowId.removeAll()
        ruleReevaluation.reset()
        preparedWindowSubscriptionRetainCounts.removeAll()
        windowSubscriptionIdentityRevision &+= 1
        CGSEventObserver.shared.stop()
    }
}

extension AXEventHandler {
    func scheduleWindowRuleReevaluationIfNeeded(targets: Set<WindowRuleReevaluationTarget>) {
        ruleReevaluation.schedule(targets: targets)
    }

    func hasPendingManagedReplacementDestroy(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        evidence: WindowDestroyEvidence? = nil
    ) -> Bool {
        let key = ManagedReplacementKey(pid: token.pid, workspaceId: workspaceId)
        return pendingManagedReplacementBursts[key]?.destroys.contains {
            $0.candidate.token == token && (evidence == nil || $0.candidate.evidence == evidence)
        } == true
    }

    func drainDeferredCreatedWindows(
        spaceIdsForWindow: @escaping (UInt32) -> [UInt64] = { SkyLight.shared.spacesForWindow($0) }
    ) {
        guard !deferredCreatedWindowOrder.isEmpty else { return }

        let deferredWindowIds = deferredCreatedWindowOrder
        for windowId in deferredWindowIds {
            guard let controller else { return }
            processDeferredCreatedWindow(windowId, controller: controller, spaceIdsForWindow: spaceIdsForWindow)
        }
    }

    func beginWindowCloseFocusRecovery(
        in workspaceId: WorkspaceDescriptor.ID,
        closedToken: WindowToken
    ) -> Bool {
        guard let controller else { return false }
        guard isWorkspaceActive(workspaceId) else {
            endWindowCloseFocusRecovery(reason: "inactive_workspace")
            return false
        }

        windowCloseFocusRecoveryContext = WindowCloseFocusRecoveryContext(
            workspaceId: workspaceId,
            closedToken: closedToken,
            expiresAt: Date().addingTimeInterval(Self.windowCloseFocusRecoveryDuration)
        )
        controller.focusPolicyEngine.beginLease(
            owner: .windowCloseFocusRecovery,
            reason: "window_close_focus_recovery",
            suppressesFocusFollowsMouse: true,
            duration: Self.windowCloseFocusRecoveryDuration,
            notify: false
        )
        return true
    }

    func activeWindowCloseFocusRecoveryWorkspaceId() -> WorkspaceDescriptor.ID? {
        guard let context = windowCloseFocusRecoveryContext else { return nil }
        guard context.expiresAt > Date(), isWorkspaceActive(context.workspaceId) else {
            endWindowCloseFocusRecovery(reason: "expired_or_inactive")
            return nil
        }
        return context.workspaceId
    }

    func endWindowCloseFocusRecovery(
        matching workspaceId: WorkspaceDescriptor.ID? = nil,
        reason: String = "end"
    ) {
        if let workspaceId, windowCloseFocusRecoveryContext?.workspaceId != workspaceId {
            return
        }
        guard windowCloseFocusRecoveryContext != nil else { return }
        windowCloseFocusRecoveryContext = nil
        controller?.focusPolicyEngine.endLease(owner: .windowCloseFocusRecovery, notify: false)
    }

    func shouldSuppressObservedActivationDuringWindowCloseRecovery(
        observedToken: WindowToken,
        requestDisposition: ActivationRequestDisposition
    ) -> Bool {
        guard activeWindowCloseFocusRecoveryWorkspaceId() != nil,
              let context = windowCloseFocusRecoveryContext,
              context.closedToken.pid == observedToken.pid
        else {
            return false
        }

        if case .matchesActiveRequest = requestDisposition {
            return false
        }
        return true
    }

    func shouldSuppressExternalFocusFallbackDuringWindowCloseRecovery(
        observedToken: WindowToken,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard activeWindowCloseFocusRecoveryWorkspaceId() != nil,
              windowCloseFocusRecoveryContext?.closedToken.pid == observedToken.pid
        else {
            return false
        }

        if case .matchesActiveRequest = requestDisposition {
            return false
        }
        return true
    }

    func noteMouseFocusIntent(token: WindowToken) {
        recentMouseFocusIntent = RecentMouseFocusIntent(
            token: token,
            expiresAt: Date().addingTimeInterval(Self.mouseFocusIntentDuration)
        )
        finishMouseFocusIntent(token)
    }

    func hasRecentMouseFocusIntent(for token: WindowToken) -> Bool {
        guard let intent = recentMouseFocusIntent else { return false }
        guard intent.expiresAt > Date() else {
            recentMouseFocusIntent = nil
            return false
        }
        return intent.token == token
    }

    func hasRecentMouseFocusIntent(forPID pid: pid_t) -> Bool {
        guard let intent = recentMouseFocusIntent else { return false }
        guard intent.expiresAt > Date() else {
            recentMouseFocusIntent = nil
            return false
        }
        return managedWindowTokenUsingCachedIdentity(intent.token, matchesObservedPid: pid)
    }

    func retireStaleActivationObservation(pid: pid_t, causalObservationGeneration: UInt64?) -> Bool {
        if let causalObservationGeneration,
           causalObservationGeneration != latestActivationObservationGeneration
        {
            retireStaleFocusedAdmissionRetry(
                pid: pid,
                observationGeneration: causalObservationGeneration
            )
            return true
        }
        return false
    }

    func beginActivationObservation(
        pid: pid_t,
        source: ActivationEventSource,
        causalGeneration: UInt64?,
        controller: WMController
    ) -> UInt64 {
        recordNiriCreateFocusTrace(
            .init(
                kind: .activationSourceObserved(
                    pid: pid,
                    source: source
                )
            )
        )
        controller.scratchpadStacking.noteScratchpadStackingAppActivation(pid: pid, source: source)
        if let causalGeneration {
            return causalGeneration
        }
        invalidateActivationObservations()
        return latestActivationObservationGeneration
    }

    func invalidateActivationObservations() {
        latestActivationObservationGeneration = nextActivationObservationGeneration
        nextActivationObservationGeneration &+= 1
    }

    func isCurrentFocusedAdmissionContinuation(
        _ continuation: FocusedAdmissionRetryContinuation
    ) -> Bool {
        guard continuation.observationGeneration == latestActivationObservationGeneration else {
            return false
        }
        guard let callbackGeneration = continuation.callbackGeneration else { return true }
        return AppAXContextRegistry.contexts[continuation.token.pid]?.callbackGeneration == callbackGeneration
    }

    func awaitPendingManagedReplacementBursts(for appPIDs: Set<pid_t>? = nil) async {
        let tasks = pendingManagedReplacementTasks
            .filter { appPIDs?.contains($0.key.pid) ?? true }
            .sorted {
                ($0.key.pid, $0.key.workspaceId.uuidString)
                    < ($1.key.pid, $1.key.workspaceId.uuidString)
            }
            .map(\.value)
        for task in tasks {
            guard !Task.isCancelled else { return }
            await task.value
        }
    }

    func resetManagedReplacementState() {
        if let open = controller?.intentLedger.openSameAppCloseProbe(),
           hasPendingManagedReplacementDestroy(open.payload.focusedToken)
        {
            cancelSameAppCloseProbe(
                matchingFocusedToken: open.payload.focusedToken,
                reason: "managed_replacement_reset"
            )
        }
        let preparedWindowIds =
            pendingManagedReplacementBursts.values.flatMap { burst in
                burst.creates.map(\.candidate.windowId)
            }
        for (_, task) in pendingManagedReplacementTasks {
            task.cancel()
        }
        pendingManagedReplacementTasks.removeAll()
        pendingManagedReplacementBursts.removeAll()
        releasePreparedWindowSubscriptions(preparedWindowIds)
        if let controller {
            for intent in controller.intentLedger.openReplacementFocusIntents() {
                _ = controller.intentLedger.cancel(id: intent.id)
            }
        }
        nextManagedReplacementEventSequence = 0
    }

    func shouldDelayManagedReplacementCreate(_ candidate: PreparedCreate) -> Bool {
        guard managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) != nil else {
            return false
        }

        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        if pendingManagedReplacementBursts[key] != nil {
            return true
        }

        return candidate.structuralReplacementMatch?.source == .pendingDestroy
    }

    func enqueueManagedReplacementCreate(
        _ candidate: PreparedCreate,
        focusedActivation: PendingFocusedManagedActivation? = nil
    ) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        recordDeferredManagedReplacementCreate(candidate)
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        armManagedReplacementFocusTransaction(
            token: candidate.token,
            workspaceId: candidate.workspaceId
        )
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let pendingCreate = PendingManagedCreate(
            sequence: nextManagedReplacementSequence(),
            candidate: candidate,
            focusedActivation: focusedActivation
        )
        guard burst.append(create: pendingCreate) else {
            releasePreparedWindowSubscription(candidate.windowId)
            return
        }
        pendingManagedReplacementBursts[key] = burst
        finishManagedReplacementEnqueue(burst, key: key, resetExistingDeadline: isNewBurst)
    }

    func enqueueManagedReplacementDestroy(_ candidate: PreparedDestroy) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        armManagedReplacementFocusTransaction(
            token: candidate.token,
            workspaceId: candidate.workspaceId
        )
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let pendingDestroy = PendingManagedDestroy(sequence: nextManagedReplacementSequence(), candidate: candidate)
        burst.append(destroy: pendingDestroy)
        pendingManagedReplacementBursts[key] = burst
        holdSameAppCloseProbe(matchingFocusedToken: candidate.token)
        finishManagedReplacementEnqueue(burst, key: key, resetExistingDeadline: isNewBurst)
    }

    func flushManagedReplacementBurstIfUnambiguouslyMatched(for key: ManagedReplacementKey) -> Bool {
        guard let burst = pendingManagedReplacementBursts[key],
              burst.destroys.count == 1,
              burst.creates.count == 1,
              matchedManagedReplacementPair(in: burst) != nil
        else {
            return false
        }
        flushManagedReplacementBurst(for: key)
        return true
    }

    func visitPendingReplacementDestroys(
        pid: pid_t, visit: (PreparedDestroy) -> Bool
    ) -> Bool {
        for burst in pendingManagedReplacementBursts.values {
            for destroy in burst.destroys where destroy.candidate.token.pid == pid {
                if !visit(destroy.candidate) { return false }
            }
        }
        return true
    }

    func scheduleManagedReplacementFlush(
        for key: ManagedReplacementKey,
        policy: ManagedReplacementCorrelationPolicy,
        resetExistingDeadline: Bool
    ) {
        if resetExistingDeadline {
            pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        } else if pendingManagedReplacementTasks[key] != nil {
            return
        }

        let delay = policy.graceDelay
        pendingManagedReplacementTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushManagedReplacementBurst(for: key)
        }
    }

    private func nextManagedReplacementSequence() -> UInt64 {
        defer { nextManagedReplacementEventSequence += 1 }
        return nextManagedReplacementEventSequence
    }

    func deferCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.insert(windowId).inserted else { return }
        deferredCreatedWindowOrder.append(windowId)
    }

    func removeDeferredCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.remove(windowId) != nil else { return }
        deferredCreatedWindowOrder.removeAll { $0 == windowId }
    }
}

extension AXEventHandler {
    func isCurrentActivationFacts(_ facts: ActivationFacts, controller: WMController) -> Bool {
        guard facts.observationGeneration == latestActivationObservationGeneration else { return false }
        return areActivationFactsApplicable(facts, controller: controller)
    }

    func recordNiriCreateFocusTrace(_ event: NiriCreateFocusTraceEvent) {
        diagnostics.recordNiriCreateFocusTrace(event)
    }

    func createFocusTraceDump() -> String {
        diagnostics.createFocusTraceDump()
    }

    func managedReplacementTraceDump() -> String {
        diagnostics.managedReplacementTraceDump()
    }

    func recordManagedReplacementTrace(key: ManagedReplacementKey, kind: ManagedReplacementTraceEvent.Kind) {
        diagnostics.recordManagedReplacementTrace(key: key, kind: kind)
    }

    func takeManagedReplacementBurst(for key: ManagedReplacementKey) -> PendingManagedReplacementBurst? {
        pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        return pendingManagedReplacementBursts.removeValue(forKey: key)
    }

    func continueNativeFocusProbe(pid: pid_t) {
        handleAppActivation(
            pid: pid,
            source: .focusedWindowChanged,
            origin: .probe,
            causalObservationGeneration: latestActivationObservationGeneration
        )
    }
}
