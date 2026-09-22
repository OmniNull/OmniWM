// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func invalidateOverviewDeferredActionsForServiceStop() {
        windowActionHandlerStorage?.invalidateOverviewDeferredActionsForServiceStop()
    }

    func setPreventSleepEnabled(_ enabled: Bool) {
        if enabled {
            SleepPreventionManager.shared.preventSleep()
        } else {
            SleepPreventionManager.shared.allowSleep()
        }
    }

    func toggleHiddenBarPanel() {
        statusBarController?.dismissPanel()
        hiddenBarController.togglePanel(placement: hiddenBarPanelPlacement())
    }

    func hiddenBarPanelPlacement() -> HiddenBarPanelPlacement? {
        let monitors = workspaceManager.monitors
        guard let monitor = currentMouseLocation().monitorApproximation(in: monitors)
            ?? monitors.first(where: \.isMain) ?? monitors.first
        else { return nil }
        let resolved = settings.workspaceBar.resolved(for: monitor)
        let attachment = isWorkspaceBarVisible(on: monitor, resolved: resolved)
            ? workspaceBarManager.popupAttachment(on: monitor.id) : nil
        return HiddenBarPanelPlacement(
            attachment: attachment ?? PopupAttachment(
                anchor: CGPoint(x: monitor.frame.midX, y: monitor.visibleFrame.maxY)
            ),
            visibleFrame: monitor.visibleFrame
        )
    }

    func hiddenBarFallbackIconPlacements() -> [HiddenBarFallbackIconPlacement] {
        workspaceManager.monitors.map { monitor in
            let resolved = settings.workspaceBar.resolved(for: monitor)
            return HiddenBarFallbackIconPlacement(
                monitorId: monitor.id,
                frame: HiddenBarFallbackIconController.iconFrame(
                    monitor: monitor,
                    barVisible: isWorkspaceBarVisible(on: monitor, resolved: resolved),
                    barFrame: workspaceBarManager.primaryDisplayedFrame(on: monitor.id),
                    position: resolved.position
                )
            )
        }
    }

    func setHiddenBarEnabled(_ enabled: Bool) {
        hiddenBarController.setEnabled(enabled)
    }

    func updateHiddenBarSettings() {
        hiddenBarController.applySettings()
    }

    func detectMenuBarApps() async -> [DetectedMenuBarApp] {
        await hiddenBarController.detectMenuBarApps()
    }

    func hiddenBarDisplayName(for bundleID: String) -> String {
        hiddenBarController.displayName(for: bundleID)
    }

    func setQuakeTerminalEnabled(_ enabled: Bool) {
        if enabled {
            quakeTerminalController.setup()
        } else {
            quakeTerminalController.cleanup()
        }
    }

    func toggleQuakeTerminal() {
        guard settings.quakeTerminal.enabled else { return }
        quakeTerminalController.toggle()
    }

    func reapplyQuakeTerminalGeometryForMonitorChange() {
        guard settings.quakeTerminal.enabled else { return }
        quakeTerminalController.applyGeometryToVisibleWindow()
    }

    func reloadQuakeTerminalOpacity() {
        quakeTerminalController.reloadOpacityConfig()
    }

    func reloadQuakeTerminalBackgroundEffect() {
        quakeTerminalController.reloadOpacityConfig()
    }

    func reloadQuakeTerminalBackgroundBlur() {
        quakeTerminalController.reloadBackgroundBlur()
    }

    func toggleSystemStats() {
        let monitors = workspaceManager.monitors
        let target = SystemStatsPopupController.targetMonitor(
            pointer: NSEvent.mouseLocation.monitorApproximation(in: monitors),
            main: monitors.first(where: \.isMain),
            monitors: monitors
        ) { workspaceBarManager.statsAnchor(on: $0) != nil }
        guard let target else { return }
        toggleSystemStatsFromBar(on: target.id)
    }

    func toggleSystemStatsFromBar(on monitorId: Monitor.ID) {
        guard let monitor = workspaceManager.monitors.first(where: { $0.id == monitorId }),
              let attachment = workspaceBarManager.popupAttachment(on: monitorId, forStats: true)
        else {
            return
        }
        systemStatsPopupController.toggle(
            attachment: attachment,
            monitorId: monitorId,
            screenVisibleFrame: monitor.visibleFrame
        )
    }

    func statusMenuAttachment(from anchor: NSView) -> PopupAttachment? {
        guard let window = anchor.window else { return nil }
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var edge = PopupAttachment.Edge.below
        if anchor is HiddenBarFallbackIconButton,
           let monitor = workspaceManager.monitors.first(where: { $0.displayId == window.screen?.displayId })
        {
            let resolved = settings.workspaceBar.resolved(for: monitor)
            if isWorkspaceBarVisible(on: monitor, resolved: resolved) {
                edge = workspaceBarManager.popupAttachment(on: monitor.id)?.edge ?? .below
            }
        }
        return PopupAttachment(sourceFrame: frame, edge: edge)
    }

    func dismissSystemStatsPopup(anchoredTo monitorId: Monitor.ID) {
        systemStatsPopupController.dismissIfAnchored(to: monitorId)
    }

    func openCommandPalette() {
        commandPaletteController.toggle(wmController: self)
    }

    func clipboardPaletteItems() -> [ClipboardPaletteItem] {
        clipboardHistoryService.paletteItems
    }

    func setClipboardHistoryEnabled(_ enabled: Bool) {
        settings.clipboard.historyEnabled = enabled
        syncClipboardHistoryService()
    }

    func copyClipboardItem(id: UUID, plainText: Bool = false) async -> Bool {
        await clipboardHistoryService.copyItemToPasteboard(id: id, plainText: plainText)
    }

    func clipboardItemPreview(id: UUID) async -> ClipboardPalettePreview? {
        await clipboardHistoryService.preview(id: id)
    }

    func setClipboardItemPinned(_ pinned: Bool, id: UUID) async -> [ClipboardPaletteItem] {
        await clipboardHistoryService.setPinned(pinned, id: id)
    }

    func deleteClipboardItem(id: UUID) async -> [ClipboardPaletteItem] {
        await clipboardHistoryService.deleteItem(id: id)
    }

    func clearClipboardHistory() async throws -> [ClipboardPaletteItem] {
        try await clipboardHistoryService.clearHistory()
    }

    func syncClipboardHistoryService() {
        clipboardHistoryService.updateConfiguration(clipboardHistoryConfiguration())
    }

    func openSponsorsWindow() {
        sponsorsWindowController.show()
    }

    func openMenuAnywhere() {
        windowActionHandler.openMenuAnywhere()
    }

    @discardableResult
    func navigateToCommandPaletteWindow(_ handle: WindowHandle) -> Bool {
        windowActionHandler.navigateToExplicitlySelectedWindow(handle: handle)
    }

    func summonCommandPaletteWindowRight(
        _ handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) {
        windowActionHandler.summonWindowRight(
            handle: handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }

    func toggleOverview() {
        windowActionHandler.toggleOverview()
    }

    func handleOverviewHotkey(_ invocation: HotkeyInvocation) -> OverviewHotkeyDisposition {
        windowActionHandlerStorage?.handleOverviewHotkey(invocation) ?? .inactive
    }

    func updateOverviewSettings() {
        windowActionHandlerStorage?.updateOverviewSettings()
    }

    func isOverviewOpen() -> Bool {
        windowActionHandler.isOverviewOpen()
    }
}
