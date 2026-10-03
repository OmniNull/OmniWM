// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct PendingManagedFocusSnapshot: Equatable {
    var token: WindowToken?
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var requestId: UInt64?

    static let empty = PendingManagedFocusSnapshot(
        token: nil,
        workspaceId: nil,
        monitorId: nil,
        requestId: nil
    )
}

struct MonitorSession: Equatable {
    var visibleWorkspaceId: WorkspaceDescriptor.ID?
    var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
}

struct ExternalFocusIdentity: Equatable, Sendable {
    let pid: pid_t?
    let windowId: Int?
    let verifiedManagedParentToken: WindowToken?

    init(
        pid: pid_t?,
        windowId: Int?,
        verifiedManagedParentToken: WindowToken? = nil
    ) {
        self.pid = pid
        self.windowId = windowId
        self.verifiedManagedParentToken = if pid != nil, windowId != nil {
            verifiedManagedParentToken
        } else {
            nil
        }
    }

    var exactToken: WindowToken? {
        guard let pid, let windowId else { return nil }
        return WindowToken(pid: pid, windowId: windowId)
    }

    func downgradingToPIDOnly() -> ExternalFocusIdentity {
        ExternalFocusIdentity(pid: pid, windowId: nil)
    }

    func clearingVerifiedManagedParent() -> ExternalFocusIdentity {
        guard verifiedManagedParentToken != nil else { return self }
        return ExternalFocusIdentity(pid: pid, windowId: windowId)
    }

    func rekeying(from oldToken: WindowToken, to newToken: WindowToken) -> ExternalFocusIdentity {
        let rekeysExternalToken = exactToken == oldToken
        return ExternalFocusIdentity(
            pid: rekeysExternalToken ? newToken.pid : pid,
            windowId: rekeysExternalToken ? newToken.windowId : windowId,
            verifiedManagedParentToken: rekeysExternalToken || verifiedManagedParentToken == oldToken
                ? nil
                : verifiedManagedParentToken
        )
    }

    func removingManagedToken(_ token: WindowToken) -> ExternalFocusIdentity {
        if exactToken == token || verifiedManagedParentToken == token {
            return clearingVerifiedManagedParent()
        }
        return self
    }
}

enum NativeFocusOwner: Equatable, Sendable {
    case managed(WindowToken)
    case external(ExternalFocusIdentity)
    case ownedSurface
    case none

    static func external(
        pid: pid_t?,
        windowId: Int?,
        verifiedManagedParentToken: WindowToken? = nil
    ) -> NativeFocusOwner {
        .external(
            ExternalFocusIdentity(
                pid: pid,
                windowId: windowId,
                verifiedManagedParentToken: verifiedManagedParentToken
            )
        )
    }

    var managedToken: WindowToken? {
        guard case let .managed(token) = self else { return nil }
        return token
    }

    var externalToken: WindowToken? {
        externalIdentity?.exactToken
    }

    var externalIdentity: ExternalFocusIdentity? {
        guard case let .external(identity) = self else { return nil }
        return identity
    }

    var isExternal: Bool {
        if case .external = self {
            return true
        }
        return false
    }
}

struct FocusSessionSnapshot: Equatable {
    var selectedManagedToken: WindowToken?
    var nativeFocusOwner: NativeFocusOwner = .none
    var pendingManagedFocus: PendingManagedFocusSnapshot = .empty
    var lastTiledFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
    var lastFloatingFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
    var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
    var lastTiledFocusedToken: WindowToken?
    var tiledFocusHistory: [WindowToken] = []
    var windowFocusHistory: [WindowToken] = []
    var focusLease: FocusPolicyLease?
    var suppressedFocusToken: WindowToken?
    var systemModalFocusToken: WindowToken?
    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
}

extension FocusSessionSnapshot {
    mutating func recordWindowFocus(_ token: WindowToken) {
        guard windowFocusHistory.first != token else { return }
        windowFocusHistory.removeAll { $0 == token }
        windowFocusHistory.insert(token, at: 0)
        if windowFocusHistory.count > 32 {
            windowFocusHistory.removeLast(windowFocusHistory.count - 32)
        }
    }

    @discardableResult
    mutating func recordTiledFocus(_ token: WindowToken) -> Bool {
        var unchanged = tiledFocusHistory.count <= 32 && tiledFocusHistory.first == token
        if unchanged {
            var index = 1
            while index < tiledFocusHistory.count {
                if tiledFocusHistory[index] == token {
                    unchanged = false
                    break
                }
                index += 1
            }
        }
        lastTiledFocusedToken = token
        guard !unchanged else { return false }
        tiledFocusHistory.removeAll { $0 == token }
        tiledFocusHistory.insert(token, at: 0)
        if tiledFocusHistory.count > 32 {
            tiledFocusHistory.removeLast(tiledFocusHistory.count - 32)
        }
        return true
    }

    @discardableResult
    mutating func rememberFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> Bool {
        var changed = false
        if lastFocusedByWorkspace[workspaceId] != token {
            lastFocusedByWorkspace[workspaceId] = token
            changed = true
        }
        return rememberFocusFallback(token, in: workspaceId, mode: mode) || changed
    }

