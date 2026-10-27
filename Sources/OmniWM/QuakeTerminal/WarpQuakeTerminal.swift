// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor @Observable
final class WarpQuakeTerminal {
    enum Problem: Error, Equatable {
        case notInstalled
        case launchFailed
        case windowNotFound

        var message: String {
            switch self {
            case .notInstalled:
                String(localized: "Warp is not installed. Install Warp from warp.dev, or choose Ghostty or Kitty.")
            case .launchFailed:
                String(localized: "OmniWM could not start Warp.")
            case .windowNotFound:
                String(localized: "OmniWM could not find a window for Warp.")
            }
        }
    }

    static let installations = [
        (bundleIdentifier: "dev.warp.Warp-Stable", scheme: "warp"),
        (bundleIdentifier: "dev.warp.Warp-Preview", scheme: "warppreview")
    ]

    private(set) var problem: Problem?
    @ObservationIgnored var onToggleFailure: (@MainActor (Problem) -> Void)?
    private(set) var token: WindowToken?
    private(set) var hideCallCount = 0
    weak var controller: WMController?

    @ObservationIgnored var newWindowURLProvider: @MainActor () -> URL? = {
        WarpQuakeTerminal.resolveNewWindowURL()
    }

    @ObservationIgnored var urlOpener: @MainActor (URL, NSWorkspace.OpenConfiguration) async throws
        -> NSRunningApplication = { url, config in
            try await NSWorkspace.shared.open(url, configuration: config)
        }

    @ObservationIgnored var windowWaitTimeout: Duration = .seconds(5)
    @ObservationIgnored var windowWaitPollInterval: Duration = .milliseconds(50)
    @ObservationIgnored private var commandTail: Task<Void, Never>?

    init(controller: WMController?) {
        self.controller = controller
    }

    static func resolveNewWindowURL(
        isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> URL? {
        guard let installation = installations.first(where: { isInstalled($0.bundleIdentifier) }) else { return nil }
        var components = URLComponents()
        components.scheme = installation.scheme
        components.host = "action"
        components.path = "/new_window"
        components.queryItems = [URLQueryItem(name: "path", value: home)]
        return components.url
    }

    func setTokenForTests(_ token: WindowToken?) {
        self.token = token
    }

    func noteWindowRemoved(_ removedToken: WindowToken) {
        if token == removedToken {
            token = nil
        }
    }

    @discardableResult
    func activate() -> Task<Void, Never> {
        enqueue { terminal in
            if terminal.newWindowURLProvider() == nil {
                terminal.report(.notInstalled)
            } else {
                terminal.problem = nil
            }
        }
    }

    @discardableResult
    func toggle() -> Task<Void, Never> {
        enqueue { terminal in
            await terminal.toggleInstance()
        }
    }

    @discardableResult
    func hide() -> Task<Void, Never> {
        hideCallCount += 1
        return enqueue { terminal in
            terminal.hideInstance()
        }
    }

    private func enqueue(
        _ operation: @escaping @MainActor @Sendable (WarpQuakeTerminal) async -> Void
    ) -> Task<Void, Never> {
        let previous = commandTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
        commandTail = task
        return task
    }

    private func toggleInstance() async {
        guard let controller else { return }
        if let currentToken = token,
           let entry = controller.workspaceManager.entry(for: currentToken)
        {
            toggleExistingWindow(entry: entry, token: currentToken, controller: controller)
            return
        }
        await launchAndPresentNewWindow(controller: controller)
    }

    private func toggleExistingWindow(entry: WindowState, token: WindowToken, controller: WMController) {
        if controller.workspaceManager.hiddenState(for: token) != nil {
            guard let target = controller.scratchpadTarget() else { return }
            if entry.workspaceId != target.workspaceId {
                controller.reassignManagedWindow(token, to: target.workspaceId)
            }
            let entry = controller.workspaceManager.entry(for: token) ?? entry
            controller.layoutRefreshController.unhideWindow(entry, monitor: target.monitor)
            controller.focusWindow(token)
        } else {
            let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
                ?? controller.workspaceManager.monitors.first
                ?? Monitor.fallback()
            let side = controller.layoutRefreshController.preferredHideSide(for: monitor)
            controller.layoutRefreshController.hideWindow(entry, monitor: monitor, side: side, reason: .quake)
        }
    }

    private func launchAndPresentNewWindow(controller: WMController) async {
        token = nil
        guard let newWindowURL = newWindowURLProvider() else {
            report(.notInstalled)
            return
        }

        let runningApp: NSRunningApplication
        do {
            let config = NSWorkspace.OpenConfiguration()
            runningApp = try await urlOpener(newWindowURL, config)
        } catch {
            report(.launchFailed)
            return
        }

        let pid = runningApp.processIdentifier
        let existingTokens = Set(controller.workspaceManager.entries(forPid: pid).map(\.token))
        guard let entry = await waitForWindow(pid: pid, existingTokens: existingTokens) else {
            report(.windowNotFound)
            return
        }

        presentAdmittedWindow(entry: entry, controller: controller)
    }

    private func presentAdmittedWindow(entry: WindowState, controller: WMController) {
        let newToken = entry.token
        token = newToken
        controller.applyManagedWindowOverride(.forceFloat, for: newToken, entry: entry)
        let screen = targetScreen()
        let placement = QuakeTerminalPlacement(
            position: controller.settings.quakeTerminal.position,
            on: screen,
            widthPercent: controller.settings.quakeTerminal.widthPercent,
            heightPercent: controller.settings.quakeTerminal.heightPercent
        )
        let targetFrame = placement.finalFrame()
        _ = AXWindowService.setFrame(entry.axRef, frame: targetFrame)
        let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == screen.displayId })
            ?? controller.workspaceManager.monitors.first
            ?? Monitor.fallback()
        controller.workspaceManager.updateFloatingGeometry(frame: targetFrame, for: newToken, referenceMonitor: monitor)
        controller.focusWindow(newToken)
        problem = nil
    }

    private func hideInstance() {
        guard let controller,
              let currentToken = token,
              let entry = controller.workspaceManager.entry(for: currentToken),
              controller.workspaceManager.hiddenState(for: currentToken) == nil
        else { return }
        let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
            ?? controller.workspaceManager.monitors.first
            ?? Monitor.fallback()
        let side = controller.layoutRefreshController.preferredHideSide(for: monitor)
        controller.layoutRefreshController.hideWindow(entry, monitor: monitor, side: side, reason: .quake)
    }

    private func waitForWindow(pid: pid_t, existingTokens: Set<WindowToken>) async -> WindowState? {
        let clock = ContinuousClock()
        let deadline = clock.now + windowWaitTimeout
        while clock.now < deadline {
            if let controller {
                let entries = controller.workspaceManager.entries(forPid: pid)
                if let entry = entries.first(where: { !existingTokens.contains($0.token) }) {
                    return entry
                }
            }
            await Task.yield()
            try? await Task.sleep(for: windowWaitPollInterval)
        }
        return nil
    }

    private func targetScreen() -> NSScreen {
        guard let controller else { return NSScreen.main ?? NSScreen.screens.first! }
        return QuakeTerminalPlacement.targetScreen(
            settings: controller.settings,
            screens: NSScreen.screens,
            mainScreen: NSScreen.main,
            monitors: { [weak controller] in controller?.workspaceManager.monitors ?? [] },
            focusedWindowScreenProvider: { [weak controller] in
                controller?.focusedManagedWindowScreenForQuakeTerminal()
            }
        )
    }

    private func report(_ problem: Problem) {
        self.problem = problem
        onToggleFailure?(problem)
    }
}
