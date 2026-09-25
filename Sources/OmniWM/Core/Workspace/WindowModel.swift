// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum TrackedWindowMode: Equatable, Hashable, Sendable {
    case tiling
    case floating
}

struct ManagedReplacementMetadata: Equatable, Sendable {
    var bundleId: String?
    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode
    var role: String?
    var subrole: String?
    var title: String?
    var windowLevel: Int32?
    var parentWindowId: UInt32?
    var frame: CGRect?
    var transientWindowServerEvidence = false
    var degradedWindowServerChildEvidence = false

    func mergingNonNilValues(from overlay: ManagedReplacementMetadata) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: overlay.bundleId ?? bundleId,
            workspaceId: overlay.workspaceId,
            mode: overlay.mode,
            role: overlay.role ?? role,
            subrole: overlay.subrole ?? subrole,
            title: overlay.title ?? title,
            windowLevel: overlay.windowLevel ?? windowLevel,
            parentWindowId: overlay.parentWindowId ?? parentWindowId,
            frame: overlay.frame ?? frame,
            transientWindowServerEvidence: transientWindowServerEvidence || overlay.transientWindowServerEvidence,
            degradedWindowServerChildEvidence: degradedWindowServerChildEvidence
                || overlay.degradedWindowServerChildEvidence
        )
    }
}

final class WindowModel {
    typealias WindowKey = WindowToken

    private struct WorkspaceModeKey: Hashable {
        let workspaceId: WorkspaceDescriptor.ID
        let mode: TrackedWindowMode
    }

    private struct ConstraintsCacheRecord {
        let constraints: WindowSizeConstraints
        let cachedAt: Date
    }

    private(set) var entries: [WindowToken: WindowState] = [:]
    private var windowIdToToken: [Int: WindowToken] = [:]
    private var handleByToken: [WindowToken: WindowHandle] = [:]
    private var constraintsCacheByToken: [WindowToken: ConstraintsCacheRecord] = [:]
    private var observedSizeEvidenceByToken: [WindowToken: ObservedSizeEvidence] = [:]
    private var workspaceIndex = WindowTokenIndex<WorkspaceDescriptor.ID>()
    private var workspaceModeIndex = WindowTokenIndex<WorkspaceModeKey>()
    private var pidIndex = WindowTokenIndex<pid_t>()

