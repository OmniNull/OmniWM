// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ConfigScriptSessionToken {
    let identity: ConfigScriptSession
    let epoch: UInt64

    init(identity: ConfigScriptSession = .random(), epoch: UInt64 = 0) {
        self.identity = identity
        self.epoch = epoch
    }
}

struct ConfigScriptFocusBaseline: Equatable, Sendable {
    let owner: NativeFocusOwner
    let pending: WindowToken?

    func unchanged(in now: Self, apartFrom window: WindowToken) -> Bool {
        (now.owner == owner || now.owner.managedToken == window || now.owner.externalToken == window)
            && (now.pending == nil || now.pending == pending || now.pending == window)
    }
}

struct ConfigScriptTarget: Sendable {
    let sessionID: ConfigScriptSession

    let token: WindowToken?
    let focus: ConfigScriptFocusBaseline
    struct Workspace: Sendable {
        let id: WorkspaceDescriptor.ID
        let name: String
        let layout: ActiveLayoutKind
    }

    fileprivate let bundleId: String?
    fileprivate let workspace: Workspace?
    var workspaceId: WorkspaceDescriptor.ID? {
        workspace?.id
    }

    var context: ConfigScriptContext {
        context(windowId: token.map { ConfigScriptWindowID.string($0, session: sessionID) })
    }

    func context(windowId: String?) -> ConfigScriptContext {
        ConfigScriptContext(
            windowId: windowId,
            bundleId: bundleId,
            workspace: workspace?.name,
            layout: workspace?.layout.rawValue
        )
    }
}

struct ConfigScriptCapture: Sendable {
    let target: ConfigScriptTarget
    let snapshot: ConfigScriptSnapshot?
}

extension WMController {
    func configScriptTarget(focus: ConfigScriptFocusBaseline? = nil) -> ConfigScriptTarget {
        workspaceManager.configScriptTarget(session: scriptSession.identity, apps: appInfoCache, focus: focus)
    }

    func startConfigScriptProgram(
        _ arguments: [String],
        target: ConfigScriptTarget
    ) async throws -> ExternalCommandResult {
        guard target.sessionID == scriptSession.identity else { return .staleWindowId }
        if let automationRefusal { return automationRefusal }
        try await LauncherProcess.start(arguments)
        return .executed
    }

    func performConfigScriptCommand(_ command: HotkeyCommand, target: ConfigScriptTarget) -> ExternalCommandResult {
        guard target.sessionID == scriptSession.identity else { return .staleWindowId }
        let focus = command.configFocusRequirement
        let manager = workspaceManager
        if focus != .none, !matchesConfigScriptFocus(target) { return .staleWindowId }
        if focus == .focused || focus == .layoutSelection {
            guard let token = target.token else { return .notFound }
            guard manager.selectedManagedToken == token,
                  let workspaceId = target.workspaceId else { return .staleWindowId }
            let available = manager.withEntry(token) { entry in
                entry.workspaceId == workspaceId && !manager.isWindowSuppressedByMacOS(entry)
            }
            guard available == true else { return .staleWindowId }
            if focus == .layoutSelection {
                switch manager.activeLayoutKind(for: workspaceId) {
                case .niri:
                    guard let selected = manager.niriViewportState(for: workspaceId).selectedNodeId,
                          niriEngine?.findNode(for: token, in: workspaceId)?.id == selected
                    else { return .staleWindowId }
                case .dwindle:
                    guard dwindleEngine?.selectedNode(in: workspaceId)?.windowToken == token
                    else { return .staleWindowId }
                }
            }
        }
        return commandHandler.performCommand(command)
    }

