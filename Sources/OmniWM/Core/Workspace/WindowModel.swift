// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum TrackedWindowMode: Equatable, Hashable, Sendable {
    case tiling
    case floating
}

final class WindowModel {
    typealias WindowKey = WindowToken
    typealias EntryIndex = Dictionary<WindowToken, WindowState>.Values.Index

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
        target: WindowTarget,
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
        if let existing = entries[token] {
            guard (existing.axRef == nil) == (target.axRef == nil) else { return token }
            updateEntry(token) { $0.target = target }
            updateWorkspace(for: token, workspace: workspace)
            setMode(mode, for: token)
            if let managedReplacementMetadata {
                updateEntry(token) { $0.managedReplacementMetadata = managedReplacementMetadata }
            }
            if readEntry(token, { $0.ruleEffects != ruleEffects }) ?? true {
                updateEntry(token) { $0.ruleEffects = ruleEffects }
                constraintsCacheByToken.removeValue(forKey: token)
            }
            updateEntry(token) { $0.admissionHints = admissionHints }
            updateEntry(token) { $0.lifetimeAuthority = lifetimeAuthority }
            return token
        }

        let entry = WindowState(
            token: token,
            target: target,
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
        guard authority == .directLifecycle || entries[token]?.axRef != nil else { return }
        updateEntry(token) { $0.lifetimeAuthority = authority }
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowState? {
        guard let originalReference = entries[oldToken]?.axRef else { return nil }
        if oldToken == newToken {
            if !CFEqual(originalReference.element, newAXRef.element) {
                observedSizeEvidenceByToken.removeValue(forKey: oldToken)
            }
            updateEntry(oldToken) { $0.target = .external(newAXRef) }
            constraintsCacheByToken.removeValue(forKey: oldToken)
            if let managedReplacementMetadata {
                updateEntry(oldToken) { $0.managedReplacementMetadata = managedReplacementMetadata }
            }
            return entries[oldToken]
        }

        if let existingToken = windowIdToToken[newToken.windowId], existingToken != oldToken {
            Log.reconcile.fault(
                "WindowModel rejected rekey windowId=\(newToken.windowId) existing=\(existingToken.pid):\(existingToken.windowId) proposed=\(newToken.pid):\(newToken.windowId)"
            )
            return nil
        }

        guard entries.index(forKey: newToken) == nil,
              var entry = entries.removeValue(forKey: oldToken)
        else {
            return nil
        }

        let preservesAXIncarnation = CFEqual(originalReference.element, newAXRef.element)
        entry.token = newToken
        entry.target = .external(newAXRef)
        constraintsCacheByToken.removeValue(forKey: oldToken)
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
        guard let (oldWorkspace, mode) = readEntry(token, { ($0.workspaceId, $0.mode) }) else { return }
        if oldWorkspace != workspace {
            workspaceIndex.remove(
                token,
                from: oldWorkspace
            )
            workspaceModeIndex.remove(
                token,
                from: WorkspaceModeKey(workspaceId: oldWorkspace, mode: mode)
            )
            workspaceIndex.append(token, to: workspace)
            workspaceModeIndex.append(
                token,
                to: WorkspaceModeKey(workspaceId: workspace, mode: mode)
            )
        }
        updateEntry(token) { $0.workspaceId = workspace }
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        guard let tokens = workspaceIndex.tokensByKey[workspace] else { return [] }
        return tokens.compactMap { entries[$0] }
    }

    func forEachToken(in workspace: WorkspaceDescriptor.ID, _ body: (WindowToken) -> Void) {
        guard let tokens = workspaceIndex.tokensByKey[workspace] else { return }
        for token in tokens where entries.index(forKey: token) != nil {
            body(token)
        }
    }

    func forEachToken(_ body: (WindowToken) -> Void) {
        for token in entries.keys {
            body(token)
        }
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

    func forEachWindowForLayoutSnapshot(
        in workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        _ body: (borrowing WindowState) -> Void
    ) {
        for token in tokens(in: workspace, mode: mode) {
            _ = readEntry(token) { body($0) }
        }
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        readEntry(token) { $0.workspaceId }
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
    private func readEntry<Result>(_ token: WindowToken, _ read: (inout WindowState) -> Result) -> Result? {
        guard let index = entries.index(forKey: token) else { return nil }
        return read(&entries.values[index])
    }

    func withEntry<Result>(_ token: WindowToken, _ read: (borrowing WindowState) -> Result) -> Result? {
        readEntry(token) { (entry: inout WindowState) in read(entry) }
    }

    func withEntry<Result>(forWindowId windowId: Int, _ read: (borrowing WindowState) -> Result) -> Result? {
        windowIdToToken[windowId].flatMap { withEntry($0, read) }
    }

    func withEntry<Result>(at index: EntryIndex, _ read: (borrowing WindowState) -> Result) -> Result {
        func borrow(_ entry: inout WindowState) -> Result {
            read(entry)
        }
        return borrow(&entries.values[index])
    }

    private func updateEntry(_ token: WindowToken, _ update: (inout WindowState) -> Void) {
        guard let index = entries.index(forKey: token) else { return }
        update(&entries.values[index])
    }

    func mode(for token: WindowToken) -> TrackedWindowMode? {
        readEntry(token) { $0.mode }
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken) {
        guard let (workspaceId, currentMode) = readEntry(token, { ($0.workspaceId, $0.mode) }),
              currentMode != mode
        else { return }
        workspaceModeIndex.remove(
            token,
            from: WorkspaceModeKey(workspaceId: workspaceId, mode: currentMode)
        )
        updateEntry(token) { $0.mode = mode }
        workspaceModeIndex.append(
            token,
            to: WorkspaceModeKey(workspaceId: workspaceId, mode: mode)
        )
    }

    func floatingState(for token: WindowToken) -> FloatingState? {
        readEntry(token) { $0.floatingState } ?? nil
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        updateEntry(token) { $0.floatingState = state }
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        readEntry(token) { $0.manualLayoutOverride } ?? nil
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        updateEntry(token) { $0.manualLayoutOverride = override }
    }

    func admissionHints(for token: WindowToken) -> ManagedWindowAdmissionHints? {
        readEntry(token) { $0.admissionHints }
    }

    func setAdmissionHints(_ hints: ManagedWindowAdmissionHints, for token: WindowToken) {
        updateEntry(token) { $0.admissionHints = hints }
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        readEntry(token) { $0.lifecyclePhase }
    }

    func setLifecyclePhase(_ phase: WindowLifecyclePhase, for token: WindowToken) {
        updateEntry(token) { $0.lifecyclePhase = phase }
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        readEntry(token) { $0.observedState }
    }

    func setObservedState(_ state: ObservedWindowState, for token: WindowToken) {
        updateEntry(token) { $0.observedState = state }
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        readEntry(token) { $0.desiredState }
    }

    func setDesiredState(_ state: DesiredWindowState, for token: WindowToken) {
        updateEntry(token) { $0.desiredState = state }
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        readEntry(token) { $0.restoreIntent } ?? nil
    }

    func setRestoreIntent(_ intent: RestoreIntent?, for token: WindowToken) {
        updateEntry(token) { $0.restoreIntent = intent }
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        readEntry(token) { $0.managedReplacementMetadata } ?? nil
    }

    func setManagedReplacementMetadata(_ metadata: ManagedReplacementMetadata?, for token: WindowToken) {
        updateEntry(token) { $0.managedReplacementMetadata = metadata }
    }

    func setHiddenState(_ state: HiddenState?, for token: WindowToken) {
        updateEntry(token) { $0.hiddenState = state }
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
        readEntry(token) { $0.hiddenState } ?? nil
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        readEntry(token) { $0.hiddenState != nil } ?? false
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        readEntry(token) { $0.layoutReason } ?? .standard
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        readEntry(token) { $0.layoutReason == .nativeFullscreen } ?? false
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        updateEntry(token) { $0.layoutReason = reason }
    }

    @discardableResult
    func restoreFromNativeState(for token: WindowToken) -> Bool {
        guard readEntry(token, { $0.layoutReason != .standard }) == true else { return false }
        updateEntry(token) { $0.layoutReason = .standard }
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
        guard entries.index(forKey: token) != nil else { return }
        constraintsCacheByToken[token] = ConstraintsCacheRecord(
            constraints: constraints.normalized(),
            cachedAt: Date()
        )
    }

    func observedSizeEvidence(for token: WindowToken) -> ObservedSizeEvidence? {
        observedSizeEvidenceByToken[token]
    }

    func setObservedSizeEvidence(_ evidence: ObservedSizeEvidence, for token: WindowToken) -> Bool {
        guard entries.index(forKey: token) != nil else { return false }
        if evidence.isEmpty {
            return observedSizeEvidenceByToken.removeValue(forKey: token) != nil
        }
        guard observedSizeEvidenceByToken[token]?.isWithinFrameTolerance(of: evidence) != true else { return false }
        observedSizeEvidenceByToken[token] = evidence
        return true
    }
}
