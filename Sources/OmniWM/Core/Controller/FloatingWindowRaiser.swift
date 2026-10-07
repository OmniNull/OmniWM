// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class FloatingWindowRaiser {
    private weak var controller: WMController?
    private let visibleOwnedWindowsProvider: () -> [NSWindow]
    private let frontOwnedWindow: (NSWindow) -> Void

    init(
        controller: WMController,
        visibleOwnedWindowsProvider: @escaping () -> [NSWindow],
        frontOwnedWindow: @escaping (NSWindow) -> Void
    ) {
        self.controller = controller
        self.visibleOwnedWindowsProvider = visibleOwnedWindowsProvider
        self.frontOwnedWindow = frontOwnedWindow
    }

    private enum RaisableSurfaceBatchKey: Hashable {
        case application(pid_t)
        case ownedApplication
    }

    @MainActor
    private enum RaisableSurface {
        case managed(WindowState)
        case owned(NSWindow)

        var windowId: Int {
            switch self {
            case let .managed(entry):
                entry.windowId
            case let .owned(window):
                window.windowNumber
            }
        }

        var sortPid: pid_t {
            switch self {
            case let .managed(entry):
                entry.pid
            case .owned:
                getpid()
            }
        }

        var batchKey: RaisableSurfaceBatchKey {
            switch self {
            case let .managed(entry):
                .application(entry.pid)
            case .owned:
                .ownedApplication
            }
        }
    }

    private struct FloatingWindowRaisePlan {
        let batches: [[RaisableSurface]]
    }

    func raiseAllFloatingWindows() {
        guard let controller, canRaiseWindows(controller) else { return }

        controller.restoreVisibleWorkspaceInactiveFloatingWindows()
        guard let plan = makeRaiseAllFloatingPlan() else { return }
        raise(plan, controller: controller)
    }

    private func raise(_ plan: FloatingWindowRaisePlan, controller: WMController) {
        for batch in plan.batches {
            for surface in batch {
                controller.performWindowOrdering(windowId: surface.windowId)
            }
            guard let anchor = batch.last else { continue }
            front(surface: anchor)
        }
    }

    func toggleFloatingFocus() -> ExternalCommandResult {
        guard let controller, canRaiseWindows(controller),
              let workspaceId = controller.activeWorkspace()?.id
        else { return .noChange }
        let workspaceManager = controller.workspaceManager

        if workspaceManager.isFloatingFocusToggleSource(controller.focusedManagedTokenForCommand(), in: workspaceId) {
            guard let target = workspaceManager.preferredFocusToken(in: workspaceId) else { return .noChange }
            return controller.windowActionHandler.navigateToWindowInternal(token: target, workspaceId: workspaceId)
                ? .executed
                : .noChange
        }

        controller.layoutRefreshController.restoreWorkspaceInactiveFloatingWindows(activeWorkspaceIds: [workspaceId])
        guard let target = workspaceManager.floatingFocusToggleTarget(in: workspaceId) else { return .noChange }
        if let plan = makeRaiseAllFloatingPlan(in: workspaceId) {
            raise(plan, controller: controller)
        }
        controller.focusWindow(target)
        return .executed
    }

    func hasRaisableFloatingWindows() -> Bool {
        makeRaiseAllFloatingPlan() != nil || controller?.hasVisibleWorkspaceInactiveFloatingWindows() == true
    }

    private func canRaiseWindows(_ controller: WMController) -> Bool {
        guard !controller.isLockScreenActive else { return false }
        if controller.hasStartedServices {
            return !controller.isFrontmostAppLockScreen()
        }
        return true
    }

    private func makeRaiseAllFloatingPlan(in workspaceId: WorkspaceDescriptor.ID? = nil) -> FloatingWindowRaisePlan? {
        guard let controller else { return nil }

        let workspaceIds = workspaceId.map { [$0] } ?? Array(controller.workspaceManager.visibleWorkspaceIds())
        let managedSurfaces = workspaceIds
            .flatMap { controller.workspaceManager.floatingEntries(in: $0) }
            .filter { controller.workspaceManager.isFloatingWindowDisplayable($0) }
            .map(RaisableSurface.managed)
        let ownedSurfaces = workspaceId != nil ? [] : visibleOwnedWindowsProvider()
            .filter { $0.windowNumber > 0 }
            .map(RaisableSurface.owned)
        let surfaces = managedSurfaces + ownedSurfaces
        guard !surfaces.isEmpty else { return nil }

        let preferredWindowId = preferredWindowId(in: surfaces)
        let orderedSurfaces = surfaces.sorted { lhs, rhs in
            switch (lhs.windowId == preferredWindowId, rhs.windowId == preferredWindowId) {
            case (true, false):
                return false
            case (false, true):
                return true
            default:
                if lhs.sortPid != rhs.sortPid {
                    return lhs.sortPid < rhs.sortPid
                }
                return lhs.windowId < rhs.windowId
            }
        }

        var surfacesByBatchKey: [RaisableSurfaceBatchKey: [RaisableSurface]] = [:]
        var batchOrder: [RaisableSurfaceBatchKey] = []

        for surface in orderedSurfaces {
            if surfacesByBatchKey[surface.batchKey] == nil {
                batchOrder.append(surface.batchKey)
                surfacesByBatchKey[surface.batchKey] = []
            }
            surfacesByBatchKey[surface.batchKey, default: []].append(surface)
        }

        if let preferredBatchKey = orderedSurfaces.last?.batchKey,
           let focusIndex = batchOrder.firstIndex(of: preferredBatchKey)
        {
            let preferredBatchKey = batchOrder.remove(at: focusIndex)
            batchOrder.append(preferredBatchKey)
        }

        let batches = batchOrder.compactMap { surfacesByBatchKey[$0] }
        return FloatingWindowRaisePlan(batches: batches)
    }

    private func preferredWindowId(in surfaces: [RaisableSurface]) -> Int? {
        guard let controller else { return nil }

        let candidateWindowIds = Set(surfaces.map(\.windowId))
        let preferredOwnedWindowId = (NSApp?.orderedWindows ?? [])
            .map(\.windowNumber)
            .first(where: candidateWindowIds.contains)
            ?? [NSApp?.keyWindow, NSApp?.mainWindow]
            .compactMap { $0?.windowNumber }
            .first(where: candidateWindowIds.contains)
        if let preferredOwnedWindowId {
            return preferredOwnedWindowId
        }

        if let focusedToken = controller.workspaceManager.renderableFocusToken,
           candidateWindowIds.contains(focusedToken.windowId)
        {
            return focusedToken.windowId
        }

        guard let interactionWorkspaceId = controller.activeWorkspace()?.id else { return nil }
        let lastFloatingFocusedToken = controller.workspaceManager.lastFloatingFocusedToken(
            in: interactionWorkspaceId
        )
        guard let lastFloatingFocusedToken,
              candidateWindowIds.contains(lastFloatingFocusedToken.windowId)
        else {
            return nil
        }
        return lastFloatingFocusedToken.windowId
    }

    private func front(surface: RaisableSurface) {
        guard let controller else { return }

        switch surface {
        case let .managed(entry):
            controller.performWindowFronting(
                pid: entry.pid,
                windowId: entry.windowId,
                axRef: entry.axRef
            )
        case let .owned(window):
            frontOwnedWindow(window)
        }
    }
}
