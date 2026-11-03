// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension AppDelegate {
    func prepareShellForQuit(
        controller: WMController,
        confirmDiscard: (Error) -> Bool
    ) async -> Bool {
        do {
            try await controller.clipboardHistoryService.flushForQuit()
        } catch {
            guard confirmDiscard(error) else {
                controller.clipboardHistoryService.resumeAfterCanceledQuit()
                return false
            }
        }
        controller.shellAppWindowManager.shutdown()
        await controller.workspaceBarManager.flushShellForQuit()
        return true
    }
}
