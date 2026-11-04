// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension ShellAppWindowManager {
    var permissionDescriptors: [ShellComponentDescriptor] {
        controller.shellAppCatalog.definitions.values.compactMap(\.component)
            + runtimes.values.flatMap(\.descriptors)
    }

    func permissionTitle(of principal: ShellWidgetPrincipal) -> String? {
        permissionDescriptors.first { $0.principal == principal }?.title
    }

    func permissionsChanged() {
        for runtime in runtimes.values {
            runtime.permissionsChanged()
        }
    }

    func publishApprovals() {
        controller.workspaceBarManager.shellPermissionPrompts?.setAppApprovals(
            network: runtimes.values.flatMap(\.networkApprovals.values),
            programs: runtimes.values.flatMap(\.providerApprovals.values)
        )
    }
}
