// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class WorldStore {
    private let model: WindowModel
    let windows: WindowModel.ReadView
    private let trace: ReconcileTraceRecorder
    private(set) var seq: UInt64 = 0
    private(set) var focus = FocusSessionSnapshot()
    private(set) var viewports: [WorkspaceDescriptor.ID: ViewportState] = [:]
    private(set) var scratchpads = ScratchpadState()
    private(set) var hiddenAppPIDs: Set<pid_t> = []
    private var appVisibilityGenerationByPID: [pid_t: UInt64] = [:]
    private(set) var monitorSessions: [Monitor.ID: MonitorSession] = [:]
    private(set) var spaceTopology = SpaceTopology()
    private(set) var niriEngine: NiriLayoutEngine?
    private(set) var dwindleEngine: DwindleLayoutEngine?
    private var activeLayoutResolver: ((WorkspaceDescriptor.ID) -> ActiveLayoutKind)?
    private(set) var epochMarks = InvalidationMarks()
    private var broadcastMarks = InvalidationMarks()
    private var workspaceMarks: [WorkspaceDescriptor.ID: InvalidationMarks] = [:]
    private var commitDepth = 0
    private var currentCommitEvent: WMEvent?

    var isEngineMutationSanctioned: Bool {
        commitDepth > 0
    }

    private func pushEngineSanction() {
        let sanctioned = isEngineMutationSanctioned
        niriEngine?.isMutationSanctioned = sanctioned
        dwindleEngine?.isMutationSanctioned = sanctioned
    }

    init(nowProvider: @escaping () -> Date = Date.init) {
        let model = WindowModel()
        self.model = model
        windows = WindowModel.ReadView(model: model)
        trace = ReconcileTraceRecorder(nowProvider: nowProvider)
    }

    @discardableResult
    func commit(
        _ event: WMEvent,
        monitors: [Monitor],
        snapshot: () -> ReconcileSnapshot,
        completeSnapshot: (inout ReconcileSnapshot) -> Void = { _ in },
        preMutate: () -> Void = {},
        resolvePlan: (ActionPlan, WindowToken?, ReconcileSnapshot) -> ActionPlan
    ) -> ReconcileTxn {
        commitDepth += 1
        pushEngineSanction()
        let previousCommitEvent = currentCommitEvent
        currentCommitEvent = event
        defer {
            commitDepth -= 1
            pushEngineSanction()
            currentCommitEvent = previousCommitEvent
        }
        seq &+= 1

        let windowExistedBeforeMutation = if case .windowAdmitted = event {
            event.token.flatMap { model.entry(for: $0) } != nil
        } else {
            false
        }
        preMutate()
        let familyEvents = hostedFamilyEvents(for: event, monitors: monitors)
        applyWindowMutationBeforePlan(event, monitors: monitors)
        let existingEntry = event.token.flatMap { model.entry(for: $0) }
        let normalizedEvent = EventNormalizer.normalize(
            event: event,
            existingEntry: existingEntry,
            monitors: monitors
        )
        let reducerSnapshot = snapshot()
        let plan = StateReducer.reduce(
            event: normalizedEvent,
            existingEntry: existingEntry,
            currentSnapshot: reducerSnapshot,
            monitors: monitors,
            windowExistedBeforeMutation: windowExistedBeforeMutation
        )
        var resolvedPlan = resolvePlan(plan, normalizedEvent.token, reducerSnapshot)
        applyHostedFamilyEvents(familyEvents, monitors: monitors, snapshot: snapshot, plan: &resolvedPlan)
        applyWindowRemovalAfterPlan(event, monitors: monitors)

        var committedSnapshot = resolvedPlan.mutatesRuntimeState || event.mutatesSnapshotAfterPlan || !familyEvents
            .isEmpty
            ? snapshot()
            : reducerSnapshot
        completeSnapshot(&committedSnapshot)
        return trace.recordTransaction(
            event: event,
            normalizedEvent: normalizedEvent,
            resolvedPlan: resolvedPlan,
            committedSnapshot: committedSnapshot,
            validateInvariants: commitDepth == 1
        )
    }

    func traceRecords() -> [ReconcileTraceRecord] {
        trace.snapshot()
    }

    func invariantViolationCountsDump() -> String {
        trace.invariantViolationCountsDump()
    }

    func noteInvalidation(workspaceId: WorkspaceDescriptor.ID?, domains: InvalidationDomain) {
        seq &+= 1
        epochMarks.record(seq, domains: domains)
        if let workspaceId {
            workspaceMarks[workspaceId, default: InvalidationMarks()].record(seq, domains: domains)
        } else {
            broadcastMarks.record(seq, domains: domains)
        }
    }

    func noteInvalidation(
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        domains: InvalidationDomain
    ) {
        guard !workspaceIds.isEmpty else { return }
        seq &+= 1
        epochMarks.record(seq, domains: domains)
        for workspaceId in workspaceIds {
            workspaceMarks[workspaceId, default: InvalidationMarks()].record(seq, domains: domains)
        }
    }

    func invalidationMarks(for workspaceId: WorkspaceDescriptor.ID) -> InvalidationMarks {
        broadcastMarks.merged(with: workspaceMarks[workspaceId] ?? InvalidationMarks())
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

    func removeInvalidationMarks<S: Sequence>(for workspaceIds: S) where S.Element == WorkspaceDescriptor.ID {
        for workspaceId in workspaceIds {
            workspaceMarks.removeValue(forKey: workspaceId)
        }
    }

    func applyWindowMutationBeforePlan(_ event: WMEvent, monitors: [Monitor]) {
        switch event.reconcileDomain {
        case .window:
            applyWindowEventBeforePlan(event, monitors: monitors)
        case .session:
            applySessionEventBeforePlan(event)
        case .focus,
             .viewport:
            break
        }
    }

    private func applyWindowEventBeforePlan(_ event: WMEvent, monitors: [Monitor]) {
        switch event {
        case .windowAdmitted:
            applyWindowAdmission(event, monitors: monitors)

        case .windowRekeyed:
            applyWindowRekey(event)

        case .topLevelInventoryObserved,
             .floatingGeometryUpdated,
             .hostedWindowGeometryObserved,
             .floatingStateChanged,
             .manualLayoutOverrideChanged,
             .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .hiddenStateChanged,
             .nativeFullscreenTransition,
             .managedReplacementMetadataChanged:
            model.applyFieldMutation(event, monitors: monitors)

        case let .workspaceAssigned(token, _, to, _, _):
            updateWorkspace(for: token, workspace: to, monitors: monitors)
            refreshProjectionExclusions(in: [to])

        case let .windowModeChanged(token, workspaceId, _, mode, _):
            setMode(mode, for: token, monitors: monitors)
            if mode == .tiling {
                refreshProjectionExclusions(in: [workspaceId])
            }

        case let .windowAdmissionHintsChanged(token, _, admissionHints, _):
            guard canUpdateAdmissionHints(for: token) else { return }
            model.setAdmissionHints(admissionHints, for: token)

        case .hiddenApplicationsChanged:
            applyHiddenApplications(event)

        case let .windowMinimizedChanged(token, workspaceId, minimized, _):
            guard var state = windows.entry(for: token)?.observedState else { return }
            state.isMinimized = minimized
            model.setObservedState(state, for: token)
            refreshProjectionExclusions(in: [workspaceId])

        case let .windowNativeWithdrawalChanged(token, workspaceId, withdrawn, _):
            guard var state = windows.entry(for: token)?.observedState else { return }
            state.isNativeWithdrawn = withdrawn
            model.setObservedState(state, for: token)
            refreshProjectionExclusions(in: [workspaceId])

        case let .appVisibilityInvalidated(pid, _, _):
            appVisibilityGenerationByPID[pid, default: 0] &+= 1

        case .layoutOperationPerformed,
             .windowRemoved:
            break

        default:
            preconditionFailure("Expected a window event")
        }
    }

    private func applySessionEventBeforePlan(_ event: WMEvent) {
        switch event {
        case let .scratchpadMembershipChanged(token, index, _):
            scratchpads.assign(token, to: index)

        case let .scratchpadRevealChanged(index, _):
            scratchpads.reveal(index)

        case let .visibleWorkspacesChanged(sessions, _):
            monitorSessions = sessions

        case let .spaceTopologyChanged(topology, _):
            spaceTopology = topology

        case .activeSpaceChanged,
             .systemSleep,
             .systemWake,
             .topologyChanged,
             .userCommand:
            break

        default:
            preconditionFailure("Expected a session event")
        }
    }

    private func applyWindowAdmission(_ event: WMEvent, monitors: [Monitor]) {
        guard case let .windowAdmitted(
            token,
            workspaceId,
            _,
            mode,
            target,
            ruleEffects,
            admissionHints,
            lifetimeAuthority,
            _,
            metadata,
            _,
            _
        ) = event else { preconditionFailure("Unexpected event for applyWindowAdmission") }
        let resolvedAdmissionHints = canUpdateAdmissionHints(for: token)
            ? admissionHints
            : model.admissionHints(for: token) ?? admissionHints
        model.upsert(
            target: target,
            pid: token.pid,
            windowId: token.windowId,
            workspace: workspaceId,
            mode: mode,
            ruleEffects: ruleEffects,
            admissionHints: resolvedAdmissionHints,
            lifetimeAuthority: lifetimeAuthority,
            managedReplacementMetadata: metadata
        )
        reconcileNiriMembership(
            for: token,
            keeping: mode == .tiling ? workspaceId : nil,
            monitors: monitors
        )
        refreshProjectionExclusions(in: [workspaceId])
    }

    private func applyWindowRekey(_ event: WMEvent) {
        guard case let .windowRekeyed(from, to, workspaceId, _, _, newAXRef, metadata, _) = event
        else { preconditionFailure("Unexpected event for applyWindowRekey") }
        spaceTopology.rekeyWindow(from: from.windowId, to: to.windowId)
        model.rekeyWindow(
            from: from,
            to: to,
            newAXRef: newAXRef,
            managedReplacementMetadata: metadata
        )
        _ = niriEngine?.rekeyWindow(from: from, to: to, in: workspaceId)
        _ = dwindleEngine?.rekeyWindow(from: from, to: to, in: workspaceId)
        scratchpads.rekey(from: from, to: to)
        refreshProjectionExclusions(in: [workspaceId])
    }

    private func applyHiddenApplications(_ event: WMEvent) {
        guard case let .hiddenApplicationsChanged(pids, affectedWorkspaceIds, _) = event
        else { preconditionFailure("Unexpected event for applyHiddenApplications") }
        for pid in hiddenAppPIDs.symmetricDifference(pids) {
            appVisibilityGenerationByPID[pid, default: 0] &+= 1
        }
        hiddenAppPIDs = pids
        refreshProjectionExclusions(in: affectedWorkspaceIds)
    }

    private func applyWindowRemovalAfterPlan(_ event: WMEvent, monitors: [Monitor]) {
        guard case let .windowRemoved(token, _, _) = event else { return }
        model.removeWindow(key: token)
        spaceTopology.windowSpace.removeValue(forKey: token.windowId)
        reconcileNiriMembership(for: token, keeping: nil, monitors: monitors)
    }

    func assertInCommit(_ operation: StaticString) {
        assert(commitDepth > 0, "\(operation) must run inside WorldStore.commit")
    }
}