    private func appendIndexes(for entry: WindowState) {
        let token = entry.token
        windowIdToToken[entry.windowId] = token
        workspaceIndex.append(
            token,
            to: entry.workspaceId
        )
        workspaceModeIndex.append(
            token,
            to: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode)
        )
        pidIndex.append(token, to: entry.pid)
    }

    private func removeIndexes(for entry: WindowState, token: WindowToken? = nil, windowId: Int? = nil) {
        let token = token ?? entry.token
        let windowId = windowId ?? entry.windowId

        windowIdToToken.removeValue(forKey: windowId)
        workspaceIndex.remove(
            token,
            from: entry.workspaceId
        )
        workspaceModeIndex.remove(
            token,
            from: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode)
        )
        pidIndex.remove(token, from: token.pid)
    }

    private func rekeyIndexes(for entry: WindowState, from oldToken: WindowToken, to newToken: WindowToken) {
        windowIdToToken.removeValue(forKey: oldToken.windowId)
        windowIdToToken[newToken.windowId] = newToken

        workspaceIndex.replace(
            from: oldToken,
            to: newToken,
            in: entry.workspaceId
        )
        workspaceModeIndex.replace(
            from: oldToken,
            to: newToken,
            in: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode)
        )

        if oldToken.pid == newToken.pid {
            pidIndex.replace(
                from: oldToken,
                to: newToken,
                in: oldToken.pid
            )
        } else {
            pidIndex.remove(oldToken, from: oldToken.pid)
            pidIndex.append(newToken, to: newToken.pid)
        }
    }

    @discardableResult
    func upsert(
        window: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        admissionHints: ManagedWindowAdmissionHints = .none,
        lifetimeAuthority: ManagedWindowLifetimeAuthority = .axTopLevelInventory,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        let token = WindowToken(pid: pid, windowId: windowId)
        if let existingToken = windowIdToToken[windowId], existingToken != token {
            Log.reconcile.fault(
                "WindowModel rejected duplicate windowId=\(windowId) existing=\(existingToken.pid):\(existingToken.windowId) proposed=\(token.pid):\(token.windowId)"
            )
            return existingToken
        }
        if entries[token] != nil {
            entries[token]?.axRef = window
            updateWorkspace(for: token, workspace: workspace)
            setMode(mode, for: token)
            if let managedReplacementMetadata {
                entries[token]?.managedReplacementMetadata = managedReplacementMetadata
            }
            if entries[token]?.ruleEffects != ruleEffects {
                entries[token]?.ruleEffects = ruleEffects
                constraintsCacheByToken.removeValue(forKey: token)
            }
            entries[token]?.admissionHints = admissionHints
            entries[token]?.lifetimeAuthority = lifetimeAuthority
            return token
        }

        let entry = WindowState(
            token: token,
            axRef: window,
            workspaceId: workspace,
            mode: mode,
            managedReplacementMetadata: managedReplacementMetadata,
            ruleEffects: ruleEffects,
            admissionHints: admissionHints,
            lifetimeAuthority: lifetimeAuthority
        )
        entries[token] = entry
        handleByToken[token] = WindowHandle(id: token)
        appendIndexes(for: entry)
        return token
    }

    func setLifetimeAuthority(
        _ authority: ManagedWindowLifetimeAuthority,
        for token: WindowToken
    ) {
        entries[token]?.lifetimeAuthority = authority
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowState? {
        if oldToken == newToken {
            guard entries[oldToken] != nil else { return nil }
            entries[oldToken]?.axRef = newAXRef
            constraintsCacheByToken.removeValue(forKey: oldToken)
            if let managedReplacementMetadata {
                entries[oldToken]?.managedReplacementMetadata = managedReplacementMetadata
            }
            return entries[oldToken]
        }

        if let existingToken = windowIdToToken[newToken.windowId], existingToken != oldToken {
            Log.reconcile.fault(
                "WindowModel rejected rekey windowId=\(newToken.windowId) existing=\(existingToken.pid):\(existingToken.windowId) proposed=\(newToken.pid):\(newToken.windowId)"
            )
            return nil
        }

        guard entries[newToken] == nil,
              var entry = entries.removeValue(forKey: oldToken)
        else {
            return nil
        }

        entry.token = newToken
        entry.axRef = newAXRef
        constraintsCacheByToken.removeValue(forKey: oldToken)
        let preservesAXIncarnation = CFEqual(entry.axRef.element, newAXRef.element)
        if let evidence = observedSizeEvidenceByToken.removeValue(forKey: oldToken), preservesAXIncarnation {
            observedSizeEvidenceByToken[newToken] = evidence
        }
        if let handle = handleByToken.removeValue(forKey: oldToken) {
            handle.id = newToken
            handleByToken[newToken] = handle
        }
        if let managedReplacementMetadata {
            entry.managedReplacementMetadata = managedReplacementMetadata
        }
        entries[newToken] = entry
        rekeyIndexes(for: entry, from: oldToken, to: newToken)

        return entry
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        handleByToken[token]
    }

    func updateWorkspace(for token: WindowToken, workspace: WorkspaceDescriptor.ID) {
        guard let entry = entries[token] else { return }
        let oldWorkspace = entry.workspaceId
        if oldWorkspace != workspace {
            workspaceIndex.remove(
                token,
                from: oldWorkspace
            )
            workspaceModeIndex.remove(
                token,
                from: WorkspaceModeKey(workspaceId: oldWorkspace, mode: entry.mode)
            )
            workspaceIndex.append(token, to: workspace)
            workspaceModeIndex.append(
                token,
                to: WorkspaceModeKey(workspaceId: workspace, mode: entry.mode)
            )
        }
        entries[token]?.workspaceId = workspace
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        guard let tokens = workspaceIndex.tokensByKey[workspace] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func windowCount(in workspace: WorkspaceDescriptor.ID) -> Int {
        workspaceIndex.tokensByKey[workspace]?.count ?? 0
    }

    func windows(in workspace: WorkspaceDescriptor.ID, mode: TrackedWindowMode) -> [WindowState] {
        tokens(in: workspace, mode: mode).compactMap { entries[$0] }
    }

    func tokens(in workspace: WorkspaceDescriptor.ID, mode: TrackedWindowMode) -> [WindowToken] {
        workspaceModeIndex.tokensByKey[WorkspaceModeKey(workspaceId: workspace, mode: mode)] ?? []
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        entries[token]?.workspaceId
    }

    func entry(for token: WindowToken) -> WindowState? {
        entries[token]
    }

    func entry(for handle: WindowHandle) -> WindowState? {
        entry(for: handle.id)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowState? {
        entry(for: WindowToken(pid: pid, windowId: windowId))
    }

    func entries(forPid pid: pid_t) -> [WindowState] {
        guard let tokens = pidIndex.tokensByKey[pid] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func hasEntries(forPid pid: pid_t) -> Bool {
        pidIndex.tokensByKey[pid]?.isEmpty == false
    }

    func entry(forWindowId windowId: Int) -> WindowState? {
        windowIdToToken[windowId].flatMap { entries[$0] }
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> WindowState? {
        guard let entry = entry(forWindowId: windowId),
              visibleIds.contains(entry.workspaceId) else { return nil }
        return entry
    }

    func allEntries() -> [WindowState] {
        Array(entries.values)
    }

    func allEntries(mode: TrackedWindowMode) -> [WindowState] {
        workspaceModeIndex.tokensByKey
            .filter { $0.key.mode == mode }
            .values
            .flatMap { $0.compactMap { entries[$0] } }
    }
}

extension WindowModel {
    func mode(for token: WindowToken) -> TrackedWindowMode? {
        entries[token]?.mode
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken) {
        guard let entry = entries[token], entry.mode != mode else { return }
        workspaceModeIndex.remove(
            token,
            from: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: entry.mode)
        )
        entries[token]?.mode = mode
        workspaceModeIndex.append(
            token,
            to: WorkspaceModeKey(workspaceId: entry.workspaceId, mode: mode)
        )
    }

    func floatingState(for token: WindowToken) -> FloatingState? {
        entries[token]?.floatingState
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        entries[token]?.floatingState = state
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        entries[token]?.manualLayoutOverride
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        entries[token]?.manualLayoutOverride = override
    }

    func admissionHints(for token: WindowToken) -> ManagedWindowAdmissionHints? {
        entries[token]?.admissionHints
    }

    func setAdmissionHints(_ hints: ManagedWindowAdmissionHints, for token: WindowToken) {
        entries[token]?.admissionHints = hints
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        entries[token]?.lifecyclePhase
    }

    func setLifecyclePhase(_ phase: WindowLifecyclePhase, for token: WindowToken) {
        entries[token]?.lifecyclePhase = phase
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        entries[token]?.observedState
    }

    func setObservedState(_ state: ObservedWindowState, for token: WindowToken) {
        entries[token]?.observedState = state
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        entries[token]?.desiredState
    }

    func setDesiredState(_ state: DesiredWindowState, for token: WindowToken) {
        entries[token]?.desiredState = state
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        entries[token]?.restoreIntent
    }

    func setRestoreIntent(_ intent: RestoreIntent?, for token: WindowToken) {
        entries[token]?.restoreIntent = intent
    }

    func applyNiriPlacements(_ placements: [WindowToken: PersistedNiriPlacement], monitors: [Monitor]) {
        for (token, placement) in placements {
            guard let entry = self.entry(for: token), entry.mode == .tiling else { continue }
            var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            restoreIntent.niriPlacement = placement
            restoreIntent.detachedNiriContainerSizingState = nil
            guard entry.restoreIntent != restoreIntent else { continue }
            self.setRestoreIntent(restoreIntent, for: token)
        }
    }

    func applyDwindlePlacements(_ placements: [WindowToken: PersistedDwindlePlacement], monitors: [Monitor]) {
        for (token, placement) in placements {
            guard let entry = self.entry(for: token), entry.mode == .tiling else { continue }
            var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            restoreIntent.dwindlePlacement = placement
            guard entry.restoreIntent != restoreIntent else { continue }
            self.setRestoreIntent(restoreIntent, for: token)
        }
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        entries[token]?.managedReplacementMetadata
    }

    func setManagedReplacementMetadata(_ metadata: ManagedReplacementMetadata?, for token: WindowToken) {
        entries[token]?.managedReplacementMetadata = metadata
    }

    func setHiddenState(_ state: HiddenState?, for token: WindowToken) {
        entries[token]?.hiddenState = state
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
        entries[token]?.hiddenState
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        entries[token]?.hiddenState != nil
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        entries[token]?.layoutReason ?? .standard
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        entries[token]?.layoutReason == .nativeFullscreen
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        entries[token]?.layoutReason = reason
    }

    @discardableResult
    func restoreFromNativeState(for token: WindowToken) -> Bool {
        guard let entry = entries[token],
              entry.layoutReason != .standard
        else { return false }
        entries[token]?.layoutReason = .standard
        return true
    }

    @discardableResult
    func removeWindow(key: WindowKey) -> WindowState? {
        handleByToken.removeValue(forKey: key)
        constraintsCacheByToken.removeValue(forKey: key)
        observedSizeEvidenceByToken.removeValue(forKey: key)
        guard let entry = entries[key] else { return nil }
        removeIndexes(for: entry, token: key, windowId: key.windowId)
        entries.removeValue(forKey: key)
        return entry
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        guard let record = constraintsCacheByToken[token],
              Date().timeIntervalSince(record.cachedAt) < maxAge
        else {
            return nil
        }
        return record.constraints
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        guard entries[token] != nil else { return }
        constraintsCacheByToken[token] = ConstraintsCacheRecord(
            constraints: constraints.normalized(),
            cachedAt: Date()
        )
    }

    func observedSizeEvidence(for token: WindowToken) -> ObservedSizeEvidence? {
        observedSizeEvidenceByToken[token]
    }

    func setObservedSizeEvidence(_ evidence: ObservedSizeEvidence, for token: WindowToken) -> Bool {
        guard entries[token] != nil else { return false }
        if evidence.isEmpty {
            return observedSizeEvidenceByToken.removeValue(forKey: token) != nil
        }
        guard observedSizeEvidenceByToken[token]?.isWithinFrameTolerance(of: evidence) != true else { return false }
        observedSizeEvidenceByToken[token] = evidence
        return true
    }
}
