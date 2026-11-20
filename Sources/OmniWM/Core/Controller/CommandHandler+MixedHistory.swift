// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension CommandHandler {
    func mixedTransferSelection(
        for command: HotkeyCommand,
        controller: WMController
    ) -> (token: WindowToken, source: WorkspaceDescriptor.ID)? {
        switch command {
        case .move,
             .windowMovement: break
        case let .workspace(action):
            switch action {
            case .moveTo,
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

    func finishLayoutChange(
        _ start: borrowing NiriLayoutChangeStart?,
        transfer: (token: WindowToken, source: WorkspaceDescriptor.ID)?,
        controller: WMController
    ) {
        guard !completedMixedTransfer(transfer, controller: controller) else { return }
        controller.niriLayoutHandler.recordLayoutChange(since: start)
    }

    private func completedMixedTransfer(
        _ before: (token: WindowToken, source: WorkspaceDescriptor.ID)?,
        controller: WMController
    ) -> Bool {
        guard let before, let target = controller.workspaceManager.workspace(for: before.token),
              target != before.source else { return false }
        return controller.workspaceManager.activeLayoutKind(for: target) == .dwindle
    }
}
