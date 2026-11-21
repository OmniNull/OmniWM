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
