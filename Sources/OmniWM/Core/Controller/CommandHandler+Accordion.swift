// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension CommandHandler {
    func toggleAccordion() {
        guard let controller, let workspace = controller.activeWorkspace() else { return }
        var configs = controller.settings.workspaces.configurations
        guard let index = configs.firstIndex(where: { $0.name == workspace.name }) else { return }

        let enabled = !configs[index].accordion
        configs[index] = configs[index].with(accordion: enabled)
        controller.settings.workspaces.configurations = configs
        controller.niriLayoutHandler.syncAccordion(enabled, in: workspace.id)
        controller.layoutRefreshController.requestRelayout(reason: .workspaceLayoutToggled)
        if let ipcApplicationBridge = controller.ipcApplicationBridge {
            Task {
                await ipcApplicationBridge.publishEvent(.layoutChanged)
            }
        }
    }
}
