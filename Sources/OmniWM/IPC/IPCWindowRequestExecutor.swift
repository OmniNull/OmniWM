// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCWindowRequestExecutor {
    private let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func handle(_ request: IPCWindowRequest) -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }

        switch IPCWindowOpaqueID.validate(request.windowId, expectingSessionToken: sessionToken) {
        case .invalid:
            return .invalidArguments
        case .stale:
            return .staleWindowId
        case let .valid(pid, windowId):
            return perform(request, token: WindowToken(pid: pid, windowId: windowId))
        }
    }

    private func perform(_ request: IPCWindowRequest, token: WindowToken) -> ExternalCommandResult {
        switch request.name {
        case .focus:
            return controller.windowActionHandler.focusWindowFromBar(token: token)
                ? .executed
                : .notFound
        case .navigate:
            guard let handle = controller.workspaceManager.handle(for: token) else {
                return .notFound
            }
            return controller.windowActionHandler.navigateToWindow(handle: handle)
                ? .executed
                : .notFound
        case .summonRight:
            guard let handle = controller.workspaceManager.handle(for: token) else {
                return .notFound
            }
            return controller.windowActionHandler.summonWindowRight(handle: handle)
                ? .executed
                : .notFound
        case .close:
            guard let handle = controller.workspaceManager.handle(for: token) else { return .notFound }
            return controller.windowActionHandler.closeWindow(handle: handle) ? .executed : .windowActionFailed
        case .moveToWorkspace:
            guard let target = request.workspaceTarget else { return .invalidArguments }
            guard let handle = controller.workspaceManager.handle(for: token) else { return .notFound }
            return moveWindow(handle, to: target)
        case .moveColumnToFirst,
             .moveColumnToLast,
             .moveColumnToIndex,
             .moveColumn:
            return moveColumn(request, token: token)
        case .toggleContainerFullPrimarySpan,
             .setContainerPrimarySpan,
             .setWindowPrimarySpan,
             .cycleWindowPrimarySpan,
             .setWindowSecondarySpan,
             .resetWindowSecondarySpan,
             .cycleWindowSecondarySpan:
            return resizeWindow(request, token: token)
        case .toggleColumnTabbed:
            return performNiriWindowAction(token) { $0.toggleColumnTabbed(target: .window($1)) }
        case .toggleFloating:
            return toggleFloating(token)
        case .assignToScratchpad:
            return assignToScratchpad(request, token: token)
        }
    }

    private func toggleFloating(_ token: WindowToken) -> ExternalCommandResult {
        guard controller.workspaceManager.entry(for: token) != nil else { return .notFound }
        return controller.niriLayoutHandler.preservingFocusedColumnAnchor(for: token) {
            controller.toggleWindowFloating(
                token,
                preferredMonitor: monitor(of: token),
                arrivesQuietly: token != controller.focusedManagedTokenForCommand()
            )
        }
    }

    private func assignToScratchpad(_ request: IPCWindowRequest, token: WindowToken) -> ExternalCommandResult {
        guard let rawIndex = request.scratchpadIndex,
              let index = ScratchpadIndex(rawIndex)
        else { return .invalidArguments }
        let workspaceManager = controller.workspaceManager
        let arrivesQuietly = token != controller.focusedManagedTokenForCommand()
        if workspaceManager.scratchpadIndex(for: token) == index,
           workspaceManager.hiddenState(for: token)?.isScratchpad == true
        {
            return controller.unassignScratchpadWindows(
                [token],
                on: monitor(of: token)?.id,
                arrivesQuietly: arrivesQuietly
            )
        }
        return controller.niriLayoutHandler.preservingFocusedColumnAnchor(for: token) {
            controller.assignWindowToScratchpad(
                token,
                to: index,
                preferredMonitor: monitor(of: token),
                focusOrigin: .keyboardOrProgrammatic,
                arrivesQuietly: arrivesQuietly
            )
        }
    }

    private func moveColumn(_ request: IPCWindowRequest, token: WindowToken) -> ExternalCommandResult {
        let target: NiriColumnMoveTarget? = switch request.name {
        case .moveColumnToFirst: .first
        case .moveColumnToLast: .last
        case .moveColumnToIndex: request.columnIndex.flatMap { $0 >= 1 ? .index($0) : nil }
        case .moveColumn: request.direction.map { .direction(Direction(ipc: $0)) }
        default: nil
        }
        guard let target else { return .invalidArguments }
        return performNiriWindowAction(token) { $0.moveColumnPreservingFocus(containing: $1, target: target) }
    }

    private func resizeWindow(_ request: IPCWindowRequest, token: WindowToken) -> ExternalCommandResult {
        let change = request.change.map(NiriSizeChange.init(ipc:))
        let forward = request.cycle.map { $0 == .forward }
        switch (request.name, change, forward) {
        case (.toggleContainerFullPrimarySpan, _, _):
            return performNiriWindowAction(token) { $0.toggleContainerFullPrimarySpan(target: .window($1)) }
        case (.resetWindowSecondarySpan, _, _):
            return performNiriWindowAction(token) { $0.resetWindowSecondarySpan(target: .window($1)) }
        case let (.setContainerPrimarySpan, change?, _):
            return performNiriWindowAction(token) { $0.setContainerPrimarySpan(change, target: .window($1)) }
        case let (.setWindowPrimarySpan, change?, _):
            return performNiriWindowAction(token) { $0.setWindowPrimarySpan(change, target: .window($1)) }
        case let (.setWindowSecondarySpan, change?, _):
            return performNiriWindowAction(token) { $0.setWindowSecondarySpan(change, target: .window($1)) }
        case let (.cycleWindowPrimarySpan, _, forward?):
            return performNiriWindowAction(token) { $0.cycleWindowPrimarySpan(forward: forward, target: .window($1)) }
        case let (.cycleWindowSecondarySpan, _, forward?):
            return performNiriWindowAction(token) {
                $0.cycleWindowSecondarySpan(forward: forward, target: .window($1))
            }
        default:
            return .invalidArguments
        }
    }

    private func performNiriWindowAction(
        _ token: WindowToken,
        _ action: (NiriLayoutHandler, WindowHandle) -> Bool
    ) -> ExternalCommandResult {
        let workspaceManager = controller.workspaceManager
        guard let handle = workspaceManager.handle(for: token),
              let entry = workspaceManager.entry(for: token)
        else { return .notFound }
        guard workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri else {
            return .ignoredLayoutMismatch
        }
        guard entry.mode == .tiling,
              !workspaceManager.isWindowSuppressedByMacOS(token),
              let engine = controller.niriEngine,
              !engine.isExcludedFromProjection(token, in: entry.workspaceId),
              engine.findNode(for: handle, in: entry.workspaceId) != nil
        else { return .noChange }
        return action(controller.niriLayoutHandler, handle) ? .executed : .noChange
    }

    private func monitor(of token: WindowToken) -> Monitor? {
        controller.workspaceManager.workspace(for: token).flatMap { controller.workspaceManager.monitor(for: $0) }
    }

    private func moveWindow(_ handle: WindowHandle, to target: WorkspaceTarget) -> ExternalCommandResult {
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }
        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ) else { return .notFound }
        guard !IPCCommandValidation.isAlreadyOnWorkspace(
            handle.id,
            rawWorkspaceID: rawWorkspaceID,
            controller: controller
        ) else { return .noChange }
        if case .changed = controller.workspaceNavigationHandler.commitWindowMove(
            handle: handle,
            toWorkspaceId: targetWorkspaceId
        ) {
            return .executed
        }
        return .workspaceStateConflict
    }
}
