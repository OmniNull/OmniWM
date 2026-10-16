// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMIPC

extension WorkspaceBarManager {
    static func barClick(for request: ShellRequest, sessionToken: String) -> ShellBarClick? {
        switch request {
        case let .window(window) where window.name == .focus:
            guard case let .valid(pid, windowId) = IPCWindowOpaqueID.validate(
                window.windowId,
                expectingSessionToken: sessionToken
            ) else {
                return nil
            }
            return .focusWindow(WindowToken(pid: pid, windowId: windowId))
        case let .command(.workspace(.switchTo(workspaceNumber))):
            return .focusWorkspace(rawName: String(workspaceNumber))
        case let .command(.scratchpad(.toggle(index))):
            return ScratchpadIndex(index).map { .toggleScratchpad($0) }
        default:
            return nil
        }
    }

    private func performBarClick(_ click: ShellBarClick, monitor: Monitor.ID, controller: WMController) -> Bool {
        switch click {
        case let .focusWindow(token):
            guard let handle = controller.workspaceManager.handle(for: token) else { return false }
            controller.focusWindowFromBar(handle: handle)
        case let .focusWorkspace(rawName):
            guard let workspaceId = controller.workspaceManager.workspaceId(named: rawName) else { return false }
            controller.focusWorkspaceFromBar(id: workspaceId)
        case let .toggleScratchpad(index):
            controller.activateScratchpadFromBar(index: index, on: monitor)
        }
        return true
    }

    func performShellRequest(_ request: ShellRequest, origin: ShellCommandOrigin) {
        guard let controller else { return }
        let route: @MainActor @Sendable (IPCCommandRouter) -> ExternalCommandResult
        switch request {
        case .statusMenu:
            openStatusMenu(from: origin, controller: controller)
            return
        case let .menu(content):
            openApplicationMenu(content, from: origin, controller: controller)
            return
        case let .moveFocusedWindow(target):
            moveFocusedWindow(to: target, on: origin.monitor, controller: controller)
            return
        case let .hiddenBarActivate(item):
            if let key = MenuBarItemKey(shellID: item) {
                showHiddenBarMenu(key, origin: origin)
            }
            return
        case let .command(command): route = { $0.handle(command) }
        case let .window(window): route = { $0.handle(window) }
        }
        if let click = Self.barClick(for: request, sessionToken: shellSessionToken),
           performBarClick(click, monitor: origin.monitor, controller: controller)
        {
            return
        }
        let sessionToken = shellSessionToken
        let perform: @MainActor @Sendable (WMController) -> ExternalCommandResult = { controller in
            route(IPCCommandRouter(controller: controller, sessionToken: sessionToken))
        }
        let widget = origin.widget
        let command = origin.command
        let report: @MainActor @Sendable (ExternalCommandResult) -> Void = { [weak self] result in
            guard let widget, let command, result != .executed, result != .noChange else { return }
            self?.shellHost?.logCommandFailure("\"\(command)\" failed: \(result)", widget: widget)
        }
        if !EventIntake.post(.ipcCommand(IPCCommandIntake(perform: perform, completion: report))) {
            report(perform(controller))
        }
    }

    private func moveFocusedWindow(to target: String, on monitor: Monitor.ID, controller: WMController) {
        guard let snapshot = barsByMonitor[monitor]?.model.snapshot else { return }
        switch Self.shellTarget(
            target,
            sessionToken: shellSessionToken,
            snapshot: snapshot,
            workspaceId: controller.workspaceManager.workspaceId(named:)
        ) {
        case let .workspace(workspaceId)?,
             let .window(workspaceId, _)?:
            _ = controller.workspaceNavigationHandler.moveFocusedWindowFromBar(toWorkspaceId: workspaceId)
        case let .scratchpad(slot)?:
            if let index = ScratchpadIndex(slot) {
                _ = controller.activateScratchpadFromBar(index: index, on: monitor)
            }
        case nil:
            break
        }
    }

    private func openApplicationMenu(
        _ content: MenuContent,
        from origin: ShellCommandOrigin,
        controller: WMController
    ) {
        guard let anchor = origin.anchor,
              let monitor = controller.workspaceManager.monitor(byId: origin.monitor)
        else { return }
        let app: NSRunningApplication? = switch content {
        case .apple,
             .all: NSWorkspace.shared.frontmostApplication
        case .application: controller.shellMenuApp().flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        }
        guard let app, !app.isTerminated else { return }
        menuMonitorId = origin.monitor
        refreshAutoHide()
        defer {
            menuMonitorId = nil
            refreshAutoHide()
        }
        MenuAnywhereController.shared.showNativeMenu(
            for: app,
            content: content,
            anchor: anchor.frame,
            edge: controller.settings.workspaceBar.resolved(for: monitor).position.popupEdge,
            visibleFrame: monitor.visibleFrame
        )
    }

