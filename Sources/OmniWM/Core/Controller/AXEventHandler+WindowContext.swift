// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum WindowServerIdentityResolution {
    case exact(token: WindowToken, info: WindowServerInfo)
    case mismatched
    case unavailable

    init(windowId: UInt32, info: WindowServerInfo?) {
        guard let info else {
            self = .unavailable
            return
        }
        guard info.id == windowId else {
            self = .mismatched
            return
        }
        self = .exact(token: WindowToken(pid: info.pid, windowId: Int(windowId)), info: info)
    }

    var token: WindowToken? {
        guard case let .exact(token, _) = self else { return nil }
        return token
    }
}

@MainActor
extension AXEventHandler {
    func setup() {
        CGSEventObserver.shared.start()
    }

    func requestTargetedFullRescan(for appPIDs: Set<pid_t>) {
        guard let controller, !appPIDs.isEmpty else { return }
        controller.layoutRefreshController.requestFullRescan(
            reason: .staleFullRescan,
            scope: .targeted(appPIDs: appPIDs, nativeSpaceIds: [])
        )
    }

    func isWorkspaceActive(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId)
        else {
            return false
        }
        return controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
    }

    static func effectivePlacementOrigin(
        _ placementOrigin: WorkspacePlacementOrigin,
        createPlacementContext: WindowCreatePlacementContext?
    ) -> WorkspacePlacementOrigin {
        createPlacementContext == nil ? placementOrigin : .liveCreate
    }

    func captureCreatePlacementContext(windowId: UInt32, spaceId: UInt64) {
        guard let controller else { return }
        guard pendingCreatePlacementContext(for: Int(windowId))?.nativeSpaceMonitorId == nil else { return }
        let nativeSpaceMonitorId = spaceId == 0
            ? nil
            : resolveNativeSpacePlacementMonitorId(spaceId: spaceId, controller: controller)
        _ = retainedCreatePlacementContext(
            windowId: windowId,
            controller: controller,
            nativeSpaceMonitorId: nativeSpaceMonitorId
        )
    }

    func retainedCreatePlacementContext(
        windowId: UInt32,
        controller: WMController,
        nativeSpaceMonitorId: Monitor.ID? = nil
    ) -> WindowCreatePlacementContext {
        if let context = pendingCreatePlacementContext(for: Int(windowId)) {
            guard context.nativeSpaceMonitorId == nil, let nativeSpaceMonitorId else {
                return context
            }
            let mergedContext = WindowCreatePlacementContext(
                nativeSpaceMonitorId: nativeSpaceMonitorId,
                pendingFocusedWorkspaceId: context.pendingFocusedWorkspaceId,
                pendingFocusedMonitorId: context.pendingFocusedMonitorId,
                focusedWorkspaceId: context.focusedWorkspaceId,
                focusedMonitorId: context.focusedMonitorId,
                interactionWorkspaceId: context.interactionWorkspaceId,
                interactionMonitorId: context.interactionMonitorId,
                createdAt: context.createdAt
            )
            createPlacementContextsByWindowId[windowId] = mergedContext
            return mergedContext
        }
        pruneExpiredCreatePlacementContexts()
        let context = liveCreatePlacementContext(
            controller: controller,
            nativeSpaceMonitorId: nativeSpaceMonitorId
        )
        createPlacementContextsByWindowId[windowId] = context
        return context
    }

    func liveCreatePlacementContext(
        controller: WMController,
        nativeSpaceMonitorId: Monitor.ID? = nil
    ) -> WindowCreatePlacementContext {
        let focusedWorkspaceId = resolveFocusedPlacementWorkspaceId(controller: controller)
        let interactionMonitorId = controller.workspaceManager.interactionMonitorId
        let interactionWorkspaceId = interactionMonitorId.flatMap {
            controller.workspaceManager.activeWorkspaceOrFirst(on: $0)?.id
        }
        return WindowCreatePlacementContext(
            nativeSpaceMonitorId: nativeSpaceMonitorId,
            pendingFocusedWorkspaceId: controller.workspaceManager.pendingFocusedWorkspaceId,
            pendingFocusedMonitorId: resolvePendingFocusedPlacementMonitorId(controller: controller),
            focusedWorkspaceId: focusedWorkspaceId,
            focusedMonitorId: focusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            },
            interactionWorkspaceId: interactionWorkspaceId,
            interactionMonitorId: interactionMonitorId,
            createdAt: Date()
        )
    }

    private func resolvePendingFocusedPlacementMonitorId(
        controller: WMController
    ) -> Monitor.ID? {
        controller.workspaceManager.pendingFocusedMonitorId
            ?? controller.workspaceManager.pendingFocusedWorkspaceId.flatMap {
                controller.workspaceManager.monitorId(for: $0)
            }
    }

    private func resolveFocusedPlacementWorkspaceId(
        controller: WMController
    ) -> WorkspaceDescriptor.ID? {
        guard let focusedToken = controller.workspaceManager.nativeManagedFocusToken,
              let workspaceId = controller.workspaceManager.workspace(for: focusedToken)
        else {
            return nil
        }
        return workspaceId
    }

    private func resolveNativeSpacePlacementMonitorId(
        spaceId: UInt64,
        controller: WMController
    ) -> Monitor.ID? {
        let monitors = controller.workspaceManager.monitors
        let displayId = SkyLight.shared.displayId(forSpaceId: spaceId, among: monitors)
        guard let displayId,
              let monitor = monitors.first(where: { $0.displayId == displayId })
        else {
            return nil
        }

        return monitor.id
    }

    func discardCreatePlacementContext(windowId: UInt32) {
        createPlacementContextsByWindowId.removeValue(forKey: windowId)
    }

    func resetCreatePlacementContextState() {
        createPlacementContextsByWindowId.removeAll()
    }

    func pruneExpiredCreatePlacementContexts(now: Date = Date()) {
        createPlacementContextsByWindowId = createPlacementContextsByWindowId.filter { _, context in
            now.timeIntervalSince(context.createdAt) < Self.createPlacementContextTTL
        }
    }

    func pendingCreatePlacementContext(
        for windowId: Int,
        now: Date = Date()
    ) -> WindowCreatePlacementContext? {
        guard let windowId = UInt32(exactly: windowId) else { return nil }
        guard let context = createPlacementContextsByWindowId[windowId] else { return nil }
        guard now.timeIntervalSince(context.createdAt) < Self.createPlacementContextTTL else {
            createPlacementContextsByWindowId.removeValue(forKey: windowId)
            return nil
        }
        return context
    }

    func discardCreatePlacementContext(for windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        discardCreatePlacementContext(windowId: windowId)
    }

    func recordCreatePlacementTrace(
        token: WindowToken,
        placement: WorkspacePlacementResolution,
        createPlacementContext: WindowCreatePlacementContext?,
        appKitFrame: CGRect?,
        controller: WMController
    ) {
        recordNiriCreateFocusTrace(
            .init(
                kind: .createPlacementResolved(
                    token: token,
                    workspaceId: placement.workspaceId,
                    rung: placement.rung,
                    pendingWorkspaceId: createPlacementContext?.pendingFocusedWorkspaceId,
                    pendingMonitorId: createPlacementContext?.pendingFocusedMonitorId,
                    focusedWorkspaceId: createPlacementContext?.focusedWorkspaceId,
                    focusedMonitorId: createPlacementContext?.focusedMonitorId,
                    nativeSpaceMonitorId: createPlacementContext?.nativeSpaceMonitorId,
                    frameMonitorId: controller.placementResolver.monitorForAppKitFrame(appKitFrame)?.id,
                    interactionWorkspaceId: createPlacementContext?.interactionWorkspaceId,
                    interactionMonitorId: createPlacementContext?.interactionMonitorId,
                    ruleSkipReason: placement.ruleSkipReason
                )
            )
        )
    }

    func resolveWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        windowInfoProvider(windowId)
    }

    func resolveWindowInfo(_ windowIds: Set<UInt32>) async throws -> [UInt32: WindowServerInfo] {
        guard !windowIds.isEmpty else { return [:] }
        return try await windowInfoBatchProvider(windowIds) ?? [:]
    }

    func resolveWindowServerIdentity(_ windowId: UInt32) -> WindowServerIdentityResolution {
        WindowServerIdentityResolution(windowId: windowId, info: resolveWindowInfo(windowId))
    }

    func resolveWindowToken(_ windowId: UInt32) -> WindowToken? {
        resolveWindowServerIdentity(windowId).token
    }

    func resolveTrackedToken(_ windowId: UInt32) -> WindowToken? {
        guard let controller,
              let token = resolveWindowToken(windowId)
        else { return nil }
        return controller.workspaceManager.entry(for: token)?.token
    }

    func resolveTrackedTokenForDestruction(
        _ windowId: UInt32,
        pidHint: pid_t?,
        identityResolution: WindowServerIdentityResolution
    ) -> WindowToken? {
        guard let controller else { return nil }
        if let hintedToken = pidHint.map({ WindowToken(pid: $0, windowId: Int(windowId)) }),
           controller.workspaceManager.entry(for: hintedToken) != nil
        {
            return hintedToken
        }
        switch identityResolution {
        case let .exact(token, _):
            return controller.workspaceManager.entry(for: token)?.token
        case .mismatched:
            return nil
        case .unavailable:
            return controller.workspaceManager.entry(forWindowId: Int(windowId))?.token
        }
    }

    func resolveAXWindowRef(windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        AXWindowService.axWindowRef(for: windowId, pid: pid)
    }

    func subscribeToWindows(_ windowIds: [UInt32]) -> Bool {
        windowSubscriptionProvider(windowIds)
    }

    func resolveBundleId(_ pid: pid_t) -> String? {
        guard let controller else { return nil }
        return controller.appInfoCache.bundleId(for: pid) ?? NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier
    }

    func isWindowDisplayable(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            return false
        }
        return controller.isManagedWindowDisplayable(entry.token)
    }
}
