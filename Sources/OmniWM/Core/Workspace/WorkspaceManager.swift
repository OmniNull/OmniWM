// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceManager {
    private(set) var monitors: [Monitor] = Monitor.current() {
        didSet { rebuildMonitorIndexes() }
    }

    private var _monitorsById: [Monitor.ID: Monitor] = [:]
    let workspaceCatalog = WorkspaceCatalog()
    let settings: SettingsStore

    private var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]

    private(set) var gaps: Double = 8
    private let world = WorldStore()
    let animationDriver = AnimationDriver()
    var nativeFullscreenRecordsByOriginalToken: [WindowToken: NativeFullscreenRecord] = [:]
    var nativeFullscreenOriginalTokenByCurrentToken: [WindowToken: WindowToken] = [:]
    var nativeFullscreenTransitionGenerationCounter = 0
    var nativeFullscreenTransitionTimeoutTasks: [WindowToken: Task<Void, Never>] = [:]
    var pendingRuntimeMonitorOverrideClearWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    var isDrainingPendingRuntimeMonitorOverrideClears = false
    var quietArrivalTokens: Set<WindowToken> = []
    private lazy var persistedRestoreCatalogStore = PersistedRestoreCatalogStore(
        bootCatalog: settings.loadPersistedWindowRestoreCatalog(),
        buildSnapshot: { [unowned self] in self.persistedWindowRestoreCatalogBuildSnapshot() },
        save: { [unowned self] in self.settings.savePersistedWindowRestoreCatalog($0) }
    )
    var persistedRestoreBundleIdProvider: ((pid_t) -> String?)?

    private lazy var projections = WorkspaceProjectionCache(manager: self)

    var onGapsChanged: (() -> Void)?
    var onSessionStateChanged: ((SessionSurfaceInvalidationScope) -> Void)?
    var onRuntimeInvalidation:
        ((WorkspaceDescriptor.ID?, InvalidationDomain, SessionSurfaceInvalidationScope) -> Void)?
    var onWindowPresenceObserved: ((WindowHandle) -> Void)?
    var onWindowRemoved: ((WindowState) -> Void)?
    var onDeferredWorkspaceMonitorMove: ((WorkspaceMonitorMoveOutcome) -> Void)?
    var onAnimationMotionsWillBeRemoved: ((Set<WorkspaceDescriptor.ID>) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        if monitors.isEmpty {
            monitors = [Monitor.fallback()]
        }
        rebuildMonitorIndexes()
        world.installActiveLayoutResolver { [unowned self] workspaceId in
            self.activeLayoutKind(for: workspaceId)
        }
        applySettings()
        reconcileInteractionMonitorState(notify: false)
        configureWorkspaceNumberHotkeys()
    }

    var disconnectedWorkspaceAssignments: [MonitorRestoreKey: WorkspaceDescriptor.ID] {
        disconnectedVisibleWorkspaceCache
    }

    func removeWorkspaceRuntimeState(for ids: [WorkspaceDescriptor.ID]) {
        world.removeInvalidationMarks(for: ids)
        removeAnimationMotions(for: ids)
    }

    func captureLiveNiriPlacements(containing tokens: [WindowToken], in workspaceId: WorkspaceDescriptor.ID) {
        _ = world.captureLiveNiriPlacements(containing: tokens, in: workspaceId, monitors: monitors)
    }

    var windowQueries: WindowModel.ReadView {
        world.windows
    }

    func scratchpadIndex(for token: WindowToken) -> ScratchpadIndex? {
        world.scratchpadIndex(for: token)
    }

    var scratchpadState: ScratchpadState {
        world.scratchpads
    }

    var focusSessionSnapshot: FocusSessionSnapshot {
        world.focus
    }

    var recordedViewportStates: [WorkspaceDescriptor.ID: ViewportState] {
        world.viewports
    }

    var monitorSessionSnapshots: [Monitor.ID: MonitorSession] {
        world.monitorSessions
    }

    func reconcileTraceDump(limit: Int? = nil) -> String {
        ReconcileDebugDump.trace(world.traceRecords(), limit: limit)
    }

    func invariantViolationCountsDump() -> String {
        world.invariantViolationCountsDump()
    }

    var worldSeq: UInt64 {
        world.seq
    }

    var hiddenAppPIDs: Set<pid_t> {
        world.hiddenAppPIDs
    }

    func isAppHidden(pid: pid_t) -> Bool {
        world.isAppHidden(pid: pid)
    }

    func appVisibilityGeneration(for pid: pid_t) -> UInt64 {
        world.appVisibilityGeneration(for: pid)
    }

    func isSeqEpochCurrent(_ plannedSeq: UInt64, domains: InvalidationDomain) -> Bool {
        world.isSeqEpochCurrent(plannedSeq, domains: domains)
    }

    func isSeqCurrent(
        _ plannedSeq: UInt64,
        for workspaceId: WorkspaceDescriptor.ID,
        domains: InvalidationDomain
    ) -> Bool {
        guard workspaceCatalog.descriptor(for: workspaceId) != nil else { return false }
        return world.isSeqCurrent(plannedSeq, for: workspaceId, domains: domains)
    }
}