extension WorldStore {
    func appVisibilityGeneration(for pid: pid_t) -> UInt64 {
        appVisibilityGenerationByPID[pid] ?? 0
    }

    func applyMonitorSessions(_ sessions: [Monitor.ID: MonitorSession]) {
        assertInCommit("applyMonitorSessions")
        monitorSessions = sessions
    }

    func setLifecyclePhase(_ phase: WindowLifecyclePhase, for token: WindowToken) {
        assertInCommit("setLifecyclePhase")
        model.setLifecyclePhase(phase, for: token)
    }

    func setObservedState(_ state: ObservedWindowState, for token: WindowToken) {
        assertInCommit("setObservedState")
        model.setObservedState(state, for: token)
    }

    func setDesiredState(_ state: DesiredWindowState, for token: WindowToken) {
        assertInCommit("setDesiredState")
        model.setDesiredState(state, for: token)
    }

    func setRestoreIntent(_ intent: RestoreIntent?, for token: WindowToken) {
        assertInCommit("setRestoreIntent")
        model.setRestoreIntent(intent, for: token)
    }

    func updateWorkspace(
        for token: WindowToken,
        workspace: WorkspaceDescriptor.ID,
        monitors: [Monitor]
    ) {
        assertInCommit("updateWorkspace")
        model.updateWorkspace(for: token, workspace: workspace)
        reconcileNiriMembership(
            for: token,
            keeping: model.mode(for: token) == .tiling ? workspace : nil,
            monitors: monitors
        )
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken, monitors: [Monitor]) {
        assertInCommit("setMode")
        model.setMode(mode, for: token)
        reconcileNiriMembership(
            for: token,
            keeping: mode == .tiling ? model.workspace(for: token) : nil,
            monitors: monitors
        )
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        assertInCommit("setFloatingState")
        model.setFloatingState(state, for: token)
    }

