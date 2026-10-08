// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    var workspaceBarRefreshIsEnabled: Bool {
        settings.workspaceBar.enabled
    }

    var statusBarRefreshIsEnabled: Bool {
        statusBarController != nil && settings.statusBar.showWorkspaceName
    }

    var hasWindowOrLayoutEventSubscribers: Bool {
        ipcApplicationBridge?.hasSubscribers(for: .windowsChanged) == true
            || ipcApplicationBridge?.hasSubscribers(for: .layoutChanged) == true
    }

    var hasWorkspaceBarDataConsumers: Bool {
        workspaceBarRefreshIsEnabled
            || statusBarRefreshIsEnabled
            || ipcApplicationBridge?.hasSubscribers(for: .workspaceBar) == true
            || hasWindowOrLayoutEventSubscribers
    }

    func setWorkspaceBarEnabled(_ enabled: Bool) {
        if settings.workspaceBar.enabled != enabled {
            settings.workspaceBar.enabled = enabled
        }
        pruneHiddenWorkspaceBarMonitorIds()
        workspaceBarManager.setup(controller: self, settings: settings)
        if !enabled {
            workspaceBarManager.cleanup()
        }
        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
        syncWorkspaceBarRevealMonitor()
        hiddenBarController.dismissPanel()
        updateHiddenBarSettings()
    }

    func requestWorkspaceBarRefresh() {
        surfaceReconciler.noteWorldChanged()
    }

    func updateWorkspaceBarNotificationBadgeSettings() {
        workspaceBarManager.syncNotificationBadges()
    }

    func refreshStatusBar() {
        statusBarController?.refreshWorkspaces()
    }

    func activeStatusBarWorkspaceSummary() -> StatusBarWorkspaceSummary? {
        guard let monitor = monitorForInteraction(),
              let workspace = workspaceManager.activeWorkspace(on: monitor.id)
        else {
            return nil
        }

        let focusedAppName: String? = if let focusedToken = workspaceManager.selectedManagedToken,
                                         let entry = workspaceManager.entry(for: focusedToken),
                                         entry.workspaceId == workspace.id
        {
            resolvedAppInfo(for: entry.pid)?.name
        } else {
            nil
        }

        return StatusBarWorkspaceSummary(
            monitorId: monitor.id,
            workspaceLabel: settings.workspaces.displayName(for: workspace.name),
            workspaceRawName: workspace.name,
            focusedAppName: focusedAppName
        )
    }

    func updateWorkspaceBarSettings(forceIconReload: Bool = false) {
        updateWorkspaceBarNotificationBadgeSettings()
        workspaceBarManager.syncHoverPreview(controller: self, settings: settings)
        synchronizeWorkspaceBarIconOverrides(
            forceReload: forceIconReload
        )
        pruneHiddenWorkspaceBarMonitorIds()
        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
        windowActionHandlerStorage?.refreshOverviewProjection(affectedWorkspaceIds: [])
        syncWorkspaceBarRevealMonitor()
        hiddenBarController.dismissPanel()
    }

    func updateWorkspaceBarIconOverride(bundleId: String, forceReload: Bool) {
        guard synchronizeWorkspaceBarIconOverrides(
            forceReloadBundleId: forceReload ? bundleId : nil
        ) else {
            return
        }
        surfaceReconciler.noteWorldChanged()
    }

    func refreshUnavailableWorkspaceBarIconOverride(bundleId: String?) {
        guard let bundleId,
              let resolution = workspaceBarIconResolver.overrideResolution(for: bundleId),
              resolution.image == nil,
              case .bundleResource = resolution.source
        else {
            return
        }

        guard synchronizeWorkspaceBarIconOverrides(
            forceReloadBundleId: bundleId
        ) else {
            return
        }
        surfaceReconciler.noteWorldChanged()
    }

    func updateWorkspaceBarAppearance() {
        workspaceBarManager.updateAppearance()
    }

    func workspaceBarProjection(
        for monitor: Monitor,
        projection options: WorkspaceBarProjectionOptions
    ) -> WorkspaceBarProjection {
        WorkspaceBarDataSource(
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            iconResolver: workspaceBarIconResolver,
            settings: settings
        ).workspaceBarProjection(
            for: monitor,
            options: options,
            focusedToken: workspaceManager.selectedManagedToken
        )
    }

    func focusWorkspaceFromBar(id workspaceId: WorkspaceDescriptor.ID) {
        windowActionHandler.focusWorkspaceFromBar(id: workspaceId, focusOrigin: .pointerSelection)
    }

    func focusWindowFromBar(handle: WindowHandle) {
        windowActionHandler.focusWindowFromBar(handle: handle, focusOrigin: .pointerSelection)
    }

    @discardableResult
    func activateScratchpadFromBar(index: ScratchpadIndex, on monitorId: Monitor.ID?) -> ExternalCommandResult {
        if workspaceManager.revealedScratchpadIndex() != index {
            let hiddenAppHandles = workspaceManager.scratchpadMembers(in: index).compactMap { token in
                workspaceManager.entry(for: token).flatMap {
                    workspaceManager.isAppHidden(pid: $0.pid) ? workspaceManager.handle(for: token) : nil
                }
            }
            if let handle = hiddenAppHandles.first,
               windowActionHandler.revealScratchpadFromBar(
                   handle: handle,
                   index: index,
                   monitorId: monitorId
               )
            {
                return .executed
            }
        }

        if let monitorId {
            _ = workspaceManager.setInteractionMonitor(monitorId)
        }
        return toggleScratchpad(index, on: monitorId, focusOrigin: .pointerSelection)
    }

    func publishWorkspaceDataChanges(from previous: DesiredSurfaceScene, to desired: DesiredSurfaceScene) {
        if desired.bars != previous.bars, statusBarRefreshIsEnabled {
            refreshStatusBar()
        }
        let channels = Self.workspaceDataChannels(from: previous, to: desired)
        guard !channels.isEmpty, let ipcApplicationBridge else { return }
        Task {
            for channel in channels {
                await ipcApplicationBridge.publishEvent(channel)
            }
        }
    }

    static func workspaceDataChannels(
        from previous: DesiredSurfaceScene,
        to desired: DesiredSurfaceScene
    ) -> [IPCSubscriptionChannel] {
        if desired.bars != previous.bars {
            return [.workspaceBar, .windowsChanged, .layoutChanged]
        }
        guard desired.niriColumns != previous.niriColumns else { return [] }
        var channels: [IPCSubscriptionChannel] = []
        if desired.niriColumns.mapValues(\.columnIndexByToken) != previous.niriColumns.mapValues(\.columnIndexByToken) {
            channels.append(.windowsChanged)
        }
        if desired.niriColumns.mapValues(\.viewport) != previous.niriColumns.mapValues(\.viewport) {
            channels.append(.layoutChanged)
        }
        return channels
    }

    func isWorkspaceBarEnabled(on monitor: Monitor, resolved: ResolvedBarSettings) -> Bool {
        resolved.enabled && !hiddenWorkspaceBarMonitorIds.contains(monitor.id)
    }

    func isWorkspaceBarConfiguredVisible(on monitor: Monitor, resolved: ResolvedBarSettings) -> Bool {
        guard isWorkspaceBarEnabled(on: monitor, resolved: resolved) else { return false }
        return (!resolved.autoHide && settings.workspaceBar.revealModifier == .off)
            || isWorkspaceBarRevealHeld || (resolved.autoHide && workspaceBarManager.isPointerRevealed(on: monitor.id))
    }

    func isWorkspaceBarVisible(on monitor: Monitor, resolved: ResolvedBarSettings? = nil) -> Bool {
        let effective = resolved ?? settings.workspaceBar.resolved(for: monitor)
        guard isWorkspaceBarConfiguredVisible(on: monitor, resolved: effective) else { return false }
        return !isWorkspaceBarSuppressedByNativeFullscreen(on: monitor, resolved: effective)
    }

    func canAutoHideWorkspaceBar(on monitor: Monitor, resolved: ResolvedBarSettings) -> Bool {
        resolved.autoHide && isWorkspaceBarEnabled(on: monitor, resolved: resolved)
            && !isWorkspaceBarSuppressedByNativeFullscreen(on: monitor, resolved: resolved)
    }

    private func isWorkspaceBarSuppressedByNativeFullscreen(
        on monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> Bool {
        guard settings.workspaceBar.hideInNativeFullscreen || resolved.notchMode == .fillLeftOfNotch else {
            return false
        }
        let topology = workspaceManager.spaceTopology
        guard topology.isPopulated else { return false }
        return topology.isDisplayShowingFullscreenSpace(on: monitor) == true
    }
}