    @discardableResult
    mutating func rememberFocusFallback(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> Bool {
        guard focusFallbackToken(in: workspaceId, mode: mode) != token else { return false }
        switch mode {
        case .tiling:
            lastTiledFocusedByWorkspace[workspaceId] = token
        case .floating:
            lastFloatingFocusedByWorkspace[workspaceId] = token
        }
        return true
    }

    func focusFallbackToken(
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> WindowToken? {
        switch mode {
        case .tiling:
            lastTiledFocusedByWorkspace[workspaceId]
        case .floating:
            lastFloatingFocusedByWorkspace[workspaceId]
        }
    }

    @discardableResult
    mutating func clearRememberedFocus(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> Bool {
        var changed = false

        if lastTiledFocusedToken == token {
            lastTiledFocusedToken = nil
            changed = true
        }
        let previousHistoryCount = tiledFocusHistory.count
        tiledFocusHistory.removeAll { $0 == token }
        if tiledFocusHistory.count != previousHistoryCount {
            changed = true
        }
        let previousWindowHistoryCount = windowFocusHistory.count
        windowFocusHistory.removeAll { $0 == token }
        if windowFocusHistory.count != previousWindowHistoryCount {
            changed = true
        }

        if let workspaceId {
            if lastTiledFocusedByWorkspace[workspaceId] == token {
                lastTiledFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            if lastFloatingFocusedByWorkspace[workspaceId] == token {
                lastFloatingFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            if lastFocusedByWorkspace[workspaceId] == token {
                lastFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            return changed
        }

        changed = Self.removeRememberedFocus(token, from: &lastTiledFocusedByWorkspace) || changed
        changed = Self.removeRememberedFocus(token, from: &lastFloatingFocusedByWorkspace) || changed
        changed = Self.removeRememberedFocus(token, from: &lastFocusedByWorkspace) || changed

        return changed
    }

    @discardableResult
    mutating func replaceRememberedFocus(from oldToken: WindowToken, to newToken: WindowToken) -> Bool {
        guard oldToken != newToken else { return false }
        var changed = false

        if lastTiledFocusedToken == oldToken {
            lastTiledFocusedToken = newToken
            changed = true
        }
        for index in tiledFocusHistory.indices where tiledFocusHistory[index] == oldToken {
            tiledFocusHistory[index] = newToken
            changed = true
        }
        if windowFocusHistory.contains(oldToken) {
            var seen: Set<WindowToken> = []
            windowFocusHistory = windowFocusHistory.map { $0 == oldToken ? newToken : $0 }
                .filter { seen.insert($0).inserted }
            changed = true
        }

        changed = Self.replaceRememberedFocus(
            from: oldToken,
            to: newToken,
            in: &lastTiledFocusedByWorkspace
        ) || changed
        changed = Self.replaceRememberedFocus(
            from: oldToken,
            to: newToken,
            in: &lastFloatingFocusedByWorkspace
        ) || changed
        changed = Self.replaceRememberedFocus(
            from: oldToken,
            to: newToken,
            in: &lastFocusedByWorkspace
        ) || changed

        return changed
    }

    @discardableResult
    mutating func reconcileRememberedFocus(
        afterModeChangeOf token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        to newMode: TrackedWindowMode
    ) -> Bool {
        var changed = false
        switch newMode {
        case .tiling:
            if lastFloatingFocusedByWorkspace[workspaceId] == token {
                lastFloatingFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
        case .floating:
            if lastTiledFocusedByWorkspace[workspaceId] == token {
                lastTiledFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            if lastTiledFocusedToken == token {
                lastTiledFocusedToken = nil
                changed = true
            }
            let previousHistoryCount = tiledFocusHistory.count
            tiledFocusHistory.removeAll { $0 == token }
            if tiledFocusHistory.count != previousHistoryCount {
                changed = true
            }
        }

        if selectedManagedToken == token || pendingManagedFocus.token == token {
            changed = rememberFocus(token, in: workspaceId, mode: newMode) || changed
        }

        return changed
    }

    @discardableResult
    mutating func clearPendingManagedFocus() -> Bool {
        guard pendingManagedFocus != .empty else { return false }
        pendingManagedFocus = .empty
        return true
    }

    @discardableResult
    mutating func clearPendingManagedFocus(
        matching token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        requestId: UInt64?
    ) -> Bool {
        let request = pendingManagedFocus
        let matchesToken = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        let matchesRequest = requestId.map { request.requestId == $0 } ?? (request.requestId == nil)
        guard matchesToken, matchesWorkspace, matchesRequest else { return false }
        return clearPendingManagedFocus()
    }

    private static func removeRememberedFocus(
        _ token: WindowToken,
        from rememberedFocus: inout [WorkspaceDescriptor.ID: WindowToken]
    ) -> Bool {
        var changed = false
        while let workspaceId = rememberedFocus.first(where: { $0.value == token })?.key {
            rememberedFocus.removeValue(forKey: workspaceId)
            changed = true
        }
        return changed
    }

    private static func replaceRememberedFocus(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in rememberedFocus: inout [WorkspaceDescriptor.ID: WindowToken]
    ) -> Bool {
        var changed = false
        var index = rememberedFocus.startIndex
        while index != rememberedFocus.endIndex {
            if rememberedFocus.values[index] == oldToken {
                rememberedFocus.values[index] = newToken
                changed = true
            }
            rememberedFocus.formIndex(after: &index)
        }
        return changed
    }
}
