// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorldStore {
    static var validatesScopesByDefault: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    var scopeValidationRequested: Bool {
        get { trace.scopeValidationRequested }
        set { trace.scopeValidationRequested = newValue }
    }

    var validatesEveryScope: Bool {
        trace.validatesEveryScope
    }

    func traceRecords() -> [ReconcileTraceRecord] {
        trace.snapshot()
    }

    func invariantViolationCountsDump() -> String {
        trace.invariantViolationCountsDump()
    }

    func isSeqCurrent(
        _ plannedSeq: UInt64,
        for workspaceId: WorkspaceDescriptor.ID,
        domains: InvalidationDomain
    ) -> Bool {
        invalidationMarks(for: workspaceId).isCurrent(plannedSeq, domains: domains)
    }

    func isSeqEpochCurrent(_ plannedSeq: UInt64, domains: InvalidationDomain) -> Bool {
        epochMarks.isCurrent(plannedSeq, domains: domains)
    }

    func pushEngineSanction() {
        let sanctioned = isEngineMutationSanctioned
        niriEngine?.isMutationSanctioned = sanctioned
        dwindleEngine?.isMutationSanctioned = sanctioned
    }

    func withWindowMoveObserver(_ publish: (ConfigScriptEventObservers) -> Void) {
        if let client = ConfigScriptEventObservers.borrowRegistration(&scriptWindowMoveObserver, publish) {
            publish(client)
        }
    }

    func publishMoves(
        _ transaction: borrowing ReconcileTxn, in moves: ConfigScriptWindowMoves, depth: Int, wasTracked: Bool
    ) {
        guard moves.hasMoves(at: depth),
              let manager = scriptWindowMoveObserver?.controller?.workspaceManager else { return }
        let admission = if case .windowAdmitted = transaction.event { !wasTracked } else { false }
        let hydrated = transaction.plan.persistedHydration != nil
        withWindowMoveObserver { observer in
            moves.publish(depth: depth, to: observer, in: manager, admission: admission, hydrated: hydrated)
        }
    }

    var isEngineMutationSanctioned: Bool {
        commitDepth > 0
    }

    func assertInCommit(_ operation: StaticString) {
        assert(commitDepth > 0, "\(operation) must run inside WorldStore.commit")
    }

    @inline(__always)
    func borrowWindowStateObserver(
        _ kind: ConfigScriptEventKind, _ publish: (ConfigScriptEventObservers) -> Void
    ) -> ConfigScriptEventObservers? {
        switch kind {
        case .windowMinimize: ConfigScriptEventObservers.borrowRegistration(&scriptWindowMinimizeObserver, publish)
        case .windowUpdateState: ConfigScriptEventObservers.borrowRegistration(&scriptWindowModeObserver, publish)
        default: preconditionFailure()
        }
    }

    func settleScriptWindowState(_ observer: ConfigScriptEventObservers) {
        if isEngineMutationSanctioned {
            pendingScriptWindowState = observer
        } else {
            observer.publishSettledWindowStates()
        }
    }

    func commitScope(
        in workspaceId: WorkspaceDescriptor.ID?,
        label: String,
        source: WMEventSource,
        snapshot: () -> ReconcileSnapshot,
        _ body: () -> Void
    ) {
        let event = WMEvent.userCommand(workspaceId: workspaceId, label: label, source: source)
        let transactionsAtEntry = trace.transactionCount
        inCommitFrame(event) { isOutermost in
            body()
            let validates = isOutermost && (trace.validatesEveryScope || trace.transactionCount != transactionsAtEntry)
            trace.recordScope(event: event, validating: validates ? snapshot() : nil)
        }
    }
}
