// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

struct ConfigScriptTarget: Sendable {
    let session: String
    let token: WindowToken?
    let workspaceId: WorkspaceDescriptor.ID?
    fileprivate let bundleId: String?
    fileprivate let workspace: String?
    fileprivate let layout: ActiveLayoutKind?

    var context: ConfigScriptContext {
        ConfigScriptContext(
            windowId: token.map { IPCWindowOpaqueID.encode(token: $0, sessionToken: session) },
            bundleId: bundleId, workspace: workspace, layout: layout?.rawValue
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
        let manager = workspaceManager
        let window = manager.nativeManagedFocusToken.flatMap { token in
            manager.withEntry(token) { entry in
                let bundleId = entry.target.hostedMetadata?.appId ?? entry.managedReplacementMetadata?.bundleId
                    ?? appInfoCache.cachedBundleId(for: token.pid)
                return (token: token, bundleId: bundleId)
            }
        }
        let workspace = activeWorkspace()
        return ConfigScriptTarget(
            session: automationSessionToken, token: window?.token, workspaceId: workspace?.id,
            bundleId: window?.bundleId, workspace: workspace?.name,
            layout: workspace.map { manager.activeLayoutKind(for: $0.id) }
        )
    }

    func startConfigScriptProgram(
        _ arguments: [String],
        target: ConfigScriptTarget
    ) async throws -> ExternalCommandResult {
        guard target.session == automationSessionToken else { return .staleWindowId }
        if let refusal = IPCCommandValidation.controllerState(self) { return refusal }
        try await LauncherProcess.start(arguments)
        return .executed
    }

    func performConfigScriptCommand(_ command: HotkeyCommand, target: ConfigScriptTarget) -> ExternalCommandResult {
        guard target.session == automationSessionToken else { return .staleWindowId }
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
            guard target.session == automationSessionToken else { return .staleWindowId }
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
