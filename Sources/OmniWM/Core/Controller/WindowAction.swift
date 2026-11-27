// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation
import OmniWMIPC

enum WindowDisplayTarget: Equatable, Sendable {
    case display(Monitor.ID)
    case neighbor(Direction, of: Monitor.ID?)
}

enum WindowAction: Equatable, Sendable {
    case focus
    case navigate
    case summonRight
    case close
    case moveToWorkspace(WorkspaceTarget)
    case moveToDisplay(WindowDisplayTarget, column: Int?)
    case moveColumn(NiriColumnMoveTarget)
    case placeInOwnColumn(Int)
    case toggleContainerFullPrimarySpan
    case setContainerPrimarySpan(NiriSizeChange)
    case setWindowPrimarySpan(NiriSizeChange)
    case cycleWindowPrimarySpan(forward: Bool)
    case setWindowSecondarySpan(NiriSizeChange)
    case resetWindowSecondarySpan
    case cycleWindowSecondarySpan(forward: Bool)
    case toggleColumnTabbed
    case toggleFloating
    case setFloatingFrame(FloatingFrameFields)
    case assignToScratchpad(ScratchpadIndex)

    fileprivate var refusesAttachedWindow: Bool {
        switch self {
        case .moveToWorkspace,
             .moveToDisplay,
             .summonRight,
             .toggleFloating,
             .setFloatingFrame,
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

    func performWindowAction(
        _ action: WindowAction,
        on token: WindowToken,
        edgeOf anchor: WorkspaceDescriptor.ID? = nil
    ) -> ExternalCommandResult {
        if action.refusesAttachedWindow, isAttachedWindow(token) { return .attachedWindow }
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
        case let .moveToDisplay(target, column):
            guard let handle = workspaceManager.handle(for: token) else { return .notFound }
            return moveWindow(handle, to: target, column: column, edgeOf: anchor)
        case let .moveColumn(target):
            return performNiriWindowAction(token) { $0.moveColumnPreservingFocus(containing: $1, target: target) }
        case let .placeInOwnColumn(slot):
            return performNiriWindowAction(token) { $0.placeWindowInOwnColumn(containing: $1, at: slot) }
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
        case let .setFloatingFrame(fields):
            return setFloatingFrame(token, to: fields)
        case let .assignToScratchpad(index):
            return assignToScratchpad(token, index: index)
        }
    }

    private func isAttachedWindow(_ token: WindowToken) -> Bool {
        workspaceManager.withEntry(token) { $0.target.hostedMetadata?.role.parent != nil } == true
    }

    private func setFloatingFrame(_ token: WindowToken, to fields: FloatingFrameFields) -> ExternalCommandResult {
        let manager = workspaceManager
        guard let handle = manager.handle(for: token) else { return .notFound }
        let state = manager.withEntry(token) {
            (manager.isWindowSuppressedByMacOS($0), $0.floatingState?.lastFrame ?? $0.observedState.frame)
        }
        guard case let (suppressed, base)? = state, !suppressed, let frame = fields.frame(over: base) else {
            return .noChange
        }
        return placeFloatingWindow(handle, frame: frame) ? .executed : .noChange
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
        guard let workspaceId = workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
        else { return .notFound }
        return commitMove(handle, to: workspaceId, placement: nil)
    }

    private func moveWindow(
        _ handle: WindowHandle,
        to target: WindowDisplayTarget,
        column: Int?,
        edgeOf anchor: WorkspaceDescriptor.ID?
    ) -> ExternalCommandResult {
        let manager = workspaceManager
        let display: Monitor.ID
        switch target {
        case let .display(id):
            guard manager.monitor(byId: id) != nil else { return .notFound }
            display = id
        case let .neighbor(direction, of):
            guard let source = of ?? manager.workspace(for: handle.id).flatMap(manager.monitorId(for:)) else {
                return .notFound
            }
            if let anchor, !isWindow(handle.id, onEdge: direction, of: anchor, display: source) { return .noChange }
            guard let neighbor = manager.adjacentMonitor(from: source, direction: direction) else { return .noChange }
            display = neighbor.id
        }
        guard let workspace = manager.activeWorkspaceOrFirst(on: display) else { return .noChange }
        return commitMove(handle, to: workspace.id, placement: column.map { .position($0 - 1) } ?? .append)
    }

    private func commitMove(
        _ handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        placement: NiriColumnPlacement?
    ) -> ExternalCommandResult {
        guard workspaceManager.workspace(for: handle.id) != workspaceId else { return .noChange }
        if case .changed = workspaceNavigationHandler.commitWindowMove(
            handle: handle,
            toWorkspaceId: workspaceId,
            placement: placement
        ) {
            return .executed
        }
        return .workspaceStateConflict
    }

    private func isWindow(
        _ token: WindowToken,
        onEdge direction: Direction,
        of workspaceId: WorkspaceDescriptor.ID,
        display: Monitor.ID
    ) -> Bool {
        let manager = workspaceManager
        guard let entry = manager.entry(for: token), entry.workspaceId == workspaceId, entry.mode == .tiling,
              !manager.isWindowSuppressedByMacOS(entry), manager.monitorId(for: workspaceId) == display,
              manager.activeLayoutKind(for: workspaceId) == .niri,
              let engine = niriEngine, let monitor = manager.monitor(byId: display),
              let node = engine.findNode(for: token, in: workspaceId), let column = engine.column(of: node)
        else { return false }
        let orientation = niriLayoutHandler.resolvedOrientation(for: workspaceId, monitor: monitor, engine: engine)
        if let step = direction.primaryStep(for: orientation) {
            let columns = engine.projectedColumns(in: workspaceId)
            guard let index = columns.firstIndex(where: { $0.column === column }),
                  columns[index].windows.contains(where: { $0 === node })
            else { return false }
            return !columns.indices.contains(index + step)
        }
        guard let step = direction.secondaryStep(for: orientation) else { return false }
        let windows = engine.projectedWindows(in: column, workspaceId: workspaceId)
        guard let member = windows.firstIndex(where: { $0 === node }) else { return false }
        return !windows.indices.contains(member + step)
    }
}