    func performConfigScriptDispatch(
        _ operation: borrowing ConfigScriptDispatch.Operation, target: ConfigScriptTarget
    ) -> ExternalCommandResult {
        switch operation {
        case let .native(command):
            return performConfigScriptCommand(command, target: target)
        case let .mark(action):
            return (try? performConfigScriptMark(action, target: target)) ?? .invalidArguments
        case let .gather(gather):
            return performConfigScriptGather(gather, target: target)
        case let .dwindleReplace(replace):
            return performConfigScriptDwindleReplace(replace, target: target).externalResult
        case let .window(window):
            guard target.sessionID == scriptSession.identity else { return .staleWindowId }
            if window.action == .summonRight {
                guard matchesConfigScriptFocus(target), workspaceManager.selectedManagedToken == target.token else {
                    return .staleWindowId
                }
            }
            if let automationRefusal { return automationRefusal }
            guard window.session == scriptSession.identity else { return .staleWindowId }
            switch window.check {
            case nil:
                return performWindowAction(window.action, on: window.token)
            case .fromEdge:
                guard window.token == target.token, let anchor = target.workspaceId else { return .invalidArguments }
                return performWindowAction(window.action, on: window.token, edgeOf: anchor)
            case let .focus(targetOf, nativeFullscreen):
                let manager = workspaceManager
                if let workspaceId = targetOf?.id,
                   activeWorkspace()?.id != workspaceId
                   || !target.focus.unchanged(in: manager.configScriptFocusBaseline, apartFrom: window.token)
                   || manager.resolveWorkspaceFocusToken(in: workspaceId) != window.token
                {
                    return .noChange
                }
                guard !nativeFullscreen || manager.showsNativeFullscreenPlaceholder(for: window.token) else {
                    return .noChange
                }
                return performWindowAction(window.action, on: window.token)
            }
        }
    }

    func performConfigScriptMark(
        _ action: borrowing WindowMarkAction, target: ConfigScriptTarget
    ) throws(ConfigScriptDispatchRefusal) -> ExternalCommandResult {
        guard target.sessionID == scriptSession.identity else {
            throw ConfigScriptDispatchRefusal(reason: "the callback belongs to an earlier session")
        }
        do {
            return try performWindowMark(action, focus: .captured(target.token, workspace: target.workspaceId))
        } catch {
            throw ConfigScriptDispatchRefusal(reason: error.rawValue)
        }
    }

    private func matchesConfigScriptFocus(_ target: ConfigScriptTarget) -> Bool {
        matchesAutomationFocus(target.token, workspaceId: target.workspaceId)
    }
}

extension WorkspaceManager {
    fileprivate func configScriptWorkspace() -> ConfigScriptTarget.Workspace? {
        guard let monitor = interactionMonitorID() else { return nil }
        if let id = monitorSessionSnapshots[monitor]?.visibleWorkspaceId, let workspace = configScriptWorkspace(id) {
            return workspace
        }
        guard let id = defaultVisibleWorkspaceId(on: monitor) else { return nil }
        return configScriptWorkspace(id)
    }

    private func configScriptWorkspace(_ id: WorkspaceDescriptor.ID) -> ConfigScriptTarget.Workspace? {
        guard let name = workspaceCatalog.name(for: id) else { return nil }
        let layout = settings.workspaces.configScriptLayout(for: name)
        return ConfigScriptTarget.Workspace(id: id, name: name, layout: layout)
    }
}

private enum ConfigFocusRequirement {
    case none
    case relative
    case focused
    case layoutSelection
}

extension HotkeyCommand {
    fileprivate var configFocusRequirement: ConfigFocusRequirement {
        switch self {
        case .sizing(.undo),
             .sizing(.redo),
             .sizing(.balanceSizes),
             .dwindle(.preselectClear): .none
        case .sizing,
             .column,
             .move,
             .moveColumn,
             .windowMovement,
             .dwindle,
             .fullscreen(.managed): .layoutSelection
        case .focus,
             .focusNavigation,
             .toggleFloatingFocus,
             .openMenuAnywhere: .relative
        case .windowState,
             .fullscreen(.native),
             .windowMark,
             .scratchpad(.assign),
             .workspace(.moveTo),
             .workspace(.moveToOnMonitor),
             .workspace(.moveUp),
             .workspace(.moveDown),
             .workspace(.moveToMonitor),
             .workspace(.moveToSlot): .focused
        default: .none
        }
    }
}

extension WorkspaceManager {
    var configScriptFocusBaseline: ConfigScriptFocusBaseline {
        ConfigScriptFocusBaseline(owner: nativeFocusOwner, pending: pendingFocusedToken)
    }

    func configScriptTarget(
        session: @autoclosure () -> ConfigScriptSession, apps: AppInfoCache, focus: ConfigScriptFocusBaseline? = nil
    ) -> ConfigScriptTarget {
        let focus = focus ?? configScriptFocusBaseline
        var window: WindowToken?
        var bundle: String?
        if let focused = nativeManagedFocusToken, var identity = configWindow(for: focused) {
            window = identity.token
            bundle = identity.takeBundle()
            if bundle == nil { bundle = apps.cachedBundleId(for: focused.pid) }
        }
        return ConfigScriptTarget(
            sessionID: session(),
            token: window,
            focus: focus,
            bundleId: bundle,
            workspace: configScriptWorkspace()
        )
    }
}