    func applyFocusSession(_ focusSession: FocusSessionSnapshot) {
        assertInCommit("applyFocusSession")
        InteractionMonitorWriteRecorder.shared.recordFocusTransition(
            previousInteraction: focus.interactionMonitorId,
            previousPrevious: focus.previousInteractionMonitorId,
            to: focusSession,
            event: currentCommitEvent
        )
        focus = focusSession
    }

    @discardableResult
    func updateFocus<T>(_ mutate: (inout FocusSessionSnapshot) -> T) -> T {
        assertInCommit("updateFocus")
        let previousInteraction = focus.interactionMonitorId
        let previousPrevious = focus.previousInteractionMonitorId
        let result = mutate(&focus)
        InteractionMonitorWriteRecorder.shared.recordFocusTransition(
            previousInteraction: previousInteraction,
            previousPrevious: previousPrevious,
            to: focus,
            event: currentCommitEvent
        )
        return result
    }

    func layoutTopology(for workspaceId: WorkspaceDescriptor.ID) -> LayoutTopology {
        switch activeLayoutResolver?(workspaceId) {
        case .dwindle:
            return LayoutTopology(dwindleFullscreenTokens: dwindleEngine?.fullscreenTokens(in: workspaceId) ?? [])
        case .niri,
             nil:
            return LayoutTopology(columns: niriEngine?.topologyColumns(in: workspaceId) ?? [])
        }
    }

