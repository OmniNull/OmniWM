// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum ConfigScriptSession: Equatable, Sendable {
    case uuid(UUID)
    case text(String)

    var text: String {
        switch self {
        case let .uuid(id): id.uuidString
        case let .text(text): text
        }
    }
}

struct ConfigScriptSessionToken {
    let text: String
    let identity: ConfigScriptSession
    let epoch: UInt64

    init() {
        let id = UUID()
        text = id.uuidString
        identity = .uuid(id)
        epoch = 0
    }

    init(_ text: String, epoch: UInt64 = 0) {
        self.epoch = epoch
        self.text = text
        if let id = UUID(uuidString: text), id.uuidString.utf8.elementsEqual(text.utf8) {
            identity = .uuid(id)
        } else {
            identity = .text(text)
        }
    }
}

struct ConfigScriptTarget: Sendable {
    let sessionID: ConfigScriptSession
    var session: String {
        sessionID.text
    }

    let token: WindowToken?
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
        context(windowId: token.map { IPCWindowOpaqueID.encode(token: $0, sessionToken: session) })
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
    func configScriptCapture(reads: ConfigScriptReads) -> ConfigScriptCapture {
        let target = configScriptTarget()
        let snapshot = reads.isEmpty ? nil : configScriptSnapshot(reads: reads, target: target)
        return ConfigScriptCapture(target: target, snapshot: snapshot)
    }

    func configScriptTarget() -> ConfigScriptTarget {
        workspaceManager.configScriptTarget(session: automationSession.identity, apps: appInfoCache)
    }

    func startConfigScriptProgram(
        _ arguments: [String],
        target: ConfigScriptTarget
    ) async throws -> ExternalCommandResult {
        guard target.sessionID == automationSession.identity else { return .staleWindowId }
        if let refusal = IPCCommandValidation.controllerState(self) { return refusal }
        try await LauncherProcess.start(arguments)
        return .executed
    }

    func performConfigScriptCommand(_ command: HotkeyCommand, target: ConfigScriptTarget) -> ExternalCommandResult {
        guard target.sessionID == automationSession.identity else { return .staleWindowId }
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
        case let .window(window):
            guard target.sessionID == automationSession.identity else { return .staleWindowId }
            if window.request.name == .summonRight {
                guard matchesConfigScriptFocus(target), workspaceManager.selectedManagedToken == target.token else {
                    return .staleWindowId
                }
            }
            return IPCWindowRequestExecutor(controller: self, sessionToken: target.session)
                .handle(window.request, address: window.address)
        }
    }

    private func matchesConfigScriptFocus(_ target: ConfigScriptTarget) -> Bool {
        let manager = workspaceManager
        return activeWorkspace()?.id == target.workspaceId && manager.nativeManagedFocusToken == target.token
            && (manager.pendingFocusedToken == nil || manager.pendingFocusedToken == target.token)
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
    func configScriptTarget(session: @autoclosure () -> ConfigScriptSession, apps: AppInfoCache) -> ConfigScriptTarget {
        let focused = nativeManagedFocusToken
        var window: WindowToken?
        var bundle: String?
        if let focused, var identity = configWindow(for: focused) {
            window = identity.token
            bundle = identity.takeBundle()
            if bundle == nil { bundle = apps.cachedBundleId(for: focused.pid) }
        }
        return ConfigScriptTarget(
            sessionID: session(),
            token: window,
            bundleId: bundle,
            workspace: configScriptWorkspace()
        )
    }
}
