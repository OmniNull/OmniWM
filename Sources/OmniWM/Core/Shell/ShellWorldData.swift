// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct ShellWorkspace: Equatable, Sendable {
    let id: String
    let name: String
    let focused: Bool
    let visible: Bool
    let windows: Int
}

struct ShellMenuApp: Equatable, Sendable, ShellValueWritable {
    let pid: pid_t
    let name: String
    let bundle: String

    func write(into writer: inout ShellValueWriter) {
        writer.map(3)
        writer.key("pid")
        writer.number(Double(pid))
        writer.key("name")
        writer.string(name)
        writer.key("bundle")
        writer.string(bundle)
    }
}

struct ShellWorldData: Equatable, Sendable {
    var workspace = ""
    var app = ""
    var bundle = ""
    var title = ""
    var workspaces: [ShellWorkspace] = []
    var menuApp: ShellMenuApp?
}

extension WMController {
    func shellMenuApp(
        frontmost: @autoclosure () -> NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) -> ShellMenuApp? {
        if let token = workspaceManager.selectedManagedToken,
           let entry = workspaceManager.entry(for: token)
        {
            let info = appInfoCache.info(for: entry.pid)
            return ShellMenuApp(pid: entry.pid, name: info?.name ?? "", bundle: info?.bundleId ?? "")
        }
        guard let app = frontmost(), !app.isTerminated else { return nil }
        return ShellMenuApp(
            pid: app.processIdentifier,
            name: app.localizedName ?? "",
            bundle: app.bundleIdentifier ?? ""
        )
    }

    func shellWorld() -> ShellWorldData {
        let focused = activeWorkspace()?.id
        let visible = workspaceManager.visibleWorkspaceIds()
        let focusedToken = workspaceManager.nativeManagedFocusToken
        let workspaces = workspaceManager.workspaces.map { workspace in
            ShellWorkspace(
                id: workspace.name,
                name: settings.workspaces.displayName(for: workspace.name),
                focused: workspace.id == focused,
                visible: visible.contains(workspace.id),
                windows: workspaceManager.windowCount(in: workspace.id)
            )
        }
        let entry = focusedToken.flatMap { workspaceManager.entry(for: $0) }
        let info = entry.flatMap { appInfoCache.info(for: $0.pid) }
        let frontmost = info?.name == nil || info?.bundleId == nil ? NSWorkspace.shared.frontmostApplication : nil
        return ShellWorldData(
            workspace: workspaces.first(where: \.focused)?.name ?? "",
            app: info?.name ?? frontmost?.localizedName ?? "",
            bundle: info?.bundleId ?? frontmost?.bundleIdentifier ?? "",
            title: entry.flatMap { AXWindowService.titlePreferFast(windowId: UInt32($0.windowId)) } ?? "",
            workspaces: workspaces,
            menuApp: shellMenuApp()
        )
    }
}
