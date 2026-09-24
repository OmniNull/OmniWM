// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewWindowFacts {
    private weak var wmController: WMController?
    private let environment: OverviewEnvironment

    init(wmController: WMController, environment: OverviewEnvironment) {
        self.wmController = wmController
        self.environment = environment
    }

    func windowFrame(_ entry: WindowState) -> CGRect? {
        environment.windowFrame(entry)
    }

    func makeOverviewWindowData(
        for entry: WindowState,
        preferredFrame: CGRect?,
        appInfoCache: AppInfoCache
    ) -> OverviewWindowLayoutData {
        let title = environment.windowTitle(entry) ?? ""
        let appInfo = appInfoCache.info(for: entry.pid)
        return OverviewWindowLayoutData(
            token: entry.token,
            workspaceId: entry.workspaceId,
            title: title.isEmpty ? (appInfo?.name ?? String(localized: "Window")) : title,
            appName: appInfo?.name ?? String(localized: "Unknown"),
            appIcon: appInfo?.icon,
            frame: preferredFrame ?? environment.windowFrame(entry) ?? .zero,
            isNativeFullscreen: entry.layoutReason == .nativeFullscreen,
            floatingPreviewFrame: floatingPreviewFrame(for: entry)
        )
    }

    func floatingPreviewFrame(for entry: WindowState) -> CGRect? {
        guard entry.mode == .floating else { return nil }
        return entry.desiredState.floatingFrame ?? entry.floatingState?.lastFrame
    }

    func visibleManagedEntry(for handle: WindowHandle) -> WindowState? {
        guard let workspaceManager = wmController?.workspaceManager,
              workspaceManager.handle(for: handle.id) === handle,
              let entry = workspaceManager.entry(for: handle),
              isOverviewEligible(entry, workspaceManager: workspaceManager)
        else {
            return nil
        }
        return entry
    }

    func isOverviewEligible(
        _ entry: WindowState,
        workspaceManager: WorkspaceManager
    ) -> Bool {
        !workspaceManager.isWindowSuppressedByMacOS(entry.token)
    }

    func isStructurallyMutable(_ entry: WindowState) -> Bool {
        entry.layoutReason == .standard
    }

    func cachedNiriSnapshot(
        _ snapshot: NiriOverviewWorkspaceSnapshot
    ) -> NiriOverviewWorkspaceSnapshot? {
        let columns = snapshot.columns.compactMap { column -> NiriOverviewColumnSnapshot? in
            let tiles = column.tiles.filter { tile in
                guard let workspaceManager = wmController?.workspaceManager,
                      let entry = workspaceManager.entry(for: tile.token)
                else {
                    return false
                }
                return entry.workspaceId == snapshot.workspaceId
                    && isOverviewEligible(entry, workspaceManager: workspaceManager)
            }
            guard !tiles.isEmpty else { return nil }
            return NiriOverviewColumnSnapshot(
                index: column.index, widthWeight: column.widthWeight, preferredWidth: column.preferredWidth,
                tiles: tiles, stripFrame: column.stripFrame, isTabbed: column.isTabbed, activeToken: column.activeToken
            )
        }
        guard !columns.isEmpty else { return nil }
        return NiriOverviewWorkspaceSnapshot(workspaceId: snapshot.workspaceId, columns: columns, strip: snapshot.strip)
    }

    func isNiriLayout(workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let wmController else { return false }
        guard let name = wmController.workspaceManager.descriptor(for: workspaceId)?.name else { return false }
        let layoutType = wmController.settings.workspaces.layoutType(for: name)
        return layoutType != .dwindle
    }
}