extension WorkspaceManager {
    func applyPlannedFocusAndViewport(_ plan: ActionPlan) {
        if let focusSession = plan.focusSession { world.applyFocusSession(focusSession) }
        if let viewport = plan.viewport { world.applyViewportPlan(viewport) }
    }

    func applyPlannedWindowState(_ plan: ActionPlan, to token: WindowToken) -> RestoreIntent? {
        world.applyWindowStateAndRefreshRestoreIntent(plan, to: token, monitors: monitors)
    }

    func applyRestoreInteractionMonitors(_ plan: RestoreRefreshPlan) {
        world.updateFocus {
            $0.interactionMonitorId = plan.interactionMonitorId
            $0.previousInteractionMonitorId = plan.previousInteractionMonitorId
        }
    }

    func applyTopologyInteractionState(_ transition: TopologyTransitionPlan, context: MonitorResolutionContext) {
        disconnectedVisibleWorkspaceCache = transition.disconnectedVisibleWorkspaceCache
        world.updateFocus {
            $0.interactionMonitorId = transition.interactionMonitorId
            $0.previousInteractionMonitorId = transition.previousInteractionMonitorId
            if let pendingWorkspaceId = $0.pendingManagedFocus.workspaceId,
               let pendingMonitorId = effectiveMonitor(for: pendingWorkspaceId, context: context)?.id
            {
                $0.pendingManagedFocus.monitorId = pendingMonitorId
            }
        }
    }

    @discardableResult
    func commitWorldEvent(
        _ event: WMEvent,
        monitors: [Monitor],
        preMutate: () -> Void = {},
        resolvePlan: (ActionPlan, WindowToken?, ReconcileSnapshot) -> ActionPlan
    ) -> ReconcileTxn {
        world.commit(
            event,
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            preMutate: preMutate,
            resolvePlan: resolvePlan
        )
    }

    func refreshRestoreIntentsForAllEntries() {
        world.refreshRestoreIntents(monitors: monitors)
    }

    func replaceMonitorsForTopologyTransition(with newMonitors: [Monitor]) {
        monitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors

        let currentMonitorIds = Set(monitors.map(\.id))
        let expectedVisibleMonitorIds = expectedVisibleMonitorIds()
        commitMonitorSessions(monitorSessionSnapshots.filter {
            currentMonitorIds.contains($0.key) && expectedVisibleMonitorIds.contains($0.key)
        })
        invalidateWorkspaceProjectionCaches()
    }

    func refreshWindowMonitorReferencesForAllEntries() {
        let context = monitorResolutionContext()
        world.refreshWindowMonitorReferences { workspaceId in
            self.monitorId(for: workspaceId, context: context)
        }
    }

    func plannedPersistedHydrationMutation(for token: WindowToken) -> PersistedHydrationMutation? {
        guard let entry = windowQueries.entry(for: token),
              entry.hiddenState == nil,
              let metadata = persistedRestoreMetadata(for: entry),
              let hydrationPlan = PersistedRestorePlanner.plan(
                  .init(
                      token: token,
                      metadata: metadata,
                      catalog: persistedRestoreCatalogStore.bootCatalog,
                      consumedEntries: persistedRestoreCatalogStore.consumedBootEntries,
                      monitors: monitors,
                      workspaceIdForName: { [weak self] workspaceName in
                          self?.workspaceId(for: workspaceName, createIfMissing: false)
                      }
                  )
              )
        else {
            return nil
        }

        return PersistedHydrationMutation(
            workspaceId: hydrationPlan.workspaceId,
            monitorId: hydrationPlan.preferredMonitorId ?? effectiveMonitor(for: hydrationPlan.workspaceId)?.id,
            targetMode: hydrationPlan.targetMode,
            floatingFrame: hydrationPlan.floatingFrame,
            niriPlacement: hydrationPlan.niriPlacement,
            detachedNiriContainerSizingState: hydrationPlan.detachedNiriContainerSizingState,
            dwindlePlacement: hydrationPlan.dwindlePlacement,
            consumedKey: hydrationPlan.consumedKey,
            consumedEntry: hydrationPlan.consumedEntry
        )
    }