    private func openStatusMenu(from origin: ShellCommandOrigin, controller: WMController) {
        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.id == origin.monitor })
        else { return }
        let frame = origin.anchor?.frame
            ?? CGRect(x: monitor.frame.midX, y: monitor.visibleFrame.maxY, width: 0, height: 0)
        controller.statusBarController?.routeClick(
            route: StatusBarController.clickRoute(
                isRightClick: origin.event.button == .right,
                optionHeld: origin.event.option
            ),
            anchorFrame: frame,
            screen: NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) },
            edge: controller.settings.workspaceBar.resolved(for: monitor).position.popupEdge,
            monitorId: origin.monitor
        )
    }

    func applyShellRequest(_ request: IPCShellRequest) -> ExternalCommandResult {
        guard request.isValid else { return .invalidArguments }
        switch request {
        case let .set(key, value):
            guard shellVars[key] != nil || shellVars.count < IPCShellRequest.countLimit else {
                return .invalidArguments
            }
            shellVars[key] = value
        case let .unset(key):
            guard shellVars.removeValue(forKey: key) != nil else { return .noChange }
        case let .toggle(widget):
            return toggleShell(widget) ? .executed : .notFound
        case .profile,
             .theme,
             .eject,
             .initialize:
            return .invalidArguments
        case let .trigger(widget, name, value):
            return shellHost?.trigger(widget, name: name, value: value) == true ? .executed : .notFound
        }
        shellHost?.updateVars()
        return .executed
    }

    var shellDirectory: URL? {
        controller.map { ShellWidgetHost.shellDirectory(in: $0.settings.settingsFileURL.deletingLastPathComponent()) }
    }

    func ejectShellWidget(_ widget: String, in shellDirectory: URL) throws -> URL? {
        let config = ShellConfig.resolve(shellDirectory: shellDirectory)
        return try ShellProfiles.eject(widget, config: config, shellDirectory: shellDirectory)
    }

    func applyShellFileRequest(_ request: IPCShellRequest) async -> ExternalCommandResult {
        guard request.isValid, shellDirectory != nil else { return .invalidArguments }
        do {
            let changed: Bool
            switch request {
            case let .profile(name): changed = try await shellConfiguration.selectProfile(name)
            case let .theme(name, nil): changed = try await shellConfiguration.selectTheme(name)
            case let .theme(name, scheme?):
                guard name == ShellWallpaperPalette.themeName,
                      let scheme = ShellWallpaperScheme(rawValue: scheme)
                else {
                    return .invalidArguments
                }
                changed = try await shellConfiguration.editFile { directory in
                    let theme = try ShellProfiles.selectTheme(name, in: directory)
                    return try ShellProfiles.selectScheme(scheme, in: directory) || theme
                }
            case let .eject(widget):
                changed = try await shellConfiguration.editFile { directory in
                    try ShellProfiles.eject(
                        widget,
                        config: ShellConfig.resolve(shellDirectory: directory),
                        shellDirectory: directory
                    ) != nil
                }
            case let .initialize(widget):
                changed = try await shellConfiguration.editFile { try ShellProfiles.create(widget, in: $0) }
            default: return applyShellRequest(request)
            }
            return changed ? .executed : .noChange
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return .notFound
        } catch {
            Log.shell.error("Shell request failed: \(error.localizedDescription)")
            return .invalidArguments
        }
    }

    func refreshShellAppearance() {
        shellHost?.appearanceDidChange()
    }

    func refreshShellIcons() {
        shellHost?.iconsDidChange()
    }

    func refreshShellBarColors(_ settings: SettingsStore) {
        shellHost?.setBarColors(accent: settings.workspaceBar.accentColor, foreground: settings.workspaceBar.textColor)
    }

    func refreshShellShaders() {
        shellHost?.refreshShaders()
    }

    func shellSurfaceView(_ widget: String, key: ShellBarKey) -> NSView? {
        guard let instance = barsByMonitor[key.monitor] else { return nil }
        return shellHost?.surfaceView(
            widget: widget,
            key: key,
            scale: screenProvider(instance.monitor.displayId)?.backingScaleFactor ?? 2
        )
    }
}
