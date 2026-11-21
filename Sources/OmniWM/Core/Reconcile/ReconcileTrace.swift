// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ReconcileTraceRecord: Equatable {
    let sequence: UInt64
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let invariantViolations: [ReconcileInvariantViolation]
}

@MainActor
final class ReconcileTraceRecorder {
    private static let defaultLimit = 256

    private let nowProvider: () -> Date
    private let validatesScopes: Bool
    var scopeValidationRequested = false
    private(set) var transactionCount: UInt64 = 0
    private var invariantViolationCounts: [String: Int] = [:]
    private var nextSequence: UInt64 = 1
    private var records: RingBuffer<ReconcileTraceRecord>

    init(limit: Int = defaultLimit, validatesScopes: Bool, nowProvider: @escaping () -> Date = Date.init) {
        records = RingBuffer(capacity: limit)
        self.validatesScopes = validatesScopes
        self.nowProvider = nowProvider
    }

    var validatesEveryScope: Bool {
        validatesScopes || scopeValidationRequested
    }

    func recordTransaction(
        event: WMEvent,
        normalizedEvent: WMEvent,
        resolvedPlan: ActionPlan,
        committedSnapshot: ReconcileSnapshot,
        validateInvariants: Bool
    ) -> ReconcileTxn {
        transactionCount &+= 1
        var tracedPlan = resolvedPlan
        let invariantViolations = validateInvariants
            ? noteViolations(in: committedSnapshot, after: event, plan: &tracedPlan)
            : []
        let txn = ReconcileTxn(
            timestamp: nowProvider(),
            event: event,
            normalizedEvent: normalizedEvent,
            plan: tracedPlan,
            snapshot: committedSnapshot,
            invariantViolations: invariantViolations
        )
        append(transaction: txn)
        return txn
    }

    func recordScope(event: WMEvent, validating snapshot: ReconcileSnapshot?) {
        var plan = ActionPlan()
        plan.notes = ActionPlan.userCommandNotes
        var invariantViolations: [ReconcileInvariantViolation] = []
        if let snapshot {
            invariantViolations = noteViolations(in: snapshot, after: event, plan: &plan)
        }
        append(event: event, plan: plan, invariantViolations: invariantViolations, timestamp: nowProvider())
    }

    private func noteViolations(
        in snapshot: ReconcileSnapshot,
        after event: WMEvent,
        plan: inout ActionPlan
    ) -> [ReconcileInvariantViolation] {
        let invariantViolations = InvariantChecks.validate(snapshot: snapshot)
        guard !invariantViolations.isEmpty else { return invariantViolations }
        plan.notes.append(contentsOf: invariantViolations.map(\.traceNote))
        for violation in invariantViolations {
            invariantViolationCounts[violation.code, default: 0] += 1
        }
        assertionFailure(
            "Reconcile invariants violated after \(event.summary): "
                + invariantViolations.map(\.code).joined(separator: ",")
        )
        return invariantViolations
    }

    func invariantViolationCountsDump() -> String {
        guard !invariantViolationCounts.isEmpty else { return "clean" }
        return invariantViolationCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    func append(
        event: WMEvent,
        normalizedEvent: WMEvent? = nil,
        plan: ActionPlan,
        invariantViolations: [ReconcileInvariantViolation] = [],
        timestamp: Date = Date()
    ) {
        let strippedEvent = event.strippingAXReferences()
        let record = ReconcileTraceRecord(
            sequence: nextSequence,
            timestamp: timestamp,
            event: strippedEvent,
            normalizedEvent: normalizedEvent.map { $0.strippingAXReferences() } ?? strippedEvent,
            plan: plan,
            invariantViolations: invariantViolations
        )
        nextSequence += 1
        records.append(record)
    }

    func append(transaction: ReconcileTxn) {
        append(
            event: transaction.event,
            normalizedEvent: transaction.normalizedEvent,
            plan: transaction.plan,
            invariantViolations: transaction.invariantViolations,
            timestamp: transaction.timestamp
        )
    }

    func snapshot() -> [ReconcileTraceRecord] {
        records.snapshot()
    }

    func reset() {
        records.removeAll()
        nextSequence = 1
    }
}