    @discardableResult
    func applyPersistedHydrationMutation(
        _ hydration: PersistedHydrationMutation,
        to token: WindowToken
    ) -> Bool {
        guard let entry = windowQueries.entry(for: token) else {
            return false
        }

        if entry.workspaceId != hydration.workspaceId {
            world.updateWorkspace(for: token, workspace: hydration.workspaceId, monitors: monitors)
        }

        let focusChanged = applyWindowModeMutationWithoutReconcile(
            hydration.targetMode,
            for: token,
            workspaceId: hydration.workspaceId
        )

        if let entry = windowQueries.entry(for: token) {
            var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            restoreIntent.niriPlacement = hydration.niriPlacement
            restoreIntent.detachedNiriContainerSizingState = hydration.detachedNiriContainerSizingState
            restoreIntent.dwindlePlacement = hydration.dwindlePlacement
            world.setRestoreIntent(restoreIntent, for: token)
        }

        if let floatingFrame = hydration.floatingFrame {
            let referenceMonitor = hydration.monitorId.flatMap(monitor(byId:))
            let referenceVisibleFrame = referenceMonitor?.visibleFrame ?? floatingFrame
            let normalizedOrigin = normalizedFloatingOrigin(
                for: floatingFrame,
                in: referenceVisibleFrame
            )
            world.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: referenceMonitor?.id,
                    restoreToFloating: true
                ),
                for: token
            )
        }

        persistedRestoreCatalogStore.noteConsumed(hydration.consumedEntry)
        if focusChanged {
            notifySessionStateChanged()
        }
        return true
    }

    @discardableResult
    private func applyWindowModeMutationWithoutReconcile(
        _ mode: TrackedWindowMode,
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let entry = entry(for: token) else { return false }
        let oldMode = entry.mode
        guard oldMode != mode else { return false }

        world.setMode(mode, for: token, monitors: monitors)
        let previousWorkspaceId = focusInvalidationWorkspaceId(for: focusSessionSnapshot)
        guard world.updateFocus({
            $0.reconcileRememberedFocus(afterModeChangeOf: token, in: workspaceId, to: mode)
        }) else {
            return false
        }
        noteFocusInvalidation(
            previousWorkspaceId: previousWorkspaceId,
            currentWorkspaceId: focusInvalidationWorkspaceId(for: focusSessionSnapshot)
        )
        return true
    }

    func flushPersistedWindowRestoreCatalogNow() {
        persistedRestoreCatalogStore.flushNow()
    }

    func schedulePersistedWindowRestoreCatalogSave() {
        persistedRestoreCatalogStore.scheduleSave()
    }
}

extension WorkspaceManager {
    func monitor(byId id: Monitor.ID) -> Monitor? {
        _monitorsById[id]
    }

    private func rebuildMonitorIndexes() {
        projections.invalidateMonitorProjections()
        _monitorsById = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        invalidateWorkspaceProjectionCaches()
    }

    func invalidateSettingsProjectionCaches() {
        projections.invalidateSettingsProjectionCaches()
    }

    func invalidateWorkspaceProjectionCaches() {
        projections.invalidateWorkspaceProjectionCaches()
    }

    func sortedMonitors() -> [Monitor] {
        projections.sortedMonitors()
    }

    func currentTopologyProfile() -> TopologyProfile {
        projections.currentTopologyProfile()
    }

    func configuredWorkspaceNames() -> [String] {
        projections.configuredWorkspaceNames()
    }

    func configuredWorkspaceNameSet() -> Set<String> {
        projections.configuredWorkspaceNameSet()
    }