    func installActiveLayoutResolver(_ resolver: ((WorkspaceDescriptor.ID) -> ActiveLayoutKind)?) {
        activeLayoutResolver = resolver
    }

    @discardableResult
    func installNiriEngine(_ engine: NiriLayoutEngine?, monitors: [Monitor]) -> Bool {
        let captured = if let current = niriEngine, current !== engine {
            captureNiriPlacements(from: current, monitors: monitors)
        } else {
            false
        }
        engine?.isMutationSanctioned = isEngineMutationSanctioned
        niriEngine = engine
        return captured
    }

    @discardableResult
    func storeNiriPlacement(
        _ placement: PersistedNiriPlacement,
        detached: Bool,
        for token: WindowToken,
        monitors: [Monitor]
    ) -> Bool {
        guard let entry = model.entry(for: token) else { return false }
        var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
        restoreIntent.niriPlacement = placement
        if detached {
            restoreIntent.detachedNiriContainerSizingState = NiriContainerSizingState(
                width: placement.column.width,
                presetWidthIndex: placement.column.presetWidthIndex,
                isFullWidth: placement.column.isFullWidth,
                savedWidth: placement.column.savedWidth,
                hasManualSingleWindowWidthOverride: placement.column.hasManualSingleWindowWidthOverride,
                height: placement.column.height,
                isFullHeight: placement.column.isFullHeight,
                savedHeight: placement.column.savedHeight,
                hasManualSingleWindowHeightOverride: placement.column.hasManualSingleWindowHeightOverride
            )
        } else {
            restoreIntent.detachedNiriContainerSizingState = nil
        }
        guard entry.restoreIntent != restoreIntent else { return false }
        model.setRestoreIntent(restoreIntent, for: token)
        return true
    }

    func installDwindleEngine(_ engine: DwindleLayoutEngine?) {
        engine?.isMutationSanctioned = isEngineMutationSanctioned
        dwindleEngine = engine
    }

    func applyViewportPlan(_ viewportPlan: ViewportPlan) {
        assertInCommit("applyViewportPlan")
        switch viewportPlan {
        case let .set(workspaceId, state):
            viewports[workspaceId] = state
        case let .remove(workspaceIds):
            for workspaceId in workspaceIds {
                viewports.removeValue(forKey: workspaceId)
            }
        }
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        model.setCachedConstraints(constraints, for: token)
    }

    @discardableResult
    func setObservedSizeEvidence(_ evidence: ObservedSizeEvidence, for token: WindowToken) -> Bool {
        model.setObservedSizeEvidence(evidence, for: token)
    }
}
