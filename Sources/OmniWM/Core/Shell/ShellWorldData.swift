// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
           let pid = workspaceManager.withEntry(token, { $0.pid })
        {
            let info = appInfoCache.info(for: pid)
            return ShellMenuApp(pid: pid, name: info?.name ?? "", bundle: info?.bundleId ?? "")
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
        let focus = focusedToken.flatMap { token in
            workspaceManager.withEntry(token) { (pid: $0.pid, windowId: $0.windowId, hosted: $0.target.hostedMetadata) }
        }
        let hosted = focus?.hosted
        let info = hosted == nil ? focus.flatMap { appInfoCache.info(for: $0.pid) } : nil
        let frontmost = hosted == nil && (info?.name == nil || info?.bundleId == nil)
            ? NSWorkspace.shared.frontmostApplication : nil
        return ShellWorldData(
            workspace: workspaces.first(where: \.focused)?.name ?? "",
            app: hosted?.title ?? info?.name ?? frontmost?.localizedName ?? "",
            bundle: hosted?.appId ?? info?.bundleId ?? frontmost?.bundleIdentifier ?? "",
            title: hosted?.title ?? focus
                .flatMap { AXWindowService.titlePreferFast(windowId: UInt32($0.windowId)) } ?? "",
            workspaces: workspaces,
            menuApp: shellMenuApp()
        )
    }
}
