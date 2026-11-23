// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ConfigScriptEventObservers {
    func replaceNiri(_ previous: NiriLayoutEngine?, with current: NiriLayoutEngine?) {
        guard previous !== current else { return }
        previous?.onFullscreenChange = nil
        current?.onFullscreenChange = niriFullscreenChange
    }

    func replaceDwindle(_ previous: DwindleLayoutEngine?, with current: DwindleLayoutEngine?) {
        guard previous !== current else { return }
        previous?.onFullscreenChange = nil
        current?.onFullscreenChange = dwindleFullscreenChange
    }

    func workspaceLayoutsChanged(previous: borrowing [WorkspaceConfiguration], defaultLayout: LayoutType) {
        guard let manager = controller?.workspaceManager else { return }
        for workspace in manager.workspaces {
            let override = previous.first { $0.name == workspace.name }?.layoutType ?? .defaultLayout
            let wasDwindle = (override == .defaultLayout ? defaultLayout : override) == .dwindle
            guard wasDwindle != (manager.activeLayoutKind(for: workspace.id) == .dwindle) else { continue }
            let dwindle = manager.dwindleEngine?.fullscreenTokens(in: workspace.id) ?? []
            let niri = Set(manager.niriEngine?.root(for: workspace.id)?.allWindows
                .compactMap { $0.isFullscreen ? $0.token : nil } ?? [])
            let oldTokens = wasDwindle ? dwindle : niri
            for token in dwindle.symmetricDifference(niri) where windowStates.priorFullscreen[token] == nil {
                if manager.withEntry(token, { $0.workspaceId == workspace.id && $0.mode == .tiling }) == true {
                    windowStates.priorFullscreen[token] = oldTokens.contains(token)
                }
            }
        }
        if !windowStates.priorFullscreen.isEmpty { manager.settleScriptWindowState(self) }
    }

    func discardFirstAdmissionChanges(_ token: WindowToken?) {
        guard let token else { return }
        windowStates.priorModes.removeValue(forKey: token)
        windowStates.priorFullscreen.removeValue(forKey: token)
    }

    func noteModeChange(_ token: WindowToken, was previous: TrackedWindowMode) {
        guard let manager = controller?.workspaceManager else { return }
        let tracksMode = kinds.contains(.windowUpdateState)
        if tracksMode, windowStates.priorModes[token] == nil { windowStates.priorModes[token] = previous }
        if kinds.contains(.windowFullscreen), windowStates.priorFullscreen[token] == nil,
           let workspace = manager.workspace(for: token),
           managedFullscreen(token, workspaceId: workspace, manager: manager)
        {
            windowStates.priorFullscreen[token] = previous == .tiling
        } else if !tracksMode {
            return
        }
        manager.settleScriptWindowState(self)
    }

    func niriFullscreenChange(_ token: WindowToken, _ previous: Bool) {
        noteManagedFullscreenChange(token, was: previous, layout: .niri)
    }

    func dwindleFullscreenChange(_ token: WindowToken, _ previous: Bool) {
        noteManagedFullscreenChange(token, was: previous, layout: .dwindle)
    }

    private func noteManagedFullscreenChange(_ token: WindowToken, was previous: Bool, layout: ActiveLayoutKind) {
        guard windowStates.priorFullscreen[token] == nil,
              let manager = controller?.workspaceManager, let workspace = manager.workspace(for: token),
              manager.activeLayoutKind(for: workspace) == layout else { return }
        windowStates.priorFullscreen[token] = manager.withEntry(token) { $0.mode == .tiling } == true && previous
        manager.settleScriptWindowState(self)
    }

    func publishSettledWindowStates() {
        guard let manager = controller?.workspaceManager else { return }
        var modes: [WindowToken: TrackedWindowMode] = [:]
        var fullscreen: [WindowToken: Bool] = [:]
        swap(&modes, &windowStates.priorModes)
        swap(&fullscreen, &windowStates.priorFullscreen)
        if kinds.contains(.windowUpdateState) {
            for (token, previous) in modes {
                guard let mode = manager.withEntry(token, { $0.mode }), mode != previous else { continue }
                windowStateChanged(.windowUpdateState, token: token, value: .floating(mode == .floating))
            }
        }
        for (token, previous) in fullscreen {
            guard let (workspace, mode, native) = manager.withEntry(token, {
                ($0.workspaceId, $0.mode, $0.observedState.isNativeFullscreen)
            }), !native else { continue }
            let current = mode == .tiling && managedFullscreen(token, workspaceId: workspace, manager: manager)
            if current != previous { windowStateChanged(.windowFullscreen, token: token, value: .fullscreen(current)) }
        }
        if windowStates.priorModes.isEmpty {
            modes.removeAll(keepingCapacity: true)
            swap(&modes, &windowStates.priorModes)
        }
        if windowStates.priorFullscreen.isEmpty {
            fullscreen.removeAll(keepingCapacity: true)
            swap(&fullscreen, &windowStates.priorFullscreen)
        }
    }
}
