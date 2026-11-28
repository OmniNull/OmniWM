// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension CommandHandler {
    enum LayoutChangeCoverage {
        case ownWorkspace
        case everyNiriWorkspace
    }

    static func layoutChangeCoverage(of command: HotkeyCommand) -> LayoutChangeCoverage? {
        switch command {
        case .move,
             .moveColumn,
             .windowMovement:
            .ownWorkspace
        case let .column(action):
            switch action {
            case .moveToFirst,
                 .moveToLast,
                 .moveToIndex,
                 .toggleTabbed: .ownWorkspace
            case .moveToWorkspace,
                 .moveToWorkspaceUp,
                 .moveToWorkspaceDown: .everyNiriWorkspace
            }
        case let .workspace(action):
            switch action {
            case .moveTo,
                 .moveToOnMonitor,
                 .moveUp,
                 .moveDown,
                 .moveToMonitor,
                 .moveToSlot: .everyNiriWorkspace
            default: nil
            }
        case let .sizing(action):
            action != .undo && action != .redo ? .ownWorkspace : nil
        default:
            nil
        }
    }

    static func layoutChangeStart(
        recording command: HotkeyCommand,
        controller: WMController
    ) -> NiriLayoutChangeStart? {
        switch Self.layoutChangeCoverage(of: command) {
        case .ownWorkspace: controller.niriLayoutHandler.activeLayoutChangeStart()
        case .everyNiriWorkspace:
            controller.niriLayoutHandler
                .layoutChangeStartCoveringEveryNiriWorkspace(in: controller.activeWorkspace()?.id)
        case nil: nil
        }
    }

    static func mixedTransferSelection(
        for command: HotkeyCommand,
        controller: WMController
    ) -> (token: WindowToken, source: WorkspaceDescriptor.ID)? {
        switch command {
        case .move,
             .windowMovement: break
        case let .workspace(action):
            switch action {
            case .moveTo,
                 .moveToOnMonitor,
                 .moveUp,
                 .moveDown,
                 .moveToMonitor,
                 .moveToSlot: break
            default: return nil
            }
        default: return nil
        }
        guard let token = controller.workspaceManager.selectedManagedToken,
              let source = controller.workspaceManager.workspace(for: token),
              controller.workspaceManager.activeLayoutKind(for: source) == .niri
        else { return nil }
        return (token, source)
    }

    static func finishLayoutChange(
        _ start: borrowing NiriLayoutChangeStart?,
        transfer: (token: WindowToken, source: WorkspaceDescriptor.ID)?,
        controller: WMController
    ) {
        guard start != nil, !completedMixedTransfer(transfer, controller: controller) else { return }
        controller.niriLayoutHandler.recordLayoutChange(since: start)
    }

    private static func completedMixedTransfer(
        _ before: (token: WindowToken, source: WorkspaceDescriptor.ID)?,
        controller: WMController
    ) -> Bool {
        guard let before, let target = controller.workspaceManager.workspace(for: before.token),
              target != before.source else { return false }
        return controller.workspaceManager.activeLayoutKind(for: target) == .dwindle
    }
}
