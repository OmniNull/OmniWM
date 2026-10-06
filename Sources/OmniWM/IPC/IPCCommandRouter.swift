// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
final class IPCCommandRouter {
    let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func handle(_ request: IPCCommandRequest) -> ExternalCommandResult {
        switch request {
        case let .focus(command):
            guard let hotkey = HotkeyCommand(ipc: command) else { return .invalidArguments }
            return controller.commandHandler.performCommand(hotkey)
        case let .windowMovement(command):
            return controller.commandHandler.performCommand(HotkeyCommand(ipc: command))
        case let .workspace(command):
            return handle(command)
        case let .monitorFocus(command):
            return handle(command)
        case let .column(command):
            guard let hotkey = HotkeyCommand(ipc: command) else { return .invalidArguments }
            return controller.commandHandler.performCommand(hotkey)
        case let .sizing(command):
            return controller.commandHandler.performCommand(HotkeyCommand(ipc: command))
        case let .swapWorkspaceWithMonitor(ipcDirection):
            return swapWorkspaceWithMonitor(direction: Direction(ipc: ipcDirection))
        case let .dwindle(command):
            return controller.commandHandler.performCommand(HotkeyCommand(ipc: command))
        case .openCommandPalette:
            return controller.commandHandler.performCommand(.openCommandPalette)
        case let .openCommandPaletteMode(mode):
            if let guardResult = IPCCommandValidation.controllerState(controller) {
                return guardResult
            }
            controller.openCommandPalette(mode: CommandPaletteMode(ipc: mode))
            return .executed
        case .raiseAllFloatingWindows:
            return raiseAllFloatingWindows()
        case .rescueOffscreenWindows:
            return rescueOffscreenWindows()
        case let .workspaceLayout(command):
            return handle(command)
        case let .fullscreen(command):
            return controller.commandHandler.performCommand(.fullscreen(command))
        case let .presentation(command):
            return controller.commandHandler.performCommand(.presentation(command))
        case let .windowState(command):
            return controller.commandHandler.performCommand(.windowState(command))
        case let .scratchpad(command):
            return controller.commandHandler.performCommand(HotkeyCommand(ipc: command))
        case .openMenuAnywhere:
            return controller.commandHandler.performCommand(.openMenuAnywhere)
        }
    }

    private func handle(_ command: IPCWorkspaceCommand) -> ExternalCommandResult {
        switch command {
        case let .switchTo(workspaceNumber):
            guard let target = WorkspaceTarget(workspaceNumber: workspaceNumber) else {
                return .invalidArguments
            }
            return switchWorkspace(to: target)
        case .next:
            return switchWorkspace(using: .workspace(.next))
        case .previous:
            return switchWorkspace(using: .workspace(.previous))
        case .backAndForth:
            return switchWorkspace(using: .workspace(.backAndForth))
        case let .switchAnywhere(workspaceNumber):
            guard let target = WorkspaceTarget(workspaceNumber: workspaceNumber) else {
                return .invalidArguments
            }
            return switchWorkspaceAnywhere(to: target)
        case let .switchSlot(slotNumber):
            return switchWorkspaceSlot(slotNumber)
        case let .moveTo(workspaceNumber):
            guard let target = WorkspaceTarget(workspaceNumber: workspaceNumber) else {
                return .invalidArguments
            }
            return moveFocusedWindow(to: target)
        case .moveUp:
            return moveFocusedWindow(using: .workspace(.moveUp))
        case .moveDown:
            return moveFocusedWindow(using: .workspace(.moveDown))
        case let .moveToOnMonitor(workspaceNumber, ipcDirection):
            guard let target = WorkspaceTarget(workspaceNumber: workspaceNumber) else {
                return .invalidArguments
            }
            return moveFocusedWindow(
                to: target,
                onMonitor: Direction(ipc: ipcDirection)
            )
        case let .moveToSlot(slotNumber):
            return moveFocusedWindow(toWorkspaceSlot: slotNumber)
        case let .moveToMonitor(ipcDirection):
            return moveFocusedWindowToMonitor(Direction(ipc: ipcDirection))
        }
    }

    private func handle(_ command: IPCMonitorFocusCommand) -> ExternalCommandResult {
        switch command {
        case .previous:
            return focusMonitor(previous: true)
        case .next:
            return focusMonitor(previous: false)
        case .last:
            return focusLastMonitor()
        }
    }

    private func handle(_ command: IPCWorkspaceLayoutCommand) -> ExternalCommandResult {
        switch command {
        case .toggle:
            return controller.commandHandler.performCommand(.workspace(.toggleLayout))
        case let .set(layout):
            if let guardResult = IPCCommandValidation.controllerState(controller) {
                return guardResult
            }
            return controller.commandHandler.setWorkspaceLayout(LayoutType(ipc: layout)) ? .executed : .noChange
        }
    }

    func handle(_ request: IPCWindowRequest) -> ExternalCommandResult {
        IPCWindowRequestExecutor(controller: controller, sessionToken: sessionToken).handle(request)
    }

