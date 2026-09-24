// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class CommandHandler {
    weak var controller: WMController?
    var nativeFullscreenStateProvider: ((AXWindowRef) -> Bool)?
    var nativeFullscreenSetter: ((AXWindowRef, Bool) -> Bool)?
    var frontmostAppPidProvider: (() -> pid_t?)?
    var frontmostFocusedWindowTokenProvider: (() -> WindowToken?)?

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func handleHotkeyInvocation(_ invocation: HotkeyInvocation) -> ExternalCommandResult {
        guard let controller else { return .notFound }
        guard controller.isEnabled else { return .ignoredDisabled }
        if invocation.command == .presentation(.overview), invocation.trigger?.isRepeat == true {
            return .executed
        }
        switch controller.handleOverviewHotkey(invocation) {
        case .handled:
            return .executed
        case .blocked:
            return .ignoredOverview
        case .inactive:
            return performCommand(invocation.command)
        }
    }

    @discardableResult
    func performCommand(_ command: HotkeyCommand) -> ExternalCommandResult {
        guard let controller else { return .notFound }
        guard controller.isEnabled else { return .ignoredDisabled }
        guard !Self.shouldIgnoreCommand(command, isOverviewOpen: controller.isOverviewOpen()) else {
            return .ignoredOverview
        }

        guard Self.isLayoutCompatible(command.layoutCompatibility, with: currentLayoutType()) else {
            return .ignoredLayoutMismatch
        }

        return performAllowedCommand(command, controller: controller)
    }

    static func isLayoutCompatible(_ compatibility: LayoutCompatibility, with layoutType: LayoutType) -> Bool {
        switch (compatibility, layoutType) {
        case (.niri, .dwindle),
             (.dwindle, .niri),
             (.dwindle, .defaultLayout):
            false
        default:
            true
        }
    }

    private func performAllowedCommand(_ command: HotkeyCommand, controller: WMController) -> ExternalCommandResult {
        switch command {
        case let .focus(direction):
            focusWindow(direction: direction)
        case let .focusNavigation(action):
            return perform(action, controller: controller)
        case let .move(direction):
            let outcome = moveWindow(direction: direction)
            if outcome == .atWorkspaceEdge, controller.settings.focus.moveCrossesMonitorAtEdge {
                controller.workspaceNavigationHandler.moveWindowAcrossMonitorAtEdge(direction: direction)
            }
        case let .workspace(action):
            return perform(action, controller: controller)
        case let .windowMovement(action):
            return perform(action, controller: controller)
        case let .column(action):
            return perform(action, controller: controller)
        case let .monitorFocus(action):
            return perform(action, controller: controller)
        case let .fullscreen(action):
            return perform(action, controller: controller)
        case let .moveColumn(direction):
            moveContainer(direction: direction)
        case let .sizing(action):
            return perform(action, controller: controller)
        case let .dwindle(action):
            return perform(action, controller: controller)
        case .openCommandPalette:
            controller.openCommandPalette()
        case .raiseAllFloatingWindows:
            controller.raiseAllFloatingWindows()
        case .rescueOffscreenWindows:
            _ = controller.rescueOffscreenWindows()
        case .windowState(.toggleFloating):
            return controller.toggleFocusedWindowFloating()
        case .windowState(.close):
            return controller.closeFocusedWindow()
        case let .scratchpad(action):
            return perform(action, controller: controller)
        case .openMenuAnywhere:
            controller.openMenuAnywhere()
        case let .presentation(action):
            return perform(action, controller: controller)
        }
        return .executed
    }

    static func shouldIgnoreCommand(_ command: HotkeyCommand, isOverviewOpen: Bool) -> Bool {
        isOverviewOpen && command != .presentation(.overview)
    }

    func layoutHandler<T>(as capability: T.Type) -> T? {
        guard let controller else { return nil }
        let layoutType = currentLayoutType()
        let handler: AnyObject = switch layoutType {
        case .dwindle:
            controller.layoutRefreshController.dwindleHandler
        case .niri,
             .defaultLayout:
            controller.layoutRefreshController.niriHandler
        }
        return handler as? T
    }

    private func moveWindow(direction: Direction) -> WindowMoveOutcome {
        switch currentLayoutType() {
        case .dwindle:
            controller?.dwindleLayoutHandler.moveWindow(direction: direction) ?? .blocked
        case .niri,
             .defaultLayout:
            moveWindowInNiri(direction: direction)
        }
    }

    private func focusWindow(direction: Direction) {
        guard let controller else { return }
        switch currentLayoutType() {
        case .dwindle:
            if controller.dwindleLayoutHandler.focusNeighbor(direction: direction) {
                return
            }
            if controller.settings.focus.crossesMonitorAtEdge,
               controller.workspaceNavigationHandler.focusMonitor(direction: direction)
            {
                return
            }
            _ = controller.dwindleLayoutHandler.wrapGroupFocus(direction: direction)
        case .niri,
             .defaultLayout:
            if controller.niriLayoutHandler.focusNeighbor(direction: direction) != true,
               controller.settings.focus.crossesMonitorAtEdge
            {
                _ = controller.workspaceNavigationHandler.focusMonitor(direction: direction)
            }
        }
    }

    func moveWindowWithinContainer(direction: Direction) {
        switch currentLayoutType() {
        case .dwindle:
            controller?.dwindleLayoutHandler.moveGroupMember(direction: direction)
        case .niri,
             .defaultLayout:
            controller?.niriLayoutHandler.moveWindowWithinContainer(direction: direction)
        }
    }

    private func moveContainer(direction: Direction) {
        switch currentLayoutType() {
        case .dwindle:
            _ = controller?.dwindleLayoutHandler.swapWindow(direction: direction)
        case .niri,
             .defaultLayout:
            controller?.niriLayoutHandler.moveColumn(direction: direction)
        }
    }

    func focusWindowWrapping(direction: Direction) {
        switch currentLayoutType() {
        case .dwindle:
            _ = controller?.dwindleLayoutHandler.wrapGroupFocus(direction: direction)
        case .niri,
             .defaultLayout:
            if direction == .down {
                controller?.niriLayoutHandler.focusWindowDownOrTopInNiri()
            } else if direction == .up {
                controller?.niriLayoutHandler.focusWindowUpOrBottomInNiri()
            }
        }
    }

    func toggleFullscreen() {
        switch currentLayoutType() {
        case .dwindle:
            controller?.dwindleLayoutHandler.toggleFullscreen()
        case .niri,
             .defaultLayout:
            controller?.niriLayoutHandler.toggleFullscreen()
        }
    }

    private func moveWindowInNiri(direction: Direction) -> WindowMoveOutcome {
        controller?.niriLayoutHandler.moveWindow(direction: direction) ?? .blocked
    }

    func toggleNativeFullscreenForFocused() {
        guard let controller else { return }
        let setFullscreen = nativeFullscreenSetter ?? { axRef, fullscreen in
            AXWindowService.setNativeFullscreen(axRef, fullscreen: fullscreen)
        }
        let isFullscreen = nativeFullscreenStateProvider ?? { axRef in
            AXWindowService.isFullscreen(axRef)
        }

        if let token = controller.workspaceManager.selectedManagedToken,
           let entry = controller.workspaceManager.entry(for: token),
           !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token)
        {
            let currentState = isFullscreen(entry.axRef)
            if currentState {
                applyNativeFullscreenExit(
                    token,
                    axRef: entry.axRef,
                    controller: controller,
                    setter: setFullscreen
                )
                return
            }

            guard controller.workspaceManager.requestNativeFullscreenEnter(token, in: entry.workspaceId) else {
                return
            }
            guard setFullscreen(entry.axRef, true) else {
                controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
                return
            }
            return
        }

        guard controller.workspaceManager.isAppFullscreenActive
            || controller.workspaceManager.hasPendingNativeFullscreenTransition
        else {
            return
        }

        let frontmostPid = frontmostAppPidProvider?() ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostToken = frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { controller.axEventHandler.focusedWindowToken(for: $0) }
        guard let token = controller.workspaceManager.nativeFullscreenCommandTarget(frontmostToken: frontmostToken),
              let entry = controller.workspaceManager.entry(for: token),
              !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token)
        else {
            return
        }

        applyNativeFullscreenExit(
            token,
            axRef: entry.axRef,
            controller: controller,
            setter: setFullscreen
        )
    }

    private func applyNativeFullscreenExit(
        _ token: WindowToken,
        axRef: AXWindowRef,
        controller: WMController,
        setter: (AXWindowRef, Bool) -> Bool
    ) {
        guard controller.workspaceManager.requestNativeFullscreenExit(token) else { return }
        if !setter(axRef, false) {
            _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        }
    }

    func toggleColumnTabbedInNiri() {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriWorkspaceContext { engine, wsId, motion, state, _, _, _, orientation in
            if engine.toggleColumnTabbed(
                in: wsId,
                state: state,
                motion: motion,
                orientation: orientation
            ) {
                controller.workspaceManager.recordReconcileEvent(
                    .layoutOperationPerformed(workspaceId: wsId, operation: .displayModeChanged, source: .command)
                )
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
                if engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    controller.layoutRefreshController.startScrollAnimation(for: wsId)
                }
            }
        }
    }

    private func currentLayoutType() -> LayoutType {
        guard let controller else { return .niri }
        guard let ws = controller.activeWorkspace() else { return .niri }
        return controller.settings.workspaces.layoutType(for: ws.name)
    }

    func toggleWorkspaceLayout() {
        guard let controller else { return }
        guard let workspace = controller.activeWorkspace() else { return }
        let workspaceName = workspace.name

        let currentLayout = controller.settings.workspaces.layoutType(for: workspaceName)

        let newLayout: LayoutType = switch currentLayout {
        case .niri,
             .defaultLayout: .dwindle
        case .dwindle: .niri
        }

        _ = setWorkspaceLayout(newLayout, forWorkspaceNamed: workspaceName)
    }

    @discardableResult
    func setWorkspaceLayout(_ newLayout: LayoutType, forWorkspaceNamed workspaceName: String? = nil) -> Bool {
        guard let controller else { return false }
        let resolvedWorkspaceName = workspaceName ?? controller.activeWorkspace()?.name
        guard let resolvedWorkspaceName else { return false }

        var configs = controller.settings.workspaces.configurations
        guard let index = configs.firstIndex(where: { $0.name == resolvedWorkspaceName }) else { return false }

        guard configs[index].layoutType != newLayout else { return false }

        configs[index] = configs[index].with(layoutType: newLayout)
        controller.settings.workspaces.configurations = configs
        controller.layoutRefreshController.requestRelayout(reason: .workspaceLayoutToggled)
        if let ipcApplicationBridge = controller.ipcApplicationBridge {
            Task {
                await ipcApplicationBridge.publishEvent(.layoutChanged)
            }
        }
        return true
    }
}
