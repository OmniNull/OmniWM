// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func handleSessionStateChanged(surfaceScope: SessionSurfaceInvalidationScope) {
        pruneEdgePictures()
        intentLedger.cancelConfirmedWorkerRaise(unlessFocused: workspaceManager.nativeManagedFocusToken)
        axEventHandler.recheckVisibilityAfterFocusLoss()
        if let source = columnModeToast.source,
           workspaceManager.visibleWorkspaceId(on: source.monitorId) != source.workspaceId
        {
            columnModeToast.hide()
        }
        switch surfaceScope {
        case .full:
            surfaceReconciler.noteWorldChanged()
            windowSwitcherControllerStorage?.refreshWindows()
        case .border,
             .layoutEdge:
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
        var windows: [(pid: pid_t, windowId: Int)] = []
        if let workspaceId {
            workspaceManager.windowQueries.forEachToken(in: workspaceId) { windows.append(($0.pid, $0.windowId)) }
        } else {
            workspaceManager.windowQueries.forEachToken { windows.append(($0.pid, $0.windowId)) }
        }
        guard !windows.isEmpty else { return }
        axManager.cancelPendingFrameJobs(windows, reason: "invalidation")
    }
}
