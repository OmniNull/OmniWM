// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    struct ManagementStopRestoration {
        let token: WindowToken
        let window: NSWindow
        let frame: CGRect?
    }

    func prepareManagementStop() -> [ManagementStopRestoration] {
        let manager = controller.workspaceManager
        return windows.compactMap { token, window in
            guard let entry = manager.entry(for: token), entry.target.hostedMetadata != nil,
                  entry.layoutReason != .nativeFullscreen,
                  manager.nativeFullscreenRecord(for: token) == nil,
                  !manager.spaceTopology.isWindowOnFullscreenSpace(entry.windowId),
                  !manager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
            else { return nil }
            let hidden = manager.hiddenState(for: token)
            let frame = window.frame
            if hidden == nil, StopWindowGeometry.isOnscreen(frame, monitors: manager.monitors) {
                return ManagementStopRestoration(token: token, window: window, frame: frame)
            }
            let monitor = manager.monitor(for: entry.workspaceId)
                ?? (hidden?.referenceMonitorId ?? entry.floatingState?.referenceMonitorId)
                .flatMap { manager.monitor(byId: $0) }
                ?? manager.monitors.first(where: \.isMain) ?? manager.monitors.first
            let placement = StopWindowGeometry.placement(
                floating: entry.mode == .floating ? entry.floatingState : nil,
                hidden: hidden, monitor: monitor
            )
            return ManagementStopRestoration(
                token: token, window: window,
                frame: StopWindowGeometry.destination(for: frame, in: monitor?.visibleFrame, placement: placement)
            )
        }
    }

    func restoreForManagementStop(_ restorations: [ManagementStopRestoration]) {
        liveResizeStarts.removeAll()
        let manager = controller.workspaceManager
        for restoration in restorations {
            let token = restoration.token
            guard windows[token] === restoration.window, manager.entry(for: token)?.target.hostedMetadata != nil
            else { continue }
            guard let frame = restoration.frame, setFrame(frame, for: token) else {
                Log.shell.error("Hosted stop restoration has no connected monitor: window=\(token.windowId)")
                continue
            }
            let window = restoration.window
            manager.observeHostedWindowGeometry(frame: window.frame, for: token)
            manager.setWindowMinimized(window.isMiniaturized, token: token, source: .service)
            manager.setHiddenState(nil, for: token)
            if window.isMiniaturized {
                setContentVisible(false, token: token)
            } else {
                setHidden(false, for: token)
            }
        }
    }

    func reconcileManagementResume() {
        guard controller.hasStartedServices else { return }
        let manager = controller.workspaceManager
        for (token, window) in windows {
            guard let entry = manager.entry(for: token), entry.target.hostedMetadata != nil else { continue }
            if entry.target.hostedMetadata?.role == .main {
                manager.setWindowMinimized(window.isMiniaturized, token: token, source: .service)
            }
            if manager.hiddenState(for: token) == nil {
                manager.observeHostedWindowGeometry(frame: window.frame, for: token)
                if entry.mode == .floating, entry.target.hostedMetadata?.role == .main, !window.isMiniaturized {
                    controller.axEventHandler.updateFloatingWindowGeometryAndMonitorMembership(
                        entry: entry, frame: window.frame
                    )
                }
            }
            resizeContent(of: token, window: window)
            slot(for: token)?.surface.updateDisplayContext(scale: window.backingScaleFactor)
            setContentVisible(window.isVisible && !window.isMiniaturized, token: token)
        }
    }
}
