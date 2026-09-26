// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class IPCQueryRouter {
    let controller: WMController
    private let appVersion: String?
    private let sessionToken: String
    var windowOrderedInProvider: (UInt32) -> Bool? = { SkyLight.shared.isWindowOrderedIn($0) }

    init(
        controller: WMController,
        appVersion: String? = Bundle.main.appVersion,
        sessionToken: String
    ) {
        self.controller = controller
        self.appVersion = appVersion
        self.sessionToken = sessionToken
    }

    func pingResult() -> IPCPingResult {
        IPCPingResult()
    }

    func versionResult(executableSHA256: String?) -> IPCVersionResult {
        IPCVersionResult(
            protocolVersion: OmniWMIPCProtocol.version,
            appVersion: appVersion,
            gitHash: OmniWMBuildInfo.gitHash,
            buildConfiguration: OmniWMBuildInfo.configuration,
            executableSHA256: executableSHA256
        )
    }

    func workspaceBarResult() -> IPCWorkspaceBarQueryResult {
        let monitors = controller.workspaceManager.monitors.map { monitor in
            let resolved = controller.settings.workspaceBar.resolved(for: monitor)
            let isVisible = controller.isWorkspaceBarVisible(on: monitor, resolved: resolved)
            let geometry = WorkspaceBarGeometry.resolve(
                monitor: monitor,
                resolved: resolved,
                isVisible: isVisible
            )
            let projection = controller.workspaceBarProjection(
                for: monitor,
                projection: resolved.projectionOptions
            )

            return IPCWorkspaceBarMonitor(
                id: IPCDisplayRef.identifier(monitor.id),
                name: monitor.name,
                enabled: resolved.enabled,
                isVisible: isVisible,
                showLabels: resolved.showLabels,
                backgroundOpacity: resolved.backgroundOpacity,
                barHeight: Double(geometry.barHeight),
                scratchpads: projection.scratchpads.map(workspaceBarScratchpad(from:)),
                workspaces: projection.items.map(workspaceBarWorkspace(from:))
            )
        }

        return IPCWorkspaceBarQueryResult(
            interactionMonitorId: controller.workspaceManager.interactionMonitorId.map(IPCDisplayRef.identifier),
            monitors: monitors
        )
    }

    func activeWorkspaceResult() -> IPCActiveWorkspaceQueryResult {
        let (monitor, workspace) = controller.interactionWorkspaceProjection()
        let focusedApp: IPCAppRef?

        if let workspace,
           let focusedToken = controller.workspaceManager.nativeManagedFocusToken,
           let entry = controller.workspaceManager.entry(for: focusedToken),
           entry.workspaceId == workspace.id
        {
            focusedApp = IPCAppRef(appInfo: controller.appInfoCache.info(for: entry.pid))
        } else {
            focusedApp = nil
        }

        return IPCActiveWorkspaceQueryResult(
            display: monitor.map(IPCDisplayRef.init(monitor:)),
            workspace: workspace.map { IPCWorkspaceRef(descriptor: $0, settings: controller.settings) },
            focusedApp: focusedApp
        )
    }

    func focusedMonitorResult() -> IPCFocusedMonitorQueryResult {
        let (monitor, activeWorkspace) = controller.interactionWorkspaceProjection()

        return IPCFocusedMonitorQueryResult(
            display: monitor.map(IPCDisplayRef.init(monitor:)),
            activeWorkspace: activeWorkspace.map { IPCWorkspaceRef(descriptor: $0, settings: controller.settings) }
        )
    }

    func appsResult() -> IPCAppsQueryResult {
        IPCAppsQueryResult(
            apps: controller.runningAppsWithWindows().map { app in
                IPCManagedAppSummary(
                    bundleId: app.bundleId ?? "",
                    appName: app.appName,
                    windowSize: IPCSize(
                        width: app.windowSize.width,
                        height: app.windowSize.height
                    )
                )
            }
        )
    }

    func metricsResult() -> IPCMetricsQueryResult {
        IPCMetricsQueryResult(
            axWrites: AXWriteMetrics.shared.snapshot(),
            displayTicks: controller.layoutRefreshController.displayTickMetricsSnapshot(),
            layoutBuilds: controller.layoutRefreshController.layoutBuildMetricsCounts(),
            process: ProcessResourceSnapshot.capture(),
            traceCaptureActive: FrameEffectTraceContext.isActive
        )
    }

    func focusedWindowResult() -> IPCFocusedWindowQueryResult {
        guard let focusedToken = controller.workspaceManager.nativeManagedFocusToken,
              let entry = controller.workspaceManager.entry(for: focusedToken)
        else {
            return IPCFocusedWindowQueryResult(window: nil)
        }

        let workspaceDescriptor = controller.workspaceManager.descriptor(for: entry.workspaceId)
        let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let appInfo = controller.appInfoCache.info(for: entry.pid)
        let frame = AXWindowService.framePreferFast(entry.axRef)
        let snapshot = IPCFocusedWindowSnapshot(
            id: IPCWindowOpaqueID.encode(token: focusedToken, sessionToken: sessionToken),
            pid: entry.pid,
            workspace: workspaceDescriptor.map { IPCWorkspaceRef(descriptor: $0, settings: controller.settings) },
            display: monitor.map(IPCDisplayRef.init(monitor:)),
            app: IPCAppRef(appInfo: appInfo),
            title: AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
            frame: frame.map(IPCRect.init)
        )

        return IPCFocusedWindowQueryResult(window: snapshot)
    }

    func windowsResult(_ request: IPCQueryRequest) -> IPCWindowsQueryResult {
        IPCWindowQueryProjection(
            controller: controller,
            sessionToken: sessionToken,
            request: request,
            windowOrderedInProvider: windowOrderedInProvider
        ).result()
    }

    func workspacesResult(_ request: IPCQueryRequest) -> IPCWorkspacesQueryResult {
        IPCWorkspaceQueryProjection(
            controller: controller,
            sessionToken: sessionToken,
            request: request
        ).result()
    }

    func displaysResult(_ request: IPCQueryRequest) -> IPCDisplaysQueryResult {
        let fieldSet = IPCQuerySelection.requestedFieldSet(from: request)
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        let displays = Monitor.sortedByPosition(controller.workspaceManager.monitors)
            .filter { monitor in
                matchesDisplayQuery(monitor, selectors: request.selectors, currentMonitorId: currentMonitorId)
            }
            .map { monitor in
                displaySnapshot(from: monitor, currentMonitorId: currentMonitorId, fields: fieldSet)
            }

        return IPCDisplaysQueryResult(displays: displays)
    }

    func rulesResult() -> IPCRulesQueryResult {
        IPCRuleProjection.result(
            settings: controller.settings,
            windowRuleEngine: controller.windowRuleEngine
        )
    }

    func ruleActionsResult() -> IPCRuleActionsQueryResult {
        IPCRuleActionsQueryResult(ruleActions: IPCAutomationManifest.ruleActionDescriptors)
    }

    func queriesResult() -> IPCQueriesQueryResult {
        IPCQueriesQueryResult(queries: IPCAutomationManifest.queryDescriptors)
    }

    func commandsResult() -> IPCCommandsQueryResult {
        IPCCommandsQueryResult(
            commands: IPCAutomationManifest.commandDescriptors,
            workspaceActions: IPCAutomationManifest.workspaceActionDescriptors,
            windowActions: IPCAutomationManifest.windowActionDescriptors,
            windowMarkActions: IPCAutomationManifest.windowMarkActionDescriptors
        )
    }

    func subscriptionsResult() -> IPCSubscriptionsQueryResult {
        IPCSubscriptionsQueryResult(subscriptions: IPCAutomationManifest.subscriptionDescriptors)
    }

    func capabilitiesResult() -> IPCCapabilitiesQueryResult {
        IPCCapabilitiesQueryResult(
            protocolVersion: OmniWMIPCProtocol.version,
            appVersion: appVersion,
            authorizationRequired: true,
            windowIdScope: "session",
            queries: IPCAutomationManifest.queryDescriptors,
            commands: IPCAutomationManifest.commandDescriptors,
            captureActions: IPCAutomationManifest.captureActionDescriptors,
            ruleActions: IPCAutomationManifest.ruleActionDescriptors,
            workspaceActions: IPCAutomationManifest.workspaceActionDescriptors,
            windowActions: IPCAutomationManifest.windowActionDescriptors,
            windowMarkActions: IPCAutomationManifest.windowMarkActionDescriptors,
            subscriptions: IPCAutomationManifest.subscriptionDescriptors
        )
    }

    private func workspaceBarWorkspace(from item: WorkspaceBarItem) -> IPCWorkspaceBarWorkspace {
        IPCWorkspaceBarWorkspace(
            id: item.id.uuidString,
            rawName: item.rawName,
            displayName: item.name,
            number: workspaceNumber(from: item.rawName),
            isFocused: item.isFocused,
            windows: item.windows.map(workspaceBarApp(from:))
        )
    }

    private func workspaceBarApp(from item: WorkspaceBarWindowItem) -> IPCWorkspaceBarApp {
        IPCWorkspaceBarApp(
            id: IPCWindowOpaqueID.encode(token: item.id, sessionToken: sessionToken),
            appName: item.appName,
            bundleId: item.bundleId,
            isFocused: item.isFocused,
            windowCount: item.windowCount,
            allWindows: item.allWindows.map { window in
                IPCWorkspaceBarWindow(
                    id: IPCWindowOpaqueID.encode(token: window.id, sessionToken: sessionToken),
                    title: window.title,
                    isFocused: window.isFocused
                )
            }
        )
    }

    private func workspaceBarScratchpad(from item: WorkspaceBarScratchpadItem) -> IPCWorkspaceBarScratchpad {
        IPCWorkspaceBarScratchpad(
            index: item.index,
            label: item.label,
            windows: item.windows.map(workspaceBarApp(from:)),
            isVisible: item.isVisible
        )
    }

    private func displaySnapshot(
        from monitor: Monitor,
        currentMonitorId: Monitor.ID?,
        fields: Set<String>?
    ) -> IPCDisplayQuerySnapshot {
        let activeWorkspace = controller.workspaceManager.activeWorkspace(on: monitor.id)
        let gaps = controller.settings.gaps.resolved(for: monitor)
        return IPCDisplayQuerySnapshot(
            id: IPCQuerySelection.include("id", in: fields) ? IPCDisplayRef.identifier(monitor.id) : nil,
            name: IPCQuerySelection.include("name", in: fields) ? monitor.name : nil,
            isMain: IPCQuerySelection.include("is-main", in: fields) ? monitor.isMain : nil,
            isCurrent: IPCQuerySelection.include("is-current", in: fields) ? (currentMonitorId == monitor.id) : nil,
            frame: IPCQuerySelection.include("frame", in: fields) ? IPCRect(monitor.frame) : nil,
            visibleFrame: IPCQuerySelection.include("visible-frame", in: fields) ? IPCRect(monitor.visibleFrame) : nil,
            hasNotch: IPCQuerySelection.include("has-notch", in: fields) ? monitor.hasNotch : nil,
            orientation: IPCQuerySelection.include("orientation", in: fields)
                ? ipcDisplayOrientation(from: controller.settings.monitors.effectiveOrientation(for: monitor)) : nil,
            innerGap: IPCQuerySelection.include("inner-gap", in: fields) ? Double(gaps.innerGap) : nil,
            outerGapLeft: IPCQuerySelection.include("outer-gap-left", in: fields) ? Double(gaps.outerGapLeft) : nil,
            outerGapRight: IPCQuerySelection.include("outer-gap-right", in: fields) ? Double(gaps.outerGapRight) : nil,
            outerGapTop: IPCQuerySelection.include("outer-gap-top", in: fields) ? Double(gaps.outerGapTop) : nil,
            outerGapBottom: IPCQuerySelection
                .include("outer-gap-bottom", in: fields) ? Double(gaps.outerGapBottom) : nil,
            fullscreenUsesOuterGaps: IPCQuerySelection.include("fullscreen-uses-outer-gaps", in: fields)
                ? gaps.fullscreenUsesOuterGaps : nil,
            activeWorkspace: IPCQuerySelection.include("active-workspace", in: fields) ? activeWorkspace
                .map { IPCWorkspaceRef(
                    descriptor: $0,
                    settings: controller.settings
                ) } : nil
        )
    }

    private func matchesDisplayQuery(
        _ monitor: Monitor,
        selectors: IPCQuerySelectors,
        currentMonitorId: Monitor.ID?
    ) -> Bool {
        if let displaySelector = selectors.display,
           !IPCQuerySelection.matchesDisplaySelector(monitor: monitor, candidate: displaySelector)
        {
            return false
        }

        if selectors.main == true, !monitor.isMain {
            return false
        }

        if selectors.current == true, monitor.id != currentMonitorId {
            return false
        }

        return true
    }

    private func workspaceNumber(from rawName: String) -> Int? {
        WorkspaceIDPolicy.workspaceNumber(from: rawName)
    }

    private func appRef(name: String?, bundleId: String?) -> IPCAppRef? {
        guard let name else { return nil }
        return IPCAppRef(name: name, bundleId: bundleId)
    }

    private func ipcDisplayOrientation(from orientation: Monitor.Orientation) -> IPCDisplayOrientation {
        switch orientation {
        case .horizontal:
            .horizontal
        case .vertical:
            .vertical
        }
    }
}
