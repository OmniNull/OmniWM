// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC

enum WindowAction: Equatable, Sendable {
    case focus
    case navigate
    case summonRight
    case close
    case moveToWorkspace(WorkspaceTarget)
    case moveColumn(NiriColumnMoveTarget)
    case toggleContainerFullPrimarySpan
    case setContainerPrimarySpan(NiriSizeChange)
    case setWindowPrimarySpan(NiriSizeChange)
    case cycleWindowPrimarySpan(forward: Bool)
    case setWindowSecondarySpan(NiriSizeChange)
    case resetWindowSecondarySpan
    case cycleWindowSecondarySpan(forward: Bool)
    case toggleColumnTabbed
    case toggleFloating
    case assignToScratchpad(ScratchpadIndex)

    fileprivate var refusesAttachedWindow: Bool {
        switch self {
        case .moveToWorkspace,
             .summonRight,
             .toggleFloating,
             .assignToScratchpad: true
        default: false
        }
    }
}

@MainActor
extension WMController {
    var automationRefusal: ExternalCommandResult? {
        guard isEnabled else { return .ignoredDisabled }
        guard !isOverviewOpen() else { return .ignoredOverview }
        return nil
    }

    func resolveWorkspace(_ target: WorkspaceTarget) -> Result<String, ExternalCommandResult> {
        switch WorkspaceTargetResolver(settings: settings, workspaceManager: workspaceManager).resolve(target) {
        case let .success(rawWorkspaceID):
            .success(rawWorkspaceID)
        case .failure(.notFound):
            .failure(.notFound)
        case .failure(.invalidTarget),
             .failure(.ambiguousDisplayName):
            .failure(.invalidArguments)
        }
    }

    func isWindow(_ token: WindowToken, onWorkspace rawWorkspaceID: String) -> Bool {
        guard let targetId = workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
        else { return false }
        return workspaceManager.workspace(for: token) == targetId
    }

    func performWindowAction(_ action: WindowAction, on token: WindowToken) -> ExternalCommandResult {
        if action.refusesAttachedWindow,
           workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent != nil
        {
            return .attachedWindow
        }
        switch action {
        case .focus:
            return windowActionHandler.focusWindowFromBar(token: token) ? .executed : .notFound
        case .navigate:
            guard let handle = workspaceManager.handle(for: token) else { return .notFound }
            return windowActionHandler.navigateToWindow(handle: handle) ? .executed : .notFound
        case .summonRight:
            guard let handle = workspaceManager.handle(for: token) else { return .notFound }
            return windowActionHandler.summonWindowRight(handle: handle) ? .executed : .notFound
        case .close:
            guard let handle = workspaceManager.handle(for: token) else { return .notFound }
            return windowActionHandler.closeWindow(handle: handle) ? .executed : .windowActionFailed
        case let .moveToWorkspace(target):
            guard let handle = workspaceManager.handle(for: token) else { return .notFound }
            return moveWindow(handle, to: target)
        case let .moveColumn(target):
            return performNiriWindowAction(token) { $0.moveColumnPreservingFocus(containing: $1, target: target) }
        case .toggleContainerFullPrimarySpan:
            return performNiriWindowAction(token) { $0.toggleContainerFullPrimarySpan(target: .window($1)) }
        case let .setContainerPrimarySpan(change):
            return performNiriWindowAction(token) { $0.setContainerPrimarySpan(change, target: .window($1)) }
        case let .setWindowPrimarySpan(change):
            return performNiriWindowAction(token) { $0.setWindowPrimarySpan(change, target: .window($1)) }
        case let .cycleWindowPrimarySpan(forward):
            return performNiriWindowAction(token) { $0.cycleWindowPrimarySpan(forward: forward, target: .window($1)) }
        case let .setWindowSecondarySpan(change):
            return performNiriWindowAction(token) { $0.setWindowSecondarySpan(change, target: .window($1)) }
        case .resetWindowSecondarySpan:
            return performNiriWindowAction(token) { $0.resetWindowSecondarySpan(target: .window($1)) }
        case let .cycleWindowSecondarySpan(forward):
            return performNiriWindowAction(token) {
                $0.cycleWindowSecondarySpan(forward: forward, target: .window($1))
            }
        case .toggleColumnTabbed:
            return performNiriWindowAction(token) { $0.toggleColumnTabbed(target: .window($1)) }
        case .toggleFloating:
            return toggleFloating(token)
        case let .assignToScratchpad(index):
            return assignToScratchpad(token, index: index)
        }
    }

    private func toggleFloating(_ token: WindowToken) -> ExternalCommandResult {
        guard workspaceManager.entry(for: token) != nil else { return .notFound }
        return niriLayoutHandler.preservingFocusedColumnAnchor(for: token) {
            toggleWindowFloating(
                token,
                preferredMonitor: monitor(of: token),
                arrivesQuietly: token != focusedManagedTokenForCommand()
            )
        }
    }

    private func assignToScratchpad(_ token: WindowToken, index: ScratchpadIndex) -> ExternalCommandResult {
        let arrivesQuietly = token != focusedManagedTokenForCommand()
        if workspaceManager.scratchpadIndex(for: token) == index,
           workspaceManager.hiddenState(for: token)?.isScratchpad == true
        {
            return unassignScratchpadWindows([token], on: monitor(of: token)?.id, arrivesQuietly: arrivesQuietly)
        }
        return niriLayoutHandler.preservingFocusedColumnAnchor(for: token) {
            assignWindowToScratchpad(
                token,
                to: index,
                preferredMonitor: monitor(of: token),
                focusOrigin: .keyboardOrProgrammatic,
                arrivesQuietly: arrivesQuietly
            )
        }
    }

    private func performNiriWindowAction(
        _ token: WindowToken,
        _ action: (NiriLayoutHandler, WindowHandle) -> Bool
    ) -> ExternalCommandResult {
        let manager = workspaceManager
        guard let handle = manager.handle(for: token), let entry = manager.entry(for: token) else { return .notFound }
        guard manager.activeLayoutKind(for: entry.workspaceId) == .niri else { return .ignoredLayoutMismatch }
        guard entry.mode == .tiling,
              !manager.isWindowSuppressedByMacOS(token),
              let engine = niriEngine,
              !engine.isExcludedFromProjection(token, in: entry.workspaceId),
              engine.findNode(for: handle, in: entry.workspaceId) != nil
        else { return .noChange }
        return action(niriLayoutHandler, handle) ? .executed : .noChange
    }

    private func monitor(of token: WindowToken) -> Monitor? {
        workspaceManager.workspace(for: token).flatMap { workspaceManager.monitor(for: $0) }
    }

    private func moveWindow(_ handle: WindowHandle, to target: WorkspaceTarget) -> ExternalCommandResult {
        let rawWorkspaceID: String
        switch resolveWorkspace(target) {
        case let .failure(result): return result
        case let .success(resolved): rawWorkspaceID = resolved
        }
        guard let targetWorkspaceId = workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
        else { return .notFound }
        guard !isWindow(handle.id, onWorkspace: rawWorkspaceID) else { return .noChange }
        if case .changed = workspaceNavigationHandler.commitWindowMove(
            handle: handle,
            toWorkspaceId: targetWorkspaceId
        ) {
            return .executed
        }
        return .workspaceStateConflict
    }
}
