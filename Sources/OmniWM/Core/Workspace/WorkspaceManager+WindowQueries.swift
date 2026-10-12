// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func entries(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        windowQueries.windows(in: workspace)
    }

    func windowCount(in workspace: WorkspaceDescriptor.ID) -> Int {
        windowQueries.windowCount(in: workspace)
    }

    func tiledEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        windowQueries.windows(in: workspace, mode: .tiling)
    }

    func barVisibleEntries(
        in workspace: WorkspaceDescriptor.ID,
        showFloatingWindows: Bool = false
    ) -> [WindowState] {
        var entries = tiledEntries(in: workspace)
        if showFloatingWindows {
            entries.append(contentsOf: barVisibleFloatingEntries(in: workspace))
        }
        return entries
    }

    func floatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        windowQueries.windows(in: workspace, mode: .floating)
    }

    func isFloatingWindowDisplayable(_ entry: borrowing WindowState) -> Bool {
        guard entry.mode == .floating,
              entry.layoutReason == .standard,
              !isWindowSuppressedByMacOS(entry)
        else { return false }
        return !isHiddenInCorner(entry.token)
    }

    private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        floatingEntries(in: workspace).filter {
            !isScratchpadToken($0.token) && hiddenState(for: $0.token)?.isScratchpad != true
        }
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        windowQueries.handle(for: token)
    }

    func entry(for token: WindowToken) -> WindowState? {
        windowQueries.entry(for: token)
    }

    func entry(for handle: WindowHandle) -> WindowState? {
        windowQueries.entry(for: handle)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowState? {
        windowQueries.entry(forPid: pid, windowId: windowId)
    }

    func entries(forPid pid: pid_t) -> [WindowState] {
        windowQueries.entries(forPid: pid)
    }

    func hasEntries(forPid pid: pid_t) -> Bool {
        windowQueries.hasEntries(forPid: pid)
    }

    func entry(forWindowId windowId: Int) -> WindowState? {
        windowQueries.entry(forWindowId: windowId)
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces: Bool) -> WindowState? {
        guard inVisibleWorkspaces else {
            return windowQueries.entry(forWindowId: windowId)
        }
        return windowQueries.entry(forWindowId: windowId, inVisibleWorkspaces: visibleWorkspaceIds())
    }

    func allEntries() -> [WindowState] {
        windowQueries.allEntries()
    }

    func allFloatingEntries() -> [WindowState] {
        windowQueries.allEntries(mode: .floating)
    }

    func windowMode(for token: WindowToken) -> TrackedWindowMode? {
        windowQueries.mode(for: token)
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        windowQueries.lifecyclePhase(for: token)
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        windowQueries.observedState(for: token)
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        windowQueries.desiredState(for: token)
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        windowQueries.restoreIntent(for: token)
    }

    func admissionHints(for token: WindowToken) -> ManagedWindowAdmissionHints? {
        windowQueries.admissionHints(for: token)
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        windowQueries.cachedConstraints(for: token, maxAge: maxAge)
    }

    func observedSizeEvidence(for token: WindowToken) -> ObservedSizeEvidence? {
        windowQueries.observedSizeEvidence(for: token)
    }
}