    func monitorDescriptionByWorkspaceName() -> [String: MonitorDescription] {
        projections.monitorDescriptionByWorkspaceName()
    }

    func workspaceIdsByMonitor() -> [Monitor.ID: [WorkspaceDescriptor.ID]] {
        projections.workspaceIdsByMonitor()
    }

    func monitorIdShowingWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        projections.monitorIdShowingWorkspace(workspaceId)
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        projections.visibleWorkspaceIds()
    }

    func visibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        projections.visibleWorkspaceMap()
    }

    func setGaps(to size: Double) {
        let clamped = max(0, min(64, size))
        guard clamped != gaps else { return }
        gaps = clamped
        invalidateNiriCachedPrimarySpans()
        noteInvalidation(workspaceId: nil, domains: [.workspace, .layout])
        onGapsChanged?()
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        guard windowQueries.entry(for: token) != nil else { return }
        let normalized = constraints.normalized()
        world.setCachedConstraints(normalized, for: token)
    }

    @discardableResult
    func setObservedSizeEvidence(_ evidence: ObservedSizeEvidence, for token: WindowToken) -> Bool {
        world.setObservedSizeEvidence(evidence, for: token)
    }

    func applyWorkspaceMonitorRelocation(
        _ move: WorkspaceMonitorRelocation,
        sessions: [Monitor.ID: MonitorSession],
        transferInteraction: Bool
    ) {
        world.applyWorkspaceMonitorMove(
            move,
            monitorSessions: sessions,
            transferInteraction: transferInteraction,
            monitors: monitors
        )
        world.niriEngine?.moveWorkspace(move.workspaceId, to: move.targetMonitor.id, monitor: move.targetMonitor)
    }

    var niriEngine: NiriLayoutEngine? {
        get { world.niriEngine }
        set {
            let captured: Bool
            if let current = world.niriEngine, current !== newValue {
                captured = withEngineMutationScope(label: "niri_engine_replaced", source: .workspaceManager) {
                    world.installNiriEngine(newValue, monitors: monitors)
                }
            } else {
                captured = world.installNiriEngine(newValue, monitors: monitors)
            }
            if captured {
                schedulePersistedWindowRestoreCatalogSave()
            }
        }
    }

    @discardableResult
    func captureDetachedNiriPlacement(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        let captured = world.captureDetachedNiriPlacement(
            for: token,
            in: workspaceId,
            monitors: monitors
        )
        if captured {
            schedulePersistedWindowRestoreCatalogSave()
        }
        return captured
    }

    var dwindleEngine: DwindleLayoutEngine? {
        get { world.dwindleEngine }
        set { world.installDwindleEngine(newValue) }
    }

    func layoutTopology(for workspaceId: WorkspaceDescriptor.ID) -> LayoutTopology {
        world.layoutTopology(for: workspaceId)
    }

    func applyViewportInBatch(_ state: ViewportState, for workspaceId: WorkspaceDescriptor.ID) {
        let previous = recordedViewportStates[workspaceId]
        var committed = state
        committed.clearOffsetTransition()
        if previous != committed {
            world.applyViewportPlan(.set(workspaceId: workspaceId, state: committed))
        }
        noteViewportInvalidationIfNeeded(
            for: workspaceId,
            previousViewport: previous,
            pendingOffsetAnimation: state.hasPendingOffsetAnimation
        )
        animationDriver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: previous,
            next: recordedViewportStates[workspaceId] ?? committed,
            transition: state.offsetTransition
        )
    }

    var spaceTopology: SpaceTopology {
        world.spaceTopology
    }
}

extension WorkspaceManager {
    func noteInvalidation(
        workspaceId: WorkspaceDescriptor.ID?,
        domains: InvalidationDomain,
        surfaceScope: SessionSurfaceInvalidationScope = .full
    ) {
        world.noteInvalidation(workspaceId: workspaceId, domains: domains)
        onRuntimeInvalidation?(workspaceId, domains, surfaceScope)
    }

    func noteInvalidation(
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        domains: InvalidationDomain,
        surfaceScope: SessionSurfaceInvalidationScope = .full
    ) {
        world.noteInvalidation(workspaceIds: workspaceIds, domains: domains)
        for workspaceId in workspaceIds {
            onRuntimeInvalidation?(workspaceId, domains, surfaceScope)
        }
    }
}
