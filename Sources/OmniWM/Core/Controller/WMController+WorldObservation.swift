// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func handleSessionStateChanged(surfaceScope: SessionSurfaceInvalidationScope) {
        if let source = columnModeToast.source,
           workspaceManager.visibleWorkspaceId(on: source.monitorId) != source.workspaceId
        {
            columnModeToast.hide()
        }
        switch surfaceScope {
        case .full:
            surfaceReconciler.noteWorldChanged()
            windowSwitcherControllerStorage?.refreshWindows()
        case .border:
            surfaceReconciler.noteBorderChanged()
        }
        let changeSet = focusNotificationDispatcher.notifyFocusChangesIfNeeded()
        if statusBarRefreshIsEnabled {
            refreshStatusBar()
        }
        if let ipcApplicationBridge {
            Task {
                if changeSet.focusChanged {
                    await ipcApplicationBridge.publishEvent(.focus)
                }
                if changeSet.workspaceChanged || changeSet.monitorChanged {
                    await ipcApplicationBridge.publishEvent(.activeWorkspace)
                }
                if changeSet.monitorChanged {
                    await ipcApplicationBridge.publishEvent(.focusedMonitor)
                    await ipcApplicationBridge.publishEvent(.displayChanged)
                }
            }
        }
    }

    func cancelPendingFrameJobsForInvalidation(workspaceId: WorkspaceDescriptor.ID?) {
        let entries = workspaceId.map { workspaceManager.entries(in: $0) } ?? workspaceManager.allEntries()
        guard !entries.isEmpty else { return }
        axManager.cancelPendingFrameJobs(entries.map { ($0.pid, $0.windowId) }, reason: "invalidation")
    }
}