    private func focusMonitor(previous: Bool) -> ExternalCommandResult {
        let previousMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        let result = controller.commandHandler.performCommand(.monitorFocus(previous ? .previous : .next))
        guard result == .executed else { return result }
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        return currentMonitorId == previousMonitorId ? .noChange : .executed
    }

    private func focusLastMonitor() -> ExternalCommandResult {
        let previousMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        let result = controller.commandHandler.performCommand(.monitorFocus(.last))
        guard result == .executed else { return result }
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        return currentMonitorId == previousMonitorId ? .noChange : .executed
    }

    private func switchWorkspace(using command: HotkeyCommand) -> ExternalCommandResult {
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = controller.commandHandler.performCommand(command)
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .noChange : .executed
    }

    private func moveFocusedWindow(using command: HotkeyCommand) -> ExternalCommandResult {
        guard let token = controller.workspaceManager.selectedManagedToken else { return .notFound }
        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        let result = controller.commandHandler.performCommand(command)
        guard result == .executed else { return result }
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .noChange : .executed
    }

    private func moveFocusedWindowToMonitor(_ direction: Direction) -> ExternalCommandResult {
        guard let token = controller.workspaceManager.selectedManagedToken,
              let workspaceId = controller.workspaceManager.workspace(for: token),
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
              controller.workspaceManager.adjacentMonitor(from: monitorId, direction: direction) != nil
        else { return .notFound }
        return moveFocusedWindow(using: .workspace(.moveToMonitor(direction)))
    }

    private func swapWorkspaceWithMonitor(direction: Direction) -> ExternalCommandResult {
        guard let monitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id,
            controller.workspaceManager.adjacentMonitor(from: monitorId, direction: direction) != nil
        else { return .notFound }
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = controller.commandHandler.performCommand(.workspace(.swapWithMonitor(direction)))
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .noChange : .executed
    }

    private func raiseAllFloatingWindows() -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }
        guard controller.windowActionHandler.hasRaisableFloatingWindows() else {
            return .noChange
        }
        return controller.commandHandler.performCommand(.raiseAllFloatingWindows)
    }

    private func rescueOffscreenWindows() -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }
        return controller.rescueOffscreenWindows() > 0 ? .executed : .noChange
    }

    private func switchWorkspace(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        if let currentWorkspace = controller.activeWorkspace(),
           currentWorkspace.name == rawWorkspaceID,
           controller.workspaceNavigationHandler.canSkipSwitch(toVisibleWorkspace: currentWorkspace.id)
        {
            return .noChange
        }
        return controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: rawWorkspaceID)
            ? .executed
            : .notFound
    }

    private func switchWorkspaceAnywhere(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        if let currentWorkspace = controller.activeWorkspace(),
           currentWorkspace.name == rawWorkspaceID,
           controller.workspaceNavigationHandler.canSkipSwitch(toVisibleWorkspace: currentWorkspace.id)
        {
            return .noChange
        }
        return controller.workspaceNavigationHandler.focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID)
            ? .executed
            : .notFound
    }

    private func switchWorkspaceSlot(_ slot: Int) -> ExternalCommandResult {
        guard slot >= 1 else { return .invalidArguments }
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }
        guard let target = controller.workspaceNavigationHandler.workspaceSlot(slot) else { return .notFound }
        if controller.activeWorkspace()?.id == target.id,
           controller.workspaceNavigationHandler.canSkipSwitch(toVisibleWorkspace: target.id)
        {
            return .noChange
        }
        return controller.workspaceNavigationHandler.switchWorkspaceSlot(slot) ? .executed : .notFound
    }

    private func moveFocusedWindow(toWorkspaceSlot slot: Int) -> ExternalCommandResult {
        guard slot >= 1 else { return .invalidArguments }
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }
        guard let token = controller.workspaceManager.selectedManagedToken,
              let target = controller.workspaceNavigationHandler.workspaceSlot(slot)
        else { return .notFound }
        guard controller.workspaceManager.workspace(for: token) != target.id else { return .noChange }
        return controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceSlot: slot)
            ? .executed
            : .workspaceStateConflict
    }

    private func moveFocusedWindow(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }
        guard let token = controller.workspaceManager.selectedManagedToken else { return .notFound }
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        guard !IPCCommandValidation.isAlreadyOnWorkspace(token, rawWorkspaceID: rawWorkspaceID, controller: controller)
        else { return .noChange }
        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        controller.workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .notFound : .executed
    }

    private func moveFocusedWindow(
        to target: WorkspaceTarget,
        onMonitor monitorDirection: Direction
    ) -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }
        guard let token = controller.workspaceManager.selectedManagedToken else { return .notFound }
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        guard !IPCCommandValidation.isAlreadyOnWorkspace(token, rawWorkspaceID: rawWorkspaceID, controller: controller)
        else { return .noChange }
        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        controller.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
            rawWorkspaceID: rawWorkspaceID,
            monitorDirection: monitorDirection
        )
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .notFound : .executed
    }
}
