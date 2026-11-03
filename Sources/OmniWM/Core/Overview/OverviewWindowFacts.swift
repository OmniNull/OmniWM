// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore

@MainActor
final class OverviewWindowFacts {
    private weak var wmController: WMController?
    private let environment: OverviewEnvironment

    init(wmController: WMController, environment: OverviewEnvironment) {
        self.wmController = wmController
        self.environment = environment
    }

    func windowFrame(_ entry: WindowState) -> CGRect? {
        guard entry.axRef != nil else { return wmController?.shellAppWindowManager.frame(for: entry.token) }
        return environment.windowFrame(entry)
    }

    func makeOverviewWindowData(
        for entry: WindowState,
        preferredFrame: CGRect?,
        appInfoCache: AppInfoCache
    ) -> OverviewWindowLayoutData {
        let presentation = appInfoCache.presentation(for: entry, title: environment.windowTitle(entry))
        let title = presentationTitle(for: entry, fallback: presentation.title ?? "")
        return OverviewWindowLayoutData(
            token: entry.token,
            workspaceId: entry.workspaceId,
            title: title.isEmpty ? (presentation.name ?? String(localized: "Window")) : title,
            appName: presentation.name ?? String(localized: "Unknown"),
            appIcon: presentation.icon,
            frame: preferredFrame ?? windowFrame(entry) ?? .zero,
            isNativeFullscreen: entry.layoutReason == .nativeFullscreen,
            floatingPreviewFrame: floatingPreviewFrame(for: entry)
        )
    }

    func presentationTitle(for entry: WindowState, fallback: String) -> String {
        guard let metadata = entry.target.hostedMetadata else { return fallback }
        guard metadata.role == .main,
              wmController?.shellAppWindowManager.activeSheet(for: entry.token) != nil else { return metadata.title }
        return metadata.title + " — " + String(localized: "Dialog open")
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
        entry.target.hostedMetadata?.role.isSheet != true
            && !workspaceManager.isWindowSuppressedByMacOS(entry.token)
    }

    func isStructurallyMutable(_ entry: WindowState) -> Bool {
        entry.layoutReason == .standard && entry.target.hostedMetadata?.role.parent == nil
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
