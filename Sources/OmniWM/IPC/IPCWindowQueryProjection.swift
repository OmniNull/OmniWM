// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct IPCWindowQueryProjection {
    private let controller: WMController
    private let sessionToken: String
    private let selectors: IPCQuerySelectors
    private let fields: Set<String>?
    private let focusedToken: WindowToken?
    private let visibleWorkspaceIds: Set<WorkspaceDescriptor.ID>
    private let windowOrderedInProvider: (UInt32) -> Bool?

    init(
        controller: WMController,
        sessionToken: String,
        request: IPCQueryRequest,
        windowOrderedInProvider: @escaping (UInt32) -> Bool?
    ) {
        self.controller = controller
        self.sessionToken = sessionToken
        selectors = request.selectors
        fields = IPCQuerySelection.requestedFieldSet(from: request)
        focusedToken = controller.workspaceManager.nativeManagedFocusToken
        visibleWorkspaceIds = controller.workspaceManager.visibleWorkspaceIds()
        self.windowOrderedInProvider = windowOrderedInProvider
    }

    func result() -> IPCWindowsQueryResult {
        let includesColumnIndex = IPCQuerySelection.include("column-index", in: fields)
        let windows = IPCQuerySelection.orderedWorkspaces(controller: controller).flatMap { workspace in
            let topology = controller.workspaceManager.layoutTopology(for: workspace.id)
            let columnIndexByToken = includesColumnIndex
                ? controller.niriLayoutHandler.columnSummary(for: workspace.id)?.columnIndexByToken
                : nil
            return WorkspaceEntryOrdering.orderedEntries(
                controller.workspaceManager.entries(in: workspace.id),
                topology: topology
            )
            .filter { entry in
                matchesWindowQuery(entry)
            }
            .map { entry in
                windowSnapshot(
                    from: entry,
                    isFullscreen: topology.isFullscreen(entry.token),
                    columnIndex: columnIndexByToken?[entry.token]
                )
            }
        }

        return IPCWindowsQueryResult(windows: windows)
    }

    private func windowSnapshot(
        from entry: WindowState,
        isFullscreen: Bool,
        columnIndex: Int?
    ) -> IPCWindowQuerySnapshot {
        let workspaceDescriptor = controller.workspaceManager.descriptor(for: entry.workspaceId)
        let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let appInfo = controller.appInfoCache.info(for: entry.pid)
        let hiddenState = controller.workspaceManager.hiddenState(for: entry.token)
        let isAppHidden = controller.workspaceManager.isAppHidden(pid: entry.pid)
        let scratchpadIndex = controller.workspaceManager.scratchpadIndex(for: entry.token)
        let isVisible = isWindowVisible(entry, hiddenState: hiddenState, isAppHidden: isAppHidden)

        return IPCWindowQuerySnapshot(
            id: IPCQuerySelection.include("id", in: fields) ? IPCWindowOpaqueID.encode(
                token: entry.token,
                sessionToken: sessionToken
            ) : nil,
            pid: IPCQuerySelection.include("pid", in: fields) ? entry.pid : nil,
            windowId: IPCQuerySelection.include("window-id", in: fields) ? entry.windowId : nil,
            workspace: IPCQuerySelection.include("workspace", in: fields) ? workspaceDescriptor.map { IPCWorkspaceRef(
                descriptor: $0,
                settings: controller.settings
            ) } : nil,
            display: IPCQuerySelection.include("display", in: fields) ? monitor.map(IPCDisplayRef.init(monitor:)) : nil,
            app: IPCQuerySelection.include("app", in: fields) ? IPCAppRef(appInfo: appInfo) : nil,
            title: IPCQuerySelection.include("title", in: fields) ? AXWindowService
                .titlePreferFast(windowId: UInt32(entry.windowId)) : nil,
            frame: IPCQuerySelection.include("frame", in: fields) ? AXWindowService.framePreferFast(entry.axRef)
                .map(IPCRect.init) : nil,
            mode: IPCQuerySelection.include("mode", in: fields) ? IPCWindowMode(mode: entry.mode) : nil,
            layoutReason: IPCQuerySelection
                .include("layout-reason", in: fields) ? IPCLayoutReason(reason: entry.layoutReason) : nil,
            manualOverride: IPCQuerySelection.include("manual-override", in: fields)
                ? controller.workspaceManager.manualLayoutOverride(for: entry.token)
                .map(IPCManualWindowOverride.init(override:))
                : nil,
            isFocused: IPCQuerySelection.include("is-focused", in: fields) ? (entry.token == focusedToken) : nil,
            isFullscreen: IPCQuerySelection.include("is-fullscreen", in: fields) ? isFullscreen : nil,
            isVisible: IPCQuerySelection.include("is-visible", in: fields) ? isVisible : nil,
            isAppHidden: IPCQuerySelection.include("is-app-hidden", in: fields) ? isAppHidden : nil,
            isScratchpad: IPCQuerySelection.include("is-scratchpad", in: fields) ? scratchpadIndex != nil : nil,
            scratchpadIndex: IPCQuerySelection.include("scratchpad-index", in: fields) ? scratchpadIndex?
                .rawValue : nil,
            hiddenReason: IPCQuerySelection.include("hidden-reason", in: fields) ? hiddenState.map { hiddenState in
                IPCHiddenReason(
                    hiddenState: hiddenState,
                    isInactiveTabMember: hiddenState.offscreenSide != nil
                        && controller.workspaceManager.isInactiveTabMember(entry.token, in: entry.workspaceId)
                )
            } : nil,
            columnIndex: columnIndex
        )
    }

    private func matchesWindowQuery(_ entry: WindowState) -> Bool {
        if let windowSelector = selectors.window {
            switch IPCWindowOpaqueID.validate(windowSelector, expectingSessionToken: sessionToken) {
            case let .valid(pid, windowId):
                guard entry.pid == pid, entry.windowId == windowId else { return false }
            case .stale,
                 .invalid:
                return false
            }
        }

        if let workspaceSelector = selectors.workspace,
           !IPCQuerySelection.matchesWorkspaceSelector(
               workspaceId: entry.workspaceId,
               candidate: workspaceSelector,
               controller: controller
           )
        {
            return false
        }

        if let displaySelector = selectors.display,
           !IPCQuerySelection.matchesDisplaySelector(
               monitor: controller.workspaceManager.monitor(for: entry.workspaceId),
               candidate: displaySelector
           )
        {
            return false
        }

        if selectors.focused == true, entry.token != focusedToken {
            return false
        }

        if selectors.visible == true {
            let hiddenState = controller.workspaceManager.hiddenState(for: entry.token)
            let isAppHidden = controller.workspaceManager.isAppHidden(pid: entry.pid)
            if !isWindowVisible(
                entry,
                hiddenState: hiddenState,
                isAppHidden: isAppHidden
            ) {
                return false
            }
        }

        if selectors.floating == true, entry.mode != .floating {
            return false
        }

        if selectors.scratchpad == true, !controller.workspaceManager.isScratchpadToken(entry.token) {
            return false
        }

        return matchesApplication(for: entry)
    }

    private func matchesApplication(for entry: WindowState) -> Bool {
        if let appSelector = selectors.app {
            let appName = controller.appInfoCache.info(for: entry.pid)?.name
            guard appName?.localizedCaseInsensitiveCompare(appSelector) == .orderedSame else { return false }
        }

        if let bundleIdSelector = selectors.bundleId {
            let bundleId = controller.appInfoCache.info(for: entry.pid)?.bundleId
            guard bundleId?.localizedCaseInsensitiveCompare(bundleIdSelector) == .orderedSame else { return false }
        }

        return true
    }

    private func isWindowVisible(
        _ entry: WindowState,
        hiddenState: HiddenState?,
        isAppHidden: Bool
    ) -> Bool {
        guard visibleWorkspaceIds.contains(entry.workspaceId),
              hiddenState == nil,
              !isAppHidden,
              !entry.observedState.isNativeSuppressed
        else {
            return false
        }
        return windowOrderedInProvider(UInt32(entry.windowId)) ?? true
    }
}
